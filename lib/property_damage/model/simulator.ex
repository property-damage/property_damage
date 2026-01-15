defmodule PropertyDamage.Model.Simulator do
  @moduledoc """
  Behaviour for simulating command execution to predict expected events.

  Simulators enable symbolic execution during sequence generation. When generating
  command sequences, PropertyDamage uses the simulator to predict what events each
  command will produce, allowing coherent sequence generation.

  ## Usage

  Define a module implementing this behaviour:

      defmodule MySimulator do
        @behaviour PropertyDamage.Model.Simulator

        @impl true
        def simulate(%CreateItem{name: name, quantity: qty}, _state) do
          [%ItemCreated{name: name, quantity: qty, item_ref: nil}]
        end

        def simulate(%ViewItem{item_ref: ref}, state) do
          if Map.has_key?(state.items, ref) do
            [%ItemViewed{item_ref: ref}]
          else
            [%ItemNotFound{item_ref: ref}]
          end
        end

        # Catch-all for commands with no predictable events
        def simulate(_command, _state), do: []
      end

  Then reference it in your Model:

      defmodule MyModel do
        @behaviour PropertyDamage.Model

        def simulator, do: MySimulator
        # ... other callbacks
      end

  ## Inline Implementation

  For simpler cases, you can implement the Simulator directly in your Model:

      defmodule MyModel do
        @behaviour PropertyDamage.Model
        @behaviour PropertyDamage.Model.Simulator

        def simulator, do: __MODULE__

        @impl PropertyDamage.Model.Simulator
        def simulate(%CreateItem{name: name}, _state) do
          [%ItemCreated{name: name, item_ref: nil}]
        end

        def simulate(_command, _state), do: []
      end

  ## Return Value

  The `simulate/2` callback should return a list of event structs that the command
  is expected to produce. For commands that create new entities, use `nil` for
  the reference field - it will be resolved at execution time.

  Return an empty list `[]` for commands with no predictable events.
  """

  @doc """
  Simulate a command and return expected events.

  ## Parameters

  - `command` - The command struct to simulate
  - `state` - The current projection state

  ## Returns

  A list of event structs that the command is expected to produce.
  Return `[]` for commands with no predictable events.
  """
  @callback simulate(command :: struct(), state :: map()) :: [struct()]
end
