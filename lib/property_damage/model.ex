defmodule PropertyDamage.Model do
  @moduledoc """
  Behaviour for models in stateful property-based testing.

  A model ties together all the components needed for testing: which commands
  can be generated, which projections track state and assertions, and the
  test lifecycle hooks.

  ## Required Callbacks

  - `commands/0` - List of command modules (optionally weighted)
  - `command_sequence_projection/0` - Projection module used for command generation

  ## Optional Callbacks

  - `assertion_projections/0` - Projections that verify invariants
  - `injectable_events/0` - Events that can arrive from Adapter.Injector modules
  - `setup_once/1` - Setup that runs once at the start (not during shrinking)
  - `setup_each/1` - Setup that runs before each execution (including shrink attempts)
  - `teardown_each/1` - Cleanup after each execution
  - `teardown_once/1` - Final cleanup after all shrinking complete
  - `terminate?/3` - Control when command generation should stop

  ## Command Sequence Generation

  The framework generates command sequences through this loop:

  1. **State Check**: Get current state from `command_sequence_projection/0`
  2. **Filter Commands**: Evaluate each command's `when:` precondition against state
  3. **Select Command**: Choose from valid commands based on `weight:`
  4. **Generate Instance**: Call the selected command's `with:` generator with state
  5. **Simulate Execution**: Call `simulate/2` to predict resulting events
  6. **Update State**: Apply predicted events to the projection
  7. **Repeat**: Go to step 2 until sequence length reached

  During execution, real events replace simulated predictions, and assertion
  projections verify invariants.

  ```
  command_sequence_projection.init()
    → filter commands by `when:` predicate
    → select command (weighted random)
    → generate command data (module generator + `with:` overrides)
    → simulator.simulate(command, state)
    → synthetic events
    → command_sequence_projection.apply(events)
    → updated state
    → repeat until max_commands or terminate?/3 returns true
  ```

  ## Example

      defmodule MyTest.OrderModel do
        @behaviour PropertyDamage.Model

        alias MyTest.Commands.{CreateOrder, ViewOrder, CancelOrder}
        alias MyTest.Projections.{ModelState, OrderBalances}

        @impl true
        def commands, do: [CreateOrder, ViewOrder, CancelOrder]

        @impl true
        def command_sequence_projection, do: ModelState

        # Optional: projections that verify invariants
        @impl true
        def assertion_projections, do: [OrderBalances]

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

          # Weighted: {module, weight: n}
          {ViewOrder, weight: 2},

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

  ## Simulator

  Models can define a Simulator module that predicts expected events for each command.
  See `PropertyDamage.Model.Simulator` for the behaviour definition.

      defmodule MySimulator do
        @behaviour PropertyDamage.Model.Simulator

        @impl true
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
      end

  Then reference it in the model:

      def simulator, do: MySimulator

  For inline implementation, have the model implement both behaviours:

      defmodule MyModel do
        @behaviour PropertyDamage.Model
        @behaviour PropertyDamage.Model.Simulator

        def simulator, do: __MODULE__

        @impl PropertyDamage.Model.Simulator
        def simulate(%CreateOrder{name: name}, _state), do: [%OrderCreated{name: name}]
        def simulate(_command, _state), do: []
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
          {ViewOrder, weight: 2},                # Always enabled, weight 2
          {CancelOrder,
            weight: 1,
            when: fn s -> map_size(s.orders) > 0 end,
            with: fn s -> %{order_ref: StreamData.member_of(Map.keys(s.orders))} end}
        ]
      end
  """
  @callback commands() :: [command_spec()]

  @doc """
  Returns the projection module used for command sequence generation.

  This projection's state is passed to:
  - `when:` predicates in command specs (preconditions)
  - `with:` override functions in command specs (generators)
  - `simulate/2` for predicting expected events

  During sequence generation, the simulator predicts events and this projection
  applies them to update state, enabling valid subsequent command selection.

  ## Example

      @impl true
      def command_sequence_projection, do: MyApp.OrderStateProjection
  """
  @callback command_sequence_projection() :: module()

  @doc """
  Returns the module implementing the Simulator behaviour.

  The simulator predicts expected events for each command during sequence
  generation, enabling symbolic execution.

  ## Example

      # Reference an external simulator
      def simulator, do: MyApp.OrderSimulator

      # Or inline (module implements both Model and Simulator behaviours)
      def simulator, do: __MODULE__

  See `PropertyDamage.Model.Simulator` for implementing the behaviour.
  """
  @callback simulator() :: module()

  @doc """
  Returns list of assertion projection modules.

  These projections verify invariants via `use PropertyDamage.Model.Projection`.
  Their state is updated with each command and event, and assertions are run
  according to their `@trigger` conditions.

  Optional - defaults to `[]` if not implemented.
  """
  @callback assertion_projections() :: [module()]

  @doc """
  Returns list of event modules that can be injected from outside.

  These events arrive via Adapter.Injector modules (webhooks, callbacks, etc.),
  not from command execution. Used for validation to ensure all injectable
  events are covered by Adapter.Injector `@emits` declarations.

  Optional - defaults to `[]` if not implemented.
  """
  @callback injectable_events() :: [module()]

  @typedoc """
  Argument map delivered to every lifecycle callback.

  `:adapter_config` is guaranteed on every invocation of every lifecycle
  callback: it is the `adapter_config` map passed to the run (defaulting to
  `%{}`). The remaining keys are path tags, present only on the paths that set
  them, so a robust callback destructures `adapter_config` and treats the rest
  as informational:

  - `:run_number` - the exploration run index. Present on the run-loop and
    trace/single-run paths (the latter passes `0`); absent during replay.
  - `:replay` - always `true` when present. Set only on the
    `PropertyDamage.replay/2` path; never combined with `:run_number`.
  - `:capture` - always `true` when present. Set only on the trace-capture
    path (`RunTrace`), alongside `:run_number`.
  """
  @type lifecycle_config :: %{
          required(:adapter_config) => map(),
          optional(:run_number) => non_neg_integer(),
          optional(:replay) => true,
          optional(:capture) => true
        }

  @doc """
  Setup that runs ONCE at the start of the property test.

  This is NOT re-run during shrinking. Use for expensive one-time setup
  like starting applications or external services.

  Runs on the standard run path only (`PropertyDamage.run/3`); replay never
  invokes the `_once` callbacks. Receives `%{adapter_config: adapter_config}`.

  ## Returns

  - `:ok` - Setup succeeded
  - `{:error, reason}` - Setup failed, test aborted
  """
  @callback setup_once(config :: lifecycle_config()) :: :ok | {:error, term()}

  @doc """
  Setup that runs BEFORE EACH execution.

  This runs before every execution including every shrink attempt.
  Use for resetting state that must be pristine (database, cache, etc.).

  `:adapter_config` is always present. The run-loop and trace/single-run paths
  additionally pass `:run_number` (the trace path uses `0`); replay instead
  passes `replay: true`; the trace-capture path also sets `capture: true`.
  Destructure `%{adapter_config: config}` and treat the rest as informational.

  ## Returns

  - `:ok` - Setup succeeded
  - `{:error, reason}` - Setup failed, execution skipped
  """
  @callback setup_each(config :: lifecycle_config()) :: :ok | {:error, term()}

  @doc """
  Teardown that runs after each execution.

  This is best-effort cleanup. The framework logs warnings if teardowns
  raise but does not fail the test.

  Receives the same argument contract as `setup_each/1`: `:adapter_config` is
  always present; the run-loop and trace/single-run paths add `:run_number`
  (the trace path uses `0`), and replay adds `replay: true`.

  ## Returns

  Always returns `:ok`. Handle errors internally.
  """
  @callback teardown_each(config :: lifecycle_config()) :: :ok

  @doc """
  Final teardown after all shrinking complete.

  This is best-effort cleanup. The framework logs warnings if teardowns
  raise but does not fail the test.

  Runs on the standard run path only. Receives
  `%{adapter_config: adapter_config}`.

  ## Returns

  Always returns `:ok`. Handle errors internally.
  """
  @callback teardown_once(config :: lifecycle_config()) :: :ok

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
    assertion_projections: 0,
    injectable_events: 0,
    setup_once: 1,
    setup_each: 1,
    teardown_each: 1,
    teardown_once: 1,
    terminate?: 3,
    simulator: 0
  ]

  @typedoc """
  Normalized command specification with weight, module, and resolved spec.

  The spec is a map containing all configuration for the command, resolved
  from `command_spec/1` or legacy callbacks.
  """
  @type normalized_command :: {pos_integer(), module(), map()}

  @doc """
  Normalize command list to `{weight, module, spec}` format.

  Handles all input formats:
  - `Module` → `{weight, Module, spec}` using command_spec/1 or legacy callbacks
  - `{Module, weight}` → `{weight, Module, spec}` (legacy format)
  - `{Module, opts}` → `{weight, Module, spec}` opts passed to command_spec/1
  - `%{command: Module, ...}` → `{weight, Module, spec}` map merged with resolved spec

  ## Examples

      iex> PropertyDamage.Model.normalize_commands([CreateOrder])
      [{1, CreateOrder, %{command: CreateOrder, execution: :sync, ...}}]

      iex> PropertyDamage.Model.normalize_commands([{ViewOrder, weight: 2}])
      [{2, ViewOrder, %{command: ViewOrder, weight: 2, ...}}]
  """
  @spec normalize_commands([command_spec()]) :: [normalized_command()]
  def normalize_commands(commands) do
    Enum.map(commands, &normalize_command_spec/1)
  end

  @doc """
  Normalize a single command specification.

  Resolves the command's spec using `command_spec/1` if available,
  otherwise falls back to legacy callbacks.
  """
  @spec normalize_command_spec(command_spec()) :: normalized_command()
  def normalize_command_spec(spec) do
    case spec do
      # Simple module
      module when is_atom(module) ->
        finalize_spec(resolve_spec(module, []), module)

      # {module, weight} format (legacy)
      {module, weight} when is_atom(module) and is_integer(weight) and weight > 0 ->
        finalize_spec(resolve_spec(module, weight: weight), module)

      # {module, opts} format (new)
      {module, opts} when is_atom(module) and is_list(opts) ->
        finalize_spec(resolve_spec(module, opts), module)

      # Map form with :command key
      %{command: module} = map when is_atom(module) ->
        opts = map |> Map.delete(:command) |> Map.to_list()
        finalize_spec(resolve_spec(module, opts), module)
    end
  end

  # Validate the resolved spec's selection/generation callbacks and return the
  # `{weight, module, spec}` tuple. Bad `when:`/`with:` arities used to fail
  # with an opaque CaseClauseError deep in generation; surface them here.
  defp finalize_spec(resolved, module) do
    validate_when!(Map.get(resolved, :when), module)
    validate_with!(Map.get(resolved, :with), module)
    {validate_weight!(resolved.weight, module), module, resolved}
  end

  # A command's weight is its bucket size in the weighted random selection;
  # zero/negative/non-integer weights make total_weight non-positive and break
  # the generator's `StreamData.integer(1..total_weight)` draw. Reject them with
  # a clear error at normalization rather than failing obscurely at generation.
  defp validate_weight!(weight, _module) when is_integer(weight) and weight > 0, do: weight

  defp validate_weight!(weight, module) do
    raise ArgumentError,
          "Invalid weight #{inspect(weight)} for command #{inspect(module)}: " <>
            "weight must be a positive integer."
  end

  # A `when:` precondition is invoked as `pred.(state)` during command
  # selection; anything but a 1-arity function (or nil) breaks that call.
  defp validate_when!(nil, _module), do: :ok
  defp validate_when!(fun, _module) when is_function(fun, 1), do: :ok

  defp validate_when!(fun, module) when is_function(fun) do
    raise ArgumentError,
          "Invalid `when:` for command #{inspect(module)}: " <>
            "expected a 1-arity function `fn state -> boolean end`, " <>
            "got a function of arity #{fun_arity(fun)}."
  end

  defp validate_when!(other, module) do
    raise ArgumentError,
          "Invalid `when:` for command #{inspect(module)}: " <>
            "expected a 1-arity function `fn state -> boolean end`, got #{inspect(other)}."
  end

  # A `with:` override is either a map or invoked as `fun.(state)` to produce a
  # map during generation; reject other shapes before they hit generation.
  defp validate_with!(nil, _module), do: :ok
  defp validate_with!(map, _module) when is_map(map), do: :ok
  defp validate_with!(fun, _module) when is_function(fun, 1), do: :ok

  defp validate_with!(fun, module) when is_function(fun) do
    raise ArgumentError,
          "Invalid `with:` for command #{inspect(module)}: " <>
            "expected a 1-arity function `fn state -> map end` or a map, " <>
            "got a function of arity #{fun_arity(fun)}."
  end

  defp validate_with!(other, module) do
    raise ArgumentError,
          "Invalid `with:` for command #{inspect(module)}: " <>
            "expected a 1-arity function `fn state -> map end` or a map, got #{inspect(other)}."
  end

  defp fun_arity(fun) do
    fun |> :erlang.fun_info(:arity) |> elem(1)
  end

  @doc """
  Resolve a command's spec map.

  Commands authored via `use PropertyDamage.Command` (or an explicit
  `command_spec/1`) resolve through that single surface. A command module without
  `command_spec/1` resolves to the framework defaults layered with `opts`, so
  spec-less commands still produce a complete spec map.

  ## Parameters

  - `module` - The command module
  - `opts` - Override options to pass to command_spec/1

  ## Returns

  A complete spec map.
  """
  @spec resolve_spec(module(), keyword()) :: map()
  def resolve_spec(module, opts) do
    if function_exported?(module, :command_spec, 1) do
      module.command_spec(opts)
    else
      PropertyDamage.Command.build_spec(module, [], opts)
    end
  end

  @doc """
  The full projection list a model exposes.

  The command-sequence projection plus any `assertion_projections/0`,
  deduplicated (a projection listed in both appears once).
  """
  @spec projection_modules(module()) :: [module()]
  def projection_modules(model) do
    assertion_projections =
      if function_exported?(model, :assertion_projections, 0) do
        model.assertion_projections()
      else
        []
      end

    [model.command_sequence_projection() | assertion_projections]
    |> Enum.uniq()
  end

  @doc """
  The model's invariant catalog (DR-026).

  The union of every projection's invariant registry (`__invariants__/0`), keyed
  by `{projection, id}` so two projections may reuse an `id` for distinct
  invariants. Each entry carries the `%PropertyDamage.Invariants.Invariant{}` and
  the assertions that check it, with a per-check kind:

  - `:synchronous` - a during-run `@trigger every:` check
  - `:lifecycle` - a `@trigger at:` lifecycle-boundary check
  - `:polling` - a temporal `@poll_state` check

  Returns a list deterministically ordered by `{inspect(projection), id}`.
  """
  @spec assertion_catalog(module()) :: [
          %{
            projection: module(),
            id: atom(),
            invariant: PropertyDamage.Invariants.Invariant.t(),
            checks: [%{name: atom(), kind: :synchronous | :lifecycle | :polling}]
          }
        ]
  def assertion_catalog(model) do
    for projection <- projection_modules(model),
        function_exported?(projection, :__invariants__, 0),
        {id, invariant} <- projection.__invariants__() do
      checks =
        projection.__assertions__()
        |> Enum.filter(&(&1.invariant_id == id))
        |> Enum.map(fn a -> %{name: a.name, kind: check_kind(a)} end)

      %{projection: projection, id: id, invariant: invariant, checks: checks}
    end
    |> Enum.sort_by(fn entry -> {inspect(entry.projection), entry.id} end)
  end

  defp check_kind(%{type: :polling}), do: :polling
  defp check_kind(%{type: :synchronous, trigger: %{type: :at}}), do: :lifecycle
  defp check_kind(%{type: :synchronous}), do: :synchronous
end
