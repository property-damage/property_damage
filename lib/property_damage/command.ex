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
        weight: pos_integer(),                # Generation weight
        observables: [module()],              # Events this command can produce
        idempotent: boolean(),                # Eligible for stutter testing
        acceptable_retry_events: [module()]   # Acceptable stutter-retry responses
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

  ## Static Metadata Lives in the Spec

  `command_spec/1` is the single surface for a command's static metadata. Per-instance
  computations (`generator/1`, `idempotency_key/1`, `label/2`, `awaits/2`) stay function
  callbacks; everything static is a spec key:

  | Spec Field                 | Meaning                                            |
  |----------------------------|----------------------------------------------------|
  | `:execution`               | `:sync` / `:probe` / `:async`                      |
  | `:settle`                  | Retry config for probe/async                       |
  | `:shrink`                  | Shrinking priority (read-only -> `:prefer_remove`) |
  | `:observables`             | Event modules this command can produce             |
  | `:idempotent`              | Eligibility for stutter testing                    |
  | `:acceptable_retry_events` | Acceptable alternative stutter-retry responses     |
  | `:when` / `:with` / `:weight` | Model-level wiring (precondition/overrides/weight) |

  ## Design Principles

  - **Reusability**: Commands are pure semantic definitions, decoupled from state shape.
    Model-specific configuration (weights, preconditions, overrides) is declared in
    the Model, not the Command.

  - **Composability**: The `generator/1` function enables composition.
    A specialized command can call another command's generator and extend it.

  - **Separation of Concerns**: Commands define WHAT operations exist and their fields.
    Models define WHEN to use them and HOW to parameterize them.
    Adapters define HOW to execute them against the SUT.

  ## Optional Per-Instance Callbacks

  Beyond the static `command_spec/1` surface, commands may implement these
  per-instance callbacks (each takes the command and/or state, so it cannot live
  in a static map):

  - `label/2` - Human-readable label for debugging output
  - `idempotency_key/1` - Idempotency key passed to the adapter during stutter
  - `awaits/2` - Inbound (injector) events this command correlates (see `PropertyDamage.Await`)

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
  (Optional) Provides a human-readable label for a command instance.

  Labels can be static or dynamic based on state and command fields.
  Return `nil` for no special label.

  When a failure report is built, the label is computed lazily (only on failure,
  never during generation or passing runs) against the command's
  `command_sequence_projection` pre-state, and rendered next to the command in
  the failure report (terminal/markdown/JSON) and in every exported reproduction
  (ExUnit, scripts, Livebook). A raising implementation degrades to no label.

  ## Example

      def label(_state, %__MODULE__{divisor: 0}), do: "divide by zero"
      def label(_state, %__MODULE__{}), do: nil
  """
  @callback label(state :: map(), command :: struct()) :: String.t() | nil

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
  - `:observables` - Event modules this command can produce (default `[]`)
  - `:idempotent` - Whether the command is eligible for stutter testing (default `true`)
  - `:acceptable_retry_events` - Event modules acceptable as alternative stutter-retry
    responses (default `[]`)

  ## Example

      def command_spec(overrides \\\\ []) do
        PropertyDamage.Command.build_spec(__MODULE__, [execution: :probe], overrides)
      end
  """
  @callback command_spec(overrides :: keyword()) :: map()

  @doc """
  (Optional) Declares which inbound (injector) events this command correlates.

  Returns a list of `PropertyDamage.Await` structs, each carrying a `match`
  predicate `(event -> boolean)` built from the command's own resolved fields
  (and captured response). When an injector event satisfies a `match`, the
  framework attributes it to this command's `command_index` for the rest of the
  run, instead of folding it as ambient (`command_index: nil`).

  This is **pure correlation**: it never blocks and asserts nothing. Judgment
  over the correlated set lives in projections (a `@poll_state` assertion for
  liveness, a `@trigger`/`@invariant` for safety/cardinality). See
  `PropertyDamage.Await` for the multiplicity rules (first-registered wins).

  Evaluated per command instance, after execution and placeholder capture, so
  the predicate can close over server-assigned values. Default: `[]` (the
  command correlates nothing).

  ## Example

      def awaits(_state, %__MODULE__{issue_id: id}) do
        [%PropertyDamage.Await{match: &match?(%IssueClosedWebhook{issue_id: ^id}, &1)}]
      end
  """
  @callback awaits(state :: map(), command :: struct()) :: [PropertyDamage.Await.t()]

  @optional_callbacks [
    label: 2,
    idempotency_key: 1,
    awaits: 2,
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
  - `:observables` - Event modules this command can produce, default `[]`
  - `:idempotent` - Whether the command is eligible for stutter testing, default `true`
  - `:acceptable_retry_events` - Event modules acceptable as alternative stutter-retry
    responses, default `[]`

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
      weight: 1,
      observables: [],
      idempotent: true,
      acceptable_retry_events: []
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
end
