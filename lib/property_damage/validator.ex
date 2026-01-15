defmodule PropertyDamage.Validator do
  @moduledoc """
  Validates command sequences against model preconditions.

  The Validator checks whether a command sequence is structurally valid
  by simulating state transitions without actually executing commands.
  This is used during shrinking to quickly filter out invalid candidates.

  ## Validation Process

  For each command in the sequence:

  1. Check Model's `when:` option for the command - returns false if invalid
  2. Apply Model's `simulate/2` to get simulated events
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

  - Simulation uses Model's `simulate/2` if defined, otherwise produces no events
  - State projection is updated but assertion projections are not
  - This is fast because no actual execution or check evaluation happens
  """

  alias PropertyDamage.Model

  @doc """
  Check if a command sequence is valid according to model preconditions.

  Simulates the sequence by:
  1. Initializing state from model's state projection
  2. For each command, checking Model's `when:` option against current state
  3. Updating state via Model's `simulate/2` (if defined)

  ## Parameters

  - `commands` - List of command structs to validate
  - `model` - Model module defining state projection and command wiring

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

    # Normalize the model's commands to get when:/with: options
    normalized_commands =
      model.commands()
      |> Model.normalize_commands()
      |> build_command_lookup()

    validate_commands(commands, initial_state, state_projection, model, normalized_commands)
  end

  # Build a lookup map from command module to its options
  defp build_command_lookup(normalized_commands) do
    Map.new(normalized_commands, fn {_weight, module, opts} ->
      {module, opts}
    end)
  end

  defp validate_commands([], _state, _projection, _model, _lookup), do: true

  defp validate_commands([command | rest], state, projection, model, lookup) do
    command_module = command.__struct__

    # Get the when: predicate from the command's options
    opts = Map.get(lookup, command_module, [])
    when_pred = Keyword.get(opts, :when)

    # Check precondition (when: option)
    precondition_passes =
      case when_pred do
        nil -> true
        pred when is_function(pred, 1) -> pred.(state)
      end

    if precondition_passes do
      # Simulate command to get events using Model's simulate/2
      events = simulate_command(model, command, state)

      # Update state with command and events
      new_state =
        state
        |> projection.apply(command)
        |> apply_events(events, projection)

      validate_commands(rest, new_state, projection, model, lookup)
    else
      false
    end
  end

  defp simulate_command(model, command, state) do
    if function_exported?(model, :simulate, 2) do
      model.simulate(command, state)
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
