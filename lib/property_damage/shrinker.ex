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
  compared through its failure *signature* (`failure_signature/2`):
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
  bug the system does not have.

  A further property also holds: the failure occurs at the **same or an earlier
  command index** (the failing root) than in the original. This one is guaranteed *structurally*
  rather than asserted by the signature comparison, and it holds on both the
  linear and the branching path for the same underlying reason: every shrink
  candidate is a subset or simplification of a fixed base sequence, so a
  candidate can only reproduce the failure at the same position or earlier,
  never later.

  On the linear path this is most visible in Phase 1, which first truncates the
  sequence at the failure point (`Enum.take(commands, failed_at_index + 1)`), so
  every subsequent candidate is a subset of that prefix.

  On the branching path the index is likewise not asserted. The original
  `failed_at_index` is a branch-relative coordinate (`branch_start_index +
  position`) that is not directly comparable to the linear index obtained when a
  branching sequence is flattened, so it is **not** reused for truncation: when
  `try_convert_to_linear` decides a race is not required, it takes the failure
  index from its own linear re-run of the flattened sequence (which is
  self-consistent with that sequence) and hands *that* to `shrink_linear`, so
  Phase-1 truncation targets the real failure point. The truncation stays
  `still_fails?`-guarded regardless, so even a stale or nil index can only fall
  back to leaving the full flattened sequence, never accept a later-failing
  candidate. Combined with the subset/simplification property of every branching
  strategy (branch removal, branch-content shrinking, prefix/suffix shrinking,
  and argument shrinking), the same-or-earlier-index guarantee holds structurally
  here as well.

  ## Determinism

  Shrinking is fully deterministic given:
  - The same seed (which determines the command sequence)
  - The same initial failure
  - Deterministic SUT behavior

  This ensures reproducibility: the same seed always produces the same
  shrunk sequence, making CI failures reliably reproducible locally.

  ## Sequence Types

  The Shrinker handles both linear and branching sequences:

  ### Linear Sequences

  Traditional shrinking: remove commands and simplify arguments.

  ### Branching Sequences

  Additional strategies:
  - Remove entire branches (if failure persists)
  - Shrink individual branches
  - Convert to linear (if race not required for failure)
  - Reduce branch count

  ## Two-Phase Shrinking

  ### Phase 1: Sequence Shrinking

  Removes unnecessary commands while preserving the failure:

  1. **Drop unexecuted**: Remove commands after the failure point
  2. **Hierarchical shrink**: Remove commands grouped by dependency depth
  3. **Linear shrink**: Try removing each remaining command individually

  ### Phase 2: Argument Shrinking (optional)

  Simplifies values in remaining commands:

  - Integers shrink toward 0
  - Strings shrink toward empty
  - Lists shrink toward empty
  - Refs are never shrunk (would break dependencies)

  ## Configuration

  See `PropertyDamage.Shrinker.Config` for tuning options:

  - `granularity_threshold` - When to switch from hierarchical to linear
  - `max_iterations` - Limit total shrink attempts
  - `max_time_ms` - Time budget for shrinking
  - `shrink_arguments` - Whether to attempt argument shrinking

  ## Usage

  ```elixir
  # After a failure at index 5 in the first target
  shrunk = Shrinker.shrink(
    sequence,
    failed_at_index: 5,
    failure_reason: PropertyDamage.Failure.check_failed(:balance_invariant, "..."),
    variant_index: 0,
    model: MyModel,
    targets: [%PropertyDamage.Target{adapter: MyAdapter, name: "MyAdapter", index: 0}],
    rng_seed: run_seed,
    config: config
  )
  ```
  """

  alias PropertyDamage.{
    Executor,
    Failure,
    Placeholder,
    PlaceholderRegistry,
    Scheduler,
    Sequence,
    Settle,
    Stutter,
    Telemetry
  }

  alias PropertyDamage.Runtime.RunServices

  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Sequence.Validator

  alias PropertyDamage.Shrinker.{Config, Graph}

  @typedoc """
  Failure signature for equivalence checking: `{kind, name, variant_index}`.

  The three properties that must match for a shrunk sequence to be considered
  as reproducing the "same" failure. `kind` is the failure's globally-unique
  kind (`PropertyDamage.Failure.kind/1`, `:diverged` for a divergence), so two
  failures of different *classes* can never collide; `name` is
  `PropertyDamage.Failure.name/1`: the check/projection name for a check, the
  `{projection, function}` key of the boundary observation for a divergence or
  a failure to converge, `nil` where no name is meaningful; and
  `variant_index` is the index of the target the failure happened in (`0` for a
  run with one target).

  Keying on `kind` rather than the coarser class is load-bearing: a
  `:poll_timeout` of check `:x` and an `:check_failed` of `:x` share a
  name but are different bugs, so their signatures must differ. A class-based
  signature (`{:check, :x}` for both) would let the shrinker swap one bug's
  identity for the other's. Keying on the target is load-bearing for the same
  reason: a check that fails in the reference target is a different failure
  from a divergence found in another target. Keying a divergence on its
  observation keeps a divergence of one `@compare` function from standing in
  for a divergence of another; the mismatch itself is detail, not identity.
  """
  @type failure_signature :: {Failure.kind(), Failure.name(), non_neg_integer()}

  @typedoc """
  Result of shrinking.
  """
  @type shrink_result :: %{
          sequence: Sequence.t(),
          iterations: non_neg_integer(),
          time_ms: non_neg_integer()
        }

  @doc """
  Extract a failure signature from a failure reason and the index of the target
  the failure happened in.

  The signature captures the essential properties for equivalence checking.
  """
  #
  # A `%Failure{}` already carries its (globally-unique) kind and, for named
  # kinds, its name; the envelope's `branch_id` is deliberately NOT part of the
  # signature, so a branch failure is equivalent to the same failure on the
  # linear path (matching the old branch-unwrapping behaviour). The `name` keeps
  # distinct checks from being conflated, and keeps an async-observed
  # check failure equivalent to a teardown failure of the same check.
  @spec failure_signature(Failure.t() | term(), non_neg_integer()) :: failure_signature()
  def failure_signature(%Failure{} = failure, variant_index) do
    {Failure.kind(failure), Failure.name(failure), variant_index}
  end

  def failure_signature(_other, variant_index) do
    {:unknown, nil, variant_index}
  end

  @doc """
  Check if two failures are equivalent.

  Each failure is given as `{reason, variant_index}`. Two failures are
  equivalent if they have the same kind, (for check failures) the same check
  name, and happened in the same target.
  """
  @spec equivalent_failures?({term(), non_neg_integer()}, {term(), non_neg_integer()}) ::
          boolean()
  def equivalent_failures?({reason1, index1}, {reason2, index2}) do
    failure_signature(reason1, index1) == failure_signature(reason2, index2)
  end

  # Stutter reproduction config for shrinking (DR-029). A stutter failure
  # (idempotency violation / stutter execution failure) only reproduces if the
  # offending command is stuttered, but its index shifts as truncation removes
  # earlier commands, so the original probabilistic decision is not stable.
  # Forcing probability 1.0 (keeping the original command filter, comparison, and
  # max_repeats) makes every eligible command stutter on every reproduction, so
  # the violation reproduces regardless of position. Non-stutter failures return
  # nil so the shrinker re-runs without stutter, exactly as before P4.
  defp stutter_repro_config({kind, _name, _variant_index}, %Stutter.Config{} = config)
       when kind in [:idempotency_violation, :stutter_execution_failed] do
    %{config | probability: 1.0, enabled: true}
  end

  defp stutter_repro_config(_signature, _config), do: nil

  @doc """
  Shrink a failing command sequence.

  Every candidate is a fresh execution of the run's targets. A linear candidate
  runs through `PropertyDamage.Scheduler.run/1` with every target, which sets
  each target up and tears it down again, so nothing (an event queue, a mock
  registry, adapter state) carries over from one attempt to the next. A
  branching candidate runs on the one target through
  `PropertyDamage.Executor.run/4`, with its own event queue, injectors and mocks
  per attempt. The model's `setup_each/1` runs before every attempt.

  ## Parameters

  - `sequence` - The original failing sequence (or list for backwards compatibility)
  - `opts` - Shrinking options:
    - `:failed_at_index` - Index where the failure occurred (required)
    - `:failure_reason` - Original failure reason for equivalence checking (optional but recommended)
    - `:variant_index` - Index of the target the failure happened in (default `0`)
    - `:model` - Model module (required)
    - `:targets` - The run's `[%PropertyDamage.Target{}]`, reference first
      (required); a branching sequence takes exactly one
    - `:concurrency`, `:compare`, `:check_mode` - as on `PropertyDamage.run/1`
      (defaults `:serial`, `[converge_within: 5_000]`, `:halt`)
    - `:rng_seed` - The run's effective seed: each attempt runs as run 0 of it,
      so the per-target RNG and the stutter decisions match the original run
      (default `0`)
    - `:run_nonce` - The run nonce for client-minted values (DR-034)
    - `:mint_epoch_counter` - `:atomics` counter every attempt draws a fresh
      mint epoch from (DR-034; default a new counter, so epochs start at 1)
    - `:stutter_config` - The run's stutter configuration; a stutter failure is
      reproduced with stutter forced on (DR-029)
    - `:config` - Shrinker.Config struct (default: Config.new())

  ## Returns

  A shrink_result map containing the minimal failing sequence.
  """
  @spec shrink(Sequence.t() | [struct()], keyword()) :: shrink_result()
  def shrink(sequence_or_commands, opts)

  def shrink(%Sequence{branches: nil} = sequence, opts) do
    # Linear sequence
    shrink_linear(sequence, opts)
  end

  def shrink(%Sequence{} = sequence, opts) do
    # Branching sequence
    shrink_branching(sequence, opts)
  end

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
        registry: sequence.registry
      })

    # Truncating at the failure point is an optimization, not an assumption
    # we may act on blindly: the index can be nil (poll timeouts, record
    # mode) or branch-relative (converted branching sequences), so the
    # truncated base must be VERIFIED to still fail before it replaces the
    # full sequence.
    shrink_state =
      with true <- is_integer(failed_at_index),
           truncated = Enum.take(commands, failed_at_index + 1),
           truncated_positions = Enum.take(shrink_state.positions, failed_at_index + 1),
           true <- length(truncated) < length(commands),
           true <- still_fails?(truncated, truncated_positions, shrink_state) do
        %{
          shrink_state
          | commands: truncated,
            positions: truncated_positions,
            iterations: shrink_state.iterations + 1
        }
      else
        _ -> shrink_state
      end

    # Phase 1: Sequence shrinking
    shrink_state = shrink_sequence(shrink_state)

    # Phase 2: Argument shrinking (if enabled)
    shrink_state =
      if shrink_state.config.shrink_arguments do
        shrink_arguments(shrink_state)
      else
        shrink_state
      end

    end_time = System.monotonic_time(:millisecond)

    %{
      # Carry the remapped registry so the shrunk sequence (reported and
      # replayed) still resolves its externals.
      sequence:
        Sequence.with_registry(
          Sequence.linear(shrink_state.commands),
          remap_registry(shrink_state.registry, shrink_state.positions)
        ),
      iterations: shrink_state.iterations,
      time_ms: end_time - shrink_state.start_time
    }
  end

  # The state every shrink starts from: the run to re-execute, the failure to
  # preserve, and the budget.
  defp base_state(opts) do
    variant_index = Keyword.get(opts, :variant_index, 0)

    original_signature =
      case Keyword.get(opts, :failure_reason) do
        nil -> nil
        reason -> failure_signature(reason, variant_index)
      end

    %{
      model: Keyword.fetch!(opts, :model),
      targets: Keyword.fetch!(opts, :targets),
      concurrency: Keyword.get(opts, :concurrency, :serial),
      compare: Keyword.get(opts, :compare, converge_within: 5_000),
      check_mode: Keyword.get(opts, :check_mode, :halt),
      config: Keyword.get(opts, :config, Config.new()),
      iterations: 0,
      start_time: System.monotonic_time(:millisecond),
      original_signature: original_signature,
      # Stutter reproduction (DR-029): when the original failure is a stutter
      # failure, reproduce it during shrinking with stutter forced on (prob 1.0)
      # so index-shift under truncation cannot un-stutter the offending command.
      # nil for non-stutter failures, leaving normal shrinking unperturbed.
      stutter_config:
        stutter_repro_config(original_signature, Keyword.get(opts, :stutter_config)),
      # The run's effective seed: every attempt runs as run 0 of it, so the
      # per-target RNG and the stutter base match the original run.
      rng_seed: Keyword.get(opts, :rng_seed) || 0,
      # Client-minted run-scoped values (DR-034): each shrink attempt is a fresh
      # SUT execution, so it draws a distinct mint_epoch from this monotonic
      # counter. On a non-resettable SUT that keeps attempts from re-sending the
      # exploration run's (epoch 0) minted values and colliding with it.
      run_nonce: Keyword.get(opts, :run_nonce),
      mint_epoch_counter: Keyword.get(opts, :mint_epoch_counter) || :atomics.new(1, signed: false)
    }
  end

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
  # Branching Sequence Shrinking
  # ============================================================================

  defp shrink_branching(sequence, opts) do
    shrink_state =
      opts
      |> base_state()
      |> Map.merge(%{
        sequence: sequence,
        # The placeholder registry (DR-021), whose producer_link is keyed by the
        # ORIGINAL structured positions. Kept pristine; each candidate is executed
        # with a copy remapped onto the candidate's own positions (see
        # still_fails_branch?), and the final result carries the same remap.
        registry: sequence.registry,
        # A structural mirror of `sequence` holding each surviving command's
        # ORIGINAL Position (a %Sequence{} of positions, parallel to `sequence`).
        # Kept in lockstep with every removal so we can rebuild the original ->
        # candidate position map the registry remap needs. This is the branching
        # analogue of shrink_linear's parallel `positions` list.
        positions: initial_branch_positions(sequence),
        failed_at_index: Keyword.fetch!(opts, :failed_at_index)
      })

    # Strategy 1: Try converting to linear (maybe race isn't needed)
    shrink_state = try_convert_to_linear(shrink_state)

    # Strategy 2: Remove entire branches
    shrink_state = try_remove_branches(shrink_state)

    # Strategy 3: Shrink individual branches
    shrink_state = shrink_branch_contents(shrink_state)

    # Strategy 4: Shrink prefix and suffix
    shrink_state = shrink_prefix_suffix(shrink_state)

    # Strategy 5: Argument shrinking (if enabled)
    shrink_state =
      if shrink_state.config.shrink_arguments do
        shrink_branch_arguments(shrink_state)
      else
        shrink_state
      end

    end_time = System.monotonic_time(:millisecond)

    %{
      # Carry the remapped registry so the shrunk sequence (reported and
      # replayed) still resolves its externals against its own positions.
      sequence:
        Sequence.with_registry(
          shrink_state.sequence,
          remap_branch_registry(
            shrink_state.registry,
            shrink_state.positions,
            shrink_state.sequence
          )
        ),
      iterations: shrink_state.iterations,
      time_ms: end_time - shrink_state.start_time
    }
  end

  # The original structured positions of a branching sequence, laid out as a
  # %Sequence{} mirror so removals stay in lockstep with the command sequence
  # (DR-021). Each slot holds the Position that keys the registry's producer_link.
  defp initial_branch_positions(%Sequence{prefix: prefix, branches: branches, suffix: suffix}) do
    %Sequence{
      prefix: prefix |> Enum.with_index() |> Enum.map(fn {_c, i} -> Position.prefix(i) end),
      branches:
        (branches || [])
        |> Enum.with_index()
        |> Enum.map(fn {branch, id} ->
          branch |> Enum.with_index() |> Enum.map(fn {_c, i} -> Position.branch(id, i) end)
        end),
      suffix: suffix |> Enum.with_index() |> Enum.map(fn {_c, i} -> Position.suffix(i) end)
    }
  end

  # Remap a registry's producer_link from original positions onto the positions
  # `candidate_seq` will actually run at (DR-021). `positions` mirrors
  # `candidate_seq` structurally and holds each command's original position, so
  # zipping its reading-order flattening against `candidate_seq`'s own canonical
  # positions gives the original -> candidate map. A producer whose command was
  # removed is absent from `positions` and so is dropped, exactly as on the
  # linear path.
  defp remap_branch_registry(nil, _positions, _candidate_seq), do: nil

  defp remap_branch_registry(registry, positions, candidate_seq) do
    orig_positions = Sequence.to_list(positions)

    new_positions =
      candidate_seq |> Sequence.indexed() |> Enum.map(fn {position, _idx, _cmd} -> position end)

    orig_to_new = orig_positions |> Enum.zip(new_positions) |> Map.new()
    PlaceholderRegistry.remap_positions(registry, orig_to_new)
  end

  defp try_convert_to_linear(state) do
    if exceeded_limits?(state) do
      state
    else
      # Try flattening to linear sequence. The registry's producer_link is keyed
      # by the branch-structured positions, so it must be remapped onto the flat
      # prefix positions the flattened sequence runs at (DR-021); otherwise a
      # consumer strands and the linear re-run fails with a different signature,
      # spuriously blocking the (valid) conversion.
      linear_base = Sequence.linear(Sequence.to_list(state.sequence))
      linear_registry = remap_branch_registry(state.registry, state.positions, linear_base)
      linear_seq = Sequence.with_registry(linear_base, linear_registry)
      state = increment_iterations(state)

      case linear_run_result(linear_seq, state) do
        {:reproduces, linear_failed_at_index} ->
          # Race not required - convert to linear and continue with linear
          # shrinking. Hand shrink_linear the failure index from THIS linear
          # re-run, not the original `state.failed_at_index`: the latter is a
          # branch-relative coordinate (`branch_start_index + position`) that is
          # smaller than the failing command's position in the flattened
          # sequence, so it would truncate too short, drop the failing command,
          # and leave the full flatten to the (budget-bounded) one-by-one
          # fixpoint. The linear index is self-consistent with `linear_seq`, so
          # Phase-1 truncation targets the real failure point.
          linear_result =
            shrink_linear(linear_seq,
              failed_at_index: linear_failed_at_index,
              model: state.model,
              targets: state.targets,
              concurrency: state.concurrency,
              compare: state.compare,
              check_mode: state.check_mode,
              config: state.config,
              failure_reason: reconstruct_failure_reason(state.original_signature),
              variant_index: signature_variant(state.original_signature),
              # Carry stutter reproduction into the converted-linear shrink. The
              # config is already forced (re-forcing is idempotent).
              stutter_config: state.stutter_config,
              rng_seed: state.rng_seed,
              # One mint-epoch counter for every attempt of this shrink (DR-034).
              run_nonce: state.run_nonce,
              mint_epoch_counter: state.mint_epoch_counter
            )

          # shrink_linear returns a linear sequence carrying a registry already
          # remapped onto its own compact prefix positions. Re-base the tracking
          # state on that so the remaining (branch-guarded no-op, plus prefix/
          # suffix and argument) strategies and the final remap keep operating on
          # a consistent registry/positions pair.
          converted = linear_result.sequence

          %{
            state
            | sequence: converted,
              registry: converted.registry,
              positions: initial_branch_positions(converted),
              iterations: state.iterations + linear_result.iterations
          }

        :no_reproduce ->
          state
      end
    end
  end

  defp try_remove_branches(state) do
    %Sequence{branches: branches} = state.sequence

    if is_nil(branches) or length(branches) <= 2 or exceeded_limits?(state) do
      state
    else
      # Try removing each branch
      do_remove_branches(state, 0)
    end
  end

  defp do_remove_branches(state, index) do
    %Sequence{branches: branches} = state.sequence

    if is_nil(branches) or index >= length(branches) or exceeded_limits?(state) do
      state
    else
      # Try removing branch at index
      new_branches = List.delete_at(branches, index)

      if length(new_branches) >= 2 do
        candidate = %{state.sequence | branches: new_branches}
        # Drop the same branch from the position mirror so the two stay aligned.
        candidate_positions = %{
          state.positions
          | branches: List.delete_at(state.positions.branches, index)
        }

        state = increment_iterations(state)

        if still_fails_branch?(candidate, candidate_positions, state) do
          new_state = %{state | sequence: candidate, positions: candidate_positions}
          do_remove_branches(new_state, index)
        else
          do_remove_branches(state, index + 1)
        end
      else
        state
      end
    end
  end

  defp shrink_branch_contents(state) do
    %Sequence{branches: branches} = state.sequence

    if is_nil(branches) or exceeded_limits?(state) do
      state
    else
      # Shrink each branch individually
      {new_branches, new_state} =
        Enum.reduce(Enum.with_index(branches), {[], state}, fn {branch, idx}, {acc, s} ->
          if exceeded_limits?(s) do
            {[branch | acc], s}
          else
            {shrunk_branch, updated_state} = shrink_single_branch(branch, idx, s)
            {[shrunk_branch | acc], updated_state}
          end
        end)

      new_branches = Enum.reverse(new_branches)
      %{new_state | sequence: %{state.sequence | branches: new_branches}}
    end
  end

  defp shrink_single_branch(branch, branch_idx, state) do
    # Try removing commands from this branch, prioritizing probe commands
    prioritized_indices = sort_indices_by_shrink_priority(branch)
    do_shrink_single_branch(branch, branch_idx, state, prioritized_indices)
  end

  defp do_shrink_single_branch(branch, _branch_idx, state, []) do
    {branch, state}
  end

  defp do_shrink_single_branch(branch, _branch_idx, state, _indices)
       when length(branch) <= 1 do
    {branch, state}
  end

  defp do_shrink_single_branch(branch, branch_idx, state, [index | rest_indices]) do
    if exceeded_limits?(state) do
      {branch, state}
    else
      # Try removing command at index. The branch is replaced BY POSITION:
      # value-matching would also mutate a structurally identical sibling.
      candidate_branch = List.delete_at(branch, index)
      new_branches = List.replace_at(state.sequence.branches, branch_idx, candidate_branch)
      candidate_seq = %{state.sequence | branches: new_branches}

      # Mirror the same by-position removal in the position tracker.
      pos_branch = Enum.at(state.positions.branches, branch_idx)
      candidate_pos_branch = List.delete_at(pos_branch, index)

      new_pos_branches =
        List.replace_at(state.positions.branches, branch_idx, candidate_pos_branch)

      candidate_positions = %{state.positions | branches: new_pos_branches}

      state = increment_iterations(state)

      if still_fails_branch?(candidate_seq, candidate_positions, state) do
        new_state = %{state | sequence: candidate_seq, positions: candidate_positions}
        # Recompute priorities for the shrunk branch
        new_prioritized = sort_indices_by_shrink_priority(candidate_branch)
        do_shrink_single_branch(candidate_branch, branch_idx, new_state, new_prioritized)
      else
        do_shrink_single_branch(branch, branch_idx, state, rest_indices)
      end
    end
  end

  defp shrink_prefix_suffix(state) do
    if exceeded_limits?(state) do
      state
    else
      # Shrink prefix
      state = shrink_seq_part(state, :prefix)
      # Shrink suffix
      shrink_seq_part(state, :suffix)
    end
  end

  defp shrink_seq_part(state, part) do
    commands = Map.get(state.sequence, part)
    # Prioritize probe commands for removal
    prioritized_indices = sort_indices_by_shrink_priority(commands)
    do_shrink_seq_part(state, part, commands, prioritized_indices)
  end

  defp do_shrink_seq_part(state, _part, _commands, []) do
    state
  end

  defp do_shrink_seq_part(state, _part, commands, _indices)
       when commands == [] do
    state
  end

  defp do_shrink_seq_part(state, part, commands, [index | rest_indices]) do
    if exceeded_limits?(state) do
      state
    else
      candidate_commands = List.delete_at(commands, index)
      candidate_seq = Map.put(state.sequence, part, candidate_commands)

      # Mirror the removal in the position tracker's matching section.
      pos_commands = Map.get(state.positions, part)
      candidate_positions = Map.put(state.positions, part, List.delete_at(pos_commands, index))

      state = increment_iterations(state)

      if still_fails_branch?(candidate_seq, candidate_positions, state) do
        new_state = %{state | sequence: candidate_seq, positions: candidate_positions}
        # Recompute priorities for the shrunk commands
        new_prioritized = sort_indices_by_shrink_priority(candidate_commands)
        do_shrink_seq_part(new_state, part, candidate_commands, new_prioritized)
      else
        do_shrink_seq_part(state, part, commands, rest_indices)
      end
    end
  end

  defp shrink_branch_arguments(state) do
    # Shrink arguments in all parts of the sequence
    all_commands = Sequence.to_list(state.sequence)
    shrunk_commands = Enum.map(all_commands, &shrink_command_args/1)

    # Rebuild sequence with shrunk commands
    # This is a simplification - proper implementation would track positions
    candidate = rebuild_sequence_with_commands(state.sequence, shrunk_commands)

    state = increment_iterations(state)

    # Argument shrinking replaces commands in place, so the structure (and thus
    # the position tracker) is unchanged.
    if still_fails_branch?(candidate, state.positions, state) do
      %{state | sequence: candidate}
    else
      state
    end
  end

  defp rebuild_sequence_with_commands(%Sequence{branches: nil} = seq, commands) do
    %{seq | prefix: commands, suffix: []}
  end

  defp rebuild_sequence_with_commands(seq, commands) do
    # Simple rebuild - take prefix, then branches, then suffix
    prefix_len = length(seq.prefix)
    branch_lens = Enum.map(seq.branches, &length/1)
    total_branch_len = Enum.sum(branch_lens)

    {prefix, rest} = Enum.split(commands, prefix_len)
    {branch_commands, suffix} = Enum.split(rest, total_branch_len)

    # Redistribute branch commands
    {branches, _} =
      Enum.reduce(branch_lens, {[], branch_commands}, fn len, {acc, remaining} ->
        {branch, rest} = Enum.split(remaining, len)
        {[branch | acc], rest}
      end)

    %{seq | prefix: prefix, branches: Enum.reverse(branches), suffix: suffix}
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
      # nodes still depend on so refs stay resolvable. Everything here is in
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

        if valid_candidate?(candidate, state) and
             still_fails?(candidate, candidate_positions, state) do
          new_state = %{state | commands: candidate, positions: candidate_positions}
          try_remove_levels(new_state, original, orig_positions, graph, rest, expanded)
        else
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
    prioritized_indices = sort_indices_by_shrink_priority(state.commands)
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
  # Reads the :shrink key from the command's resolved spec; spec-less commands
  # default to :neutral.
  defp shrink_priority_for_command(cmd) when is_struct(cmd) do
    case Map.get(resolved_shrink_spec(cmd.__struct__), :shrink, :neutral) do
      :prefer_remove -> 0
      :neutral -> 1
      :prefer_keep -> 2
    end
  end

  defp shrink_priority_for_command(_cmd), do: 1

  defp resolved_shrink_spec(module) do
    if function_exported?(module, :command_spec, 1) do
      module.command_spec([])
    else
      PropertyDamage.Command.framework_defaults()
    end
  end

  defp sort_indices_by_shrink_priority(commands) do
    commands
    |> Enum.with_index()
    |> Enum.sort_by(fn {cmd, _idx} ->
      shrink_priority_for_command(cmd)
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
      if protected_async?(command, position, state.registry, remaining) do
        do_linear_shrink(state, rest_indices)
      else
        candidate = List.delete_at(state.commands, index)
        candidate_positions = List.delete_at(state.positions, index)

        state = increment_iterations(state)

        if valid_candidate?(candidate, state) and
             still_fails?(candidate, candidate_positions, state) do
          # Command was removed, recompute priorities for remaining commands
          new_state = %{state | commands: candidate, positions: candidate_positions}
          new_prioritized = sort_indices_by_shrink_priority(candidate)
          do_linear_shrink(new_state, new_prioritized)
        else
          do_linear_shrink(state, rest_indices)
        end
      end
    end
  end

  defp shrink_arguments(state) do
    do_shrink_arguments(state, 0)
  end

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
        if valid_candidate?(candidate, state) and still_fails?(candidate, state.positions, state) do
          new_state = %{state | commands: candidate}
          do_shrink_arguments(new_state, index)
        else
          do_shrink_arguments(state, index + 1)
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
  defp valid_candidate?(commands, state) do
    Validator.valid_sequence?(commands, state.model)
  rescue
    _ -> false
  end

  # A fresh mint epoch for the next shrink attempt (DR-034). Monotonic across
  # this shrink's attempts (and never 0, the exploration run's epoch), so each
  # re-execution sends distinct client-minted values on a non-resettable SUT.
  defp next_mint_epoch(state), do: :atomics.add_get(state.mint_epoch_counter, 1, 1)

  defp still_fails?(commands, positions, state) do
    # Regenerate idempotency keys to ensure fresh SUT state
    commands = regenerate_idempotency_keys(commands)

    # The candidate's registry has its producer_link remapped to the candidate's
    # positions (DR-021), so externals resolve against the shrunk sequence's own
    # indices.
    case run_linear_attempt(commands, remap_registry(state.registry, positions), state) do
      {:failed, reason, variant_index, _root} ->
        check_failure_equivalence(reason, variant_index, state.original_signature)

      _passed_or_not_run ->
        false
    end
  end

  # Like still_fails_branch?/3, but also surfaces the LINEAR failure index from
  # the re-run so the caller can hand shrink_linear a truncation coordinate that
  # is consistent with the (flattened) candidate sequence. Returns
  # `{:reproduces, linear_failed_at_index}` when the candidate reproduces the
  # equivalent failure (the index may be nil for poll/record-mode or
  # setup-level failures, which shrink_linear tolerates by skipping
  # truncation), or `:no_reproduce` otherwise. Used only at the
  # convert-to-linear seam; the other branch strategies need only the boolean.
  defp linear_run_result(sequence, state) do
    # Regenerate idempotency keys to ensure fresh SUT state
    sequence = regenerate_sequence_idempotency_keys(sequence)

    case run_linear_attempt(Sequence.to_list(sequence), sequence.registry, state) do
      {:failed, reason, variant_index, root} ->
        if check_failure_equivalence(reason, variant_index, state.original_signature),
          do: {:reproduces, root},
          else: :no_reproduce

      _passed_or_not_run ->
        :no_reproduce
    end
  end

  # One linear shrink attempt: the model's setup_each/1, then the candidate on
  # every target through the scheduler, which sets each target up and tears it
  # down. Returns `{:failed, reason, variant_index, root}`, `:passed`, or
  # `:not_run` when setup_each/1 failed (the candidate is then kept, as if it
  # passed).
  defp run_linear_attempt(commands, registry, state) do
    case call_setup_each(state) do
      :ok ->
        {:ok, run} =
          Scheduler.run(
            model: state.model,
            targets: state.targets,
            commands: commands,
            # A sequence built by hand may carry no registry: its candidates
            # resolve nothing, as on the linear engine.
            placeholder_registry: registry || PlaceholderRegistry.new(),
            seed: state.rng_seed,
            run_number: 0,
            run_nonce: state.run_nonce,
            mint_epoch: next_mint_epoch(state),
            concurrency: state.concurrency,
            compare: state.compare,
            stutter_config: state.stutter_config,
            check_mode: state.check_mode
          )

        case run.failure do
          nil ->
            :passed

          %{reason: reason, variant: %{index: index}, root: root} ->
            {:failed, reason, index, root}
        end

      {:error, _reason} ->
        :not_run
    end
  end

  defp still_fails_branch?(sequence, positions, state) do
    # Call setup_each to reset SUT state before each shrink attempt
    case call_setup_each(state) do
      :ok ->
        # Regenerate idempotency keys to ensure fresh SUT state
        sequence = regenerate_sequence_idempotency_keys(sequence)

        # Attach a registry whose producer_link is remapped onto THIS candidate's
        # positions (DR-021), so externals resolve against the shrunk sequence's
        # own indices instead of the stale original ones.
        sequence =
          Sequence.with_registry(
            sequence,
            remap_branch_registry(state.registry, positions, sequence)
          )

        # A branching sequence runs on its one target, through the linear
        # engine, with its own event queue, injectors and mocks per attempt.
        [target] = state.targets

        run_result =
          RunServices.with_services(target, fn event_queue, mock_registry ->
            Executor.run(sequence, state.model, target.adapter,
              config: target.config,
              event_queue: event_queue,
              mock_registry: mock_registry,
              stutter_config: state.stutter_config,
              rng_seed: state.rng_seed,
              run_nonce: state.run_nonce,
              mint_epoch: next_mint_epoch(state),
              telemetry: Telemetry.engine_context(%{index: target.index, name: target.name}, 0)
            )
          end)

        case run_result do
          {:ok, %{success: true}} ->
            false

          {:ok, result} ->
            check_failure_equivalence(result.failure_reason, 0, state.original_signature)

          # The adapter's setup/1 failed: a setup failure of the one target.
          {:error, reason} ->
            check_failure_equivalence(Failure.setup_failed(reason), 0, state.original_signature)
        end

      {:error, _reason} ->
        # If setup_each fails, treat as if shrink candidate passed (don't remove)
        false
    end
  end

  # Call setup_each if the model implements it, with the reference target's
  # config.
  defp call_setup_each(%{model: model, targets: [reference | _]}) do
    if function_exported?(model, :setup_each, 1) do
      model.setup_each(%{adapter_config: reference.config})
    else
      :ok
    end
  end

  # Check if a failure matches the original signature
  defp check_failure_equivalence(failure_reason, variant_index, nil) do
    # No original signature: we can't prove equivalence, so for backwards
    # compatibility we accept any failure EXCEPT ones that are unmistakably
    # shrink artifacts. A dangling-ref / ref-resolution error only appears
    # because a producing command was removed; accepting it would pass off a
    # different bug as the "minimal repro". (When a signature IS present, the
    # comparison below already rejects these unless the original was itself a
    # ref-resolution error.)
    elem(failure_signature(failure_reason, variant_index), 0) != :placeholder_resolution
  end

  defp check_failure_equivalence(failure_reason, variant_index, original_signature) do
    # Same signature (kind + name + target) means the same bug. The kind carries
    # whatever the old per-type/check-name logic needed: named kinds compare
    # names, nameless kinds both carry nil. A failure in another target, or of
    # another kind, is a different failure.
    failure_signature(failure_reason, variant_index) == original_signature
  end

  # Reconstruct a minimal %Failure{} from a signature for passing to nested
  # shrink calls, which only consult its signature (kind + name) for equivalence;
  # the target travels separately as the variant index. The rebuilt failure
  # yields the signature it was built from, a divergence's name included.
  defp reconstruct_failure_reason(nil), do: nil

  defp reconstruct_failure_reason({:check_failed, name, _variant_index}) do
    Failure.check_failed(name, "")
  end

  defp reconstruct_failure_reason({kind, name, _variant_index}) do
    Failure.from_signature(kind, name)
  end

  defp signature_variant(nil), do: 0
  defp signature_variant({_kind, _name, variant_index}), do: variant_index

  defp exceeded_limits?(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.start_time

    state.iterations >= state.config.max_iterations or
      elapsed >= state.config.max_time_ms
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
  defp protected_async?(command, position, registry, downstream_commands) do
    with true <- is_struct(command),
         true <- Settle.get_semantics(command) == :async,
         %PlaceholderRegistry{} <- registry,
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

  # Regenerate idempotency keys for a sequence (handles branching)
  defp regenerate_sequence_idempotency_keys(%Sequence{} = sequence) do
    Sequence.map(sequence, &regenerate_command_idempotency_key/1)
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
