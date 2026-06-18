defmodule PropertyDamage.Linearization do
  @moduledoc """
  Linearization checking for parallel execution results.

  When commands execute in parallel branches, the Linearization module verifies
  that the observed results can be explained by some sequential (linear) ordering
  of the commands.

  ## What is Linearizability?

  A parallel execution is linearizable if there exists a sequential ordering of
  the commands such that:

  1. The ordering respects the happens-before relationship within each branch
  2. Each command's observed events are consistent with what the model predicts
     for the state at that command's position in the ordering

  If no such ordering exists, the system has exhibited non-linearizable behavior,
  which typically indicates a race condition or consistency bug.

  ## Algorithm

  Given branch execution results:

  1. Generate interleavings (orderings that preserve intra-branch order)
  2. For each interleaving, walk the commands in order, asking the model's
     simulator what events each command SHOULD produce given the model state
     at that point, and compare against the events the SUT actually produced
     for that command
  3. Advance the model state with the OBSERVED events and, at that same
     position, run the model's synchronous (`@trigger`) assertions against the
     advanced state
  4. Advance and continue
  5. If any interleaving is fully consistent (events compatible AND all
     triggered assertions hold at every position), the execution is linearizable

  ## Soundness invariant (why this module exists)

  > A concurrent/branching execution is a failure ONLY if NO single ordering of
  > the branches can simultaneously (a) reproduce every command's observed
  > events and (b) satisfy every triggered synchronous assertion at that
  > command's position. The observed events and the model-state prediction an
  > assertion runs against MUST come from the SAME candidate ordering.

  This invariant is the antidote to a soundness bug that over-reported races:
  the executor used to run each branch's synchronous assertions against that
  branch's *forked* projection state. A fork is a partial view: it sees the
  prefix plus its own branch, never the concurrently-executing sibling
  branches' effects. So a read in one branch could observe a value written by a
  sibling's write (the real interleaving) while the reader's model state never
  recorded that write, firing a spurious assertion. `Put k v ∥ Get k` was
  flagged even though Put-then-Get is a perfectly legal serialization. The fix:
  the executor disables those unsound per-branch assertions, and assertion
  checking moves HERE, where it is evaluated against observed events and the
  model prediction drawn from one consistent ordering. `check/5` therefore
  refutes an execution only when every ordering fails, and its refutation
  carries the specific assertion (when one is the cause) so the report is as
  precise as the old per-branch path was, without its false positives.

  ## Verification strength

  The check is exactly as strong as the model's simulator: predicted event
  fields that are `nil`, unresolved refs, or external markers are treated as
  wildcards, and commands the simulator does not predict (returns `[]`) are
  unconstrained. A model without a `simulator/0` cannot be verified at all;
  `check/5` then returns `{:indeterminate, 0}` rather than fabricating a
  verdict.

  ## Complexity

  The number of interleavings grows multinomially with branch count/length
  (see `linearization_count/1`). `check/5` examines at most `:max_candidates`
  interleavings (default 1000); if none is consistent but the candidate space
  was not exhausted, it returns `{:indeterminate, checked}` instead of
  claiming a race.

  ## Usage

      case Linearization.check(branches, branch_events, projections, model,
             start_index: 3) do
        {:ok, linearization} -> # consistent ordering found
        :no_linearization    -> # exhaustively refuted: race condition
        {:indeterminate, n}  -> # cannot verify (no simulator / cap reached)
      end
  """

  alias PropertyDamage.{External, Placeholder, Sequence}

  @default_max_candidates 1000

  @type branch_events :: %{non_neg_integer() => [PropertyDamage.EventLog.Entry.t()]}
  @type projection_state :: map()
  @type tagged_command ::
          {branch_id :: non_neg_integer(), position :: non_neg_integer(), struct()}
  @type linearization :: [tagged_command()]

  @doc """
  Check if branch execution results are linearizable.

  ## Parameters

  - `branch_commands` - List of command lists, one per branch (commands should
    have refs resolved so simulator predictions see concrete values)
  - `branch_events` - Map of branch_id to CHRONOLOGICAL event log entries
  - `projections` - Initial projection states (from prefix execution),
    as a `%{projection_module => state}` map
  - `model` - Model module (verification requires `simulator/0`)
  - `opts`:
    - `:start_index` - The executor command index of each branch's first
      command (default 0); used to translate entry command indices into
      branch positions
    - `:max_candidates` - Cap on interleavings examined (default 1000)

  ## Options

  - `:counters` - Assertion counters carried from the prefix, so `every: N`
    triggers continue counting across the branch region (default fresh zeros)

  ## Returns

  - `{:ok, linearization}` - A consistent sequential ordering (tagged commands)
  - `{:no_linearization, refutation}` - All interleavings examined and refuted.
    `refutation` is `nil` when every ordering failed purely on event
    incompatibility (a classic race, e.g. a lost update), or a map
    `%{branch_id:, position:, command:, check_name:, reason:}` describing the
    synchronous assertion that failed in the furthest-progressing ordering, so
    the executor can report it with the same precision as a linear failure.
  - `{:indeterminate, checked}` - Verification impossible (no simulator) or
    candidate cap reached without success
  """
  @type refutation ::
          nil
          | %{
              branch_id: non_neg_integer(),
              position: non_neg_integer(),
              command: struct(),
              check_name: atom(),
              reason: term()
            }
  @spec check([[struct()]], branch_events(), projection_state(), module(), keyword()) ::
          {:ok, linearization()}
          | {:no_linearization, refutation()}
          | {:indeterminate, non_neg_integer()}
  def check(branch_commands, branch_events, projections, model, opts \\ []) do
    start_index = Keyword.get(opts, :start_index, 0)
    max_candidates = Keyword.get(opts, :max_candidates, @default_max_candidates)
    counters = Keyword.get(opts, :counters, fresh_counters())

    if simulator(model) == nil do
      {:indeterminate, 0}
    else
      observed = observed_events_by_position(branch_events, start_index)
      tagged_branches = tag_branches(branch_commands)
      total = linearization_count(branch_commands)

      result =
        tagged_branches
        |> interleavings()
        |> Stream.take(max_candidates)
        |> Enum.reduce_while({0, nil}, fn candidate, {checked, best} ->
          case verify_candidate(candidate, observed, projections, model, counters) do
            :ok ->
              {:halt, {:ok, candidate}}

            {:refuted, depth, refutation} ->
              {:cont, {checked + 1, best_refutation(best, depth, refutation)}}
          end
        end)

      case result do
        {:ok, candidate} -> {:ok, candidate}
        {checked, best} when checked >= total -> {:no_linearization, refutation_of(best)}
        {checked, _best} -> {:indeterminate, checked}
      end
    end
  end

  # Keep the refutation that progressed furthest through its ordering; on a tie,
  # prefer an assertion-based refutation (non-nil) over a bare event mismatch,
  # since it carries an actionable check name for the report.
  defp best_refutation(nil, depth, refutation), do: {depth, refutation}

  defp best_refutation({best_depth, best_ref} = best, depth, refutation) do
    cond do
      depth > best_depth -> {depth, refutation}
      depth == best_depth and is_nil(best_ref) and not is_nil(refutation) -> {depth, refutation}
      true -> best
    end
  end

  defp refutation_of(nil), do: nil
  defp refutation_of({_depth, refutation}), do: refutation

  defp fresh_counters, do: %{step: 0, command: 0, event: 0}

  @doc """
  Verify a specific tagged linearization against observed per-command events.

  Walks the commands in the given order; for each, the simulator's predicted
  events (given the model state at that point) must be compatible with the
  events observed for that command, and the state advances with the observed
  events. Returns `true` if every command is consistent.
  """
  @spec verify(
          linearization(),
          %{{non_neg_integer(), non_neg_integer()} => [struct()]},
          projection_state(),
          module(),
          keyword()
        ) ::
          boolean()
  def verify(linearization, observed, initial_projections, model, opts \\ []) do
    counters = Keyword.get(opts, :counters, fresh_counters())
    verify_candidate(linearization, observed, initial_projections, model, counters) == :ok
  end

  # The single per-candidate decision procedure that enforces the soundness
  # invariant: at each command position the OBSERVED events and the model
  # prediction (and the assertions run against it) all come from THIS ordering.
  #
  # Returns `:ok` when the whole ordering is consistent, or
  # `{:refuted, progressed, refutation}` where `progressed` is how many commands
  # passed before refutation (used to pick the most informative failure across
  # candidates) and `refutation` is `nil` for an event mismatch or a detail map
  # for a failed synchronous assertion.
  @spec verify_candidate(
          linearization(),
          %{{non_neg_integer(), non_neg_integer()} => [struct()]},
          projection_state(),
          module(),
          map()
        ) :: :ok | {:refuted, non_neg_integer(), refutation()}
  def verify_candidate(linearization, observed, initial_projections, model, counters) do
    sim = simulator(model)
    sequence_projection = model.command_sequence_projection()
    all_projections = [sequence_projection | model_assertion_projections(model)]

    linearization
    |> Enum.reduce_while({initial_projections, counters, 0}, fn {branch_id, position, command},
                                                                {projections, counters, depth} ->
      model_state = Map.get(projections, sequence_projection)
      expected = sim.simulate(command, model_state)
      observed_events = Map.get(observed, {branch_id, position}, [])

      if events_compatible?(expected, observed_events) do
        advanced = advance(projections, command, observed_events)

        case run_position_assertions(
               advanced,
               all_projections,
               command,
               observed_events,
               counters
             ) do
          {:ok, new_counters} ->
            {:cont, {advanced, new_counters, depth + 1}}

          {:refuted, check_name, reason} ->
            refutation = %{
              branch_id: branch_id,
              position: position,
              command: command,
              check_name: check_name,
              reason: reason
            }

            {:halt, {:refuted, depth, refutation}}
        end
      else
        # No ordering can reproduce this command's observed events from the
        # state THIS ordering reached: an event-level race (e.g. a lost
        # update). Refuted with no assertion detail.
        {:halt, {:refuted, depth, nil}}
      end
    end)
    |> case do
      {:refuted, _depth, _refutation} = refuted -> refuted
      {_projections, _counters, _depth} -> :ok
    end
  end

  defp model_assertion_projections(model) do
    if Code.ensure_loaded?(model) and function_exported?(model, :assertion_projections, 0) do
      model.assertion_projections()
    else
      []
    end
  end

  # Run, against the already-advanced projection state, the synchronous
  # assertions triggered by this command and then by each of its observed
  # events, mirroring the executor's run_checks counter/trigger scheme so a
  # branch position is judged exactly as the equivalent linear position would
  # be. Returns {:ok, counters} or {:refuted, check_name, reason}; `reason`
  # is the `{:assertion_failed, name, {exception, stacktrace}}` shape the
  # executor's linear path produces, so downstream reporting is identical.
  defp run_position_assertions(projections, all_projections, command, observed_events, counters) do
    command_module = command.__struct__

    counters =
      counters
      |> Map.update(:step, 1, &(&1 + 1))
      |> Map.update(:command, 1, &(&1 + 1))
      |> Map.update(command_module, 1, &(&1 + 1))

    cmd_ctx = %{step_type: :command, module: command_module, command_or_event: command}

    case run_sync_assertions(projections, all_projections, cmd_ctx, counters) do
      {:refuted, _, _} = refuted ->
        refuted

      :ok ->
        Enum.reduce_while(observed_events, {:ok, counters}, fn event, {:ok, counters} ->
          event_module = event.__struct__

          counters =
            counters
            |> Map.update(:step, 1, &(&1 + 1))
            |> Map.update(:event, 1, &(&1 + 1))
            |> Map.update(event_module, 1, &(&1 + 1))

          event_ctx = %{step_type: :event, module: event_module, command_or_event: event}

          case run_sync_assertions(projections, all_projections, event_ctx, counters) do
            :ok -> {:cont, {:ok, counters}}
            {:refuted, _, _} = refuted -> {:halt, refuted}
          end
        end)
    end
  end

  defp run_sync_assertions(projections, all_projections, ctx, counters) do
    Enum.reduce_while(all_projections, :ok, fn projection, :ok ->
      state = Map.get(projections, projection)

      assertions =
        if Code.ensure_loaded?(projection) and function_exported?(projection, :__assertions__, 0) do
          Enum.filter(projection.__assertions__(), &(&1.type == :synchronous))
        else
          []
        end

      case run_projection_sync_assertions(projection, state, assertions, ctx, counters) do
        :ok -> {:cont, :ok}
        {:refuted, _, _} = refuted -> {:halt, refuted}
      end
    end)
  end

  defp run_projection_sync_assertions(projection, state, assertions, ctx, counters) do
    alias PropertyDamage.Model.Projection

    Enum.reduce_while(assertions, :ok, fn assertion, :ok ->
      if Projection.should_run?(assertion.trigger, ctx.step_type, ctx.module, counters) do
        try do
          apply(projection, assertion.function_name, [state, ctx.command_or_event])
          {:cont, :ok}
        rescue
          e ->
            reason = {:assertion_failed, assertion.name, {e, __STACKTRACE__}}
            {:halt, {:refuted, assertion.name, reason}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  @doc """
  Generate all valid linearizations of branch commands (untagged).

  Preserves the order within each branch while exploring all possible
  interleavings between branches. Prefer `check/5` for verification; this
  remains for diagnostics and tooling.
  """
  @spec generate_linearizations([[struct()]]) :: [[struct()]]
  def generate_linearizations([]), do: [[]]
  def generate_linearizations([single]), do: [single]

  def generate_linearizations(branches) do
    seq = Sequence.branching([], branches, [])

    seq
    |> Sequence.linearizations()
    |> Enum.map(&Sequence.to_list/1)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp simulator(model) do
    # Ensure the module is loaded before probing it: function_exported?/3
    # returns false for a not-yet-loaded module (it does not trigger loading),
    # which would silently make a model appear to have no simulator and turn a
    # decidable check into {:indeterminate, 0}.
    if Code.ensure_loaded?(model) and function_exported?(model, :simulator, 0),
      do: model.simulator(),
      else: nil
  end

  @doc false
  # Build %{ {branch_id, position} => [event] } from chronological entries.
  # Entries carry the executor command index, which starts at start_index
  # for every branch. Public for the Executor's merge replay.
  @spec observed_events_by_position(branch_events(), integer()) ::
          %{{non_neg_integer(), non_neg_integer()} => [struct()]}
  def observed_events_by_position(branch_events, start_index) do
    for {branch_id, entries} <- branch_events,
        entry <- entries,
        entry.source == :command,
        reduce: %{} do
      acc ->
        position = entry.command_index - start_index
        Map.update(acc, {branch_id, position}, [entry.event], &(&1 ++ [entry.event]))
    end
  end

  defp tag_branches(branch_commands) do
    branch_commands
    |> Enum.with_index()
    |> Enum.map(fn {commands, branch_id} ->
      commands
      |> Enum.with_index()
      |> Enum.map(fn {command, position} -> {branch_id, position, command} end)
    end)
  end

  # Lazy stream of all interleavings of the tagged branches, preserving
  # intra-branch order.
  defp interleavings(branches) do
    branches = Enum.reject(branches, &(&1 == []))

    case branches do
      [] ->
        Stream.map([nil], fn _ -> [] end)

      branches ->
        Stream.resource(
          fn -> [{[], branches}] end,
          fn
            [] ->
              {:halt, nil}

            [{acc, remaining} | stack] ->
              if Enum.all?(remaining, &(&1 == [])) do
                {[Enum.reverse(acc)], stack}
              else
                next =
                  remaining
                  |> Enum.with_index()
                  |> Enum.filter(fn {branch, _} -> branch != [] end)
                  |> Enum.map(fn {[head | tail], idx} ->
                    {[head | acc], List.replace_at(remaining, idx, tail)}
                  end)

                {[], next ++ stack}
              end
          end,
          fn _ -> :ok end
        )
    end
  end

  # Expected events are compatible with observed events when every expected
  # event has a matching observed event (order-preserving, leftover observed
  # events allowed). Predicted fields that are nil, refs, unresolved, or
  # external markers act as wildcards.
  defp events_compatible?(expected, observed) do
    Enum.reduce_while(expected, observed, fn exp, remaining ->
      case consume_match(exp, remaining, []) do
        {:ok, rest} -> {:cont, rest}
        :no_match -> {:halt, :incompatible}
      end
    end) != :incompatible
  end

  defp consume_match(_expected, [], _skipped), do: :no_match

  defp consume_match(expected, [obs | rest], skipped) do
    if event_matches?(expected, obs) do
      {:ok, Enum.reverse(skipped) ++ rest}
    else
      consume_match(expected, rest, [obs | skipped])
    end
  end

  defp event_matches?(%mod{} = expected, %mod{} = observed) do
    expected
    |> Map.from_struct()
    |> Enum.all?(fn {field, exp_value} ->
      wildcard?(exp_value) or exp_value == Map.get(observed, field)
    end)
  end

  defp event_matches?(_expected, _observed), do: false

  defp wildcard?(nil), do: true
  defp wildcard?(%Placeholder{}), do: true
  defp wildcard?(value), do: External.external?(value)

  # Advance every projection's state with the command and its observed events
  defp advance(projections, command, observed_events) do
    Enum.reduce([command | observed_events], projections, fn item, acc ->
      Map.new(acc, fn {proj_module, state} ->
        {proj_module, proj_module.apply(state, item)}
      end)
    end)
  end

  @doc """
  Count the number of possible linearizations for given branches.

  Useful for estimating complexity before attempting verification.

  ## Formula

  For branches of lengths n1, n2, ..., nk, the count is:
  (n1 + n2 + ... + nk)! / (n1! * n2! * ... * nk!)
  """
  @spec linearization_count([[struct()]]) :: non_neg_integer()
  def linearization_count([]), do: 1

  def linearization_count(branches) do
    lengths = Enum.map(branches, &length/1)
    total = Enum.sum(lengths)

    # Multinomial coefficient
    numerator = factorial(total)
    denominator = Enum.reduce(lengths, 1, fn n, acc -> acc * factorial(n) end)

    div(numerator, denominator)
  end

  defp factorial(0), do: 1
  defp factorial(n) when n > 0, do: n * factorial(n - 1)

  @doc """
  Check if linearization checking is feasible for given branches.

  Returns `:ok` if the number of linearizations is manageable,
  or `{:warning, count}` if it may be slow.
  """
  @spec feasibility([[struct()]]) :: :ok | {:warning, non_neg_integer()}
  def feasibility(branches) do
    count = linearization_count(branches)

    if count <= @default_max_candidates do
      :ok
    else
      {:warning, count}
    end
  end
end
