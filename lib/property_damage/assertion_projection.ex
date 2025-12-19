defmodule PropertyDamage.AssertionProjection do
  @moduledoc """
  Extended projection behaviour with check functions for assertions.

  AssertionProjection extends Projection with the ability to define check
  functions that verify invariants. Checks have trigger conditions that
  determine when they run, and can be linked to requirement IDs for
  traceability.

  ## Usage

      defmodule MyTest.Projections.OrderBalances do
        use PropertyDamage.AssertionProjection

        @impl true
        def init, do: %{orders: %{}, total: 0}

        @impl true
        def apply(state, %OrderCreated{amount: amt}) do
          update_in(state, [:total], &(&1 + amt))
        end

        def apply(state, _), do: state

        # Check that runs after every step
        @check :always
        @requirement "REQ-ACCT-001"
        def check(:total_non_negative, state, _ctx) do
          if state.total >= 0, do: :ok, else: {:error, "Negative total"}
        end

        # Check that runs after specific command
        @check after: RefundOrder
        @requirement "REQ-REFUND-001"
        def check(:refund_valid, state, ctx) do
          if ctx.command.amount > 0, do: :ok, else: {:error, "Invalid amount"}
        end
      end

  ## Check Triggers

  The `@check` attribute determines when a check runs:

  | Value | Runs when... |
  |-------|--------------|
  | `:always` | After every step (command + events, or injected event) |
  | `after: RefundOrder` | After RefundOrder command executes |
  | `after: [Cmd1, Cmd2]` | After any listed command executes |
  | `after: OrderCancelled` | When OrderCancelled event is produced |
  | `after: [Event1, Event2]` | When any listed event is produced |
  | `after: [Cmd, Event]` | After command OR when event produced |
  | `:always, sample: 10` | Every 10th step |
  | `after: RefundOrder, sample: 5` | Every 5th RefundOrder execution |

  ## Check Context

  Checks receive a context map with:

  ```elixir
  %{
    command: %RefundOrder{...},       # The command (nil for injected events)
    events: [%RefundFailed{...}],     # Events from this step
    command_index: 5,                  # Index in sequence
    step_count: 42,                    # Total steps so far
    projections: %{...}                # All projection states
  }
  ```

  ## Requirements Traceability

  Link checks to external requirement IDs using `@requirement`:

  ```elixir
  @requirement "REQ-REFUND-001"
  @requirement "REQ-REFUND-002"
  @check :always
  def check(:refund_valid, state, ctx), do: ...
  ```

  Or use the `requirements/1` macro for multiple at once:

  ```elixir
  requirements ["REQ-001", "REQ-002"]
  @check :always
  def check(:balance_check, state, ctx), do: ...
  ```

  ## Sampling for Performance

  Expensive checks can use `sample: N` to run only every Nth time:

  ```elixir
  @check :always, sample: 10
  def check(:expensive_check, state, _ctx), do: ...
  ```
  """

  @doc """
  Initialize the assertion projection state.
  """
  @callback init() :: any()

  @doc """
  Apply a command or event to the state.
  """
  @callback apply(state :: any(), command_or_event :: struct()) :: any()

  @doc """
  Execute a named check.

  ## Parameters

  - `name` - Atom identifying the check
  - `state` - Current projection state
  - `ctx` - Context map with command, events, indices, etc.

  ## Returns

  - `:ok` - Check passed
  - `{:error, reason}` - Check failed with reason
  """
  @callback check(name :: atom(), state :: any(), ctx :: map()) :: :ok | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour PropertyDamage.AssertionProjection

      # Accumulating attributes for check metadata
      Module.register_attribute(__MODULE__, :checks, accumulate: true)
      Module.register_attribute(__MODULE__, :pending_check, accumulate: false)
      Module.register_attribute(__MODULE__, :requirement, accumulate: true)
      Module.register_attribute(__MODULE__, :pending_requirements_list, accumulate: false)

      # Register on_definition callback to capture check/3 function definitions
      @on_definition PropertyDamage.AssertionProjection

      @before_compile PropertyDamage.AssertionProjection

      import PropertyDamage.AssertionProjection, only: [requirements: 1, check: 1, check: 2]
    end
  end

  @doc """
  Register a check trigger for the next check/3 definition.

  The trigger determines when the check runs during execution.

  ## Triggers

  - `:always` - Run after every step
  - `after: Module` - Run after specific command or event
  - `after: [Mod1, Mod2]` - Run after any of the listed modules

  ## Options

  - `:sample` - Run every Nth time (default: 1)

  ## Examples

      check :always
      def check(:my_check, state, ctx), do: ...

      check after: CreateOrder
      def check(:after_create, state, ctx), do: ...

      check :always, sample: 10
      def check(:expensive_check, state, ctx), do: ...
  """
  defmacro check(trigger, opts \\ []) do
    quote do
      @pending_check {unquote(trigger), unquote(opts)}
    end
  end

  @doc """
  Set multiple requirements at once.

  Alternative to using multiple `@requirement` attributes.

  ## Example

      requirements ["REQ-001", "REQ-002", "REQ-003"]
      @check :always
      def check(:my_check, state, ctx), do: ...
  """
  defmacro requirements(req_list) do
    quote do
      @pending_requirements_list unquote(req_list)
    end
  end

  defmacro __before_compile__(env) do
    checks = Module.get_attribute(env.module, :checks) |> Enum.reverse()

    quote do
      @doc """
      Returns metadata for all checks defined in this module.

      Each check entry contains:
      - `:name` - Atom identifying the check
      - `:trigger` - When the check runs (`:always` or `[after: [...]]`)
      - `:requirements` - List of requirement IDs
      - `:sample` - How often to run (1 = every time, N = every Nth)
      """
      def __checks__, do: unquote(Macro.escape(checks))
    end
  end

  @doc false
  # Called by @on_definition when any function is defined in the module
  def __on_definition__(env, :def, :check, [name_ast, _state, _ctx], _guards, _body) do
    name = extract_check_name(name_ast)

    case Module.get_attribute(env.module, :pending_check) do
      nil ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "check/3 definition for :#{name} missing @check attribute"

      {trigger, opts} ->
        # Merge requirements from both @requirement (accumulating) and requirements/1 (list)
        single_reqs = Module.get_attribute(env.module, :requirement) || []
        list_reqs = Module.get_attribute(env.module, :pending_requirements_list) || []
        requirements = single_reqs ++ List.wrap(list_reqs)

        check_def = %{
          name: name,
          trigger: normalize_trigger(trigger, opts),
          requirements: requirements,
          sample: Keyword.get(opts, :sample, 1)
        }

        Module.put_attribute(env.module, :checks, check_def)
        Module.delete_attribute(env.module, :pending_check)
        Module.delete_attribute(env.module, :requirement)
        Module.delete_attribute(env.module, :pending_requirements_list)
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  defp extract_check_name({name, _, _}) when is_atom(name), do: name
  defp extract_check_name(name) when is_atom(name), do: name

  defp normalize_trigger(:always, _opts), do: :always
  defp normalize_trigger([{:after, triggers} | _], _opts), do: [{:after, List.wrap(triggers)}]
  defp normalize_trigger({:after, triggers}, _opts), do: [{:after, List.wrap(triggers)}]
end
