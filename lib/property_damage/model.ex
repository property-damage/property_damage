defmodule PropertyDamage.Model do
  @moduledoc """
  Behaviour for models in stateful property-based testing.

  A model ties together all the components needed for testing: which commands
  can be generated, which projections track state and checks, and the
  setup and teardown commands every run executes around its roots.

  ## Required Callbacks

  - `commands/0` - List of command modules (optionally weighted)
  - `command_sequence_projection/0` - Projection module used for command generation

  ## Optional Callbacks

  - `check_projections/0` - Projections that verify invariants
  - `injectable_events/0` - Events that can arrive from Adapter.Injector modules
  - `setup_each/0` - The setup commands, run before the roots of every run
  - `teardown_each/0` - The teardown commands, run after the roots of every run
  - `terminate_early?/3` - Control when command generation should stop

  ## Command Sequence Generation

  The framework generates command sequences through this loop:

  1. **State Check**: Get current state from `command_sequence_projection/0`
  2. **Filter Commands**: Evaluate each command's `when:` precondition against state
  3. **Select Command**: Choose from valid commands based on `weight:`
  4. **Generate Instance**: Call the selected command's `overrides:` generator with state
  5. **Simulate Execution**: Call `simulate/2` to predict resulting events
  6. **Update State**: Apply predicted events to the projection
  7. **Repeat**: Go to step 2 until sequence length reached

  During execution, real events replace simulated predictions, and check
  projections verify invariants.

  ```
  command_sequence_projection.init()
    → filter commands by `when:` predicate
    → select command (weighted random)
    → generate command data (module generator + `overrides:` values)
    → simulator.simulate(command, state)
    → synthetic events
    → command_sequence_projection.apply(events)
    → updated state
    → repeat until max_commands or terminate_early?/3 returns true
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
        def check_projections, do: [OrderBalances]

        # Terminate when order is deleted
        @impl true
        def terminate_early?(_state, %DeleteOrder{}, _events), do: true
        def terminate_early?(_state, _command, _events), do: false
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
            overrides: fn state -> %{order_ref: StreamData.member_of(Map.keys(state.orders))} end}
        ]
      end

  ### Options

  - `:weight` - Relative selection frequency (default: 1)
  - `:when` - Precondition function `(state -> boolean)` (default: always true)
  - `:overrides` - Override function `(state -> map)` for command generation (default: %{})

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

  ## Setup and teardown commands

  A fixture (a user exists, a session is open) is something every target must
  realize its own way, and only the adapter knows how. So a model declares its
  fixtures as commands: `setup_each/0` returns the setup commands and
  `teardown_each/0` the teardown commands. Both take the entries `commands/0`
  takes, but they form a sequence, not a pick list: every entry runs, in the
  order written, and `when:` and `weight:` are ignored (`mix pd.validate` warns
  about them). Infrastructure resets that need no fixture (wiping a database)
  belong in the adapter's idempotent `setup/1`.

  The generator draws the setup commands from the run seed before the roots and
  simulates them, so the roots' `when:` and `overrides:` see the fixture state
  and an `external()` a setup command produces can flow into a root. Adding a
  setup command therefore changes which roots a seed draws; a seed is stable
  for a fixed model. The teardown commands are drawn after the roots, against
  the state the last root left.

  For every run, shrink attempt and target, the order is:

      Adapter.setup/1
        @check at: :startup checks
        setup commands            (checks on; stutter and faults off)
        roots 0..n-1              (compared at each root boundary)
        final boundary, then finalization and @check at: :teardown checks
        teardown commands         (no checks; events logged, not folded)
      Adapter.teardown/1

  Setup commands are not roots: they are never compared, shrunk, counted by
  `max_commands` or passed to `terminate_early?/3`. A setup command that errors,
  fails a check, or leaves an `external()` unresolved is a setup failure (kind
  `:setup_failed`). A teardown command never fails a run: an error or an
  unresolved placeholder is logged.

  The sequence the setup commands form is unrelated to a branching sequence's
  prefix (`PropertyDamage.Sequence`): it is the setup prefix of every run,
  branching or not.

  ## Terminal States

  The `terminate_early?/3` callback runs during generation on simulator events
  and returns `true` to end the sequence before `max_commands`.
  This is more flexible than command-level attributes because the same
  command may or may not be terminal depending on the test scenario.

  Arguments:
  - `state` - The current state after applying events from this command
  - `command` - The command that just executed
  - `events` - The events produced by that command

  Examples:
  - Terminate on specific command: `def terminate_early?(_state, %Shutdown{}, _events), do: true`
  - Terminate on state: `def terminate_early?(state, _, _), do: map_size(state.pending) == 0`
  - Terminate on event: `def terminate_early?(_, _, events), do: Enum.any?(events, &is_complete?/1)`

  If not implemented, the framework runs until `max_commands` is reached.
  """

  @typedoc """
  Command specification options.

  - `:weight` - Relative selection frequency (default: 1)
  - `:when` - Precondition function `(state -> boolean)` (default: always true)
  - `:overrides` - Override function `(state -> map)` for command generation (default: %{})
  """
  @type command_opts :: [
          weight: pos_integer(),
          when: (map() -> boolean()),
          overrides: (map() -> map())
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
  - `{Module, opts}` - Module with full options (weight, when, overrides)

  ## Examples

      def commands do
        [
          CreateOrder,                           # Always enabled, weight 1
          {ViewOrder, weight: 2},                # Always enabled, weight 2
          {CancelOrder,
            weight: 1,
            when: fn s -> map_size(s.orders) > 0 end,
            overrides: fn s -> %{order_ref: StreamData.member_of(Map.keys(s.orders))} end}
        ]
      end
  """
  @callback commands() :: [command_spec()]

  @doc """
  Returns the projection module used for command sequence generation.

  This projection's state is passed to:
  - `when:` predicates in command specs (preconditions)
  - `overrides:` functions in command specs (generators)
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
  Returns list of check projection modules.

  These projections verify invariants via `use PropertyDamage.Model.Projection`.
  Their state is updated with each command and event, and checks are run
  according to their `@check` conditions.

  Optional - defaults to `[]` if not implemented.
  """
  @callback check_projections() :: [module()]

  @doc """
  Returns list of event modules that can be injected from outside.

  These events arrive via Adapter.Injector modules (webhooks, callbacks, etc.),
  not from command execution. Used for validation to ensure all injectable
  events are covered by Adapter.Injector `@emits` declarations.

  Optional - defaults to `[]` if not implemented.
  """
  @callback injectable_events() :: [module()]

  @typedoc """
  A sequence of command entries, written as `commands/0` entries are
  (`Module`, `{Module, weight}` or `{Module, opts}`). Every entry runs, in
  order; `when:` and `weight:` are ignored.
  """
  @type sequence :: [command_spec()]

  @doc """
  The setup commands: run in every target after the adapter's `setup/1` and
  before the first root, in every run and every shrink attempt.

  Each entry's `overrides:` sees the state the earlier setup commands left.
  A setup command that errors, fails a check or leaves an `external()`
  unresolved is a setup failure. Optional - defaults to `[]`.

  ## Example

      def setup_each do
        [
          {CreateUser, overrides: %{role: "admin"}},
          {Login, overrides: fn state -> %{user_id: state.admin_id} end}
        ]
      end
  """
  @callback setup_each() :: sequence()

  @doc """
  The teardown commands: run in every target after the last root, the final
  boundary and the `@check at: :teardown` checks, and before the adapter's
  `teardown/1`, whatever the run's outcome.

  Each entry's `overrides:` sees the state after the last root. A teardown
  command runs no checks and its events are logged without being folded; an
  error or an unresolved placeholder is logged and never fails the run.
  Optional - defaults to `[]`.
  """
  @callback teardown_each() :: sequence()

  @doc """
  Decides whether to end the sequence being generated before `max_commands`.

  Runs during generation, after each command, on the events the simulator
  produced for it. Return `true` to stop generating further commands for this
  sequence.

  ## Arguments

  - `state` - The current state after applying events from this command
  - `command` - The command that just executed
  - `events` - The events produced by that command

  ## Examples

      # Terminate on specific command type
      def terminate_early?(_state, %Shutdown{}, _events), do: true
      def terminate_early?(_state, _command, _events), do: false

      # Terminate based on state
      def terminate_early?(state, _command, _events) do
        map_size(state.pending_payments) == 0
      end

      # Terminate based on events
      def terminate_early?(_state, _command, events) do
        Enum.any?(events, &match?(%PaymentCompleted{}, &1))
      end
  """
  @callback terminate_early?(state :: map(), command :: struct(), events :: [struct()]) ::
              boolean()

  @optional_callbacks [
    check_projections: 0,
    injectable_events: 0,
    setup_each: 0,
    teardown_each: 0,
    terminate_early?: 3,
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
  # `{weight, module, spec}` tuple. Bad `when:`/`overrides:` arities used to fail
  # with an opaque CaseClauseError deep in generation; surface them here.
  defp finalize_spec(resolved, module) do
    if Map.has_key?(resolved, :with) do
      raise ArgumentError,
            "Invalid `with:` for command #{inspect(module)}: `with:` was renamed `overrides:`."
    end

    if Map.has_key?(resolved, :acceptable_retry_events) do
      raise ArgumentError,
            "Invalid command entry #{inspect(module)}: " <>
              PropertyDamage.Command.retired_acceptable_retry_events()
    end

    validate_when!(Map.get(resolved, :when), module)
    validate_overrides!(Map.get(resolved, :overrides), module)
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

  # An `overrides:` option is either a map or invoked as `fun.(state)` to produce a
  # map during generation; reject other shapes before they hit generation.
  defp validate_overrides!(nil, _module), do: :ok
  defp validate_overrides!(map, _module) when is_map(map), do: :ok
  defp validate_overrides!(fun, _module) when is_function(fun, 1), do: :ok

  defp validate_overrides!(fun, module) when is_function(fun) do
    raise ArgumentError,
          "Invalid `overrides:` for command #{inspect(module)}: " <>
            "expected a 1-arity function `fn state -> map end` or a map, " <>
            "got a function of arity #{fun_arity(fun)}."
  end

  defp validate_overrides!(other, module) do
    raise ArgumentError,
          "Invalid `overrides:` for command #{inspect(module)}: " <>
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
  The model's setup commands, normalized like `normalize_commands/1`; `[]` when
  the model does not define `setup_each/0`.
  """
  @spec setup_commands(module()) :: [normalized_command()]
  def setup_commands(model), do: sequence_commands(model, :setup_each)

  @doc """
  The model's teardown commands, normalized like `normalize_commands/1`; `[]`
  when the model does not define `teardown_each/0`.
  """
  @spec teardown_commands(module()) :: [normalized_command()]
  def teardown_commands(model), do: sequence_commands(model, :teardown_each)

  defp sequence_commands(model, callback) do
    if Code.ensure_loaded?(model) and function_exported?(model, callback, 0) do
      model |> apply(callback, []) |> normalize_commands()
    else
      []
    end
  end

  # The lifecycle hooks the setup and teardown commands replaced.
  @removed_hooks [
    setup_each: 1,
    teardown_each: 1,
    setup_once: 1,
    teardown_once: 1,
    setup_once: 0,
    teardown_once: 0
  ]

  @doc """
  Raise an `ArgumentError` when `model` defines a removed lifecycle hook
  (`setup_each/1`, `teardown_each/1`, `setup_once/0,1`, `teardown_once/0,1`)
  or lists a nemesis module among its setup or teardown commands.

  Runs before any target is set up, so a stale model fails before it touches a
  system.
  """
  @spec check_lifecycle!(module()) :: :ok
  def check_lifecycle!(model) do
    Code.ensure_loaded(model)

    case Enum.filter(@removed_hooks, fn {name, arity} ->
           function_exported?(model, name, arity)
         end) do
      [] -> :ok
      hooks -> raise ArgumentError, removed_hooks_message(model, hooks)
    end

    for callback <- [:setup_each, :teardown_each],
        function_exported?(model, callback, 0),
        module <- Enum.map(apply(model, callback, []), &entry_module/1),
        is_atom(module) and PropertyDamage.Nemesis.nemesis_module?(module) do
      raise ArgumentError,
            "#{inspect(model)}.#{callback}/0 lists the nemesis #{inspect(module)}: " <>
              "faults are never injected before the first root or during teardown, " <>
              "so list it in commands/0 instead."
    end

    :ok
  end

  @doc """
  The command module a `commands/0`, `setup_each/0` or `teardown_each/0` entry
  names, or nil for an entry of another shape.
  """
  @spec entry_module(term()) :: module() | nil
  def entry_module(module) when is_atom(module), do: module
  def entry_module({module, _weight_or_opts}) when is_atom(module), do: module
  def entry_module(%{command: module}) when is_atom(module), do: module
  def entry_module(_entry), do: nil

  defp removed_hooks_message(model, hooks) do
    names = Enum.map_join(hooks, ", ", fn {name, arity} -> "#{name}/#{arity}" end)

    once =
      if Enum.any?(hooks, fn {name, _arity} -> name in [:setup_once, :teardown_once] end) do
        " Once-per-campaign setup has no hook: make the adapter's setup/1 idempotent " <>
          "(Adapter.setup/1 runs before every run) or wrap PropertyDamage.run/1 yourself."
      else
        ""
      end

    "#{inspect(model)} defines #{names}, which no longer exist. A model declares its " <>
      "fixtures as commands: setup_each/0 returns the setup commands and " <>
      "teardown_each/0 the teardown commands, run in every target before and after " <>
      "the roots. Side effects the adapter can do alone belong in Adapter.setup/1." <> once
  end

  @doc """
  The full projection list a model exposes.

  The command-sequence projection plus any `check_projections/0`,
  deduplicated (a projection listed in both appears once).
  """
  @spec projection_modules(module()) :: [module()]
  def projection_modules(model) do
    check_projections =
      if function_exported?(model, :check_projections, 0) do
        model.check_projections()
      else
        []
      end

    [model.command_sequence_projection() | check_projections]
    |> Enum.uniq()
  end

  @doc """
  The model's invariant catalog (DR-026).

  The union of every projection's invariant registry (`__invariants__/0`), keyed
  by `{projection, id}` so two projections may reuse an `id` for distinct
  invariants. Each entry carries the `%PropertyDamage.Invariants.Invariant{}` and
  the checks that check it, with a per-check kind:

  - `:synchronous` - a during-run `@check every:` check
  - `:lifecycle` - a `@check at:` lifecycle-boundary check
  - `:eventual` - an `@eventually` check

  Returns a list deterministically ordered by `{inspect(projection), id}`.
  """
  @spec check_catalog(module()) :: [
          %{
            projection: module(),
            id: atom(),
            invariant: PropertyDamage.Invariants.Invariant.t(),
            checks: [%{name: atom(), kind: :synchronous | :lifecycle | :eventual}]
          }
        ]
  def check_catalog(model) do
    for projection <- projection_modules(model),
        function_exported?(projection, :__invariants__, 0),
        {id, invariant} <- projection.__invariants__() do
      checks =
        projection.__checks__()
        |> Enum.filter(&(&1.invariant_id == id))
        |> Enum.map(fn a -> %{name: a.name, kind: check_kind(a)} end)

      %{projection: projection, id: id, invariant: invariant, checks: checks}
    end
    |> Enum.sort_by(fn entry -> {inspect(entry.projection), entry.id} end)
  end

  defp check_kind(%{type: :polling}), do: :eventual
  defp check_kind(%{type: :synchronous, trigger: %{type: :at}}), do: :lifecycle
  defp check_kind(%{type: :synchronous}), do: :synchronous
end
