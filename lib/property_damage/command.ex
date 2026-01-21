defmodule PropertyDamage.Command do
  @moduledoc """
  Behaviour for commands in stateful property-based testing.

  Commands are semantic operations that can be executed against the System Under Test (SUT).
  They are represented as structs containing their arguments, and define how to
  generate valid field values.

  ## Pure Generator Architecture

  Commands define a pure `generator/1` function that produces field maps. The generator
  takes an overrides map and returns a StreamData generator of maps. The framework
  wraps the result in the command struct automatically.

  State-dependent concerns (preconditions, ref selection, expected events) are defined
  in the **Model**, not the Command. This separation enables command reuse across
  different Models with different state shapes.

  ## Example

      defmodule MyTest.Commands.CreateOrder do
        @behaviour PropertyDamage.Command
        import PropertyDamage.Generator, only: [merge_overrides: 2]

        defstruct [:amount, :currency]

        @impl true
        def generator(overrides \\\\ %{}) do
          %{
            amount: StreamData.positive_integer(),
            currency: StreamData.member_of(["USD", "EUR"])
          }
          |> merge_overrides(overrides)
          |> StreamData.fixed_map()
        end
      end

  The Model then wires this command with state-dependent configuration:

      defmodule MyTest.OrderModel do
        def commands do
          [
            CreateOrder,  # Always enabled, weight 1
            {ViewOrder,
              when: fn s -> map_size(s.orders) > 0 end,
              with: fn s -> %{order_ref: StreamData.member_of(Map.keys(s.orders))} end}
          ]
        end

        def simulate(%CreateOrder{amount: amount}, _state) do
          [%OrderCreated{amount: amount, order_ref: nil}]
        end

        def simulate(%ViewOrder{order_ref: ref}, state) do
          if Map.has_key?(state.orders, ref) do
            [%OrderViewed{order_ref: ref}]
          else
            [%OrderNotFound{order_ref: ref}]
          end
        end
      end

  ## Design Principles

  - **Reusability**: Commands are pure semantic definitions, decoupled from state shape.
    Model-specific configuration (weights, preconditions, overrides) is declared in
    the Model, not the Command.

  - **Composability**: The `generator/1` function enables composition.
    A specialized command can call another command's generator and extend it.

  - **Separation of Concerns**: Commands define WHAT operations exist and their fields.
    Models define WHEN to use them and HOW to parameterize them.
    Adapters define HOW to execute them against the SUT.

  ## Optional Metadata Callbacks

  Commands can implement optional callbacks to provide metadata used by
  the framework for shrinking, validation, and debugging:

  - `creates_ref/0` - Field name for entity ref this command creates
  - `downstream_observables/0` - Event modules this command can produce
  - `read_only?/0` - Whether command only reads state (prioritized for removal during shrinking)
  - `label/2` - Human-readable label for debugging

  The framework reads these via `function_exported?/3`, using sensible
  defaults when not implemented.
  """

  @doc """
  Pure generator for command fields, returns StreamData of maps.

  This is the core building block. It takes overrides and returns a
  generator of maps (not structs). The framework wraps the result in
  the command struct automatically.

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
  (Optional) Provides human-readable label for debugging output.

  Labels can be static or dynamic based on state and command fields.
  Return `nil` for no special label.

  ## Example

      def label(_state, %__MODULE__{divisor: 0}), do: "divide by zero"
      def label(_state, %__MODULE__{}), do: nil
  """
  @callback label(state :: map(), command :: struct()) :: String.t() | nil

  @doc """
  (Optional, **Deprecated**) Returns the field name for the Ref this command creates.

  **DEPRECATED**: Use `external()` in event struct definitions instead.
  The `creates_ref/0` callback is superseded by the external() marker system,
  which provides:
  - Multiple external fields per event
  - Nested externals in maps and fixed-length lists
  - Automatic detection without command-level configuration
  - Cleaner separation of concerns (externals declared on events, not commands)

  ## Migration

  Instead of:

      # Old approach (deprecated)
      defmodule CreateOrder do
        defstruct [:order_ref, :amount]
        def creates_ref, do: :order_ref
      end

  Use:

      # New approach
      defmodule OrderCreated do
        import PropertyDamage, only: [external: 0]
        defstruct [id: external(), :amount]  # id is server-generated
      end

  See `PropertyDamage.external/0` for full documentation.

  ## Legacy Behavior

  When a command creates a new entity (e.g., CreateOrder creates an order),
  return the atom field name where the Ref should be stored (e.g., `:order_ref`).

  The framework uses this to:
  1. Generate a symbolic Ref during command sequence generation
  2. Resolve the Ref to a concrete value from the resulting event

  Return `nil` (or don't implement) if this command doesn't create a new entity.
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
