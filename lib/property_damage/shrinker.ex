defmodule PropertyDamage.Shrinker do
  @moduledoc """
  Shrinks failing command sequences to minimal reproductions.

  When a property test fails, the Shrinker attempts to find the smallest
  sequence that still reproduces the failure. This makes debugging easier
  by removing irrelevant commands and simplifying arguments.

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
    model: MyModel,
    adapter: MyAdapter,
    config: config
  )
  ```
  """

  alias PropertyDamage.{Validator, Executor, Ref, Sequence}
  alias PropertyDamage.Shrinker.{Config, Graph}

  @typedoc """
  Result of shrinking.
  """
  @type shrink_result :: %{
          sequence: Sequence.t(),
          iterations: non_neg_integer(),
          time_ms: non_neg_integer()
        }

  @doc """
  Shrink a failing command sequence.

  ## Parameters

  - `sequence` - The original failing sequence (or list for backwards compatibility)
  - `opts` - Shrinking options:
    - `:failed_at_index` - Index where the failure occurred (required)
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

    start_time = System.monotonic_time(:millisecond)

    # Get command list and truncate at failure point
    commands = Sequence.to_list(sequence)
    commands = Enum.take(commands, failed_at_index + 1)

    shrink_state = %{
      commands: commands,
      model: model,
      adapter: adapter,
      adapter_config: adapter_config,
      config: config,
      event_queue: event_queue,
      iterations: 0,
      start_time: start_time
    }

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
      sequence: Sequence.linear(shrink_state.commands),
      iterations: shrink_state.iterations,
      time_ms: end_time - start_time
    }
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

    start_time = System.monotonic_time(:millisecond)

    shrink_state = %{
      sequence: sequence,
      model: model,
      adapter: adapter,
      adapter_config: adapter_config,
      config: config,
      event_queue: event_queue,
      iterations: 0,
      start_time: start_time,
      failed_at_index: failed_at_index
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

      if still_fails_branch?(linear_seq, state) do
        # Race not required - convert to linear and continue with linear shrinking
        linear_result =
          shrink_linear(linear_seq,
            failed_at_index: state.failed_at_index,
            model: state.model,
            adapter: state.adapter,
            adapter_config: state.adapter_config,
            config: state.config,
            event_queue: state.event_queue
          )

        %{
          state
          | sequence: linear_result.sequence,
            iterations: state.iterations + linear_result.iterations
        }
      else
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
        Enum.reduce(Enum.with_index(branches), {[], state}, fn {branch, _idx}, {acc, s} ->
          if exceeded_limits_branch?(s) do
            {[branch | acc], s}
          else
            {shrunk_branch, updated_state} = shrink_single_branch(branch, s)
            {[shrunk_branch | acc], updated_state}
          end
        end)

      new_branches = Enum.reverse(new_branches)
      %{new_state | sequence: %{state.sequence | branches: new_branches}}
    end
  end

  defp shrink_single_branch(branch, state) do
    # Try removing commands from this branch
    do_shrink_single_branch(branch, state, 0)
  end

  defp do_shrink_single_branch(branch, state, index) do
    if exceeded_limits_branch?(state) or index >= length(branch) or length(branch) <= 1 do
      {branch, state}
    else
      # Try removing command at index
      candidate_branch = List.delete_at(branch, index)
      new_branches = replace_branch(state.sequence.branches, branch, candidate_branch)
      candidate_seq = %{state.sequence | branches: new_branches}

      state = increment_iterations_branch(state)

      if still_fails_branch?(candidate_seq, state) do
        new_state = %{state | sequence: candidate_seq}
        do_shrink_single_branch(candidate_branch, new_state, index)
      else
        do_shrink_single_branch(branch, state, index + 1)
      end
    end
  end

  defp replace_branch(branches, old_branch, new_branch) do
    Enum.map(branches, fn b -> if b == old_branch, do: new_branch, else: b end)
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
    do_shrink_seq_part(state, part, commands, 0)
  end

  defp do_shrink_seq_part(state, _part, commands, index)
       when index >= length(commands) or length(commands) == 0 do
    state
  end

  defp do_shrink_seq_part(state, part, commands, index) do
    if exceeded_limits_branch?(state) do
      state
    else
      candidate_commands = List.delete_at(commands, index)
      candidate_seq = Map.put(state.sequence, part, candidate_commands)

      state = increment_iterations_branch(state)

      if still_fails_branch?(candidate_seq, state) do
        new_state = %{state | sequence: candidate_seq}
        do_shrink_seq_part(new_state, part, candidate_commands, index)
      else
        do_shrink_seq_part(state, part, commands, index + 1)
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
    graph = Graph.build(state.commands)
    levels = Graph.compress(graph)

    state = try_remove_levels(state, graph, Enum.reverse(levels))

    linear_shrink(state)
  end

  defp try_remove_levels(state, _graph, []), do: state

  defp try_remove_levels(state, graph, [level | rest]) do
    if exceeded_limits?(state) do
      state
    else
      keep_indices =
        state.commands
        |> Enum.with_index()
        |> Enum.reject(fn {_cmd, idx} -> idx in level end)
        |> Enum.map(fn {_cmd, idx} -> idx end)

      expanded = Graph.expand_super_node(graph, keep_indices)
      candidate = select_commands(state.commands, expanded)

      state = increment_iterations(state)

      if still_fails?(candidate, state) do
        new_state = %{state | commands: candidate}
        try_remove_levels(new_state, graph, rest)
      else
        try_remove_levels(state, graph, rest)
      end
    end
  end

  defp linear_shrink(state) do
    do_linear_shrink(state, 0)
  end

  defp do_linear_shrink(state, index) do
    if exceeded_limits?(state) or index >= length(state.commands) do
      state
    else
      candidate = List.delete_at(state.commands, index)

      state = increment_iterations(state)

      if valid_candidate?(candidate, state) and still_fails?(candidate, state) do
        new_state = %{state | commands: candidate}
        do_linear_shrink(new_state, index)
      else
        do_linear_shrink(state, index + 1)
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

        if valid_candidate?(candidate, state) and still_fails?(candidate, state) do
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

  defp shrink_value(%Ref{} = ref), do: ref
  defp shrink_value(n) when is_integer(n) and n > 0, do: div(n, 2)
  defp shrink_value(n) when is_integer(n) and n < 0, do: div(n, 2)

  defp shrink_value(s) when is_binary(s) and byte_size(s) > 0 do
    String.slice(s, 0, div(byte_size(s), 2))
  end

  defp shrink_value(list) when is_list(list) and length(list) > 0 do
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

  defp still_fails?(commands, state) do
    case Executor.run(commands, state.model, state.adapter,
           adapter_config: state.adapter_config,
           event_queue: state.event_queue
         ) do
      {:ok, result} -> not result.success
      {:error, _} -> true
    end
  end

  defp still_fails_branch?(sequence, state) do
    case Executor.run(sequence, state.model, state.adapter,
           adapter_config: state.adapter_config,
           event_queue: state.event_queue
         ) do
      {:ok, result} -> not result.success
      {:error, _} -> true
    end
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
end
