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
  3. Advance the model state with the OBSERVED events and continue
  4. If any interleaving is fully consistent, the execution is linearizable

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

  alias PropertyDamage.{External, Placeholder, Ref, Sequence}
  alias PropertyDamage.Ref.Unresolved

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

  ## Returns

  - `{:ok, linearization}` - A consistent sequential ordering (tagged commands)
  - `:no_linearization` - All interleavings examined and refuted: race detected
  - `{:indeterminate, checked}` - Verification impossible (no simulator) or
    candidate cap reached without success
  """
  @spec check([[struct()]], branch_events(), projection_state(), module(), keyword()) ::
          {:ok, linearization()} | :no_linearization | {:indeterminate, non_neg_integer()}
  def check(branch_commands, branch_events, projections, model, opts \\ []) do
    start_index = Keyword.get(opts, :start_index, 0)
    max_candidates = Keyword.get(opts, :max_candidates, @default_max_candidates)

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
        |> Enum.reduce_while(0, fn candidate, checked ->
          if verify(candidate, observed, projections, model) do
            {:halt, {:ok, candidate}}
          else
            {:cont, checked + 1}
          end
        end)

      case result do
        {:ok, candidate} -> {:ok, candidate}
        checked when checked >= total -> :no_linearization
        checked -> {:indeterminate, checked}
      end
    end
  end

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
          module()
        ) ::
          boolean()
  def verify(linearization, observed, initial_projections, model) do
    sim = simulator(model)
    sequence_projection = model.command_sequence_projection()

    linearization
    |> Enum.reduce_while(initial_projections, fn {branch_id, position, command}, projections ->
      model_state = Map.get(projections, sequence_projection)
      expected = sim.simulate(command, model_state)
      observed_events = Map.get(observed, {branch_id, position}, [])

      if events_compatible?(expected, observed_events) do
        {:cont, advance(projections, command, observed_events)}
      else
        {:halt, :refuted}
      end
    end)
    |> case do
      :refuted -> false
      _projections -> true
    end
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
    if function_exported?(model, :simulator, 0), do: model.simulator(), else: nil
  end

  @doc false
  # Build %{ {branch_id, position} => [event] } from chronological entries.
  # Entries carry the executor command index, which starts at start_index
  # for every branch. Public for the Executor's merge replay.
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
  defp wildcard?(%Ref{}), do: true
  defp wildcard?(%Placeholder{}), do: true
  defp wildcard?(Unresolved), do: true
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
