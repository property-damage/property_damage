defmodule PropertyDamage.Shrinker do
  @moduledoc """
  Shrinks failing command sequences to minimal reproductions.

  When a property test fails, the Shrinker attempts to find the smallest
  sequence that still reproduces the failure. This makes debugging easier
  by removing irrelevant commands and simplifying arguments.

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
    commands,
    failed_at_index: 5,
    model: MyModel,
    adapter: MyAdapter,
    config: config
  )
  ```
  """

  alias PropertyDamage.{Validator, Executor, Ref}
  alias PropertyDamage.Shrinker.{Config, Graph}

  @typedoc """
  Result of shrinking.
  """
  @type shrink_result :: %{
          commands: [struct()],
          iterations: non_neg_integer(),
          time_ms: non_neg_integer()
        }

  @doc """
  Shrink a failing command sequence.

  ## Parameters

  - `commands` - The original failing command sequence
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
  @spec shrink([struct()], keyword()) :: shrink_result()
  def shrink(commands, opts) do
    failed_at_index = Keyword.fetch!(opts, :failed_at_index)
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    config = Keyword.get(opts, :config, Config.new())
    event_queue = Keyword.get(opts, :event_queue)

    start_time = System.monotonic_time(:millisecond)

    # Phase 1: Drop commands after failure
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

    # Phase 2: Sequence shrinking
    shrink_state = shrink_sequence(shrink_state)

    # Phase 3: Argument shrinking (if enabled)
    shrink_state =
      if config.shrink_arguments do
        shrink_arguments(shrink_state)
      else
        shrink_state
      end

    end_time = System.monotonic_time(:millisecond)

    %{
      commands: shrink_state.commands,
      iterations: shrink_state.iterations,
      time_ms: end_time - start_time
    }
  end

  # Sequence shrinking
  defp shrink_sequence(state) do
    if length(state.commands) <= state.config.granularity_threshold do
      linear_shrink(state)
    else
      hierarchical_shrink(state)
    end
  end

  # Hierarchical shrinking using dependency graph
  defp hierarchical_shrink(state) do
    graph = Graph.build(state.commands)
    levels = Graph.compress(graph)

    # Try removing entire levels from the end
    state = try_remove_levels(state, graph, Enum.reverse(levels))

    # Continue with linear shrinking on remaining commands
    linear_shrink(state)
  end

  defp try_remove_levels(state, _graph, []), do: state

  defp try_remove_levels(state, graph, [level | rest]) do
    if exceeded_limits?(state) do
      state
    else
      # Try removing this level (keeping only commands not in this level)
      keep_indices =
        state.commands
        |> Enum.with_index()
        |> Enum.reject(fn {_cmd, idx} -> idx in level end)
        |> Enum.map(fn {_cmd, idx} -> idx end)

      # Expand to include required dependencies
      expanded = Graph.expand_super_node(graph, keep_indices)
      candidate = select_commands(state.commands, expanded)

      state = increment_iterations(state)

      if still_fails?(candidate, state) do
        # Successfully removed the level
        new_state = %{state | commands: candidate}
        try_remove_levels(new_state, graph, rest)
      else
        # Can't remove this level, try the next
        try_remove_levels(state, graph, rest)
      end
    end
  end

  # Linear shrinking - try removing one command at a time
  defp linear_shrink(state) do
    do_linear_shrink(state, 0)
  end

  defp do_linear_shrink(state, index) do
    if exceeded_limits?(state) or index >= length(state.commands) do
      state
    else
      # Try removing command at index
      candidate = List.delete_at(state.commands, index)

      state = increment_iterations(state)

      if valid_candidate?(candidate, state) and still_fails?(candidate, state) do
        # Successfully removed command
        new_state = %{state | commands: candidate}
        # Try removing from same index (next command shifted down)
        do_linear_shrink(new_state, index)
      else
        # Can't remove, try next index
        do_linear_shrink(state, index + 1)
      end
    end
  end

  # Argument shrinking
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
          # Successfully shrunk arguments
          new_state = %{state | commands: candidate}
          # Try shrinking same command more
          do_shrink_arguments(new_state, index)
        else
          # Can't shrink more, try next command
          do_shrink_arguments(state, index + 1)
        end
      else
        # No more shrinking possible for this command
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

  # Never shrink refs
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

  # Helper functions
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
    # Execute and check if it still fails
    case Executor.run(commands, state.model, state.adapter,
           adapter_config: state.adapter_config,
           event_queue: state.event_queue
         ) do
      {:ok, result} -> not result.success
      # Treat errors as failures
      {:error, _} -> true
    end
  end

  defp exceeded_limits?(state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.start_time

    state.iterations >= state.config.max_iterations or
      elapsed >= state.config.max_time_ms
  end

  defp increment_iterations(state) do
    %{state | iterations: state.iterations + 1}
  end
end
