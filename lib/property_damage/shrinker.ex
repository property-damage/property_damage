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

  The accepted candidate's failure must match the original on two dimensions,
  compared by `check_failure_equivalence/2` (via its failure *signature*):
  - Same failure type (`:check_failed`, `:idempotency_violation`, etc.)
  - Same check name (for invariant violations)

  A third property also holds: the failure occurs at the **same or an earlier
  command index** than in the original. This one is guaranteed *structurally*
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
  # After a failure at index 5
  shrunk = Shrinker.shrink(
    sequence,
    failed_at_index: 5,
    failure_reason: {:check_failed, :balance_invariant, "..."},
    model: MyModel,
    adapter: MyAdapter,
    config: config
  )
  ```
  """

  alias PropertyDamage.{
    Executor,
    Placeholder,
    PlaceholderRegistry,
    Sequence,
    Settle,
    Stutter
  }

  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Sequence.Validator

  alias PropertyDamage.Shrinker.{Config, Graph}

  @typedoc """
  Failure signature for equivalence checking.

  Contains the essential properties that must match for a shrunk
  sequence to be considered as reproducing the "same" failure.
  """
  @type failure_signature :: %{
          type: atom(),
          check_name: atom() | nil
        }

  @typedoc """
  Result of shrinking.
  """
  @type shrink_result :: %{
          sequence: Sequence.t(),
          iterations: non_neg_integer(),
          time_ms: non_neg_integer()
        }

  @doc """
  Extract a failure signature from a failure reason.

  The signature captures the essential properties for equivalence checking.
  """
  @spec failure_signature(term()) :: failure_signature()
  def failure_signature({:check_failed, check_name, _message}) do
    %{type: :check_failed, check_name: check_name}
  end

  def failure_signature({:idempotency_violation, _details}) do
    %{type: :idempotency_violation, check_name: nil}
  end

  def failure_signature({:linearization_failed, _message}) do
    %{type: :linearization_failed, check_name: nil}
  end

  def failure_signature({:branch_failure, _branch_id, inner_reason}) do
    # Unwrap branch failures to get the actual failure type
    failure_signature(inner_reason)
  end

  def failure_signature({:adapter_error, _reason}) do
    %{type: :adapter_error, check_name: nil}
  end

  def failure_signature({:ref_resolution_error, _reason}) do
    %{type: :ref_resolution_error, check_name: nil}
  end

  def failure_signature({:stutter_execution_failed, _reason}) do
    %{type: :stutter_execution_failed, check_name: nil}
  end

  # A named assertion failure (@trigger / @trigger at:, including async ones
  # observed via DR-025). Record the assertion name as the check name so the
  # shrinker does not conflate distinct assertions as the same bug, and so an
  # async-observed failure stays equivalent to a teardown failure of the same
  # assertion. Must precede the generic tuple clause below.
  def failure_signature({:assertion_failed, name, _}) do
    %{type: :assertion_failed, check_name: name}
  end

  def failure_signature(other) when is_tuple(other) do
    # Extract first element as type for unknown tuple formats
    %{type: elem(other, 0), check_name: nil}
  end

  def failure_signature(_other) do
    %{type: :unknown, check_name: nil}
  end

  @doc """
  Check if two failure reasons are equivalent.

  Two failures are equivalent if they have the same type and
  (for check failures) the same check name.
  """
  @spec equivalent_failures?(term(), term()) :: boolean()
  def equivalent_failures?(reason1, reason2) do
    sig1 = failure_signature(reason1)
    sig2 = failure_signature(reason2)

    sig1.type == sig2.type and sig1.check_name == sig2.check_name
  end

  # Stutter reproduction config for shrinking (DR-029). A stutter failure
  # (idempotency violation / stutter execution failure) only reproduces if the
  # offending command is stuttered, but its index shifts as truncation removes
  # earlier commands, so the original probabilistic decision is not stable.
  # Forcing probability 1.0 (keeping the original command filter, comparison, and
  # max_repeats) makes every eligible command stutter on every reproduction, so
  # the violation reproduces regardless of position. Non-stutter failures return
  # nil so the shrinker re-runs without stutter, exactly as before P4.
  defp stutter_repro_config(%{type: type}, %Stutter.Config{} = config)
       when type in [:idempotency_violation, :stutter_execution_failed] do
    %{config | probability: 1.0, enabled: true}
  end

  defp stutter_repro_config(_signature, _config), do: nil

  @doc """
  Shrink a failing command sequence.

  ## Parameters

  - `sequence` - The original failing sequence (or list for backwards compatibility)
  - `opts` - Shrinking options:
    - `:failed_at_index` - Index where the failure occurred (required)
    - `:failure_reason` - Original failure reason for equivalence checking (optional but recommended)
    - `:model` - Model module (required)
    - `:adapter` - Adapter module (required)
    - `:adapter_config` - Config for adapter setup (default: %{})
    - `:config` - Shrinker.Config struct (default: Config.new())
    - `:event_queue` - EventQueue pid for injector events (optional)

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
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    config = Keyword.get(opts, :config, Config.new())
    event_queue = Keyword.get(opts, :event_queue)
    original_failure = Keyword.get(opts, :failure_reason)

    start_time = System.monotonic_time(:millisecond)

    commands = Sequence.to_list(sequence)

    # Compute the failure signature we need to preserve
    original_signature =
      if original_failure do
        failure_signature(original_failure)
      else
        nil
      end

    shrink_state = %{
      commands: commands,
      # Parallel to `commands`: the original structured position of each command
      # (DR-021). A linear sequence is all prefix positions. Kept in lockstep with
      # removals so the placeholder registry's producer_link can be remapped to
      # each candidate's positions before re-execution.
      positions: original_positions(commands),
      registry: sequence.registry,
      model: model,
      adapter: adapter,
      adapter_config: adapter_config,
      config: config,
      event_queue: event_queue,
      # Per-run mock registry (WP-C5), reused across shrink attempts so a
      # mock-dependent failure keeps reproducing while it minimizes. nil when the
      # run declared no mock services.
      mock_registry: Keyword.get(opts, :mock_registry),
      iterations: 0,
      start_time: start_time,
      original_signature: original_signature,
      # Stutter reproduction (DR-029): when the original failure is a stutter
      # failure, reproduce it during shrinking with stutter forced on (prob 1.0)
      # so index-shift under truncation cannot un-stutter the offending command.
      # nil for non-stutter failures, leaving normal shrinking unperturbed.
      stutter_config:
        stutter_repro_config(original_signature, Keyword.get(opts, :stutter_config)),
      rng_seed: Keyword.get(opts, :rng_seed),
      # Client-minted run-scoped values (DR-034): each shrink attempt is a fresh
      # SUT execution, so it draws a distinct mint_epoch from this monotonic
      # counter. On a non-resettable SUT that keeps attempts from re-sending the
      # exploration run's (epoch 0) minted values and colliding with it.
      run_nonce: Keyword.get(opts, :run_nonce),
      mint_epoch_counter: Keyword.get(opts, :mint_epoch_counter) || :atomics.new(1, signed: false)
    }

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
      if config.shrink_arguments do
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
      time_ms: end_time - start_time
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
    failed_at_index = Keyword.fetch!(opts, :failed_at_index)
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    config = Keyword.get(opts, :config, Config.new())
    event_queue = Keyword.get(opts, :event_queue)
    original_failure = Keyword.get(opts, :failure_reason)

    start_time = System.monotonic_time(:millisecond)

    # Compute the failure signature we need to preserve
    original_signature =
      if original_failure do
        failure_signature(original_failure)
      else
        nil
      end

    shrink_state = %{
      sequence: sequence,
      model: model,
      adapter: adapter,
      adapter_config: adapter_config,
      config: config,
      event_queue: event_queue,
      # Per-run mock registry (WP-C5); see shrink_linear.
      mock_registry: Keyword.get(opts, :mock_registry),
      iterations: 0,
      start_time: start_time,
      failed_at_index: failed_at_index,
      original_signature: original_signature,
      # See shrink_linear: forced-stutter reproduction for stutter failures.
      stutter_config:
        stutter_repro_config(original_signature, Keyword.get(opts, :stutter_config)),
      rng_seed: Keyword.get(opts, :rng_seed),
      # Distinct mint_epoch per attempt (DR-034); see shrink_linear.
      run_nonce: Keyword.get(opts, :run_nonce),
      mint_epoch_counter: Keyword.get(opts, :mint_epoch_counter) || :atomics.new(1, signed: false)
    }

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
      if config.shrink_arguments do
        shrink_branch_arguments(shrink_state)
      else
        shrink_state
      end

    end_time = System.monotonic_time(:millisecond)

    %{
      sequence: shrink_state.sequence,
      iterations: shrink_state.iterations,
      time_ms: end_time - start_time
    }
  end

  defp try_convert_to_linear(state) do
    if exceeded_limits_branch?(state) do
      state
    else
      # Try flattening to linear sequence
      linear_seq = Sequence.linear(Sequence.to_list(state.sequence))
      state = increment_iterations_branch(state)

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
              adapter: state.adapter,
              adapter_config: state.adapter_config,
              config: state.config,
              event_queue: state.event_queue,
              mock_registry: state.mock_registry,
              failure_reason: reconstruct_failure_reason(state.original_signature),
              # Carry stutter reproduction into the converted-linear shrink. The
              # config is already forced (re-forcing is idempotent).
              stutter_config: state.stutter_config,
              rng_seed: state.rng_seed,
              # Carry the run nonce so the nested linear shrink mints too (it
              # allocates its own per-attempt epoch counter).
              run_nonce: state.run_nonce
            )

          %{
            state
            | sequence: linear_result.sequence,
              iterations: state.iterations + linear_result.iterations
          }

        :no_reproduce ->
          state
      end
    end
  end

  defp try_remove_branches(state) do
    %Sequence{branches: branches} = state.sequence

    if is_nil(branches) or length(branches) <= 2 or exceeded_limits_branch?(state) do
      state
    else
      # Try removing each branch
      do_remove_branches(state, 0)
    end
  end

  defp do_remove_branches(state, index) do
    %Sequence{branches: branches} = state.sequence

    if is_nil(branches) or index >= length(branches) or exceeded_limits_branch?(state) do
      state
    else
      # Try removing branch at index
      new_branches = List.delete_at(branches, index)

      if length(new_branches) >= 2 do
        candidate = %{state.sequence | branches: new_branches}
        state = increment_iterations_branch(state)

        if still_fails_branch?(candidate, state) do
          new_state = %{state | sequence: candidate}
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

    if is_nil(branches) or exceeded_limits_branch?(state) do
      state
    else
      # Shrink each branch individually
      {new_branches, new_state} =
        Enum.reduce(Enum.with_index(branches), {[], state}, fn {branch, idx}, {acc, s} ->
          if exceeded_limits_branch?(s) do
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
    if exceeded_limits_branch?(state) do
      {branch, state}
    else
      # Try removing command at index. The branch is replaced BY POSITION:
      # value-matching would also mutate a structurally identical sibling.
      candidate_branch = List.delete_at(branch, index)
      new_branches = List.replace_at(state.sequence.branches, branch_idx, candidate_branch)
      candidate_seq = %{state.sequence | branches: new_branches}

      state = increment_iterations_branch(state)

      if still_fails_branch?(candidate_seq, state) do
        new_state = %{state | sequence: candidate_seq}
        # Recompute priorities for the shrunk branch
        new_prioritized = sort_indices_by_shrink_priority(candidate_branch)
        do_shrink_single_branch(candidate_branch, branch_idx, new_state, new_prioritized)
      else
        do_shrink_single_branch(branch, branch_idx, state, rest_indices)
      end
    end
  end

  defp shrink_prefix_suffix(state) do
    if exceeded_limits_branch?(state) do
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
    if exceeded_limits_branch?(state) do
      state
    else
      candidate_commands = List.delete_at(commands, index)
      candidate_seq = Map.put(state.sequence, part, candidate_commands)

      state = increment_iterations_branch(state)

      if still_fails_branch?(candidate_seq, state) do
        new_state = %{state | sequence: candidate_seq}
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

    state = increment_iterations_branch(state)

    if still_fails_branch?(candidate, state) do
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

    kept = MapSet.new(0..(length(original_commands) - 1))

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

  defp shrink_value(s) when is_binary(s) and byte_size(s) > 0 do
    String.slice(s, 0, div(byte_size(s), 2))
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

  defp valid_candidate?(commands, state) do
    Validator.valid_sequence?(commands, state.model)
  end

  # A fresh mint epoch for the next shrink attempt (DR-034). Monotonic across
  # this shrink's attempts (and never 0, the exploration run's epoch), so each
  # re-execution sends distinct client-minted values on a non-resettable SUT.
  defp next_mint_epoch(state), do: :atomics.add_get(state.mint_epoch_counter, 1, 1)

  defp still_fails?(commands, positions, state) do
    # Call setup_each to reset SUT state before each shrink attempt
    setup_each_result = call_setup_each(state.model, state.adapter_config)

    case setup_each_result do
      :ok ->
        # Regenerate idempotency keys to ensure fresh SUT state
        commands = regenerate_idempotency_keys(commands)

        # Build the candidate as a sequence carrying a registry whose
        # producer_link is remapped to the candidate's positions (DR-021), so
        # externals resolve against the shrunk sequence's own indices.
        candidate_sequence =
          Sequence.with_registry(
            Sequence.linear(commands),
            remap_registry(state.registry, positions)
          )

        case Executor.run(candidate_sequence, state.model, state.adapter,
               adapter_config: state.adapter_config,
               event_queue: state.event_queue,
               mock_registry: state.mock_registry,
               stutter_config: state.stutter_config,
               rng_seed: state.rng_seed,
               run_nonce: state.run_nonce,
               mint_epoch: next_mint_epoch(state)
             ) do
          {:ok, result} ->
            if result.success do
              false
            else
              # Check failure equivalence if we have an original signature
              check_failure_equivalence(result.failure_reason, state.original_signature)
            end

          {:error, _} ->
            # Execution errors are only equivalent if original was also an error
            state.original_signature == nil or state.original_signature.type == :adapter_error
        end

      {:error, _reason} ->
        # If setup_each fails, treat as if shrink candidate passed (don't remove)
        false
    end
  end

  # Like still_fails_branch?/2, but also surfaces the LINEAR failure index from
  # the re-run so the caller can hand shrink_linear a truncation coordinate that
  # is consistent with the (flattened) candidate sequence. Returns
  # `{:reproduces, linear_failed_at_index}` when the candidate reproduces the
  # equivalent failure (the index may be nil for poll/record-mode or
  # execution-level failures, which shrink_linear tolerates by skipping
  # truncation), or `:no_reproduce` otherwise. Used only at the
  # convert-to-linear seam; the other branch strategies need only the boolean.
  defp linear_run_result(sequence, state) do
    case call_setup_each(state.model, state.adapter_config) do
      :ok ->
        # Regenerate idempotency keys to ensure fresh SUT state
        sequence = regenerate_sequence_idempotency_keys(sequence)

        case Executor.run(sequence, state.model, state.adapter,
               adapter_config: state.adapter_config,
               event_queue: state.event_queue,
               mock_registry: state.mock_registry,
               stutter_config: state.stutter_config,
               rng_seed: state.rng_seed,
               run_nonce: state.run_nonce,
               mint_epoch: next_mint_epoch(state)
             ) do
          {:ok, result} ->
            cond do
              result.success ->
                :no_reproduce

              check_failure_equivalence(result.failure_reason, state.original_signature) ->
                {:reproduces, result.failed_at_index}

              true ->
                :no_reproduce
            end

          {:error, _} ->
            # Execution errors are only equivalent if the original was also an
            # error. There is no reliable linear index for such a failure, so
            # signal reproduction with a nil index (shrink_linear skips the
            # truncation when the index is not an integer).
            if state.original_signature == nil or
                 state.original_signature.type == :adapter_error do
              {:reproduces, nil}
            else
              :no_reproduce
            end
        end

      {:error, _reason} ->
        # If setup_each fails, treat as if the candidate passed (don't convert)
        :no_reproduce
    end
  end

  defp still_fails_branch?(sequence, state) do
    # Call setup_each to reset SUT state before each shrink attempt
    setup_each_result = call_setup_each(state.model, state.adapter_config)

    case setup_each_result do
      :ok ->
        # Regenerate idempotency keys to ensure fresh SUT state
        sequence = regenerate_sequence_idempotency_keys(sequence)

        case Executor.run(sequence, state.model, state.adapter,
               adapter_config: state.adapter_config,
               event_queue: state.event_queue,
               mock_registry: state.mock_registry,
               stutter_config: state.stutter_config,
               rng_seed: state.rng_seed,
               run_nonce: state.run_nonce,
               mint_epoch: next_mint_epoch(state)
             ) do
          {:ok, result} ->
            if result.success do
              false
            else
              # Check failure equivalence if we have an original signature
              check_failure_equivalence(result.failure_reason, state.original_signature)
            end

          {:error, _} ->
            # Execution errors are only equivalent if original was also an error
            state.original_signature == nil or state.original_signature.type == :adapter_error
        end

      {:error, _reason} ->
        # If setup_each fails, treat as if shrink candidate passed (don't remove)
        false
    end
  end

  # Call setup_each if the model implements it
  defp call_setup_each(model, adapter_config) do
    if function_exported?(model, :setup_each, 1) do
      model.setup_each(%{adapter_config: adapter_config})
    else
      :ok
    end
  end

  # Check if a failure matches the original signature
  defp check_failure_equivalence(failure_reason, nil) do
    # No original signature: we can't prove equivalence, so for backwards
    # compatibility we accept any failure EXCEPT ones that are unmistakably
    # shrink artifacts. A dangling-ref / ref-resolution error only appears
    # because a producing command was removed; accepting it would pass off a
    # different bug as the "minimal repro". (When a signature IS present, the
    # type check below already rejects these unless the original was itself a
    # ref-resolution error.)
    failure_signature(failure_reason).type != :ref_resolution_error
  end

  defp check_failure_equivalence(failure_reason, original_signature) do
    new_signature = failure_signature(failure_reason)

    # Must have same type
    if new_signature.type != original_signature.type do
      false
    else
      # For check failures, must have same check name
      case original_signature.type do
        :check_failed ->
          new_signature.check_name == original_signature.check_name

        _ ->
          true
      end
    end
  end

  # Reconstruct a minimal failure_reason from a signature for passing through
  # This is used when we need to pass failure_reason to nested shrink calls
  defp reconstruct_failure_reason(nil), do: nil

  defp reconstruct_failure_reason(%{type: :check_failed, check_name: check_name}) do
    {:check_failed, check_name, ""}
  end

  defp reconstruct_failure_reason(%{type: type}) do
    {type, nil}
  end

  defp exceeded_limits?(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.start_time

    state.iterations >= state.config.max_iterations or
      elapsed >= state.config.max_time_ms
  end

  defp exceeded_limits_branch?(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.start_time

    state.iterations >= state.config.max_iterations or
      elapsed >= state.config.max_time_ms
  end

  defp increment_iterations(state) do
    %{state | iterations: state.iterations + 1}
  end

  defp increment_iterations_branch(state) do
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
