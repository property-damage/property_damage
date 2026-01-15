defmodule PropertyDamage.Model.Projection do
  @moduledoc """
  Behaviour for projections that track state and optionally define assertions.

  Projections are the core building block for stateful property-based testing.
  They serve two purposes:

  1. **State tracking**: Reduce commands and events into state via `apply/2`
  2. **Invariant checking**: Define assertions via `assert_*` functions

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

        # Define assertions with @trigger and assert_* naming
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

  ## Defining Assertions

  Assertions are functions that start with `assert_` and take two arguments:

  1. `state` - The current projection state
  2. `command_or_event` - The command or event that triggered the assertion

  Each assertion **must** be preceded by a `@trigger` attribute that specifies
  when the assertion should run. The assertion name is derived from the function
  name by removing the `assert_` prefix.

      # This creates an assertion named :balance_positive
      @trigger every: 1
      def assert_balance_positive(state, _cmd_or_event) do
        if state.balance < 0 do
          PropertyDamage.fail!("balance is negative", balance: state.balance)
        end
      end

  If an assertion fails, raise an exception (or use `PropertyDamage.fail!/2`).
  If it returns without raising, the assertion passed.

  ## Raising in apply/2

  You can raise exceptions in `apply/2` to catch transition invariants:

      def apply(state, %Withdraw{amount: amt}) do
        new_balance = state.balance - amt
        if new_balance < 0 do
          raise %InsufficientFunds{balance: state.balance, requested: amt}
        end
        %{state | balance: new_balance}
      end

  ## Trigger Syntax

  Use `@trigger` with `every:` to specify when an assertion runs:

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

      def state_projection, do: MyStateProjection    # required
      def extra_projections, do: [Validator, Audit]  # optional

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

  Assertions are defined as functions starting with `assert_` followed by the assertion name.
  Called when the assertion's trigger condition is met.
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

  # Note: No callback defined - assertions are detected via function name prefix

  @optional_callbacks init: 0, apply: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour PropertyDamage.Model.Projection

      # Accumulating attribute for assertion metadata
      Module.register_attribute(__MODULE__, :assertions, accumulate: true)
      Module.register_attribute(__MODULE__, :trigger, accumulate: false)

      # Register on_definition callback to capture assert_* definitions
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
  # Detects assert_* functions with arity 2
  def __on_definition__(env, :def, name, [_state, _cmd_or_event], _guards, _body) do
    case extract_assertion_name_from_function(name) do
      nil ->
        # Not an assertion function
        :ok

      assertion_name ->
        case Module.get_attribute(env.module, :trigger) do
          nil ->
            raise CompileError,
              file: env.file,
              line: env.line,
              description: "assert_#{assertion_name}/2 missing @trigger attribute"

          trigger_opts ->
            assertion_def = %{
              name: assertion_name,
              trigger: normalize_trigger(trigger_opts)
            }

            Module.put_attribute(env.module, :assertions, assertion_def)
            Module.delete_attribute(env.module, :trigger)
        end
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
end
