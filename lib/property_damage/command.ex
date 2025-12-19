defmodule PropertyDamage.Command do
  @moduledoc """
  Behaviour for commands in stateful property-based testing.

  Commands are operations that can be executed against the System Under Test (SUT).
  They are represented as structs containing their arguments, and define how to
  generate valid command instances based on current state.

  ## Two-Layer Generator Architecture

  Commands use a two-layer architecture for composable generation:

  1. **`generator/1`** (optional) - Pure generator returning StreamData of **maps**.
     Takes overrides, applies them via `PropertyDamage.Generator.merge_overrides/2`.
     No state dependency. This is the composable building block - other commands
     can call it and extend the generation logic.

  2. **`new!/2`** (required) - State-aware generator returning StreamData of **structs**.
     Derives state-dependent values (e.g., refs from existing entities),
     passes them as overrides to `generator/1`, wraps result in struct.

  ## Example

      defmodule MyTest.Commands.CreateOrder do
        @behaviour PropertyDamage.Command
        import PropertyDamage.Generator, only: [merge_overrides: 2]

        defstruct [:amount, :currency]

        @impl true
        def precondition(_state), do: true

        @impl true
        def generator(overrides \\\\ %{}) do
          %{
            amount: StreamData.positive_integer(),
            currency: StreamData.member_of(["USD", "EUR"])
          }
          |> merge_overrides(overrides)
          |> StreamData.fixed_map()
        end

        @impl true
        def new!(_state, overrides \\\\ %{}) do
          generator(overrides)
          |> StreamData.map(&struct!(__MODULE__, &1))
        end
      end

  ## Design Principles

  - **Reusability**: Commands are designed to be reusable across models.
    Model-specific configuration (like weights) is declared in the Model,
    not the Command.

  - **Composability**: The `generator/1` function enables composition.
    A specialized command can call another command's generator and extend it.

  - **Separation of Concerns**: Commands define WHAT operations exist.
    Adapters define HOW to execute them against the SUT.

  ## Optional Metadata Callbacks

  Commands can implement optional callbacks to provide metadata used by
  the framework for shrinking, validation, and debugging:

  - `creates_ref/0` - Field name for entity ref this command creates
  - `downstream_observables/0` - Event modules this command can produce
  - `read_only?/0` - Whether command only reads state (prioritized for removal during shrinking)
  - `simulate/2` - Expected events for symbolic execution
  - `label/2` - Human-readable label for debugging

  The framework reads these via `function_exported?/3`, using sensible
  defaults when not implemented.
  """

  @doc """
  Precondition: Can this command type be generated in the current state?

  Called once per command type during generation. If false, this command
  is excluded from the candidate pool for this generation step. This is
  NOT the same as validating a specific command instance - it determines
  whether the command type makes sense given the current state.

  ## Examples

  - `CancelOrder` requires orders to exist: `map_size(state.orders) > 0`
  - `CreateOrder` is always valid: `true`
  - `RefundOrder` requires captured payments: `Enum.any?(state.payments, &(&1.captured))`

  ## Why Precondition Takes Only State

  The precondition receives the projection state, not the command itself,
  because it determines whether to *attempt* generating this command type.
  At this point, no specific command instance exists yet.
  """
  @callback precondition(state :: map()) :: boolean()

  @doc """
  (Optional) Pure generator for command fields, returns StreamData of maps.

  This is the composable building block. It takes overrides and returns a
  generator of maps (not structs). Other commands can call this to reuse
  and extend the generation logic.

  Use `PropertyDamage.Generator.merge_overrides/2` to apply overrides with
  auto-lifting of raw values to `StreamData.constant/1`.

  ## Example

      def generator(overrides \\\\ %{}) do
        %{
          amount: StreamData.positive_integer(),
          currency: StreamData.member_of(["USD", "EUR"])
        }
        |> PropertyDamage.Generator.merge_overrides(overrides)
        |> StreamData.fixed_map()
      end
  """
  @callback generator(overrides :: map()) :: StreamData.t(map())

  @doc """
  Generate a command struct from current state.

  Returns a StreamData generator that produces command structs.
  Only called if `precondition/1` returns true.

  This callback is state-aware and responsible for:
  1. Deriving state-dependent overrides (e.g., picking refs from existing entities)
  2. Calling `generator/1` with those overrides (if defined)
  3. Wrapping the result map in the command struct

  ## Example

      def new!(state, overrides \\\\ %{}) do
        generator(%{
          order_ref: StreamData.member_of(Map.keys(state.orders))
        } |> Map.merge(overrides))
        |> StreamData.map(&struct!(__MODULE__, &1))
      end
  """
  @callback new!(state :: map(), overrides :: map()) :: StreamData.t(struct())

  @doc """
  (Optional) Returns expected events for symbolic execution.

  Used during command sequence generation to update symbolic state
  without executing against the SUT. If not implemented, the framework
  applies only the command to projections (no events).

  This enables precise causality tracking for shrinking without
  requiring SUT modifications.
  """
  @callback simulate(state :: map(), command :: struct()) :: [struct()]

  @doc """
  (Optional) Provides human-readable label for debugging output.

  Labels can be static or dynamic based on state and command fields.
  Return `nil` for no special label.

  ## Example

      def label(_state, %__MODULE__{divisor: 0}), do: "divide by zero"
      def label(_state, %__MODULE__{}), do: nil
  """
  @callback label(state :: map(), command :: struct()) :: String.t() | nil

  @doc """
  (Optional) Returns the field name for the Ref this command creates.

  When a command creates a new entity (e.g., CreateOrder creates an order),
  return the atom field name where the Ref should be stored (e.g., `:order_ref`).

  The framework uses this to:
  1. Generate a symbolic Ref during command sequence generation
  2. Resolve the Ref to a concrete value from the resulting event

  Return `nil` (or don't implement) if this command doesn't create a new entity.

  ## Example

      def creates_ref, do: :order_ref
  """
  @callback creates_ref() :: atom() | nil

  @doc """
  (Optional) Returns the list of event modules this command can produce.

  Used for:
  - Validation (ensuring all referenced events exist)
  - Causality tracking during shrinking
  - Documentation

  ## Example

      def downstream_observables, do: [OrderCreated, OrderRejected]
  """
  @callback downstream_observables() :: [module()]

  @doc """
  (Optional) Returns true if this command only reads state, never modifies it.

  Read-only commands are prioritized for removal during shrinking since
  they typically don't affect the failure.

  ## Example

      def read_only?, do: true
  """
  @callback read_only?() :: boolean()

  @optional_callbacks [
    generator: 1,
    simulate: 2,
    label: 2,
    creates_ref: 0,
    downstream_observables: 0,
    read_only?: 0
  ]
end
