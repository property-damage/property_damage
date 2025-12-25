defmodule PropertyDamage.Generator do
  @moduledoc """
  Generates command sequences for stateful property-based testing.

  This module produces `PropertyDamage.Sequence` structs that can be either:
  - **Linear sequences**: Commands executed sequentially
  - **Branching sequences**: Commands with parallel execution branches

  ## Linear Sequence Generation

      Generator.generate_sequence(MyModel, max_commands: 20)
      # => StreamData producing %Sequence{prefix: [...], branches: nil}

  ## Branching Sequence Generation

      Generator.generate_sequence(MyModel,
        max_commands: 20,
        branching: [
          branch_probability: 0.3,  # 30% chance to create branch point
          max_branches: 3,          # Up to 3 parallel branches
          max_branch_length: 5      # Each branch max 5 commands
        ]
      )
      # => StreamData producing %Sequence{prefix: [...], branches: [[...], [...]], suffix: [...]}

  ## Ref Dependency Rules

  When generating branching sequences, the generator enforces ref isolation:
  - Refs created in `prefix` can be used in any branch
  - Refs created in one branch CANNOT be used in another branch
  - Refs created in branches CAN be used in `suffix`

  ## Auto-Lifting

  Raw values passed as overrides are automatically wrapped in `StreamData.constant/1`:

      merge_overrides(base, %{currency: "USD"})
      merge_overrides(base, %{currency: StreamData.member_of(["USD", "EUR"])})
  """

  alias PropertyDamage.Sequence

  @type command :: struct()
  @type state :: map()
  @type weighted_command :: {pos_integer(), module()}

  # Default options
  @default_max_commands 50
  @default_branch_probability 0.2
  @default_max_branches 3
  @default_max_branch_length 5
  @default_min_prefix_length 3

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Generate a command sequence for a given model.

  ## Parameters

  - `model` - Model module defining commands and state projection
  - `opts` - Options:
    - `:max_commands` - Maximum total commands per sequence (default: 50)
    - `:seed` - RNG seed for reproducibility
    - `:branching` - Keyword list for branching configuration (see below)

  ## Branching Options

  Pass `branching: [...]` to generate branching sequences:

  - `:branch_probability` - Probability of creating a branch point (default: 0.2)
  - `:max_branches` - Maximum number of parallel branches (default: 3)
  - `:max_branch_length` - Maximum commands per branch (default: 5)
  - `:min_prefix_length` - Minimum commands before branching (default: 3)

  If `:branching` is not provided, generates linear sequences.

  ## Returns

  A StreamData generator that produces `PropertyDamage.Sequence` structs.

  ## Examples

      # Linear sequence
      Generator.generate_sequence(MyModel, max_commands: 20)

      # Branching sequence with 30% branch probability
      Generator.generate_sequence(MyModel,
        max_commands: 30,
        branching: [branch_probability: 0.3, max_branches: 2]
      )
  """
  @spec generate_sequence(module(), keyword()) :: StreamData.t()
  def generate_sequence(model, opts \\ []) do
    max_commands = Keyword.get(opts, :max_commands, @default_max_commands)
    branching_opts = Keyword.get(opts, :branching, nil)
    commands = model.commands() |> PropertyDamage.Model.normalize_commands()
    state_projection = model.state_projection()

    StreamData.bind(StreamData.constant(nil), fn _ ->
      if branching_opts do
        do_generate_branching_sequence(
          commands,
          state_projection,
          model,
          max_commands,
          branching_opts
        )
      else
        do_generate_linear_sequence(commands, state_projection, model, max_commands)
      end
    end)
  end

  @doc """
  Merge overrides into base generators, auto-lifting raw values.

  Raw values are automatically wrapped in `StreamData.constant/1`.
  StreamData generators are passed through unchanged.

  ## Parameters

  - `base` - Map of field names to StreamData generators
  - `overrides` - Map of field names to values or generators to override

  ## Returns

  A map suitable for passing to `StreamData.fixed_map/1`.

  ## Examples

      iex> base = %{amount: StreamData.positive_integer(), currency: StreamData.constant("USD")}
      iex> result = PropertyDamage.Generator.merge_overrides(base, %{currency: "EUR"})
      iex> is_map(result)
      true
  """
  @spec merge_overrides(map(), map()) :: map()
  def merge_overrides(base, overrides) do
    Map.merge(base, lift_values(overrides))
  end

  @doc """
  Check if a value is a StreamData generator.

  ## Examples

      iex> PropertyDamage.Generator.stream_data?(StreamData.integer())
      true

      iex> PropertyDamage.Generator.stream_data?(42)
      false
  """
  @spec stream_data?(any()) :: boolean()
  def stream_data?(%StreamData{}), do: true
  def stream_data?(_), do: false

  # ============================================================================
  # Linear Sequence Generation
  # ============================================================================

  defp do_generate_linear_sequence(commands, state_projection, model, max_commands) do
    initial_state = state_projection.init()

    generate_linear_recursive(
      commands,
      state_projection,
      model,
      initial_state,
      max_commands,
      []
    )
    |> StreamData.map(&Sequence.linear/1)
  end

  defp generate_linear_recursive(_commands, _projection, _model, _state, 0, acc) do
    StreamData.constant(Enum.reverse(acc))
  end

  defp generate_linear_recursive(commands, projection, model, state, remaining, acc) do
    valid_commands = filter_valid_commands(commands, state)

    case valid_commands do
      [] ->
        StreamData.constant(Enum.reverse(acc))

      _ ->
        StreamData.bind(weighted_member_of(valid_commands), fn {_weight, cmd_module} ->
          generator = get_command_generator(cmd_module, state)

          StreamData.bind(generator, fn command ->
            events = simulate_command(cmd_module, state, command)
            new_state = update_state(state, command, events, projection)
            new_acc = [command | acc]

            if should_terminate?(model, new_state, command, events) do
              StreamData.constant(Enum.reverse(new_acc))
            else
              generate_linear_recursive(
                commands,
                projection,
                model,
                new_state,
                remaining - 1,
                new_acc
              )
            end
          end)
        end)
    end
  end

  # ============================================================================
  # Branching Sequence Generation
  # ============================================================================

  defp do_generate_branching_sequence(commands, state_projection, model, max_commands, opts) do
    branch_probability = Keyword.get(opts, :branch_probability, @default_branch_probability)
    max_branches = Keyword.get(opts, :max_branches, @default_max_branches)
    max_branch_length = Keyword.get(opts, :max_branch_length, @default_max_branch_length)
    min_prefix_length = Keyword.get(opts, :min_prefix_length, @default_min_prefix_length)

    initial_state = state_projection.init()

    # First, generate the prefix (before any branching)
    generate_prefix(
      commands,
      state_projection,
      model,
      initial_state,
      min_prefix_length,
      max_commands,
      []
    )
    |> StreamData.bind(fn {prefix, state_after_prefix, remaining} ->
      # Decide whether to branch
      StreamData.bind(StreamData.float(min: 0.0, max: 1.0), fn roll ->
        if roll < branch_probability and remaining > max_branch_length do
          # Generate branches
          generate_with_branches(
            commands,
            state_projection,
            model,
            state_after_prefix,
            prefix,
            remaining,
            max_branches,
            max_branch_length
          )
        else
          # Continue as linear sequence
          generate_linear_recursive(
            commands,
            state_projection,
            model,
            state_after_prefix,
            remaining,
            []
          )
          |> StreamData.map(fn suffix_cmds ->
            Sequence.linear(prefix ++ suffix_cmds)
          end)
        end
      end)
    end)
  end

  defp generate_prefix(commands, projection, model, state, min_length, max_total, acc) do
    if length(acc) >= min_length do
      # Met minimum, return what we have
      remaining = max_total - length(acc)
      StreamData.constant({Enum.reverse(acc), state, remaining})
    else
      valid_commands = filter_valid_commands(commands, state)

      case valid_commands do
        [] ->
          # No valid commands, end early
          remaining = max_total - length(acc)
          StreamData.constant({Enum.reverse(acc), state, remaining})

        _ ->
          StreamData.bind(weighted_member_of(valid_commands), fn {_weight, cmd_module} ->
            generator = get_command_generator(cmd_module, state)

            StreamData.bind(generator, fn command ->
              events = simulate_command(cmd_module, state, command)
              new_state = update_state(state, command, events, projection)
              new_acc = [command | acc]

              if should_terminate?(model, new_state, command, events) do
                remaining = max_total - length(new_acc)
                StreamData.constant({Enum.reverse(new_acc), new_state, remaining})
              else
                generate_prefix(
                  commands,
                  projection,
                  model,
                  new_state,
                  min_length,
                  max_total,
                  new_acc
                )
              end
            end)
          end)
      end
    end
  end

  defp generate_with_branches(
         commands,
         projection,
         model,
         state_at_branch,
         prefix,
         remaining,
         max_branches,
         max_branch_length
       ) do
    # Decide number of branches (at least 2)
    num_branches = min(max_branches, max(2, div(remaining, max_branch_length)))

    # Calculate max length per branch
    per_branch_max = min(max_branch_length, div(remaining, num_branches))

    # Generate each branch independently from the same state snapshot
    branch_generators =
      for _ <- 1..num_branches do
        generate_branch(
          commands,
          projection,
          model,
          state_at_branch,
          per_branch_max,
          []
        )
      end

    # Combine all branches
    StreamData.bind(combine_branches(branch_generators), fn branches ->
      # Compute merged state after all branches
      merged_state = merge_branch_states(state_at_branch, branches, projection)

      # Remaining commands for suffix
      branch_command_count = Enum.sum(Enum.map(branches, &length/1))
      suffix_remaining = max(0, remaining - branch_command_count)

      # Generate suffix
      generate_linear_recursive(
        commands,
        projection,
        model,
        merged_state,
        suffix_remaining,
        []
      )
      |> StreamData.map(fn suffix_cmds ->
        # Filter out empty branches
        non_empty_branches = Enum.reject(branches, &Enum.empty?/1)

        if length(non_empty_branches) >= 2 do
          Sequence.branching(prefix, non_empty_branches, suffix_cmds)
        else
          # Less than 2 branches, convert to linear
          flattened = List.flatten(non_empty_branches)
          Sequence.linear(prefix ++ flattened ++ suffix_cmds)
        end
      end)
    end)
  end

  defp generate_branch(_commands, _projection, _model, _state, 0, acc) do
    StreamData.constant(Enum.reverse(acc))
  end

  defp generate_branch(commands, projection, model, state, remaining, acc) do
    valid_commands = filter_valid_commands(commands, state)

    case valid_commands do
      [] ->
        StreamData.constant(Enum.reverse(acc))

      _ ->
        # 30% chance to end branch early (creates varied branch lengths)
        StreamData.bind(StreamData.float(min: 0.0, max: 1.0), fn roll ->
          if roll < 0.3 and length(acc) > 0 do
            StreamData.constant(Enum.reverse(acc))
          else
            StreamData.bind(weighted_member_of(valid_commands), fn {_weight, cmd_module} ->
              generator = get_command_generator(cmd_module, state)

              StreamData.bind(generator, fn command ->
                events = simulate_command(cmd_module, state, command)
                new_state = update_state(state, command, events, projection)
                new_acc = [command | acc]

                if should_terminate?(model, new_state, command, events) do
                  StreamData.constant(Enum.reverse(new_acc))
                else
                  generate_branch(
                    commands,
                    projection,
                    model,
                    new_state,
                    remaining - 1,
                    new_acc
                  )
                end
              end)
            end)
          end
        end)
    end
  end

  defp combine_branches([]), do: StreamData.constant([])

  defp combine_branches([gen | rest]) do
    StreamData.bind(gen, fn branch ->
      StreamData.bind(combine_branches(rest), fn other_branches ->
        StreamData.constant([branch | other_branches])
      end)
    end)
  end

  defp merge_branch_states(base_state, branches, projection) do
    # Apply all branch commands to get merged state
    # Note: This is a simplification - real parallel execution would need
    # linearization checking. For generation, we just need a plausible state.
    all_branch_commands = List.flatten(branches)

    Enum.reduce(all_branch_commands, base_state, fn command, state ->
      # Get command module
      cmd_module = command.__struct__

      # Simulate and apply
      events = simulate_command(cmd_module, state, command)
      update_state(state, command, events, projection)
    end)
  end

  # ============================================================================
  # Shared Helpers
  # ============================================================================

  defp filter_valid_commands(commands, state) do
    Enum.filter(commands, fn {_weight, cmd_module} ->
      cmd_module.precondition(state)
    end)
  end

  defp weighted_member_of(weighted_commands) do
    total_weight = Enum.reduce(weighted_commands, 0, fn {w, _}, acc -> acc + w end)

    StreamData.bind(StreamData.integer(1..total_weight), fn n ->
      {_weight, cmd} = select_by_weight(weighted_commands, n)
      StreamData.constant({1, cmd})
    end)
  end

  defp select_by_weight([{weight, cmd} | rest], n) do
    if n <= weight do
      {weight, cmd}
    else
      select_by_weight(rest, n - weight)
    end
  end

  defp get_command_generator(cmd_module, state) do
    cmd_module.new!(state, %{})
  end

  defp simulate_command(cmd_module, state, command) do
    if function_exported?(cmd_module, :simulate, 2) do
      cmd_module.simulate(state, command)
    else
      []
    end
  end

  defp update_state(state, command, events, projection) do
    state
    |> projection.apply(command)
    |> apply_events(events, projection)
  end

  defp apply_events(state, events, projection) do
    Enum.reduce(events, state, fn event, acc ->
      projection.apply(acc, event)
    end)
  end

  defp should_terminate?(model, state, command, events) do
    if function_exported?(model, :terminate?, 3) do
      model.terminate?(state, command, events)
    else
      false
    end
  end

  defp lift_values(map) do
    Map.new(map, fn {k, v} -> {k, lift(v)} end)
  end

  defp lift(%StreamData{} = gen), do: gen
  defp lift(value), do: StreamData.constant(value)
end
