defmodule PropertyDamage.Generator do
  @moduledoc """
  Utilities for building composable command generators.

  This module provides helper functions for the two-layer generator
  architecture used by commands. The key function is `merge_overrides/2`
  which enables flexible composition of generators.

  ## Auto-Lifting

  Raw values passed as overrides are automatically wrapped in
  `StreamData.constant/1`. This allows both static values and
  generators to be used interchangeably:

      # These are equivalent:
      merge_overrides(base, %{currency: "USD"})
      merge_overrides(base, %{currency: StreamData.constant("USD")})

      # But you can also pass generators:
      merge_overrides(base, %{currency: StreamData.member_of(["USD", "EUR"])})

  ## Composability Pattern

  Commands can reuse and extend other commands' generators:

      defmodule CreateHighValueOrder do
        def generator(overrides \\\\ %{}) do
          # Reuse CreateOrder's generator with constrained amount
          CreateOrder.generator(%{amount: StreamData.integer(10_000..100_000)})
          |> Map.merge(overrides)
        end
      end
  """

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

      iex> base = %{amount: StreamData.positive_integer()}
      iex> result = PropertyDamage.Generator.merge_overrides(base, %{amount: StreamData.integer(1..10)})
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

      iex> PropertyDamage.Generator.stream_data?("hello")
      false
  """
  @spec stream_data?(any()) :: boolean()
  def stream_data?(%StreamData{}), do: true
  def stream_data?(_), do: false

  @doc """
  Generate a command sequence for a given model.

  Uses the model's commands, state projection, and optional terminate?/3
  to generate valid command sequences that respect preconditions.

  ## Parameters

  - `model` - Model module defining commands and state projection
  - `opts` - Options:
    - `:max_commands` - Maximum commands per sequence (default: 50)
    - `:seed` - RNG seed for reproducibility

  ## Returns

  A StreamData generator that produces lists of command structs.

  ## How It Works

  1. Normalizes command weights from model.commands/0
  2. For each step, checks preconditions to find valid commands
  3. Uses weighted random selection among valid commands
  4. Calls command's generator/1 and new!/2 to create instance
  5. Simulates state update for next precondition checks
  6. Continues until max_commands or terminate?/3 returns true
  """
  @spec generate_sequence(module(), keyword()) :: StreamData.t()
  def generate_sequence(model, opts \\ []) do
    max_commands = Keyword.get(opts, :max_commands, 50)
    commands = model.commands() |> PropertyDamage.Model.normalize_commands()
    state_projection = model.state_projection()

    StreamData.bind(StreamData.constant(nil), fn _ ->
      do_generate_sequence(commands, state_projection, model, max_commands)
    end)
  end

  defp do_generate_sequence(commands, state_projection, model, max_commands) do
    initial_state = state_projection.init()

    generate_commands_recursive(
      commands,
      state_projection,
      model,
      initial_state,
      max_commands,
      []
    )
  end

  defp generate_commands_recursive(_commands, _projection, _model, _state, 0, acc) do
    StreamData.constant(Enum.reverse(acc))
  end

  defp generate_commands_recursive(commands, projection, model, state, remaining, acc) do
    # Find valid commands (those passing preconditions)
    valid_commands = filter_valid_commands(commands, state)

    case valid_commands do
      [] ->
        # No valid commands, end sequence
        StreamData.constant(Enum.reverse(acc))

      _ ->
        # Select weighted random command
        StreamData.bind(weighted_member_of(valid_commands), fn {_weight, cmd_module} ->
          # Get generator for this command
          generator = get_command_generator(cmd_module, state)

          StreamData.bind(generator, fn command ->
            # Simulate state update
            events = simulate_command(cmd_module, command)
            new_state = update_state(state, command, events, projection)
            new_acc = [command | acc]

            # Check for termination
            if should_terminate?(model, new_state, command, events) do
              StreamData.constant(Enum.reverse(new_acc))
            else
              generate_commands_recursive(
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
    # new!/2 returns a StreamData generator that produces command structs
    cmd_module.new!(state, %{})
  end

  defp simulate_command(cmd_module, command) do
    if function_exported?(cmd_module, :simulate, 2) do
      cmd_module.simulate(%{}, command)
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

  # Lift all values in a map, wrapping non-StreamData values in constant/1
  defp lift_values(map) do
    Map.new(map, fn {k, v} -> {k, lift(v)} end)
  end

  # Pass through StreamData generators unchanged
  defp lift(%StreamData{} = gen), do: gen

  # Wrap raw values in constant/1
  defp lift(value), do: StreamData.constant(value)
end
