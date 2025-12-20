defmodule PropertyDamage.Validator do
  @moduledoc """
  Validates command sequences against model preconditions.

  The Validator checks whether a command sequence is structurally valid
  by simulating state transitions without actually executing commands.
  This is used during shrinking to quickly filter out invalid candidates.

  ## Validation Process

  For each command in the sequence:

  1. Check `command.precondition(state)` - returns false if invalid
  2. Apply `command.simulate(state, command)` to get simulated events
  3. Update state projection with command and events

  ## Usage

  ```elixir
  # Check if a shrunk sequence is still valid
  if Validator.valid_sequence?(commands, model) do
    # Try executing it
  else
    # Skip this shrink candidate
  end
  ```

  ## Notes

  - Simulation uses `simulate/2` if defined, otherwise produces no events
  - State projection is updated but assertion projections are not
  - This is fast because no actual execution or check evaluation happens
  """

  @doc """
  Check if a command sequence is valid according to model preconditions.

  Simulates the sequence by:
  1. Initializing state from model's state projection
  2. For each command, checking precondition against current state
  3. Updating state via simulate/2 (if defined)

  ## Parameters

  - `commands` - List of command structs to validate
  - `model` - Model module defining state projection

  ## Returns

  - `true` - All commands pass their preconditions
  - `false` - At least one command fails its precondition

  ## Example

      commands = [
        %CreateItem{name: "A", quantity: 1},
        %ViewItem{item_ref: ref}  # Requires items to exist
      ]

      # Invalid because ViewItem runs before any items exist
      Validator.valid_sequence?(commands, MyModel)
      # => false
  """
  @spec valid_sequence?([struct()], module()) :: boolean()
  def valid_sequence?(commands, model) do
    state_projection = model.state_projection()
    initial_state = state_projection.init()

    validate_commands(commands, initial_state, state_projection)
  end

  defp validate_commands([], _state, _projection), do: true

  defp validate_commands([command | rest], state, projection) do
    command_module = command.__struct__

    # Check precondition
    if command_module.precondition(state) do
      # Simulate command to get events
      events = simulate_command(command)

      # Update state with command and events
      new_state =
        state
        |> projection.apply(command)
        |> apply_events(events, projection)

      validate_commands(rest, new_state, projection)
    else
      false
    end
  end

  defp simulate_command(command) do
    command_module = command.__struct__

    if function_exported?(command_module, :simulate, 2) do
      # simulate/2 takes state as first arg but we don't have resolved refs
      # So we pass nil and let simulate handle it
      command_module.simulate(%{}, command)
    else
      []
    end
  end

  defp apply_events(state, events, projection) do
    Enum.reduce(events, state, fn event, acc ->
      projection.apply(acc, event)
    end)
  end
end
