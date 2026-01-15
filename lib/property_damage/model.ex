defmodule PropertyDamage.Model do
  @moduledoc """
  Behaviour for models in stateful property-based testing.

  A model ties together all the components needed for testing: which commands
  can be generated, which projections track state and assertions, and the
  test lifecycle hooks.

  ## Required Callbacks

  - `commands/0` - List of command modules (optionally weighted)
  - `state_projection/0` - Projection module used for command preconditions

  ## Optional Callbacks

  - `extra_projections/0` - Additional projections for state tracking and/or assertions
  - `injectable_events/0` - Events that can arrive from InjectorAdapters
  - `setup_once/1` - Setup that runs once at the start (not during shrinking)
  - `setup_each/1` - Setup that runs before each execution (including shrink attempts)
  - `teardown_each/1` - Cleanup after each execution
  - `teardown_once/1` - Final cleanup after all shrinking complete
  - `terminate?/3` - Control when command generation should stop

  ## Example

      defmodule MyTest.OrderModel do
        @behaviour PropertyDamage.Model

        alias MyTest.Commands.{CreateOrder, ViewOrder, CancelOrder}
        alias MyTest.Projections.{ModelState, OrderBalances}

        @impl true
        def commands, do: [CreateOrder, ViewOrder, CancelOrder]

        @impl true
        def state_projection, do: ModelState

        # Optional: additional projections for assertions or extra state tracking
        @impl true
        def extra_projections, do: [OrderBalances]

        # Terminate when order is deleted
        @impl true
        def terminate?(_state, %DeleteOrder{}, _events), do: true
        def terminate?(_state, _command, _events), do: false
      end

  ## Command Specification

  Commands are specified with options controlling weight, preconditions, and parameterization:

      def commands do
        [
          # Simple: just module (weight 1, always enabled, no overrides)
          CreateOrder,

          # Weighted: {module, weight}
          {ViewOrder, 2},

          # Full options: {module, keyword_list}
          {CancelOrder,
            weight: 1,
            when: fn state -> map_size(state.orders) > 0 end,
            with: fn state -> %{order_ref: StreamData.member_of(Map.keys(state.orders))} end}
        ]
      end

  ### Options

  - `:weight` - Relative selection frequency (default: 1)
  - `:when` - Precondition function `(state -> boolean)` (default: always true)
  - `:with` - Override function `(state -> map)` for command generation (default: %{})

  Weights express *relative* frequency among valid commands. If CreateOrder
  has weight 3 and CancelOrder has weight 1, and both pass their `when:` predicates,
  CreateOrder will be selected ~75% of the time.

  ## Simulate Callback

  Models define expected events for each command via `simulate/2`:

      def simulate(%CreateOrder{name: name}, _state) do
        [%OrderCreated{name: name, order_ref: nil}]
      end

      def simulate(%ViewOrder{order_ref: ref}, state) do
        if Map.has_key?(state.orders, ref) do
          [%OrderViewed{order_ref: ref}]
        else
          [%OrderNotFound{order_ref: ref}]
        end
      end

  This enables symbolic execution during sequence generation.

  ## Lifecycle Diagram

      ┌─────────────────────────────────────────────────────────────┐
      │                     Property Test Run                       │
      │                                                             │
      │  setup_once/1 ─────────────────────────────────────────┐    │
      │                                                        │    │
      │  ┌─ Run 1 ──────────────────────────────────────┐      │    │
      │  │ setup_each/1                                 │      │    │
      │  │ [execute commands against SUT]               │      │    │
      │  │ teardown_each/1                              │      │    │
      │  └──────────────────────────────────────────────┘      │    │
      │                                                        │    │
      │  ┌─ Run 2 ──────────────────────────────────────┐      │    │
      │  │ setup_each/1                                 │      │    │
      │  │ [execute commands against SUT]               │      │    │
      │  │ teardown_each/1                              │      │    │
      │  └──────────────────────────────────────────────┘      │    │
      │                       ...                              │    │
      │                                                        │    │
      │  ┌─ If failure, shrinking ─────────────────────┐       │    │
      │  │ ┌─ Shrink attempt ────────────────────┐     │       │    │
      │  │ │ setup_each/1                        │     │       │    │
      │  │ │ [execute shrunk sequence]           │     │       │    │
      │  │ │ teardown_each/1                     │     │       │    │
      │  │ └─────────────────────────────────────┘     │       │    │
      │  │                   ...                       │       │    │
      │  └─────────────────────────────────────────────┘       │    │
      │                                                        │    │
      │  teardown_once/1 ◀─────────────────────────────────────┘    │
      │                                                             │
      └─────────────────────────────────────────────────────────────┘

  ## Terminal States

  The `terminate?/3` callback controls when command generation should stop.
  This is more flexible than command-level attributes because the same
  command may or may not be terminal depending on the test scenario.

  Arguments:
  - `state` - The current state after applying events from this command
  - `command` - The command that just executed
  - `events` - The events produced by that command

  Examples:
  - Terminate on specific command: `def terminate?(_state, %Shutdown{}, _events), do: true`
  - Terminate on state: `def terminate?(state, _, _), do: map_size(state.pending) == 0`
  - Terminate on event: `def terminate?(_, _, events), do: Enum.any?(events, &is_complete?/1)`

  If not implemented, the framework runs until `max_commands` is reached.
  """

  @typedoc """
  Command specification options.

  - `:weight` - Relative selection frequency (default: 1)
  - `:when` - Precondition function `(state -> boolean)` (default: always true)
  - `:with` - Override function `(state -> map)` for command generation (default: %{})
  """
  @type command_opts :: [
          weight: pos_integer(),
          when: (map() -> boolean()),
          with: (map() -> map())
        ]

  @typedoc """
  Command specification - module, `{module, weight}`, or `{module, opts}`.
  """
  @type command_spec :: module() | {module(), pos_integer()} | {module(), command_opts()}

  @doc """
  Returns list of command specifications.

  Each command can be specified as:
  - `Module` - Simple module, weight 1, always enabled
  - `{Module, weight}` - Module with custom weight
  - `{Module, opts}` - Module with full options (weight, when, with)

  ## Examples

      def commands do
        [
          CreateOrder,                           # Always enabled, weight 1
          {ViewOrder, 2},                        # Always enabled, weight 2
          {CancelOrder,
            weight: 1,
            when: fn s -> map_size(s.orders) > 0 end,
            with: fn s -> %{order_ref: StreamData.member_of(Map.keys(s.orders))} end}
        ]
      end
  """
  @callback commands() :: [command_spec()]

  @doc """
  Returns the projection module used for state tracking.

  This projection's state is passed to:
  - `when:` predicates in command specs
  - `with:` override functions in command specs
  - `simulate/2` for determining expected events
  """
  @callback state_projection() :: module()

  @doc """
  Returns expected events for a command given current state.

  This enables symbolic execution during sequence generation, allowing
  the framework to track state evolution and generate coherent sequences.

  ## Arguments

  - `command` - The command struct being simulated
  - `state` - The current projection state

  ## Returns

  List of event structs that the command is expected to produce.

  ## Example

      def simulate(%CreateOrder{name: name}, _state) do
        [%OrderCreated{name: name, order_ref: nil}]
      end

      def simulate(%ViewOrder{order_ref: ref}, state) do
        if Map.has_key?(state.orders, ref) do
          [%OrderViewed{order_ref: ref}]
        else
          [%OrderNotFound{order_ref: ref}]
        end
      end

      # Catch-all for commands without events
      def simulate(_command, _state), do: []
  """
  @callback simulate(command :: struct(), state :: map()) :: [struct()]

  @doc """
  Returns list of additional projection modules.

  These projections can track extra state and/or define assertions via
  `use PropertyDamage.Projection`. Their state is updated with each command
  and event, and any assertions are run according to their trigger conditions.

  Optional - defaults to `[]` if not implemented.
  """
  @callback extra_projections() :: [module()]

  @doc """
  Returns list of event modules that can be injected from outside.

  These events arrive via InjectorAdapters (webhooks, callbacks, etc.),
  not from command execution. Used for validation to ensure all injectable
  events are covered by InjectorAdapter `@emits` declarations.

  Optional - defaults to `[]` if not implemented.
  """
  @callback injectable_events() :: [module()]

  @doc """
  Setup that runs ONCE at the start of the property test.

  This is NOT re-run during shrinking. Use for expensive one-time setup
  like starting applications or external services.

  ## Returns

  - `:ok` - Setup succeeded
  - `{:error, reason}` - Setup failed, test aborted
  """
  @callback setup_once(config :: map()) :: :ok | {:error, term()}

  @doc """
  Setup that runs BEFORE EACH execution.

  This runs before every execution including every shrink attempt.
  Use for resetting state that must be pristine (database, cache, etc.).

  ## Returns

  - `:ok` - Setup succeeded
  - `{:error, reason}` - Setup failed, execution skipped
  """
  @callback setup_each(config :: map()) :: :ok | {:error, term()}

  @doc """
  Teardown that runs after each execution.

  This is best-effort cleanup. The framework logs warnings if teardowns
  raise but does not fail the test.

  ## Returns

  Always returns `:ok`. Handle errors internally.
  """
  @callback teardown_each(config :: map()) :: :ok

  @doc """
  Final teardown after all shrinking complete.

  This is best-effort cleanup. The framework logs warnings if teardowns
  raise but does not fail the test.

  ## Returns

  Always returns `:ok`. Handle errors internally.
  """
  @callback teardown_once(config :: map()) :: :ok

  @doc """
  Determines if the test should terminate after the given command/events.

  Called after each command execution with the updated state.
  Return `true` to stop generating further commands.

  ## Arguments

  - `state` - The current state after applying events from this command
  - `command` - The command that just executed
  - `events` - The events produced by that command

  ## Examples

      # Terminate on specific command type
      def terminate?(_state, %Shutdown{}, _events), do: true
      def terminate?(_state, _command, _events), do: false

      # Terminate based on state
      def terminate?(state, _command, _events) do
        map_size(state.pending_payments) == 0
      end

      # Terminate based on events
      def terminate?(_state, _command, events) do
        Enum.any?(events, &match?(%PaymentCompleted{}, &1))
      end
  """
  @callback terminate?(state :: map(), command :: struct(), events :: [struct()]) :: boolean()

  @optional_callbacks [
    extra_projections: 0,
    injectable_events: 0,
    setup_once: 1,
    setup_each: 1,
    teardown_each: 1,
    teardown_once: 1,
    terminate?: 3,
    simulate: 2
  ]

  @typedoc """
  Normalized command specification with weight, module, and options.
  """
  @type normalized_command :: {pos_integer(), module(), command_opts()}

  @doc """
  Normalize command list to `{weight, module, opts}` format.

  Handles all input formats:
  - `Module` → `{1, Module, []}`
  - `{Module, weight}` → `{weight, Module, []}`
  - `{Module, opts}` → `{weight, Module, opts}` (weight from opts or default 1)

  ## Examples

      iex> PropertyDamage.Model.normalize_commands([CreateOrder])
      [{1, CreateOrder, []}]

      iex> PropertyDamage.Model.normalize_commands([{ViewOrder, 2}])
      [{2, ViewOrder, []}]

      iex> PropertyDamage.Model.normalize_commands([{CancelOrder, weight: 3, when: &some_fn/1}])
      [{3, CancelOrder, [weight: 3, when: &some_fn/1]}]
  """
  @spec normalize_commands([command_spec()]) :: [normalized_command()]
  def normalize_commands(commands) do
    Enum.map(commands, &normalize_command_spec/1)
  end

  @doc """
  Normalize a single command specification.
  """
  @spec normalize_command_spec(command_spec()) :: normalized_command()
  def normalize_command_spec(spec) do
    case spec do
      # Simple module
      module when is_atom(module) ->
        {1, module, []}

      # {module, weight} format (legacy)
      {module, weight} when is_atom(module) and is_integer(weight) and weight > 0 ->
        {weight, module, []}

      # {weight, module} format (legacy)
      {weight, module} when is_integer(weight) and weight > 0 and is_atom(module) ->
        {weight, module, []}

      # {module, opts} format (new)
      {module, opts} when is_atom(module) and is_list(opts) ->
        weight = Keyword.get(opts, :weight, 1)
        {weight, module, opts}
    end
  end
end
