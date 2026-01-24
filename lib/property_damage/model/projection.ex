defmodule PropertyDamage.Model.Projection do
  @moduledoc """
  Behaviour for projections that track state and optionally define assertions.

  Projections are the core building block for stateful property-based testing.
  They serve two purposes:

  1. **State tracking**: Reduce commands and events into state via `apply/2`
  2. **Invariant checking**: Define assertions via `@trigger` and `@poll_state`

  ## Basic Usage

      defmodule MyProjection do
        use PropertyDamage.Model.Projection

        # Track state
        def init, do: %{orders: %{}, total: 0}

        def apply(state, %OrderCreated{id: id, amount: amt}) do
          state
          |> put_in([:orders, id], %{amount: amt})
          |> update_in([:total], &(&1 + amt))
        end

        def apply(state, _), do: state

        # Synchronous assertion - runs immediately when event occurs
        @trigger every: 1
        def assert_total_non_negative(state, _cmd_or_event) do
          if state.total < 0, do: PropertyDamage.fail!("total is negative", total: state.total)
        end

        @trigger every: CreateOrder
        def assert_order_tracked(state, %CreateOrder{id: id}) do
          unless Map.has_key?(state.orders, id) do
            PropertyDamage.fail!("order not tracked", order_id: id)
          end
        end
      end

  ## Assertion Types

  There are two types of assertions:

  ### Synchronous Assertions (`@trigger`)

  Run immediately when the trigger condition is met. Use for invariants that
  should hold right after a command/event is processed.

      @trigger every: 1
      def assert_balance_positive(state, _cmd_or_event) do
        if state.balance < 0 do
          PropertyDamage.fail!("balance is negative", balance: state.balance)
        end
      end

  ### Temporal Assertions (`@poll_state`)

  Spawn a background poller when a trigger event occurs. The poller periodically
  checks if a predicate becomes true within a timeout. Use for eventual
  consistency assertions.

      @poll_state after: PaymentInitiated, timeout: 5, interval: {100, :milliseconds}
      def payment_confirmed(_state, %PaymentInitiated{id: id}) do
        fn s -> s.payments[id] == :confirmed end
      end

  ## Defining Assertions

  Assertions are functions that take two arguments:

  1. `state` - The current projection state
  2. `command_or_event` - The command or event that triggered the assertion

  Each assertion **must** be preceded by either a `@trigger` or `@poll_state`
  attribute. Both `@trigger` and `@poll_state` functions can have any name.
  The `assert_` prefix is optional and conventional but not required.

  If a synchronous assertion fails, raise an exception (or use `PropertyDamage.fail!/2`).
  If it returns without raising, the assertion passed.

  For `@poll_state` assertions, the function must return a predicate function
  `(state -> boolean)` that will be polled.

  ## Raising in apply/2

  You can raise exceptions in `apply/2` to catch transition invariants:

      def apply(state, %Withdraw{amount: amt}) do
        new_balance = state.balance - amt
        if new_balance < 0 do
          raise %InsufficientFunds{balance: state.balance, requested: amt}
        end
        %{state | balance: new_balance}
      end

  ## @trigger Syntax

  Use `@trigger` with `every:` to specify when a synchronous assertion runs:

  | Syntax | Runs when... |
  |--------|--------------|
  | `@trigger every: 1` | After every step |
  | `@trigger every: :command` | After any command |
  | `@trigger every: :event` | After any event |
  | `@trigger every: CreateOrder` | After CreateOrder command/event |
  | `@trigger every: [Cmd1, Cmd2]` | After any listed command/event |
  | `@trigger every: 10` | Every 10th step (sampling) |
  | `@trigger every: {5, :command}` | Every 5th command |
  | `@trigger every: {3, CreateOrder}` | Every 3rd CreateOrder |

  ## @poll_state Syntax

  Use `@poll_state` with the following options:

  | Option | Type | Description |
  |--------|------|-------------|
  | `after:` | module or `[modules]` | Event(s) that spawn the poller |
  | `timeout:` | integer or `{int, unit}` | Max time to poll (integer = seconds) |
  | `interval:` | integer or `{int, unit}` | Polling frequency (integer = seconds) |

  Time units: `:milliseconds`, `:seconds`, `:minutes`

  Example:

      @poll_state after: PaymentInitiated, timeout: 5, interval: {100, :milliseconds}
      def payment_confirmed(_state, %PaymentInitiated{id: id}) do
        fn s -> s.payments[id] == :confirmed end
      end

  ## Simplified Usage (No State)

  For assertions that only inspect commands/events, skip `init/0` and `apply/2`:

      defmodule CommandValidator do
        use PropertyDamage.Model.Projection

        @trigger every: CreateOrder
        def assert_order_has_items(_state, %CreateOrder{items: items}) do
          if Enum.empty?(items), do: PropertyDamage.fail!("order must have items")
        end
      end

  ## Model Configuration

  In your Model, specify projections:

      def command_sequence_projection, do: MyStateProjection    # required
      def assertion_projections, do: [Validator, Audit]  # optional

  All projections (state + extra) use the same `Projection` behaviour.
  """

  @doc """
  Initialize the projection state.

  Called once at the start of each test run. Default returns `%{}`.
  """
  @callback init() :: any()

  @doc """
  Apply a command or event to the state.

  Called for each command and event in the execution stream.
  Can raise an exception to signal a transition invariant violation.
  Default returns the state unchanged.
  """
  @callback apply(state :: any(), command_or_event :: struct()) :: any()

  @doc """
  Execute an assertion.

  Assertions are functions decorated with `@trigger` or `@poll_state`.
  Called when the assertion's trigger condition is met. The `assert_` prefix is conventional but not required.
  Should raise an exception if the assertion fails.
  If the function returns without raising, the assertion passed.

  ## Example

      @trigger every: 1
      def assert_total_non_negative(state, _cmd_or_event) do
        if state.total < 0, do: PropertyDamage.fail!("total is negative")
      end

  ## Parameters

  - `state` - Current projection state
  - `command_or_event` - The command or event that triggered this assertion
  """

  # Note: No callback defined - assertions are detected via @trigger/@poll_state attributes

  @optional_callbacks init: 0, apply: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour PropertyDamage.Model.Projection

      # Accumulating attribute for assertion metadata
      Module.register_attribute(__MODULE__, :assertions, accumulate: true)
      Module.register_attribute(__MODULE__, :trigger, accumulate: false)
      Module.register_attribute(__MODULE__, :poll_state, accumulate: false)

      # Register on_definition callback to capture assertion definitions
      @on_definition PropertyDamage.Model.Projection

      @before_compile PropertyDamage.Model.Projection
    end
  end

  defmacro __before_compile__(env) do
    assertions = Module.get_attribute(env.module, :assertions) |> Enum.reverse()

    # Check if init/0 is defined
    has_init = Module.defines?(env.module, {:init, 0})

    # Check if apply/2 is defined
    has_apply = Module.defines?(env.module, {:apply, 2})

    default_init =
      unless has_init do
        quote do
          @doc false
          def init, do: %{}
        end
      end

    default_apply =
      unless has_apply do
        quote do
          @doc false
          def apply(state, _command_or_event), do: state
        end
      end

    quote do
      unquote(default_init)
      unquote(default_apply)

      @doc """
      Returns metadata for all assertions defined in this module.

      Each assertion entry contains:
      - `:name` - Atom identifying the assertion
      - `:trigger` - Normalized trigger specification
      """
      def __assertions__, do: unquote(Macro.escape(assertions))
    end
  end

  @doc false
  # Called by @on_definition when any function is defined in the module
  # Detects assertion functions (either @trigger or @poll_state decorated)
  def __on_definition__(env, :def, name, [_state, _cmd_or_event] = _args, _guards, body) do
    trigger_opts = Module.get_attribute(env.module, :trigger)
    poll_state_opts = Module.get_attribute(env.module, :poll_state)

    cond do
      # @poll_state decorated function - temporal assertion
      poll_state_opts != nil ->
        predicate_source = capture_predicate_source(body)

        assertion_def = %{
          name: name,
          type: :polling,
          poll_state: normalize_poll_state(poll_state_opts),
          predicate_source: predicate_source
        }

        Module.put_attribute(env.module, :assertions, assertion_def)
        Module.delete_attribute(env.module, :poll_state)

      # @trigger decorated function - synchronous assertion
      trigger_opts != nil ->
        assertion_name = extract_assertion_name_from_function(name) || name

        assertion_def = %{
          name: assertion_name,
          type: :synchronous,
          trigger: normalize_trigger(trigger_opts),
          function_name: name
        }

        Module.put_attribute(env.module, :assertions, assertion_def)
        Module.delete_attribute(env.module, :trigger)

      # assert_* function without attribute - error
      extract_assertion_name_from_function(name) != nil ->
        assertion_name = extract_assertion_name_from_function(name)

        raise CompileError,
          file: env.file,
          line: env.line,
          description: "assert_#{assertion_name}/2 missing @trigger attribute"

      true ->
        :ok
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  # Check if function name starts with "assert_" and extract the assertion name
  defp extract_assertion_name_from_function(name) when is_atom(name) do
    name_str = Atom.to_string(name)

    if String.starts_with?(name_str, "assert_") do
      name_str
      |> String.replace_prefix("assert_", "")
      |> String.to_atom()
    else
      nil
    end
  end

  # Normalize all trigger formats to a consistent internal representation
  defp normalize_trigger(opts) when is_list(opts) do
    case Keyword.get(opts, :every) do
      # every: 1 - every step
      1 ->
        %{type: :every_step}

      # every: N - every Nth step
      n when is_integer(n) and n > 1 ->
        %{type: :every_n, n: n, target: :step}

      # every: :command - after any command
      :command ->
        %{type: :wildcard, target: :command}

      # every: :event - after any event
      :event ->
        %{type: :wildcard, target: :event}

      # every: {N, :command} - every Nth command
      {n, :command} when is_integer(n) ->
        %{type: :every_n, n: n, target: :command}

      # every: {N, :event} - every Nth event
      {n, :event} when is_integer(n) ->
        %{type: :every_n, n: n, target: :event}

      # every: {N, Module} - every Nth of specific module
      {n, module} when is_integer(n) and is_atom(module) ->
        %{type: :every_n, n: n, target: :modules, modules: [module]}

      # every: {N, [Modules]} - every Nth of any listed module
      {n, modules} when is_integer(n) and is_list(modules) ->
        %{type: :every_n, n: n, target: :modules, modules: modules}

      # every: Module - after specific module
      module when is_atom(module) ->
        %{type: :modules, modules: [module]}

      # every: [Modules] - after any listed module
      modules when is_list(modules) ->
        %{type: :modules, modules: modules}

      other ->
        raise ArgumentError, "Invalid trigger: every: #{inspect(other)}"
    end
  end

  @doc """
  Check if an assertion should run given the current step context.

  ## Parameters

  - `trigger` - Normalized trigger from assertion metadata
  - `step_type` - `:command` or `:event`
  - `module` - The command or event module
  - `counters` - Map with `:step`, `:command`, `:event`, and per-module counts

  ## Returns

  `true` if the assertion should run, `false` otherwise.
  """
  @spec should_run?(map(), :command | :event, module(), map()) :: boolean()
  def should_run?(trigger, step_type, module, counters) do
    case trigger do
      # Every step
      %{type: :every_step} ->
        true

      # Every Nth step
      %{type: :every_n, n: n, target: :step} ->
        rem(counters.step, n) == 0

      # Wildcard: any command or any event
      %{type: :wildcard, target: target} ->
        step_type == target

      # Every Nth command/event
      %{type: :every_n, n: n, target: target} when target in [:command, :event] ->
        step_type == target and rem(Map.get(counters, target, 0), n) == 0

      # Specific modules
      %{type: :modules, modules: modules} ->
        module in modules

      # Every Nth of specific modules
      %{type: :every_n, n: n, target: :modules, modules: modules} ->
        if module in modules do
          count = Map.get(counters, module, 0)
          rem(count, n) == 0
        else
          false
        end
    end
  end

  @doc """
  Check if an event matches a polling trigger.

  Used by the executor to determine if a `@poll_state` assertion should spawn
  a poller when an event is processed.

  ## Parameters

  - `poll_state` - Normalized poll_state spec from assertion metadata
  - `event_module` - The module of the event being processed

  ## Returns

  `true` if the poller should be spawned, `false` otherwise.
  """
  @spec event_matches_poll_trigger?(map(), module()) :: boolean()
  def event_matches_poll_trigger?(poll_state, event_module) do
    event_module in poll_state.after
  end

  # ============================================================================
  # @poll_state Helpers
  # ============================================================================

  # Normalize @poll_state options to a consistent internal representation
  defp normalize_poll_state(opts) when is_list(opts) do
    after_events = normalize_module_list(Keyword.fetch!(opts, :after))
    timeout_ms = normalize_time(Keyword.fetch!(opts, :timeout))
    interval_ms = normalize_time(Keyword.fetch!(opts, :interval))

    %{
      after: after_events,
      timeout_ms: timeout_ms,
      interval_ms: interval_ms
    }
  end

  # Normalize a module or list of modules to always be a list
  defp normalize_module_list(module) when is_atom(module), do: [module]
  defp normalize_module_list(modules) when is_list(modules), do: modules

  # Normalize time values to milliseconds
  # Integer alone defaults to seconds (consistent with adapter timeouts)
  defp normalize_time(seconds) when is_integer(seconds), do: seconds * 1000
  defp normalize_time({value, :milliseconds}), do: value
  defp normalize_time({value, :seconds}), do: value * 1000
  defp normalize_time({value, :minutes}), do: value * 60 * 1000

  # Capture the predicate source from the function body for debugging
  # Tries to extract the fn expression from the body
  defp capture_predicate_source(body) do
    try do
      # The body is typically a block with a fn expression
      case body do
        # Direct fn expression: fn x -> ... end
        {:fn, _, _} = fn_expr ->
          Macro.to_string(fn_expr)

        # Block with single expression
        [do: {:fn, _, _} = fn_expr] ->
          Macro.to_string(fn_expr)

        # Block with single expression (alternate form)
        {:__block__, _, [{:fn, _, _} = fn_expr]} ->
          Macro.to_string(fn_expr)

        # Block ending with fn expression
        [do: {:__block__, _, exprs}] when is_list(exprs) ->
          case List.last(exprs) do
            {:fn, _, _} = fn_expr -> Macro.to_string(fn_expr)
            _ -> Macro.to_string(body)
          end

        # Fallback: stringify the whole body
        _ ->
          Macro.to_string(body)
      end
    rescue
      _ -> "unable to capture predicate source"
    end
  end
end
