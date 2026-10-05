defmodule PropertyDamage.Model.Projection do
  @moduledoc """
  Behaviour for projections that track state and optionally define checks.

  Projections are the core building block for stateful property-based testing.
  They serve two purposes:

  1. **State tracking**: Reduce commands and events into state via `apply/2`
  2. **Invariant checking**: Define checks via `@check` and `@eventually`

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

        # Synchronous check - runs immediately when event occurs
        @check every: 1
        def assert_total_non_negative(state, _cmd_or_event) do
          if state.total < 0, do: PropertyDamage.fail!("total is negative", total: state.total)
        end

        @check every: CreateOrder
        def assert_order_tracked(state, %CreateOrder{id: id}) do
          unless Map.has_key?(state.orders, id) do
            PropertyDamage.fail!("order not tracked", order_id: id)
          end
        end
      end

  ## Check Types

  There are two types of checks:

  ### Synchronous Checks (`@check`)

  Run immediately when the check condition is met. Use for invariants that
  should hold right after a command/event is processed.

      @check every: 1
      def assert_balance_positive(state, _cmd_or_event) do
        if state.balance < 0 do
          PropertyDamage.fail!("balance is negative", balance: state.balance)
        end
      end

  `@check` also supports an `at:` timing for one-shot checks at a lifecycle
  boundary (`at: :startup` / `at: :teardown`); see "Lifecycle-Boundary
  Checks" below. Use `at: :teardown` for safety properties on the settled
  final state.

  ### Eventually Checks (`@eventually`)

  Spawn a background poller when an event arrives. The poller periodically
  checks if a predicate becomes true within a timeout. Use for eventual
  consistency checks.

      @eventually after: PaymentInitiated, timeout: 5, interval: {100, :milliseconds}
      def payment_confirmed(_state, %PaymentInitiated{id: id}) do
        fn s -> s.payments[id] == :confirmed end
      end

  ## Defining Checks

  Checks are functions that take two arguments:

  1. `state` - The current projection state
  2. `command_or_event` - The command or event that triggered the check

  Each check **must** be preceded by either a `@check` or `@eventually`
  attribute. Both `@check` and `@eventually` functions can have any name.
  The `assert_` prefix is optional and conventional but not required.

  If a synchronous check fails, raise an exception (or use `PropertyDamage.fail!/2`).
  If it returns without raising, the check passed.

  For `@eventually` checks, the function must return a predicate function
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

  ## @check Syntax

  Use `@check` with `every:` to specify when a synchronous check runs:

  | Syntax | Runs when... |
  |--------|--------------|
  | `@check every: 1` | After every step |
  | `@check every: :command` | After any command |
  | `@check every: :event` | After any event |
  | `@check every: CreateOrder` | After CreateOrder command/event |
  | `@check every: [Cmd1, Cmd2]` | After any listed command/event |
  | `@check every: 10` | Every 10th step (sampling) |
  | `@check every: {5, :command}` | Every 5th command |
  | `@check every: {3, CreateOrder}` | Every 3rd CreateOrder |

  A **step** is each unit processed in the execution stream: every command AND
  every event increments the step counter. So `every: 1` runs after each command
  and after each of its events, while `every: {5, :command}` counts commands only.
  The count in `{N, target}` must be a positive integer.

  ## Lifecycle-Boundary Checks (`@check at:`)

  `@check` has a second, orthogonal timing axis: `at:`. Where `every:` *samples*
  a check during the command loop, `at:` fires it exactly **once** at a
  lifecycle phase boundary. A check carries exactly one timing: `every:` xor
  `at:` (declaring both is a compile error).

  | Syntax | Runs... |
  |--------|---------|
  | `@check at: :startup` | once on the initial `init/0` state, after `setup/1`, before command 1 |
  | `@check at: :teardown` | once on the fully-**settled** final state, after all pollers finalize, before `teardown/1` |

  Because no command or event triggers a lifecycle-boundary check, the
  second argument is the phase atom (`:startup` or `:teardown`); a state-only
  check ignores it:

      @check at: :teardown
      def assert_balance_reconciles(state, _phase) do
        if state.debits != state.credits do
          PropertyDamage.fail!("ledger did not reconcile", state: state)
        end
      end

  `at: :teardown` is the natural home for a **safety** property ("this never
  happens too much"), the temporal dual of `@eventually`'s **liveness** ("this
  eventually happens"). "Settled" means after both the state pollers
  (`@eventually`) and the resource pollers have finalized: the one point in a run
  where no poller is live and every observed event has been folded into
  projection state. An `@eventually` liveness timeout preempts the `:teardown`
  checkpoint (a timeout is itself a not-settled outcome). A failing `:startup`
  check halts the run before the first command.

  ### The accumulator contract

  A `:teardown` check runs on the **final folded state**, so detection depends on
  the projection *retaining evidence* of a violation. Write a safety projection
  to **accumulate** (track a maximum observed value, a sticky `violated?` flag, an
  application count) rather than snapshot the latest value. A snapshot projection
  that heals back to a legal value before settling silently misses a transient
  over-application:

      # GOOD — accumulates: the overshoot leaves a permanent trace.
      def apply(%{count: c, max: m} = s, %Applied{}), do: %{s | count: c + 1, max: max(m, c + 1)}

      @check at: :teardown
      def assert_at_most_once(state, _phase) do
        if state.max > 1, do: PropertyDamage.fail!("applied more than once", max: state.max)
      end

      # BAD — snapshots: a 0 -> 2 -> 1 transient is invisible at settle.
      def apply(%{count: c} = s, %Applied{}), do: %{s | count: c + 1}
      def apply(%{count: c} = s, %Reverted{}), do: %{s | count: c - 1}

  ## @eventually Syntax

  Use `@eventually` with the following options:

  | Option | Type | Description |
  |--------|------|-------------|
  | `after:` | module or `[modules]` | Event(s) that spawn the poller |
  | `timeout:` | integer or `{int, unit}` | Max time to poll (integer = seconds) |
  | `interval:` | integer or `{int, unit}` | Polling frequency (integer = seconds) |

  Time units (singular or plural): `:millisecond(s)`, `:second(s)`, `:minute(s)`

  Example:

      @eventually after: PaymentInitiated, timeout: 5, interval: {100, :milliseconds}
      def payment_confirmed(_state, %PaymentInitiated{id: id}) do
        fn s -> s.payments[id] == :confirmed end
      end

  ## Simplified Usage (No State)

  For checks that only inspect commands/events, skip `init/0` and `apply/2`:

      defmodule CommandValidator do
        use PropertyDamage.Model.Projection

        @check every: CreateOrder
        def assert_order_has_items(_state, %CreateOrder{items: items}) do
          if Enum.empty?(items), do: PropertyDamage.fail!("order must have items")
        end
      end

  ## Model Configuration

  In your Model, specify projections:

      def command_sequence_projection, do: MyStateProjection    # required
      def check_projections, do: [Validator, Audit]  # optional

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
  Execute a check.

  Checks are functions decorated with `@check` or `@eventually`.
  Called when the check's trigger condition is met. The `assert_` prefix is
  conventional but not required; when present it is stripped from the check's
  reported `:name` (so `def assert_total_ok` is reported as `:total_ok`) while the
  full function name is kept internally for dispatch. Exactly one `@check` or
  `@eventually` may decorate a check, never both and never more than one.
  Should raise an exception if the check fails.
  If the function returns without raising, the check passed.

  ## Example

      @check every: 1
      def assert_total_non_negative(state, _cmd_or_event) do
        if state.total < 0, do: PropertyDamage.fail!("total is negative")
      end

  ## Parameters

  - `state` - Current projection state
  - `command_or_event` - The command or event that triggered this check
  """

  # Note: No callback defined - checks are detected via @check/@eventually attributes

  @optional_callbacks init: 0, apply: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour PropertyDamage.Model.Projection

      # Accumulating attribute for check metadata
      Module.register_attribute(__MODULE__, :checks, accumulate: true)
      # @check / @eventually accumulate so that stacking more than one on a
      # single check is detectable (and rejected) rather than silently
      # overwriting; exactly one is expected per check.
      Module.register_attribute(__MODULE__, :check, accumulate: true)
      Module.register_attribute(__MODULE__, :eventually, accumulate: true)
      # Names of functions already registered as checks, so subsequent
      # clauses of a multi-clause check aren't re-flagged as missing @check.
      Module.register_attribute(__MODULE__, :__pd_check_fns__, accumulate: true)
      # Centralized invariant declarations (DR-026). Each value is the
      # keyword-list argument to PropertyDamage.Invariants.Invariant.new!/1, e.g.
      # `@invariant id: :balance_nonneg, description: "..."`.
      Module.register_attribute(__MODULE__, :invariant, accumulate: true)

      # Register on_definition callback to capture check definitions
      @on_definition PropertyDamage.Model.Projection

      @before_compile PropertyDamage.Model.Projection
    end
  end

  defmacro __before_compile__(env) do
    if Module.get_attribute(env.module, :check) not in [nil, []] or
         Module.get_attribute(env.module, :eventually) not in [nil, []] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "dangling @check/@eventually with no following 2-arity check function."
    end

    checks = Module.get_attribute(env.module, :checks) |> Enum.reverse()

    # Build the invariant registry (DR-026): %{id => %Invariant{}}, enforcing
    # id-uniqueness and validates: resolution, warning on declared-but-unchecked.
    invariant_attrs = Module.get_attribute(env.module, :invariant) |> Enum.reverse()
    invariants = build_invariants(env, checks, invariant_attrs)

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
      Returns metadata for all checks defined in this module.

      Each check entry contains:
      - `:name` - Atom identifying the check
      - `:trigger` - Normalized trigger specification
      """
      def __checks__, do: unquote(Macro.escape(checks))

      @doc """
      Returns the invariant registry for this projection (DR-026).

      A map of `%{id => %PropertyDamage.Invariants.Invariant{}}` covering every
      invariant declared in this projection: centrally via `@invariant`, inline
      via `@check ... id:`, and the same-named invariant each bare check
      owns by default.
      """
      def __invariants__, do: unquote(Macro.escape(invariants))
    end
  end

  # Build the %{id => %Invariant{}} registry for a projection and run the
  # compile-time structural validations (DR-026), all at @before_compile so the
  # checks are order-independent: accumulate every declaration and reference,
  # then resolve.
  defp build_invariants(env, checks, invariant_attrs) do
    alias PropertyDamage.Invariants.Invariant

    # Explicit declarations: @invariant attributes plus inline id: on checks.
    explicit_from_attrs =
      Enum.map(invariant_attrs, fn opts ->
        inv = Invariant.new!(opts)
        {inv.id, inv}
      end)

    explicit_from_inline =
      for a <- checks, a.invariant_inline? do
        {a.invariant_id, Invariant.new!(id: a.invariant_id, description: a.invariant_description)}
      end

    explicit = explicit_from_attrs ++ explicit_from_inline
    explicit_ids = Enum.map(explicit, fn {id, _} -> id end)
    dups = explicit_ids -- Enum.uniq(explicit_ids)

    unless dups == [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "duplicate invariant id(s) #{inspect(Enum.uniq(dups))} in #{inspect(env.module)}; " <>
            "each invariant id must be declared exactly once (across @invariant and inline id:)."
    end

    explicit_map = Map.new(explicit)
    explicit_id_set = MapSet.new(explicit_ids)

    # Implicit declarations: a bare check's default-named invariant, unless
    # that id is already explicitly declared (then the default links to it).
    default_ids =
      for a <- checks, not a.invariant_inline?, not a.invariant_validates?, do: a.invariant_id

    implicit_map =
      for id <- Enum.uniq(default_ids), not MapSet.member?(explicit_id_set, id), into: %{} do
        {id, Invariant.new!(id: id)}
      end

    all = Map.merge(implicit_map, explicit_map)

    # Dangling validates:: a reference to an id no declaration provides. Pure
    # local set-membership; never calls fetch!/2.
    declared_ids = MapSet.union(explicit_id_set, MapSet.new(default_ids))

    for a <- checks,
        a.invariant_validates?,
        not MapSet.member?(declared_ids, a.invariant_id) do
      raise CompileError,
        file: env.file,
        line: a.invariant_def_line,
        description:
          "check #{a.name}/2 has validates: #{inspect(a.invariant_id)}, but no invariant " <>
            "with that id is declared in #{inspect(env.module)}."
    end

    # Static vacuity: an @invariant-declared id with zero checks (inline and
    # default declarations always carry their own check, so only @invariant
    # attributes can be statically vacuous).
    checked_ids = MapSet.new(checks, & &1.invariant_id)
    attr_ids = Enum.map(explicit_from_attrs, fn {id, _} -> id end)

    for id <- Enum.uniq(attr_ids), not MapSet.member?(checked_ids, id) do
      IO.warn(
        "invariant #{inspect(id)} declared in #{inspect(env.module)} has no checks; it is " <>
          "statically vacuous (no check validates it).",
        Macro.Env.stacktrace(env)
      )
    end

    all
  end

  @doc false
  # Called by @on_definition when any function is defined in the module
  # Detects check functions (either @check or @eventually decorated)
  def __on_definition__(env, :def, name, [_state, _cmd_or_event] = _args, _guards, body) do
    # accumulate: true means these come back as lists (newest first), or [].
    check_opts = Module.get_attribute(env.module, :check) || []
    eventually_opts = Module.get_attribute(env.module, :eventually) || []
    has_check? = check_opts != []
    has_eventually? = eventually_opts != []
    decorated? = has_check? or has_eventually?
    already_registered? = name in (Module.get_attribute(env.module, :__pd_check_fns__) || [])

    cond do
      # A @check/@eventually landing on the projection's own init/apply is a
      # misplaced (dangling) attribute, not a check.
      decorated? and name in [:init, :apply] ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "@check/@eventually must immediately precede a 2-arity check function, " <>
              "not #{name}/2. Move the attribute directly above your assert_ function."

      # A check is synchronous (@check) or temporal (@eventually), never
      # both -- the two have incompatible semantics.
      has_check? and has_eventually? ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "cannot combine both @check and @eventually on the same check (#{name}/2); " <>
              "use one or the other."

      length(check_opts) > 1 ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "multiple @check attributes on #{name}/2; a check may have only one."

      length(eventually_opts) > 1 ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "multiple @eventually attributes on #{name}/2; a check may have only one."

      # A check carries exactly one timing: a during-run sample (every:) or
      # a lifecycle boundary (at:), never both (DR-024).
      has_check? and trigger_timing_conflict?(hd(check_opts)) ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "@check on #{name}/2 declares both every: and at:; a check may carry only " <>
              "one timing. Split it into two checks."

      # @eventually decorated function - eventually check
      has_eventually? ->
        check_name = extract_check_name_from_function(name) || name
        predicate_source = capture_predicate_source(body)
        {inv, opts} = extract_invariant_meta(hd(eventually_opts), check_name, env)

        check_def =
          Map.merge(inv, %{
            name: check_name,
            type: :polling,
            function_name: name,
            eventually: normalize_eventually(opts),
            predicate_source: predicate_source
          })

        Module.put_attribute(env.module, :checks, check_def)
        Module.put_attribute(env.module, :__pd_check_fns__, name)
        Module.delete_attribute(env.module, :eventually)

      # @check decorated function - synchronous check
      has_check? ->
        check_name = extract_check_name_from_function(name) || name
        {inv, opts} = extract_invariant_meta(hd(check_opts), check_name, env)

        check_def =
          Map.merge(inv, %{
            name: check_name,
            type: :synchronous,
            function_name: name,
            trigger: normalize_trigger(opts)
          })

        Module.put_attribute(env.module, :checks, check_def)
        Module.put_attribute(env.module, :__pd_check_fns__, name)
        Module.delete_attribute(env.module, :check)

      # A later clause of an already-registered (multi-clause) check: the
      # @check sat on the first clause and was consumed; this is fine.
      already_registered? ->
        :ok

      # assert_* function without attribute - error
      extract_check_name_from_function(name) != nil ->
        check_name = extract_check_name_from_function(name)

        raise CompileError,
          file: env.file,
          line: env.line,
          description: "assert_#{check_name}/2 missing @check attribute"

      true ->
        :ok
    end
  end

  # Any other definition while a @check/@eventually is pending means the
  # attribute did not land on a 2-arity check (e.g. it sat above init/0 or
  # a helper). Raise rather than silently attaching it to the wrong function.
  def __on_definition__(env, kind, name, _args, _guards, _body) do
    if Module.get_attribute(env.module, :check) not in [nil, []] or
         Module.get_attribute(env.module, :eventually) not in [nil, []] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "dangling @check/@eventually: it must immediately precede a 2-arity check " <>
            "function, but the next definition is #{kind} #{name}."
    end

    :ok
  end

  # Split the invariant-linking keys (DR-026) out of a @check/@eventually
  # keyword list, returning the check's invariant metadata plus the remaining
  # opts (the timing keys the existing trigger/poll normalizers consume).
  #
  # - `id:`        declares an invariant inline (optionally with `description:`)
  #                and registers this check as a check of it.
  # - `validates:` links this check to an invariant declared elsewhere.
  # - neither      defaults the invariant id to the check's (stripped) name,
  #                implicitly declaring a same-named invariant (full backward
  #                compatibility).
  defp extract_invariant_meta(opts, check_name, env) do
    {id, opts} = Keyword.pop(opts, :id)
    {validates, opts} = Keyword.pop(opts, :validates)
    {description, opts} = Keyword.pop(opts, :description)

    if id != nil and validates != nil do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "check #{check_name}/2 declares both id: and validates:; use id: to " <>
            "declare an invariant inline or validates: to link to one declared elsewhere, " <>
            "not both."
    end

    {invariant_id, inline?, validates?} =
      cond do
        id != nil -> {id, true, false}
        validates != nil -> {validates, false, true}
        true -> {check_name, false, false}
      end

    meta = %{
      invariant_id: invariant_id,
      invariant_inline?: inline?,
      invariant_validates?: validates?,
      invariant_description: if(inline?, do: description, else: nil),
      invariant_def_line: env.line
    }

    {meta, opts}
  end

  # Check if function name starts with "assert_" and extract the check name
  defp extract_check_name_from_function(name) when is_atom(name) do
    name_str = Atom.to_string(name)

    if String.starts_with?(name_str, "assert_") do
      name_str
      |> String.replace_prefix("assert_", "")
      |> String.to_atom()
    else
      nil
    end
  end

  # A @check carries exactly one timing axis. `at:` (lifecycle boundary) and
  # `every:` (during-run sampling) are mutually exclusive; declaring both is a
  # compile error (DR-024).
  defp trigger_timing_conflict?(opts) when is_list(opts) do
    Keyword.has_key?(opts, :every) and Keyword.has_key?(opts, :at)
  end

  # Normalize all trigger formats to a consistent internal representation. The
  # `at:` axis (a one-shot lifecycle-boundary check) takes precedence; otherwise
  # the trigger is an `every:` during-run sample.
  defp normalize_trigger(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :at) do
      normalize_at(Keyword.fetch!(opts, :at))
    else
      normalize_every(Keyword.get(opts, :every))
    end
  end

  # at: :startup -> on the initial init/0 state, before command 1
  # at: :teardown -> on the fully-settled final state, before Adapter.teardown/1
  defp normalize_at(phase) when phase in [:startup, :teardown] do
    %{type: :at, phase: phase}
  end

  defp normalize_at(other) do
    raise ArgumentError,
          "Invalid trigger: at: #{inspect(other)} -- expected :startup or :teardown"
  end

  # Normalize the `every:` (during-run sampling) axis to its internal form.
  defp normalize_every(value) do
    case value do
      # every: 1 - every step
      1 ->
        %{type: :every_step}

      # every: N - every Nth step
      n when is_integer(n) and n > 1 ->
        %{type: :every_n, n: n, target: :step}

      # every: 0 / negative - not a meaningful sampling rate
      n when is_integer(n) ->
        raise ArgumentError,
              "Invalid trigger: every: #{n} -- the count must be a positive integer"

      # every: :command - after any command
      :command ->
        %{type: :wildcard, target: :command}

      # every: :event - after any event
      :event ->
        %{type: :wildcard, target: :event}

      # A non-positive count would make the matcher's `rem(count, n)` raise an
      # ArithmeticError at runtime; reject it at compile time with a clear
      # message. (`every: 0`/negative as a bare integer is rejected below.)
      {n, _target} when is_integer(n) and n < 1 ->
        raise ArgumentError,
              "Invalid trigger: every: {#{n}, _} -- the count must be a positive integer"

      # every: {N, :command} - every Nth command
      {n, :command} when is_integer(n) ->
        %{type: :every_n, n: n, target: :command}

      # every: {N, :event} - every Nth event
      {n, :event} when is_integer(n) ->
        %{type: :every_n, n: n, target: :event}

      # every: {N, Module} - every Nth of specific module
      {n, module} when is_integer(n) and is_atom(module) ->
        validate_trigger_module!(module)
        %{type: :every_n, n: n, target: :modules, modules: [module]}

      # every: {N, [Modules]} - every Nth of any listed module
      {n, modules} when is_integer(n) and is_list(modules) ->
        Enum.each(modules, &validate_trigger_module!/1)
        %{type: :every_n, n: n, target: :modules, modules: modules}

      # every: Module - after specific module
      module when is_atom(module) ->
        validate_trigger_module!(module)
        %{type: :modules, modules: [module]}

      # every: [Modules] - after any listed module
      modules when is_list(modules) ->
        Enum.each(modules, &validate_trigger_module!/1)
        %{type: :modules, modules: modules}

      other ->
        raise ArgumentError, "Invalid trigger: every: #{inspect(other)}"
    end
  end

  # Guards against a mistyped atom value (e.g. `every: :commnd`, `every: :end`)
  # silently normalizing to a never-firing module trigger. :command/:event are
  # matched earlier; anything else atom-shaped must be a real module name.
  defp validate_trigger_module!(module) when is_atom(module) do
    unless match?("Elixir." <> _, Atom.to_string(module)) do
      raise ArgumentError,
            "Invalid trigger: every: #{inspect(module)} -- expected :command, :event, an " <>
              "integer, or a command/event module. A bare atom is not a module and would " <>
              "produce a trigger that never fires."
    end
  end

  defp validate_trigger_module!(other) do
    raise ArgumentError,
          "Invalid trigger: every: expected a module, got #{inspect(other)}"
  end

  @doc """
  Check if a check should run given the current step context.

  ## Parameters

  - `trigger` - Normalized trigger from check metadata
  - `step_type` - `:command` or `:event`
  - `module` - The command or event module
  - `counters` - Map with `:step`, `:command`, `:event`, and per-module counts

  ## Returns

  `true` if the check should run, `false` otherwise.
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

  Used by the executor to determine if an `@eventually` check should spawn
  a poller when an event is processed.

  ## Parameters

  - `eventually` - Normalized eventually spec from check metadata
  - `event_module` - The module of the event being processed

  ## Returns

  `true` if the poller should be spawned, `false` otherwise.
  """
  @spec event_matches_poll_trigger?(map(), module()) :: boolean()
  def event_matches_poll_trigger?(eventually, event_module) do
    event_module in eventually.after
  end

  # ============================================================================
  # @eventually Helpers
  # ============================================================================

  # Normalize @eventually options to a consistent internal representation
  defp normalize_eventually(opts) when is_list(opts) do
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

  # Normalize time values to milliseconds. Integer alone defaults to seconds
  # (consistent with adapter timeouts). Both singular and plural unit atoms
  # are accepted so `{1, :second}` reads as naturally as `{2, :seconds}`.
  defp normalize_time(seconds) when is_integer(seconds), do: seconds * 1000
  defp normalize_time({value, unit}) when unit in [:millisecond, :milliseconds], do: value
  defp normalize_time({value, unit}) when unit in [:second, :seconds], do: value * 1000
  defp normalize_time({value, unit}) when unit in [:minute, :minutes], do: value * 60 * 1000

  defp normalize_time({_value, unit}) do
    raise ArgumentError,
          "Invalid time unit: #{inspect(unit)} -- expected :millisecond(s), :second(s), or :minute(s)"
  end

  # Capture the predicate source from the function body for debugging
  # Tries to extract the fn expression from the body
  defp capture_predicate_source(body) do
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
