defmodule PropertyDamage.Shrinker do
  @moduledoc """
  Shrinks failing command sequences to minimal reproductions.

  When a property test fails, the Shrinker attempts to find the smallest
  sequence that still reproduces the failure. This makes debugging easier
  by removing irrelevant commands and simplifying arguments.

  ## Failure Equivalence

  The shrinker preserves failure equivalence - a shrunk sequence is only
  accepted if it produces the **same type of failure** as the original.
  This ensures the minimal reproduction demonstrates the same bug, not
  a different one.

  The accepted candidate's failure must match the original on three dimensions,
  compared through its failure *signature* (`PropertyDamage.Failure.signature/2`):
  - Same failure kind (`:check_failed`, `:idempotency_violation`, `:diverged`, etc.)
  - Same name (`PropertyDamage.Failure.name/1`): the check name for an invariant
    violation, and for a divergence or a failure to converge the key of the
    `@compare` observation that disagreed, `{projection, function}`
  - Same target: the index of the target the failure happened in (`0` with one
    target). A candidate that fails in another target, or with another kind, is
    a different failure and is rejected.

  When several targets fail in one run (a target other than the reference
  whose adapter failed leaves the run and the others go on), a candidate is
  judged by its primary failure only, the first in root order, then target
  order (`PropertyDamage.Scheduler`). Its other failures take no part: a
  candidate whose other failures differ from the original's, or that has none,
  is accepted when its primary failure matches.

  For a divergence the name matters as much as the target. Suppose one target
  computes label counts wrongly, and a `@compare` function `labels/2` catches
  it. A candidate that drops a command the labels depend on may make another
  observation, `repos/2`, disagree first, for an unrelated reason. That
  candidate diverges in the same target, but under another observation, so it
  is another failure and the shrinker rejects it.

  ## Invalid Candidates

  Before a candidate runs, the shrinker validates it against the model: it folds
  the candidate through the model's command-sequence projection and simulator
  and checks each command's `when:` predicate. A candidate whose validation
  returns false, or raises, is invalid and is never run, so it can never be a
  counterexample. Shrinking makes up sequences the generator never would, such
  as a command whose argument was halved to 0, or a command that references an
  entity whose creating command was removed. Model code may raise on such a
  sequence. The raise says the model cannot simulate the candidate, not that
  the system under test is wrong, so treating it as a failure would report a
  bug the system does not have. Validation starts from the state the
  sequence's setup commands leave (`c:PropertyDamage.Model.setup_each/0`), as
  generation does, so a root that needs fixture state is valid.

  An attempt whose setup failed in any target (the oracle answers
  `:setup_failed`: an adapter's `setup/1`, a setup command, a check on a
  setup command's event, or the completion rule) is not a counterexample
  either. It says nothing
  about the roots, so the candidate is rejected whatever the original
  failure, and the attempt counts against the budget.

  A further property also holds: the failure occurs at the **same or an earlier
  command index** (the failing root) than in the original. The shrinker
  checks it: a candidate whose failure happens at a root generated after the
  current failing root is not adopted, whatever its signature. It also holds
  structurally, because the shrinker first truncates the sequence at the
  failure point (`Enum.take(commands, failed_at_index + 1)`), so every later
  candidate is a subset of that prefix.

  ## Determinism

  Shrinking is fully deterministic given:
  - The same seed (which determines the command sequence)
  - The same initial failure
  - Deterministic SUT behavior

  This ensures reproducibility: the same seed always produces the same
  shrunk sequence, making CI failures reliably reproducible locally.

  ## Shrink Cycle

  A sequence is first truncated after the failing root. Then the
  shrinker runs four phases in order, each on what the previous phase left,
  and repeats the cycle until a whole cycle adopts no candidate or the budget
  (`PropertyDamage.Shrinker.Config`) is spent:

  1. **Drop roots**: remove roots grouped by dependency depth (hierarchical
     shrink), then each remaining root on its own (linear shrink)
  2. **Collapse the reference's expansions** toward the root itself (see
     `shrink/2`, "Expansions")
  3. **Collapse the other targets' expansions** onto the reference's
  4. **Simplify arguments** (`shrink_arguments`, on by default): the roots'
     arguments, then the fields of every leaf that its generator gave

  Argument simplification:

  - Integers shrink toward 0
  - Strings shrink toward empty
  - Lists shrink toward empty
  - Placeholders are never shrunk (would break dependencies)

  ## Configuration

  See `PropertyDamage.Shrinker.Config` for tuning options:

  - `granularity_threshold` - When to switch from hierarchical to linear
  - `max_iterations` - Limit total shrink attempts
  - `max_time_ms` - Time budget for shrinking
  - `shrink_arguments` - Whether to attempt argument shrinking

  ## Usage

  ```elixir
  # After a failure at index 5 in the first target
  reason = PropertyDamage.Failure.check_failed(:balance_invariant, "...")
  targets = [%PropertyDamage.Target{adapter: MyAdapter, name: "MyAdapter", index: 0}]

  oracle =
    PropertyDamage.Runner.shrink_oracle(
      %PropertyDamage.Runner.Context{model: MyModel, targets: targets, seed: run_seed},
      PropertyDamage.Failure.signature(reason, 0)
    )

  shrunk = Shrinker.shrink(
    sequence,
    failed_at_index: 5,
    failure_reason: reason,
    variant_index: 0,
    model: MyModel,
    targets: targets,
    oracle: oracle,
    rng_seed: run_seed,
    config: config
  )
  ```
  """

  alias PropertyDamage.{
    Expansion,
    Failure,
    Generator,
    Model,
    Placeholder,
    PlaceholderRegistry,
    ReplayArtifact,
    Sequence,
    Settle
  }

  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Sequence.Validator

  alias PropertyDamage.Shrinker.{Config, Graph, Outcome}

  @typedoc """
  Result of shrinking.
  """
  @type shrink_result :: %{
          sequence: Sequence.t(),
          expansion: map() | nil,
          iterations: non_neg_integer(),
          time_ms: non_neg_integer(),
          cycles: non_neg_integer(),
          stop: stop_reason()
        }

  @typedoc """
  Why the shrinker stopped: `:done` when it finished inside its budget,
  `:max_iterations` or `:max_time` when that budget ran out first. When both
  ran out, or the last cycle ended exactly at the iteration cap,
  `:max_iterations` wins; a budget stop does not claim minimality.
  """
  @type stop_reason :: :done | :max_iterations | :max_time

  @doc """
  Check if two failures are equivalent.

  Each failure is given as `{reason, variant_index}`. Two failures are
  equivalent if they have the same kind, (for check failures) the same check
  name, and happened in the same target.
  """
  @spec equivalent_failures?({term(), non_neg_integer()}, {term(), non_neg_integer()}) ::
          boolean()
  def equivalent_failures?({reason1, index1}, {reason2, index2}) do
    Failure.signature(reason1, index1) == Failure.signature(reason2, index2)
  end

  @doc """
  Shrink a failing command sequence.

  The shrinker does not run a candidate itself. It hands the candidate's
  plan (`t:PropertyDamage.Runner.plan/0`) and a fresh mint epoch to the
  `:oracle`, and adopts the candidate when the oracle's
  `PropertyDamage.Shrinker.Outcome` is the original failure: `:failed`, with
  the original signature, at the same or an earlier root. The oracle
  `PropertyDamage.Runner.shrink_oracle/2` builds makes every candidate a
  fresh execution of the run's targets: it runs the plan through
  `PropertyDamage.Runner.execute/2` with every target, which sets each target
  up and tears it down again, so nothing (an event queue, a mock registry,
  adapter state) carries over from one attempt to the next. A candidate the
  shrinker rejects before it runs (see "Invalid Candidates" in the moduledoc,
  and "Expansions" below) never reaches the oracle, and still counts as an
  attempt.

  The setup commands are never part of a candidate: no strategy removes,
  reorders or simplifies one, and every attempt executes the sequence's setup
  commands, with the arguments they were generated with, before the candidate's
  roots. The teardown commands are generated again for every candidate
  (`PropertyDamage.Generator.teardown_commands/4`, with `:rng_seed` as the run
  seed), so a teardown command whose `overrides:` names something a root
  created names what this candidate's roots create. The shrunk sequence
  carries the setup commands and its own teardown commands.

  ## Expansions

  For a model with `c:PropertyDamage.Model.expansions/0`, a candidate is a
  list of roots plus what each target runs at each of them. `:expansion`
  carries every target's choices, keyed by the stable id of each root
  (`:root_ids`). No attempt draws an expansion again: each attempt realizes
  the entry each target carries at each surviving root against the
  candidate's simulated state, from the seed that target's leaves came
  from. A root whose arguments were simplified realizes its leaves from the
  simplified root through the same entry. The shrinker never deletes or
  reorders a leaf on its own.

  Two phases of every cycle, between dropping roots and simplifying
  arguments, change what the targets run, root by root, in order:

    * The reference (the first target, when it runs `expansion: :random`)
      collapses toward the root itself. The shrinker tries the identity
      first: the root alone, under its entry key when the function lists the
      root alone, else recorded as `:identity` ("identity, by shrinking").
      Then it tries each earlier entry of the root's list, in order, with its
      leaves generated from the reference's own seed for that root. It keeps the
      first that still fails. A `:reference` target copies the reference in
      every candidate, so it moves with it. A `:random` target that copied
      the reference's choice at that root keeps, in these candidates, the
      entry and the commands it runs there now, so the reference can reach
      the identity alone when the failure is in that copy.
    * Each other `expansion: :random` target collapses onto the reference's
      choice: the same entry and the reference's commands, copied in every
      later candidate, so a later simplification of the reference's leaves
      is copied too. The shrinker keeps the copy when the failure survives.

  The order decides what a shrunk failure says. When a bug is in one path,
  the target with the bug keeps the entry that exposes it, and the reference
  runs the simplest entry the failure allows. When every entry fails, the
  other target ends on the reference's choice: both targets run the same
  commands, so the bug is in the implementation, not in a path.

  Argument simplification also simplifies the fields of each leaf that the
  leaf's generator drew. A field the entry's `overrides:` sets, and a field
  holding a placeholder, is never touched. The simplified values travel
  with the target's carried choice, so every later candidate realizes the
  leaf with them while its `overrides:` are evaluated again.

  A candidate whose expansions cannot be realized is invalid and never runs:
  an entry the function no longer returns for the candidate's simulated
  state, or an `overrides:` that raises on a simplified root. When a leaf of
  the entry a target runs no longer meets its precondition in a candidate,
  the root runs as itself in that target, counted as "identity, forced".
  The setup commands and their arguments are never shrunk, and the teardown
  commands are generated again for every candidate. The result records, per
  target and root, the entry the target ran: its key, `:identity` or
  `:forced`.

  ## Parameters

  - `sequence` - The original failing sequence (or list for backwards compatibility)
  - `opts` - Shrinking options:
    - `:failed_at_index` - Index where the failure occurred (required)
    - `:failure_reason` - Original failure reason for equivalence checking (optional but recommended)
    - `:variant_index` - Index of the target the failure happened in (default `0`)
    - `:model` - Model module (required)
    - `:targets` - The run's `[%PropertyDamage.Target{}]`, reference first
      (required)
    - `:oracle` - A function `(plan, mint_epoch) ->
      %PropertyDamage.Shrinker.Outcome{}` that runs a candidate and says what
      it did (required). `PropertyDamage.Runner.shrink_oracle/2` builds the
      one that runs it on every target; how a candidate runs (concurrency,
      the convergence bound, the check mode, stutter, the run nonce) is the
      oracle's.
    - `:rng_seed` - The run's effective seed: the teardown commands and the
      expansions of every candidate are drawn from it (default `0`)
    - `:mint_epoch_counter` - `:atomics` counter every candidate that reaches
      the oracle draws a fresh mint epoch from (DR-034; default a new
      counter, so epochs start at 1)
    - `:expansion` - What every target ran for the failing sequence
      (the run's expansion choices, or a report trace's
      `%{name => [choice]}`); default `nil`, every root runs as itself
    - `:root_ids` - The stable id of each root of `sequence`, the ids
      `:expansion` keys its choices by (default: each root's index)
    - `:external_markers` - The run's atom markers (see `PropertyDamage.External`).
      The teardown draw, the expansion walk and the replay check of every
      candidate simulate commands again, and each turns an event field holding
      one of these atoms into a placeholder, as generation did (default `[]`)
    - `:config` - Shrinker.Config struct (default: Config.new())

  ## Returns

  A shrink_result map: the minimal failing sequence, what every target runs
  for it (`expansion`), the number of
  candidates tried (`iterations`), the time spent, and the number of shrink
  cycles run (`cycles`; the last one adopted nothing unless the budget ran
  out) and why it stopped (`stop`, see `t:stop_reason/0`).
  """
  @spec shrink(Sequence.t() | [struct()], keyword()) :: shrink_result()
  def shrink(sequence_or_commands, opts)

  def shrink(%Sequence{} = sequence, opts), do: shrink_linear(sequence, opts)

  # Backwards compatibility: accept list of commands
  def shrink(commands, opts) when is_list(commands) do
    shrink(Sequence.linear(commands), opts)
  end

  # ============================================================================
  # Linear Sequence Shrinking
  # ============================================================================

  defp shrink_linear(sequence, opts) do
    failed_at_index = Keyword.fetch!(opts, :failed_at_index)
    commands = Sequence.to_list(sequence)

    shrink_state =
      opts
      |> base_state()
      |> Map.merge(%{
        commands: commands,
        # Parallel to `commands`: the original structured position of each command
        # (DR-021). A linear sequence is all prefix positions. Kept in lockstep with
        # removals so the placeholder registry's producer_link can be remapped to
        # each candidate's positions before re-execution.
        positions: original_positions(commands),
        registry: sequence.registry,
        setup_commands: sequence.setup,
        root_ids: Keyword.get(opts, :root_ids) || Enum.to_list(0..(length(commands) - 1)//1),
        # The generation position of the failing root: a candidate that fails
        # at a later root is not adopted.
        failing_offset: if(is_integer(failed_at_index), do: failed_at_index)
      })

    shrink_state = %{shrink_state | replay_basis: replay_basis(shrink_state)}

    # Truncating at the failure point is an optimization, not an assumption
    # we may act on blindly: the index can be nil (poll timeouts, record
    # mode), so the truncated base must be VERIFIED to still fail before it replaces the
    # full sequence. The verification is an attempt like any other: it counts
    # whether it reproduces or not, and it runs only while the budget lasts.
    shrink_state =
      if is_integer(failed_at_index) and failed_at_index + 1 < length(commands) and
           not exceeded_limits?(shrink_state) do
        truncated = Enum.take(commands, failed_at_index + 1)
        truncated_positions = Enum.take(shrink_state.positions, failed_at_index + 1)
        shrink_state = increment_iterations(shrink_state)

        adopt(truncated, truncated_positions, shrink_state) || shrink_state
      else
        shrink_state
      end

    shrink_state = cycle(shrink_state)

    end_time = System.monotonic_time(:millisecond)

    # Carry the remapped registry so the shrunk sequence (reported and
    # replayed) still resolves its externals, and the teardown commands generated
    # for its own roots.
    shrunk =
      %{sequence | prefix: shrink_state.commands}
      |> Sequence.with_registry(remap_registry(shrink_state.registry, shrink_state.positions))
      |> with_teardown(shrink_state)

    %{
      sequence: shrunk,
      expansion: carried_expansion(shrunk, shrink_state.positions, shrink_state),
      iterations: shrink_state.iterations,
      time_ms: end_time - shrink_state.start_time,
      cycles: shrink_state.cycles,
      stop: stop_reason(shrink_state, end_time)
    }
  end

  # One shrink cycle: the four phases in order, each on what the previous
  # one left. The cycle repeats while it adopts a candidate and the budget
  # lasts.
  defp cycle(state) do
    adopted = state.adopted

    state =
      state
      |> shrink_sequence()
      |> collapse_reference()
      |> collapse_variants()
      |> shrink_arguments()

    state = %{state | cycles: state.cycles + 1}

    if state.adopted > adopted and not exceeded_limits?(state), do: cycle(state), else: state
  end

  # The state every shrink starts from: the run to re-execute, the failure to
  # preserve, and the budget.
  defp base_state(opts) do
    variant_index = Keyword.get(opts, :variant_index, 0)

    original_signature =
      case Keyword.get(opts, :failure_reason) do
        nil -> nil
        reason -> Failure.signature(reason, variant_index)
      end

    %{
      model: Keyword.fetch!(opts, :model),
      # Every command's spec as the model lists it, built once per shrink.
      specs: Model.spec_table(Keyword.fetch!(opts, :model)),
      targets: Keyword.fetch!(opts, :targets),
      # Runs a candidate and says what it did (see `shrink/2`).
      oracle: Keyword.fetch!(opts, :oracle),
      config: Keyword.get(opts, :config, Config.new()),
      external_markers: Keyword.get(opts, :external_markers, []),
      iterations: 0,
      # Candidates adopted so far, and the shrink cycles run.
      adopted: 0,
      cycles: 0,
      failing_offset: nil,
      # Placeholder ids the replay artifact of the starting sequence cannot
      # resolve either (see replayable?/4).
      replay_basis: MapSet.new(),
      start_time: System.monotonic_time(:millisecond),
      original_signature: original_signature,
      # The run's effective seed: the teardown commands and the expansions of
      # every candidate are drawn from it, as the original run drew them.
      rng_seed: Keyword.get(opts, :rng_seed) || 0,
      # Client-minted run-scoped values (DR-034): each candidate the oracle
      # runs is a fresh SUT execution, so it draws a distinct mint_epoch from
      # this monotonic counter. On a non-resettable SUT that keeps candidates
      # from re-sending the exploration run's (epoch 0) minted values and
      # colliding with it.
      mint_epoch_counter:
        Keyword.get(opts, :mint_epoch_counter) || :atomics.new(1, signed: false),
      # Every target's choices in the failing run, by target name and root id;
      # nil when no root runs as an expansion.
      carry: carry(Keyword.fetch!(opts, :model), Keyword.get(opts, :expansion)),
      # Whether the run recorded every target running the roots as
      # themselves (a model without expansions): the shrunk run then records
      # the same, under the shrunk roots' generation ids.
      identity?:
        is_map(Keyword.get(opts, :expansion)) and
          not Expansion.defines?(Keyword.fetch!(opts, :model))
    }
  end

  defp carry(model, expansion) when is_map(expansion) do
    if Expansion.defines?(model), do: Expansion.carry(expansion)
  end

  defp carry(_model, _expansion), do: nil

  # What every target runs for `candidate`: each target's carried choices,
  # realized again against the candidate (see "Expansions" in the moduledoc).
  # Returns `{:ok, expansion}` (nil when nothing is carried) or `:invalid`
  # when an expansion of the candidate cannot be realized.
  defp candidate_expansion(_candidate, _positions, %{carry: nil}), do: {:ok, nil}
  defp candidate_expansion(_candidate, nil, _state), do: {:ok, nil}

  defp candidate_expansion(candidate, positions, state) do
    root_ids = Enum.map(positions, &Enum.at(state.root_ids, &1.offset))

    {:ok,
     Expansion.expand(state.model, candidate, state.targets, state.rng_seed,
       root_ids: root_ids,
       carry: state.carry,
       external_markers: state.external_markers
     )}
  rescue
    ArgumentError -> :invalid
  end

  # A model without expansions: every target runs the shrunk roots, each
  # under the id it was generated with.
  defp carried_expansion(shrunk, positions, %{carry: nil, identity?: true} = state)
       when is_list(positions),
       do: Expansion.identity(shrunk, state.targets, artifact_root_ids(shrunk, positions, state))

  defp carried_expansion(shrunk, positions, state) do
    case candidate_expansion(shrunk, positions, state) do
      {:ok, expansion} -> expansion
      :invalid -> nil
    end
  end

  # ==========================================================================
  # The expansion axis: what each target runs at each surviving root
  # ==========================================================================

  # Phase 2: at each root in order, the reference's entry collapses toward
  # the root itself: first the identity (under its key when the function
  # lists the root alone), then each earlier entry of the root's list, in
  # order, keeping the first that still fails. A `:reference` target copies
  # the reference in every candidate, so it moves with it.
  defp collapse_reference(%{carry: nil} = state), do: state

  defp collapse_reference(state) do
    case hd(state.targets) do
      %{expansion: :random, name: name} ->
        Enum.reduce(surviving_root_ids(state), state, &collapse_root(&2, name, &1))

      _not_drawing ->
        state
    end
  end

  defp collapse_root(state, name, root_id) do
    with false <- exceeded_limits?(state),
         {:ok, current} <- current_expansion(state),
         %{leaves?: true, index: index} = choice when is_integer(index) <-
           choice_at(current, name, root_id) do
      kept = followers(state, current, root_id)

      case try_carry(state, name, root_id, :to_identity, [choice], kept) do
        {:adopted, state} ->
          state

        {:tried, state, tried} ->
          listed = Enum.find_value(tried, &(&1.leaves? == false && &1.index))
          earlier = Enum.reject(0..(index - 1)//1, &(&1 == listed))
          collapse_earlier(state, {name, root_id, choice, kept}, earlier, tried)
      end
    else
      _nothing_to_collapse -> state
    end
  end

  # Each earlier entry, its leaves realized from the target's own seed key,
  # so the substitution is the same in every candidate and every process.
  defp collapse_earlier(state, _at, [], _tried), do: state

  defp collapse_earlier(state, {name, root_id, choice, kept} = at, [index | rest], tried) do
    if exceeded_limits?(state) do
      state
    else
      entry = %{
        entry: Expansion.entry_key(choice.module, index),
        index: index,
        seed_key: Expansion.seed_key(state.rng_seed, name, root_id),
        leaves?: true
      }

      case try_carry(state, name, root_id, entry, tried, kept) do
        {:adopted, state} -> state
        {:tried, state, tried} -> collapse_earlier(state, at, rest, tried)
      end
    end
  end

  # The `:random` targets that copy the reference's choice at `root_id`
  # (phase 3), each with what it runs there now. A phase-2 candidate keeps
  # them on that entry and those commands, a literal copy, so the reference
  # can collapse alone when the failure is in the copy. A later phase 3 may
  # copy the reference's new choice again.
  defp followers(state, current, root_id) do
    for %{expansion: :random, name: name} <- tl(state.targets),
        get_in(state.carry, [name, root_id]) == :follow,
        into: %{},
        do: {name, choice_at(current, name, root_id)}
  end

  # Phase 3: at each root in order, each other `:random` target takes the
  # reference's choice there: the same entry and the same commands, copied
  # again in every later candidate.
  defp collapse_variants(%{carry: nil} = state), do: state

  defp collapse_variants(state) do
    [reference | others] = state.targets

    for %{expansion: :random, name: name} <- others,
        root_id <- surviving_root_ids(state),
        reduce: state do
      state -> follow_root(state, reference.name, name, root_id)
    end
  end

  defp follow_root(state, reference, name, root_id) do
    with false <- exceeded_limits?(state),
         {:ok, current} <- current_expansion(state),
         %{} = ours <- choice_at(current, name, root_id),
         false <- same_choice?(ours, choice_at(current, reference, root_id)) do
      case try_carry(state, name, root_id, :follow, [ours]) do
        {:adopted, state} -> state
        {:tried, state, _tried} -> state
      end
    else
      _same_or_none -> state
    end
  end

  # Phase 4, leaves: each field a leaf's generator drew, in each leaf a
  # `:random` target realizes from a carried entry, is simplified as a root
  # argument is. A field an `overrides:` sets, or a field holding a
  # placeholder, is never touched. The simplified values ride the target's
  # carried choice (`fields`), so every later candidate realizes the leaf
  # with them.
  defp shrink_leaf_arguments(%{carry: nil} = state), do: state

  defp shrink_leaf_arguments(state) do
    for %{expansion: :random, name: name} <- state.targets,
        root_id <- surviving_root_ids(state),
        reduce: state do
      state -> shrink_leaves(state, name, root_id, 0)
    end
  end

  defp shrink_leaves(state, name, root_id, leaf) do
    with false <- exceeded_limits?(state),
         %{} = carried <- get_in(state.carry, [name, root_id]),
         {:ok, current} <- current_expansion(state),
         %{leaves?: true, commands: commands, generated: generated} = choice <-
           choice_at(current, name, root_id),
         %_{} = command <- Enum.at(commands, leaf) do
      simplified = simplified_fields(command, Enum.at(generated, leaf))

      if simplified == %{} do
        shrink_leaves(state, name, root_id, leaf + 1)
      else
        fields = Map.get(carried, :fields, %{})
        fields = Map.update(fields, leaf, simplified, &Map.merge(&1, simplified))

        case try_carry(state, name, root_id, Map.put(carried, :fields, fields), [choice]) do
          {:adopted, state} -> shrink_leaves(state, name, root_id, leaf)
          {:tried, state, _tried} -> shrink_leaves(state, name, root_id, leaf + 1)
        end
      end
    else
      _nothing_to_simplify -> state
    end
  end

  # A field whose value is false or nil is a value like any other here:
  # `shrink_value/1` leaves it as it is, so it is never listed.
  defp simplified_fields(command, generated) do
    for field <- generated || [],
        {value, simplified} <- [simplified_value(Map.get(command, field))],
        simplified != value,
        into: %{},
        do: {field, simplified}
  end

  defp simplified_value(value) do
    if holds_placeholder?(value), do: {value, value}, else: {value, shrink_value(value)}
  end

  defp holds_placeholder?(%Placeholder{}), do: true
  defp holds_placeholder?(%_{} = struct), do: struct |> Map.from_struct() |> holds_placeholder?()
  defp holds_placeholder?(map) when is_map(map), do: Enum.any?(map, &holds_placeholder?/1)
  defp holds_placeholder?(list) when is_list(list), do: Enum.any?(list, &holds_placeholder?/1)

  defp holds_placeholder?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> holds_placeholder?()

  defp holds_placeholder?(_value), do: false

  # Runs the current roots with target `name` carrying `carried` at
  # `root_id`, and each target of `kept` carrying its choice there. Returns
  # `{:adopted, state}` when the candidate fails as the original did, else
  # `{:tried, state, tried}`, where `tried` adds what the target ran at
  # `root_id` in this candidate to the choices already tried there. A
  # candidate that runs one of the `tried` choices again is not run; one
  # whose expansions cannot be realized (an entry the function no longer
  # returns for the candidate's state) is invalid and never runs. An invalid
  # candidate still adds what the target runs at `root_id` to `tried` when
  # the roots up to that one can be realized, so a later entry that runs
  # the same commands there, the same invalid candidate, is not realized and
  # counted again.
  defp try_carry(state, name, root_id, carried, tried, kept \\ %{}) do
    carry =
      kept
      |> Map.put(name, carried)
      |> Enum.reduce(state.carry, fn {target, value}, carry ->
        Map.update(carry, target, %{root_id => value}, &Map.put(&1, root_id, value))
      end)

    trial = %{state | carry: carry}

    case current_expansion(trial) do
      :invalid ->
        case realized_up_to(trial, name, root_id) do
          nil ->
            {:tried, increment_iterations(state), tried}

          realized ->
            if Enum.any?(tried, &same_choice?(&1, realized)),
              do: {:tried, state, tried},
              else: {:tried, increment_iterations(state), [realized | tried]}
        end

      {:ok, expansion} ->
        realized = choice_at(expansion, name, root_id)

        if Enum.any?(tried, &same_choice?(&1, realized)) do
          {:tried, state, tried}
        else
          trial = increment_iterations(trial)

          case adopt(state.commands, state.positions, trial) do
            nil -> {:tried, %{state | iterations: trial.iterations}, [realized | tried]}
            adopted -> {:adopted, adopted}
          end
        end
    end
  end

  # What every target runs for the current roots under the carried choices.
  defp current_expansion(state) do
    registry = remap_registry(state.registry, state.positions)

    candidate_expansion(
      candidate(Sequence.linear(state.commands), registry, state),
      state.positions,
      state
    )
  end

  # What target `name` runs at `root_id` when only the roots up to that one
  # are realized; nil when even those cannot be. Realizing a root depends on
  # the roots before it only, so the choice is the one the whole candidate
  # would run there.
  defp realized_up_to(state, name, root_id) do
    count = Enum.find_index(surviving_root_ids(state), &(&1 == root_id)) + 1

    prefix = %{
      state
      | commands: Enum.take(state.commands, count),
        positions: Enum.take(state.positions, count)
    }

    case current_expansion(prefix) do
      {:ok, expansion} -> choice_at(expansion, name, root_id)
      :invalid -> nil
    end
  end

  defp surviving_root_ids(state),
    do: Enum.map(state.positions, &Enum.at(state.root_ids, &1.offset))

  defp choice_at(%{variants: variants}, name, root_id) do
    variants |> Map.fetch!(name) |> Map.fetch!(:choices) |> Enum.find(&(&1.root_id == root_id))
  end

  # Two choices that run the same commands at a root are the same execution
  # there, whatever entry each names.
  defp same_choice?(%{commands: commands}, %{commands: commands}), do: true
  defp same_choice?(_left, _right), do: false

  # The original structured positions of a flat (linear) command list.
  defp original_positions(commands) do
    commands |> Enum.with_index() |> Enum.map(fn {_cmd, i} -> Position.prefix(i) end)
  end

  # Remap the placeholder registry's producer_link from original positions onto
  # a candidate's positions (DR-021). `positions[new_i]` is the original position
  # of the command now at candidate index new_i; producers that were dropped lose
  # their entry (their placeholders simply won't resolve, which is correct: a
  # surviving consumer of a removed producer makes the candidate fail to
  # reproduce). Resolution of embedded placeholders stays by id and is unaffected.
  # The producer_link rebuild itself is registry-internals, so it lives in
  # PlaceholderRegistry.remap_positions/2 (DR-039).
  defp remap_registry(nil, _positions), do: nil

  defp remap_registry(registry, positions) do
    orig_to_new =
      positions
      |> Enum.with_index()
      |> Map.new(fn {orig_position, new_i} -> {orig_position, Position.prefix(new_i)} end)

    PlaceholderRegistry.remap_positions(registry, orig_to_new)
  end

  # ============================================================================
  # Linear Shrinking Helpers (original implementation)
  # ============================================================================

  defp shrink_sequence(state) do
    if length(state.commands) <= state.config.granularity_threshold do
      linear_shrink(state)
    else
      hierarchical_shrink(state)
    end
  end

  defp hierarchical_shrink(state) do
    # The dependency graph and its depth levels are built ONCE, so their node
    # indices live in a single index space: positions in `original_commands`.
    # Candidates must therefore be rebuilt from `original_commands` and the set
    # of surviving original indices tracked explicitly. An earlier version
    # mutated `state.commands` between levels and re-derived indices from the
    # progressively-shrunk list, so after the first accepted removal the
    # original-space `level` numbers no longer matched positions in
    # `state.commands` — producing no-op acceptances, wrong-target removals,
    # and missed shrinks exactly on the long sequences this strategy exists for.
    original_commands = state.commands
    # Positions parallel to original_commands, fixed for the whole level sweep
    # (the graph's index space is original_commands). Candidate positions are
    # selected from this by surviving original index (DR-021).
    original_positions = state.positions
    graph = Graph.build(original_commands)
    levels = Graph.compress(graph)

    kept = MapSet.new(0..(length(original_commands) - 1)//1)

    state =
      try_remove_levels(
        state,
        original_commands,
        original_positions,
        graph,
        Enum.reverse(levels),
        kept
      )

    linear_shrink(state)
  end

  defp try_remove_levels(state, _original, _orig_positions, _graph, [], _kept), do: state

  defp try_remove_levels(state, original, orig_positions, graph, [level | rest], kept) do
    if exceeded_limits?(state) do
      state
    else
      # Drop this level's nodes, then pull back any ancestors that surviving
      # nodes still depend on so placeholders stay resolvable. Everything here is in
      # the original index space, which `graph` agrees with.
      candidate_keep = MapSet.difference(kept, MapSet.new(level))

      expanded =
        graph
        |> Graph.expand_super_node(MapSet.to_list(candidate_keep))
        |> MapSet.new()

      if MapSet.equal?(expanded, kept) do
        # The level's nodes are all required ancestors of survivors, so nothing
        # actually came out. Skip without spending a SUT execution.
        try_remove_levels(state, original, orig_positions, graph, rest, kept)
      else
        survivors = Enum.sort(MapSet.to_list(expanded))
        candidate = select_commands(original, survivors)
        candidate_positions = Enum.map(survivors, &Enum.at(orig_positions, &1))

        state = increment_iterations(state)

        case valid_candidate?(candidate, candidate_positions, state) &&
               adopt(candidate, candidate_positions, state) do
          %{} = adopted ->
            try_remove_levels(adopted, original, orig_positions, graph, rest, expanded)

          _rejected ->
            try_remove_levels(state, original, orig_positions, graph, rest, kept)
        end
      end
    end
  end

  defp linear_shrink(state) do
    # Run linear shrinking in a fixpoint loop until no more shrinking happens
    # This handles cases where removing one command enables removal of others
    do_linear_shrink_fixpoint(state)
  end

  # Keep running linear shrinking until no commands are removed in a full pass
  defp do_linear_shrink_fixpoint(state) do
    original_count = length(state.commands)
    # Get indices sorted by shrink priority (probe commands first)
    prioritized_indices = sort_indices_by_shrink_priority(state.commands, state.specs)
    state = do_linear_shrink(state, prioritized_indices)
    new_count = length(state.commands)

    if new_count < original_count and not exceeded_limits?(state) do
      # Made progress, try again from the beginning
      do_linear_shrink_fixpoint(state)
    else
      state
    end
  end

  # Sort command indices by shrink priority.
  # Commands with :prefer_remove (probes, read-only) are prioritized for removal.
  # Commands with :prefer_keep are removed last.
  # Reads the :shrink key from the command's spec in the model's spec table, so
  # an option on the command's listing in commands/0 counts.
  defp shrink_priority_for_command(cmd, specs) when is_struct(cmd) do
    case Map.get(Model.spec_for(specs, cmd), :shrink, :neutral) do
      :prefer_remove -> 0
      :neutral -> 1
      :prefer_keep -> 2
    end
  end

  defp shrink_priority_for_command(_cmd, _specs), do: 1

  defp sort_indices_by_shrink_priority(commands, specs) do
    commands
    |> Enum.with_index()
    |> Enum.sort_by(fn {cmd, _idx} ->
      shrink_priority_for_command(cmd, specs)
    end)
    |> Enum.map(fn {_cmd, idx} -> idx end)
  end

  defp do_linear_shrink(state, []) do
    state
  end

  defp do_linear_shrink(state, [index | rest_indices]) do
    if exceeded_limits?(state) do
      state
    else
      command = Enum.at(state.commands, index)
      remaining = Enum.drop(state.commands, index + 1)
      position = Enum.at(state.positions, index)

      # Skip if this is a protected async command (its external is still
      # consumed downstream)
      if protected_async?(command, position, state, remaining) do
        do_linear_shrink(state, rest_indices)
      else
        candidate = List.delete_at(state.commands, index)
        candidate_positions = List.delete_at(state.positions, index)

        state = increment_iterations(state)

        case valid_candidate?(candidate, candidate_positions, state) &&
               adopt(candidate, candidate_positions, state) do
          %{} = adopted ->
            # Command was removed, recompute priorities for remaining commands
            do_linear_shrink(adopted, sort_indices_by_shrink_priority(candidate, state.specs))

          _rejected ->
            do_linear_shrink(state, rest_indices)
        end
      end
    end
  end

  # Phase 4, when `shrink_arguments` is on: the roots' arguments, then the
  # fields its generator gave in every leaf a target realizes from an entry.
  defp shrink_arguments(%{config: %{shrink_arguments: true}} = state),
    do: state |> do_shrink_arguments(0) |> shrink_leaf_arguments()

  defp shrink_arguments(state), do: state

  defp do_shrink_arguments(state, index) do
    if exceeded_limits?(state) or index >= length(state.commands) do
      state
    else
      command = Enum.at(state.commands, index)
      shrunk_command = shrink_command_args(command)

      if shrunk_command != command do
        candidate = List.replace_at(state.commands, index, shrunk_command)
        state = increment_iterations(state)

        # Argument shrinking replaces in place, so positions are unchanged.
        case valid_candidate?(candidate, state.positions, state) &&
               adopt(candidate, state.positions, state) do
          %{} = adopted -> do_shrink_arguments(adopted, index)
          _rejected -> do_shrink_arguments(state, index + 1)
        end
      else
        do_shrink_arguments(state, index + 1)
      end
    end
  end

  defp shrink_command_args(command) do
    command
    |> Map.from_struct()
    |> Enum.map(fn {key, value} -> {key, shrink_value(value)} end)
    |> then(&struct(command.__struct__, &1))
  end

  # Don't shrink placeholders - they represent dependencies
  defp shrink_value(%Placeholder{} = p), do: p
  defp shrink_value(n) when is_integer(n) and n > 0, do: div(n, 2)
  defp shrink_value(n) when is_integer(n) and n < 0, do: div(n, 2)

  # Halve a binary toward empty in consistent units: take the first half of its
  # BYTES via binary_part/3 (J12). The former String.slice/3 mixed units — a
  # byte-length divisor applied as a codepoint count — so a multi-byte binary
  # sliced its whole length (no progress), and arbitrary/invalid-UTF8 binaries
  # were not slice-safe. binary_part works uniformly on any binary and always
  # shrinks (div(byte_size, 2) < byte_size for byte_size >= 2; 1 shrinks to "").
  defp shrink_value(s) when is_binary(s) and byte_size(s) > 0 do
    binary_part(s, 0, div(byte_size(s), 2))
  end

  defp shrink_value(list) when is_list(list) and list != [] do
    Enum.take(list, div(length(list), 2))
  end

  defp shrink_value(other), do: other

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp select_commands(commands, indices) do
    commands
    |> Enum.with_index()
    |> Enum.filter(fn {_cmd, idx} -> idx in indices end)
    |> Enum.map(fn {cmd, _idx} -> cmd end)
  end

  # Validation runs the model's own projection, simulator and when: predicates
  # over a candidate the shrinker made up, such as an argument halved to 0 or a
  # key no earlier command created. Model code may raise on such a candidate;
  # that makes the candidate invalid, not the run a failure.
  defp valid_candidate?(commands, positions, state) do
    sequence =
      commands
      |> Sequence.linear()
      |> Sequence.with_registry(remap_registry(state.registry, positions))
      |> Map.put(:setup, state.setup_commands)

    Validator.valid_sequence?(sequence, state.model, external_markers: state.external_markers)
  rescue
    _ -> false
  end

  # A candidate as it runs: the sequence's setup commands, the candidate's
  # roots and registry, and teardown commands generated for those roots.
  defp candidate(%Sequence{} = roots, registry, state) do
    roots
    |> Sequence.with_registry(registry || PlaceholderRegistry.new())
    |> Map.put(:setup, state.setup_commands)
    |> with_teardown(state)
  end

  # The teardown commands generated against `sequence`'s roots, with the run seed.
  defp with_teardown(%Sequence{} = sequence, state),
    do:
      Generator.teardown_commands(state.model, sequence, state.rng_seed,
        external_markers: state.external_markers
      )

  # A fresh mint epoch for the next shrink attempt (DR-034). Monotonic across
  # this shrink's attempts (and never 0, the exploration run's epoch), so each
  # re-execution sends distinct client-minted values on a non-resettable SUT.
  defp next_mint_epoch(state), do: :atomics.add_get(state.mint_epoch_counter, 1, 1)

  # Runs the candidate `commands` (each at the original position in
  # `positions`) under the carried choices of `state`. Returns `state` with the
  # candidate adopted when it fails with the original failure, in the same
  # target, at the same or an earlier root; else nil.
  defp adopt(commands, positions, state) do
    # Regenerate idempotency keys to ensure fresh SUT state
    keyed = regenerate_idempotency_keys(commands)

    # The candidate's registry has its producer_link remapped to the candidate's
    # positions (DR-021), so externals resolve against the shrunk sequence's own
    # indices.
    outcome = attempt(keyed, positions, remap_registry(state.registry, positions), state)
    offset = generation_offset(positions, outcome.root)

    if reproduces?(outcome, state.original_signature) and
         not later?(offset, state.failing_offset) do
      %{
        state
        | commands: commands,
          positions: positions,
          failing_offset: offset || state.failing_offset,
          adopted: state.adopted + 1
      }
    end
  end

  # Whether a candidate's outcome is the original failure. Without an
  # original signature the shrinker cannot prove equivalence, so it accepts
  # any failure except a placeholder-resolution one: that failure appears only
  # because a producing command was removed, so adopting it would pass off a
  # shrink artifact as the minimal reproduction. With a signature, the same
  # kind, name and target mean the same bug.
  defp reproduces?(%Outcome{status: :failed, signature: {kind, _name, _index}}, nil),
    do: kind != :placeholder_resolution

  defp reproduces?(%Outcome{status: :failed, signature: signature}, original),
    do: signature == original

  defp reproduces?(%Outcome{}, _original), do: false

  # The generation position of the candidate's root `root`.
  defp generation_offset(positions, root) when is_integer(root) and is_list(positions) do
    case Enum.at(positions, root) do
      %{offset: offset} -> offset
      nil -> nil
    end
  end

  defp generation_offset(_positions, _root), do: nil

  defp later?(offset, failing) when is_integer(offset) and is_integer(failing),
    do: offset > failing

  defp later?(_offset, _failing), do: false

  # One shrink attempt: the candidate, with the sequence's setup commands and
  # teardown commands generated for it, handed to the oracle. A candidate whose
  # expansions cannot be realized, or whose replay artifact could not re-execute
  # it, is `:invalid` and never reaches the oracle. `positions` holds each
  # root's original position (nil when no expansion is carried).
  defp attempt(commands, positions, registry, state) do
    # A sequence built by hand may carry no registry: its candidates resolve
    # nothing, as on the linear engine.
    candidate = candidate(Sequence.linear(commands), registry, state)

    with {:ok, expansion} <- candidate_expansion(candidate, positions, state),
         true <- positions == nil or replayable?(commands, positions, expansion, state) do
      run_candidate(plan(commands, candidate, expansion, state), state)
    else
      _invalid -> %Outcome{status: :invalid}
    end
  end

  # Whether the replay artifact of a candidate would re-execute it: every
  # placeholder its commands hold, the leaves every target runs included,
  # is registered by the registry the artifact's re-execution rebuilds by
  # simulating the setup commands and the roots again
  # (`PropertyDamage.ReplayArtifact.unregistered/5`). A simulator whose
  # events depend on the state may mint nothing for a root once an earlier
  # root is gone, while the candidate still holds what the original run
  # minted there. Such a candidate is invalid: a shrunk failure it led to
  # could not be replayed from its own artifact. A simulator that raises on
  # the candidate makes it invalid too. A placeholder the rebuild misses for
  # the sequence the shrink started from does not count: the shrink cannot lose what that sequence never had.
  defp replayable?(commands, positions, expansion, state) do
    commands
    |> unreplayable(positions, expansion, state)
    |> Enum.all?(&MapSet.member?(state.replay_basis, &1))
  rescue
    _ -> false
  end

  # The placeholder ids the commands of a candidate hold that the registry
  # its artifact rebuilds does not register.
  defp unreplayable(commands, positions, expansion, state) do
    roots =
      Enum.zip_with(artifact_root_ids(commands, positions, state), commands, fn id, command ->
        %{root_id: id, command: command}
      end)

    leaves =
      for {_name, %{choices: choices}} <- (expansion && expansion.variants) || %{},
          %{leaves?: true, commands: leaves} <- choices,
          leaf <- leaves,
          do: leaf

    held = state.setup_commands ++ commands ++ leaves

    ReplayArtifact.unregistered(state.model, state.setup_commands, roots, held,
      external_markers: state.external_markers
    )
  end

  # The placeholder ids the registry rebuilt for the sequence the shrink
  # starts from already misses.
  defp replay_basis(state) do
    expansion =
      case current_expansion(state) do
        {:ok, expansion} -> expansion
        :invalid -> nil
      end

    MapSet.new(unreplayable(state.commands, state.positions, expansion, state))
  rescue
    _ -> MapSet.new()
  end

  # The root ids the artifact of a candidate records: the id each root was
  # generated with (its index when no position is known).
  defp artifact_root_ids(_commands, positions, state) when is_list(positions),
    do: Enum.map(positions, &Enum.at(state.root_ids, &1.offset))

  defp artifact_root_ids(%Sequence{} = sequence, nil, state),
    do: artifact_root_ids(Sequence.to_list(sequence), nil, state)

  defp artifact_root_ids(commands, nil, _state), do: Enum.to_list(0..(length(commands) - 1)//1)

  # The plan the oracle runs for a candidate: its roots, what every target
  # runs at each of them (nil when every target runs every root as itself),
  # the setup and teardown commands, and the registry.
  defp plan(commands, candidate, expansion, state) do
    %{
      commands: commands,
      variants: expansion && Expansion.schedule(state.targets, expansion),
      setup_commands: candidate.setup,
      teardown_commands: candidate.teardown,
      placeholder_registry: candidate.registry
    }
  end

  # The one place a candidate runs: the oracle, with a fresh mint epoch.
  defp run_candidate(plan, state), do: state.oracle.(plan, next_mint_epoch(state))

  defp exceeded_limits?(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.start_time

    state.iterations >= state.config.max_iterations or
      elapsed >= state.config.max_time_ms
  end

  # Which budget, if any, ended the shrink at time `now`. The iteration cap is
  # checked first, so it wins when both ran out.
  defp stop_reason(state, now) do
    cond do
      state.iterations >= state.config.max_iterations -> :max_iterations
      now - state.start_time >= state.config.max_time_ms -> :max_time
      true -> :done
    end
  end

  defp increment_iterations(state) do
    %{state | iterations: state.iterations + 1}
  end

  # An async command whose produced external is still consumed by a later
  # command is not worth attempting to remove: the consumer would strand, the
  # candidate would fail to reproduce, and async settling makes the wasted
  # re-execution especially costly. Correctness does not depend on this (the
  # failure-equivalence check rejects such a candidate regardless); it is a
  # shrink-cost optimization. The produced placeholders are identified by the
  # command's structured position (DR-021), and a downstream consumer embeds a
  # placeholder carrying the same id.
  defp protected_async?(command, position, state, downstream_commands) do
    with true <- is_struct(command),
         true <- Settle.get_semantics(Model.spec_for(state.specs, command)) == :async,
         %PlaceholderRegistry{} = registry <- state.registry,
         produced_ids = PlaceholderRegistry.ids_at_position(registry, position),
         false <- produced_ids == [] do
      downstream_ids =
        downstream_commands
        |> Enum.flat_map(&PlaceholderRegistry.collect_placeholder_ids/1)
        |> MapSet.new()

      Enum.any?(produced_ids, &MapSet.member?(downstream_ids, &1))
    else
      _ -> false
    end
  end

  # ============================================================================
  # Idempotency Key Regeneration
  # ============================================================================

  # Regenerate idempotency keys for a list of commands to ensure fresh SUT state
  defp regenerate_idempotency_keys(commands) do
    Enum.map(commands, &regenerate_command_idempotency_key/1)
  end

  # Regenerate the idempotency key for a single command
  defp regenerate_command_idempotency_key(command) do
    if Map.has_key?(command, :idempotency_key) do
      new_key = generate_idempotency_key()
      %{command | idempotency_key: new_key}
    else
      command
    end
  end

  # Generate a new random idempotency key
  defp generate_idempotency_key do
    :crypto.strong_rand_bytes(16) |> Base.encode16()
  end
end
