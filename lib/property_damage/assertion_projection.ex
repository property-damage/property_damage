defmodule PropertyDamage.AssertionProjection do
  @moduledoc """
  Extended projection behaviour with assertion functions for invariant checking.

  AssertionProjection extends Projection with the ability to define assertions
  that verify invariants. Assertions have trigger conditions that determine
  when they run, and can be linked to requirement IDs for traceability.

  ## Usage

      defmodule MyTest.Projections.OrderBalances do
        use PropertyDamage.AssertionProjection

        # Optional: track state if needed (defaults to %{})
        @impl true
        def init, do: %{orders: %{}, total: 0}

        # Optional: update state on commands/events (defaults to returning state unchanged)
        @impl true
        def apply(state, %OrderCreated{amount: amt}) do
          %{state | total: state.total + amt}
        end

        def apply(state, _), do: state

        # Assertion that runs after every step - receives command/event as 3rd arg
        @requirement "REQ-ACCT-001"
        trigger every: 1
        def assert(:total_non_negative, state, _cmd_or_event) do
          if state.total >= 0, do: :ok, else: {:error, "Negative total"}
        end

        # Assertion that runs after specific command - can inspect the command directly
        @requirement "REQ-REFUND-001"
        trigger every: RefundOrder
        def assert(:refund_valid, _state, %RefundOrder{amount: amount}) do
          if amount > 0, do: :ok, else: {:error, "Invalid refund amount"}
        end
      end

  ## Simplified Usage (No State Tracking)

  For assertions that only need to inspect commands/events directly,
  you can skip `init/0` and `apply/2` entirely:

      defmodule MyTest.Projections.CommandValidator do
        use PropertyDamage.AssertionProjection

        # Just define assertions - init/0 returns %{}, apply/2 is a no-op
        trigger every: CreateOrder
        def assert(:order_has_items, _state, %CreateOrder{items: items}) do
          if length(items) > 0, do: :ok, else: {:error, "Order must have items"}
        end

        trigger every: :command
        def assert(:positive_amounts, _state, cmd) do
          if Map.get(cmd, :amount, 1) > 0, do: :ok, else: {:error, "Amount must be positive"}
        end
      end

  ## Trigger Syntax

  Use the `trigger` macro with `every:` to specify when an assertion runs:

  | Syntax | Runs when... |
  |--------|--------------|
  | `trigger every: 1` | After every step (command + events, or injected event) |
  | `trigger every: :command` | After any command executes |
  | `trigger every: :event` | After any event is produced |
  | `trigger every: RefundOrder` | After RefundOrder command or event |
  | `trigger every: [Cmd1, Cmd2]` | After any listed command/event |
  | `trigger every: 10` | Every 10th step (sampling) |
  | `trigger every: {5, :command}` | Every 5th command |
  | `trigger every: {3, RefundOrder}` | Every 3rd RefundOrder |
  | `trigger every: {2, [Cmd1, Cmd2]}` | Every 2nd of any listed |

  ## Requirements Traceability

  Link assertions to external requirement IDs using `@requirement`:

  ```elixir
  @requirement "REQ-REFUND-001"
  @requirement "REQ-REFUND-002"
  trigger every: 1
  def assert(:refund_valid, state, cmd_or_event), do: ...
  ```

  Or use the `requirements/1` macro for multiple at once:

  ```elixir
  requirements ["REQ-001", "REQ-002"]
  trigger every: 1
  def assert(:balance_check, state, cmd_or_event), do: ...
  ```
  """

  @doc """
  Initialize the assertion projection state.

  Optional callback. Default implementation returns an empty map `%{}`.
  """
  @callback init() :: any()

  @doc """
  Apply a command or event to the state.

  Optional callback. Default implementation returns the state unchanged.
  """
  @callback apply(state :: any(), command_or_event :: struct()) :: any()

  @doc """
  Execute a named assertion.

  ## Parameters

  - `name` - Atom identifying the assertion
  - `state` - Current projection state
  - `command_or_event` - The command or event that triggered this assertion

  ## Returns

  - `:ok` - Assertion passed
  - `{:error, reason}` - Assertion failed with reason
  """
  @callback assert(name :: atom(), state :: any(), command_or_event :: struct()) ::
              :ok | {:error, term()}

  @optional_callbacks init: 0, apply: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour PropertyDamage.AssertionProjection

      # Accumulating attributes for assertion metadata
      Module.register_attribute(__MODULE__, :assertions, accumulate: true)
      Module.register_attribute(__MODULE__, :pending_trigger, accumulate: false)
      Module.register_attribute(__MODULE__, :requirement, accumulate: true)
      Module.register_attribute(__MODULE__, :pending_requirements_list, accumulate: false)

      # Register on_definition callback to capture assert/2 function definitions
      @on_definition PropertyDamage.AssertionProjection

      @before_compile PropertyDamage.AssertionProjection

      import PropertyDamage.AssertionProjection,
        only: [
          requirements: 1,
          trigger: 1,
          # Backward compatibility: check/1 and check/2 as aliases
          check: 1,
          check: 2
        ]
    end
  end

  @doc """
  Register a trigger for the next assert/3 definition.

  The trigger determines when the assertion runs during execution.

  ## Trigger Syntax

  All triggers use the `every:` keyword:

  | Syntax | Meaning |
  |--------|---------|
  | `every: 1` | Every step |
  | `every: :command` | After any command |
  | `every: :event` | After any event |
  | `every: Module` | After specific module |
  | `every: [Modules]` | After any listed module |
  | `every: N` | Every Nth step (sampling) |
  | `every: {N, :command}` | Every Nth command |
  | `every: {N, :event}` | Every Nth event |
  | `every: {N, Module}` | Every Nth of specific module |
  | `every: {N, [Modules]}` | Every Nth of any listed module |

  ## Examples

      trigger every: 1
      def assert(:my_check, state, _cmd_or_event), do: ...

      trigger every: CreateOrder
      def assert(:after_create, state, cmd_or_event), do: ...

      trigger every: {10, :command}
      def assert(:sampled_check, state, _cmd_or_event), do: ...
  """
  defmacro trigger(opts) do
    quote do
      @pending_trigger unquote(opts)
    end
  end

  @doc """
  Legacy: Register a check trigger. Use `@trigger every:` instead.

  Provided for backward compatibility during migration.
  """
  defmacro check(trigger_or_opts, opts \\ [])

  defmacro check(:always, opts) do
    sample = Keyword.get(opts, :sample, 1)

    quote do
      @pending_trigger [every: unquote(sample)]
    end
  end

  defmacro check([{:after, triggers} | rest], _opts) do
    sample = Keyword.get(rest, :sample, 1)
    triggers = List.wrap(triggers)

    trigger_spec =
      if sample == 1 do
        triggers
      else
        {sample, triggers}
      end

    quote do
      @pending_trigger [every: unquote(Macro.escape(trigger_spec))]
    end
  end

  defmacro check({:after, triggers}, opts) do
    sample = Keyword.get(opts, :sample, 1)
    triggers = List.wrap(triggers)

    trigger_spec =
      if sample == 1 do
        triggers
      else
        {sample, triggers}
      end

    quote do
      @pending_trigger [every: unquote(Macro.escape(trigger_spec))]
    end
  end

  @doc """
  Set multiple requirements at once.

  Alternative to using multiple `@requirement` attributes.

  ## Example

      requirements ["REQ-001", "REQ-002", "REQ-003"]
      trigger every: 1
      def assert(:my_check, state, _cmd_or_event), do: ...
  """
  defmacro requirements(req_list) do
    quote do
      @pending_requirements_list unquote(req_list)
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
      - `:requirements` - List of requirement IDs
      """
      def __assertions__, do: unquote(Macro.escape(assertions))

      # Backward compatibility
      @doc false
      def __checks__, do: __assertions__()
    end
  end

  @doc false
  # Called by @on_definition when any function is defined in the module
  # Handles assert/3 (current) and check/3 (legacy)
  def __on_definition__(env, :def, :assert, [name_ast, _state, _cmd_or_event], _guards, _body) do
    register_assertion(env, name_ast)
  end

  def __on_definition__(env, :def, :check, [name_ast, _state, _ctx], _guards, _body) do
    register_assertion(env, name_ast)
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  defp register_assertion(env, name_ast) do
    name = extract_assertion_name(name_ast)

    case Module.get_attribute(env.module, :pending_trigger) do
      nil ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "assert/3 definition for :#{name} missing `trigger` attribute"

      trigger_opts ->
        # Merge requirements from both @requirement (accumulating) and requirements/1 (list)
        single_reqs = Module.get_attribute(env.module, :requirement) || []
        list_reqs = Module.get_attribute(env.module, :pending_requirements_list) || []
        requirements = single_reqs ++ List.wrap(list_reqs)

        assertion_def = %{
          name: name,
          trigger: normalize_trigger(trigger_opts),
          requirements: requirements
        }

        Module.put_attribute(env.module, :assertions, assertion_def)
        Module.delete_attribute(env.module, :pending_trigger)
        Module.delete_attribute(env.module, :requirement)
        Module.delete_attribute(env.module, :pending_requirements_list)
    end
  end

  defp extract_assertion_name({name, _, _}) when is_atom(name), do: name
  defp extract_assertion_name(name) when is_atom(name), do: name

  # Normalize all trigger formats to a consistent internal representation
  # Internal format: %{type: :every_step | :every_n | :wildcard | :modules, ...}
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
