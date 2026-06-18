defmodule PropertyDamage.Command do
  @moduledoc """
  Behaviour for commands in stateful property-based testing.

  Commands are semantic operations that can be executed against the System Under Test (SUT).
  They are represented as structs containing their arguments, and define how to
  generate valid field values.

  ## Command Specification

  Commands define a `command_spec/1` function that returns a complete specification map
  describing execution semantics, shrinking hints, and generation options. This follows
  the proven `child_spec/1` pattern from Elixir's standard library.

  The spec map structure:

      %{
        command: module(),                    # The command module
        execution: :sync | :probe | :async,   # Execution mode
        settle: %{                            # Settle config (for probe/async)
          timeout_ms: pos_integer(),
          interval_ms: pos_integer(),
          backoff: :linear | :exponential
        },
        shrink: :prefer_remove | :neutral | :prefer_keep,  # Shrinking priority
        when: (state -> boolean),             # Precondition
        with: (state -> map) | map,           # Generator overrides
        weight: pos_integer()                 # Generation weight
      }

  ## Using PropertyDamage.Command

  The `use` macro provides a default `command_spec/1` implementation:

      defmodule MyTest.Commands.CreateOrder do
        use PropertyDamage.Command

        defstruct [:amount, :currency]

        @impl true
        def generator(overrides \\\\ %{}) do
          %{amount: StreamData.positive_integer(), currency: StreamData.constant("USD")}
          |> PropertyDamage.Generator.merge_overrides(overrides)
          |> StreamData.fixed_map()
        end
      end

  Commands can customize defaults via `use` options:

      defmodule MyTest.Commands.GetOrder do
        use PropertyDamage.Command,
          execution: :probe,
          shrink: :prefer_remove,
          settle: %{timeout_ms: 5_000, interval_ms: 200, backoff: :exponential}

        defstruct [:order_ref]

        @impl true
        def generator(overrides \\\\ %{}), do: # ...
      end

  Or override `command_spec/1` entirely for dynamic specs:

      def command_spec(overrides \\\\ []) do
        defaults = PropertyDamage.Command.framework_defaults()
        Map.merge(defaults, %{command: __MODULE__, execution: :probe})
        |> Map.merge(Map.new(overrides))
      end

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

  ## Model Integration

  Models can specify commands in three forms, all of which result in a command spec:

      def commands do
        [
          # Module only - uses command's command_spec/1 with empty overrides
          CreateOrder,

          # {Module, opts} - opts passed to command_spec/1
          {ViewOrder, weight: 2, shrink: :prefer_keep},

          # Map form - merged with resolved spec
          %{command: CancelOrder, weight: 1, when: &has_orders?/1}
        ]
      end

  ## Migration from Legacy Callbacks

  The `command_spec/1` pattern consolidates multiple callbacks:

  | Legacy Callback     | Spec Field     |
  |---------------------|----------------|
  | `semantics/0`       | `:execution`   |
  | `settle_config/0`   | `:settle`      |
  | `read_only?/0`      | `:shrink`      |
  | Model's `when:`     | `:when`        |
  | Model's `with:`     | `:with`        |
  | Model's `weight:`   | `:weight`      |

  Legacy callbacks continue to work - the framework falls back to them when
  `command_spec/1` is not implemented.

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

  - `:probe` - Queries SUT state without mutation, for eventually consistent
    systems. The framework runs `execute/2` through the settle loop: the adapter
    returns `{:settled, events}` once the condition holds or `{:retry, reason}`
    to be called again (it does not poll inside `execute/2`). Should also
    implement `read_only?/0` returning `true`.

  - `:async` - Asynchronous operation that creates a resource and waits for it
    to settle. Like `:probe`, it uses the framework settle loop (return
    `{:retry, _}`/`{:settled, _}` from `execute/2`); the framework owns the
    retries per `settle_config/0`. Async commands are protected during shrinking
    if their ref is used by other commands.

  ## Examples

      # Sync (default) - creates/modifies state synchronously
      def semantics, do: :sync

      # Probe - queries and settles
      def semantics, do: :probe

      # Async - waits for async completion
      def semantics, do: :async
  """
  @callback semantics() :: :sync | :probe | :async

  @doc """
  (Optional) Returns settle configuration for probes and async commands.

  When a command's `semantics/0` is `:probe` or `:async`, this configuration
  controls the retry behavior when waiting for eventual consistency.

  ## Fields

  - `:timeout_ms` - Maximum time to wait (default: 2000)
  - `:interval_ms` - Time between retries (default: 300)
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

  @doc """
  (Optional) Returns the complete command specification.

  The command_spec/1 function returns a map containing all configuration for
  a command: execution semantics, shrinking hints, generation options, and
  more. This consolidates what was previously spread across multiple callbacks.

  ## Parameters

  - `overrides` - Keyword list of options to override defaults. Typically passed
    from the Model's command list.

  ## Returns

  A map with the following fields:

  - `:command` - The command module
  - `:execution` - Execution mode (`:sync`, `:probe`, or `:async`)
  - `:settle` - Settle configuration for probe/async commands
  - `:shrink` - Shrinking priority (`:prefer_remove`, `:neutral`, or `:prefer_keep`)
  - `:when` - Precondition function `(state -> boolean)`
  - `:with` - Generator overrides `(state -> map)` or map
  - `:weight` - Generation weight (positive integer)

  ## Example

      def command_spec(overrides \\\\ []) do
        PropertyDamage.Command.build_spec(__MODULE__, [execution: :probe], overrides)
      end
  """
  @callback command_spec(overrides :: keyword()) :: map()

  @optional_callbacks [
    label: 2,
    downstream_observables: 0,
    read_only?: 0,
    semantics: 0,
    settle_config: 0,
    idempotent?: 0,
    idempotency_key: 1,
    acceptable_retry_events: 0,
    command_spec: 1
  ]

  # ===========================================================================
  # __using__ Macro
  # ===========================================================================

  @doc """
  Provides a default `command_spec/1` implementation when you `use PropertyDamage.Command`.

  ## Options

  All options are passed through to `command_spec/1` as defaults:

  - `:execution` - Execution mode (`:sync`, `:probe`, or `:async`), default `:sync`
  - `:settle` - Settle configuration map for probe/async commands
  - `:shrink` - Shrinking priority (`:prefer_remove`, `:neutral`, `:prefer_keep`), default `:neutral`
  - `:weight` - Default generation weight, default `1`

  ## Example

      defmodule MyCommand do
        use PropertyDamage.Command, execution: :probe, shrink: :prefer_remove

        defstruct [:id]

        @impl true
        def generator(overrides \\\\ %{}) do
          %{id: StreamData.positive_integer()}
          |> PropertyDamage.Generator.merge_overrides(overrides)
          |> StreamData.fixed_map()
        end
      end

      # MyCommand.command_spec([]) returns:
      # %{
      #   command: MyCommand,
      #   execution: :probe,
      #   shrink: :prefer_remove,
      #   settle: %{timeout_ms: 2_000, interval_ms: 300, backoff: :linear},
      #   when: fn _ -> true end,
      #   with: %{},
      #   weight: 1
      # }
  """
  defmacro __using__(opts \\ []) do
    quote bind_quoted: [opts: opts] do
      @behaviour PropertyDamage.Command
      @command_defaults opts

      @doc false
      def command_spec(overrides \\ []) do
        PropertyDamage.Command.build_spec(__MODULE__, @command_defaults, overrides)
      end

      defoverridable command_spec: 1
    end
  end

  # ===========================================================================
  # Spec Building Functions
  # ===========================================================================

  @doc """
  Returns the framework's default spec values.

  These are the baseline defaults that get overridden by module defaults
  and call-time overrides.
  """
  @spec framework_defaults() :: map()
  def framework_defaults do
    %{
      execution: :sync,
      settle: %{timeout_ms: 2_000, interval_ms: 300, backoff: :linear},
      shrink: :neutral,
      when: fn _ -> true end,
      with: %{},
      weight: 1
    }
  end

  @doc """
  Builds a command spec by layering defaults.

  Priority (highest to lowest):
  1. Call-time overrides (from Model's command list)
  2. Module defaults (from `use PropertyDamage.Command` opts)
  3. Framework defaults

  ## Parameters

  - `module` - The command module
  - `module_defaults` - Defaults provided via `use` opts
  - `overrides` - Call-time overrides from Model

  ## Example

      build_spec(CreateOrder, [execution: :sync], [weight: 2])
      # => %{command: CreateOrder, execution: :sync, weight: 2, ...}
  """
  @spec build_spec(module(), keyword(), keyword()) :: map()
  def build_spec(module, module_defaults, overrides) do
    framework_defaults()
    |> Map.merge(%{command: module})
    |> Map.merge(Map.new(module_defaults))
    |> Map.merge(Map.new(overrides))
  end

  @doc """
  Builds a command spec from legacy callbacks.

  Used for backward compatibility when a command doesn't implement `command_spec/1`
  but does implement legacy callbacks like `semantics/0`, `settle_config/0`, etc.

  ## Parameters

  - `module` - The command module

  ## Returns

  A spec map built from legacy callbacks, with framework defaults for
  any callbacks not implemented.
  """
  @spec build_spec_from_legacy(module()) :: map()
  def build_spec_from_legacy(module) do
    %{
      command: module,
      execution: get_legacy_semantics(module),
      settle: get_legacy_settle(module),
      shrink: get_legacy_shrink(module),
      when: fn _ -> true end,
      with: %{},
      weight: 1
    }
  end

  # Private helpers for reading legacy callbacks

  defp get_legacy_semantics(module) do
    if function_exported?(module, :semantics, 0) do
      module.semantics()
    else
      :sync
    end
  end

  defp get_legacy_settle(module) do
    default = %{timeout_ms: 2_000, interval_ms: 300, backoff: :linear}

    if function_exported?(module, :settle_config, 0) do
      Map.merge(default, module.settle_config())
    else
      default
    end
  end

  defp get_legacy_shrink(module) do
    if function_exported?(module, :read_only?, 0) and module.read_only?() do
      :prefer_remove
    else
      :neutral
    end
  end
end
