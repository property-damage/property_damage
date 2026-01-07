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

  @doc """
  (Optional) Returns the execution semantics of this command.

  ## Semantics

  - `:sync` - Synchronous operation. Mutates SUT state, completes immediately.
    Postconditions are weak (check response codes). This is the default if not implemented.

  - `:probe` - Queries SUT state without mutation. Contains settle/retry logic
    for eventually consistent systems. Should also implement `read_only?/0` returning `true`.

  - `:async` - Asynchronous operation that creates a resource and waits for it to settle.
    Used for operations that return "processing" status and require polling.
    Async commands are protected during shrinking if their ref is used by other commands.

  - `:mock_config` - Configures mock service behavior. Not sent to the SUT adapter.
    Instead, mock adapters receive this command via `on_command/2` to update
    their behavior. Useful for testing different third-party service responses.

  ## Examples

      # Sync (default) - creates/modifies state synchronously
      def semantics, do: :sync

      # Probe - queries and settles
      def semantics, do: :probe

      # Async - waits for async completion
      def semantics, do: :async

      # Mock config - configures mock services
      def semantics, do: :mock_config
  """
  @callback semantics() :: :sync | :probe | :async | :mock_config

  @doc """
  (Optional) Returns settle configuration for probes and async commands.

  When a command's `semantics/0` is `:probe` or `:async`, this configuration
  controls the retry behavior when waiting for eventual consistency.

  ## Fields

  - `:timeout_ms` - Maximum time to wait (default: 2000)
  - `:interval_ms` - Time between retries (default: 100)
  - `:backoff` - Backoff strategy, `:linear` or `:exponential` (default: `:linear`)

  ## Example

      def settle_config do
        %{
          timeout_ms: 5_000,
          interval_ms: 200,
          backoff: :exponential
        }
      end
  """
  @callback settle_config() :: %{
              timeout_ms: pos_integer(),
              interval_ms: pos_integer(),
              backoff: :linear | :exponential
            }

  # ===========================================================================
  # Idempotency Testing Callbacks
  # ===========================================================================

  @doc """
  (Optional) Whether this command should be included in stutter/idempotency testing.

  Commands that are intentionally non-idempotent (like `IncrementCounter`) should
  return `false` to be excluded from stutter testing.

  Default: `true` (command is assumed idempotent and will be stuttered)

  ## Example

      # Non-idempotent command - exclude from stutter testing
      def idempotent?, do: false
  """
  @callback idempotent?() :: boolean()

  @doc """
  (Optional) Returns the idempotency key for this command instance.

  The idempotency key is passed to the adapter in the stutter context,
  allowing it to include the key in HTTP headers or other request metadata.

  If not implemented, no idempotency key is provided to the adapter.

  ## Example

      defstruct [:amount, :idempotency_key]

      def idempotency_key(%__MODULE__{idempotency_key: key}), do: key
  """
  @callback idempotency_key(command :: struct()) :: String.t() | nil

  @doc """
  (Optional) Event modules that are acceptable as retry responses.

  When stutter testing, a retry might return different events than the
  original execution while still being correct (e.g., `OrderCreated` vs
  `OrderAlreadyExists`). This callback declares which alternative event
  types are acceptable.

  If not implemented, only events matching the original execution are accepted.

  ## Example

      def acceptable_retry_events do
        [OrderCreated, OrderAlreadyExists]
      end
  """
  @callback acceptable_retry_events() :: [module()]

  @optional_callbacks [
    generator: 1,
    simulate: 2,
    label: 2,
    creates_ref: 0,
    downstream_observables: 0,
    read_only?: 0,
    semantics: 0,
    settle_config: 0,
    idempotent?: 0,
    idempotency_key: 1,
    acceptable_retry_events: 0
  ]
end
