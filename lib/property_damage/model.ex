defmodule PropertyDamage.Model do
  @moduledoc """
  Behaviour for models in stateful property-based testing.

  A model ties together all the components needed for testing: which commands
  can be generated, which projections track state and assertions, and the
  test lifecycle hooks.

  ## Required Callbacks

  - `commands/0` - List of command modules (optionally weighted)
  - `state_projection/0` - Projection module used for command preconditions
  - `assertion_projections/0` - Projection modules checked for invariant violations

  ## Optional Callbacks

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

        @impl true
        def assertion_projections, do: [OrderBalances]

        # Terminate when order is deleted
        @impl true
        def terminate?(_state, %DeleteOrder{}, _events), do: true
        def terminate?(_state, _command, _events), do: false
      end

  ## Command Weights

  Commands can be weighted to control selection frequency:

      def commands do
        [
          {3, CreateOrder},   # 3x relative weight
          {2, ViewOrder},     # 2x relative weight
          {1, CancelOrder}    # 1x relative weight
        ]
      end

  Simple list format `[CreateOrder, ViewOrder]` treats all commands equally.

  Weights express *relative* frequency among valid commands. If CreateOrder
  has weight 3 and CancelOrder has weight 1, and both pass their preconditions,
  CreateOrder will be selected ~75% of the time.

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
  Command specification - either a module or `{weight, module}` tuple.
  """
  @type command_spec :: module() | {pos_integer(), module()}

  @doc """
  Returns list of command modules that can be generated.

  Can return either:
  - Simple list: `[CreateOrder, ViewOrder, CancelOrder]` - all weighted equally
  - Weighted list: `[{3, CreateOrder}, {2, ViewOrder}, {1, CancelOrder}]`

  The framework normalizes simple lists to weighted format internally.
  """
  @callback commands() :: [command_spec()]

  @doc """
  Returns the projection module used for command preconditions.

  This projection's state is passed to `Command.precondition/1` and
  `Command.new!/2` during command generation.
  """
  @callback state_projection() :: module()

  @doc """
  Returns list of projection modules checked for invariant violations.

  These projections can define checks via `use PropertyDamage.AssertionProjection`.
  Their state is updated with each command and event, and checks are run
  according to their trigger conditions.
  """
  @callback assertion_projections() :: [module()]

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
    injectable_events: 0,
    setup_once: 1,
    setup_each: 1,
    teardown_each: 1,
    teardown_once: 1,
    terminate?: 3
  ]

  @doc """
  Normalize command list to weighted format.

  Converts simple module list to `{1, module}` tuples.

  ## Examples

      iex> PropertyDamage.Model.normalize_commands([CreateOrder, ViewOrder])
      [{1, CreateOrder}, {1, ViewOrder}]

      iex> PropertyDamage.Model.normalize_commands([{3, CreateOrder}, {1, ViewOrder}])
      [{3, CreateOrder}, {1, ViewOrder}]
  """
  @spec normalize_commands([command_spec()]) :: [{pos_integer(), module()}]
  def normalize_commands(commands) do
    Enum.map(commands, fn
      {weight, module} when is_integer(weight) and weight > 0 -> {weight, module}
      module when is_atom(module) -> {1, module}
    end)
  end
end
