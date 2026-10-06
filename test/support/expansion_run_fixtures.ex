defmodule PropertyDamage.Test.ExpansionRun do
  @moduledoc false
  # Fixtures for models whose roots expand into leaves (`expansions/0`): what
  # each variant executes, how the run counts it, how the report names it, and
  # how a shrunk failure re-executes it.
  #
  # Every root command carries a `tag`, a tuple the shrinker never simplifies,
  # and every leaf of an expansion copies its root's tag, so a recorder entry
  # names the root it belongs to in any execution (exploration, shrink attempt,
  # reproduction or replay).
  #
  # `RecordingAdapter` appends to a shared recorder
  # (`PropertyDamage.Test.VariantSupport.start_recorder/0`):
  #
  #   {:setup, name}               setup/1 ran: a new execution of that target
  #   {:execute, name, command}    execute/3 ran with the resolved command
  #   {:teardown, name}            teardown/1 ran
  #
  # and the fixture projections add:
  #
  #   {:compared, name}            Totals' @compare observation ran
  #   {:every2, name}              EveryTwo's `every: {2, :command}` check fired
  #
  # Models are defined at runtime by `define_model!/2`; their callback lists
  # (expansion functions included) are kept in `:persistent_term`.

  alias PropertyDamage.{FailureReport, Generator, Sequence}
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.VariantSupport

  # ==========================================================================
  # Events
  # ==========================================================================

  defmodule Noised do
    @moduledoc false
    defstruct [:tag, :amount, :part, :by, :sink]
  end

  defmodule Opened do
    @moduledoc false
    defstruct [:tag, :amount, :part, :by, :sink]
  end

  defmodule Paid do
    @moduledoc false
    defstruct [:tag, :amount, :part, :by, :sink]
  end

  defmodule Authorized do
    @moduledoc false
    defstruct [:tag, :amount, :part, :by, :sink]
  end

  defmodule Captured do
    @moduledoc false
    defstruct [:tag, :amount, :part, :by, :sink]
  end

  defmodule Refunded do
    @moduledoc false
    defstruct [:tag, :amount, :part, :by, :sink]
  end

  defmodule Credited do
    @moduledoc false
    defstruct [:tag, :amount, :part, :by, :sink]
  end

  defmodule Voided do
    @moduledoc false
    defstruct [:tag, :amount, :part, :by, :sink]
  end

  defmodule Stuck do
    @moduledoc false
    defstruct [:tag, :amount, :part, :by, :sink]
  end

  defmodule Haunted do
    @moduledoc false
    defstruct [:tag, :amount, :part, :by, :sink]
  end

  # ==========================================================================
  # Commands
  # ==========================================================================

  @doc false
  # A tag no shrink step simplifies: argument shrinking leaves tuples alone.
  def tag_gen, do: StreamData.map(StreamData.integer(1..2_000_000_000), &{:tag, &1})

  defmodule Noise do
    @moduledoc false
    use PropertyDamage.Command
    alias PropertyDamage.Test.ExpansionRun
    defstruct [:tag]

    @impl true
    def generator(overrides \\ %{}) do
      %{tag: ExpansionRun.tag_gen()}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Open do
    @moduledoc false
    use PropertyDamage.Command
    alias PropertyDamage.Test.ExpansionRun
    defstruct [:tag]

    @impl true
    def generator(overrides \\ %{}) do
      %{tag: ExpansionRun.tag_gen()}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Void do
    @moduledoc false
    use PropertyDamage.Command
    alias PropertyDamage.Test.ExpansionRun
    defstruct [:tag]

    @impl true
    def generator(overrides \\ %{}) do
      %{tag: ExpansionRun.tag_gen()}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Pay do
    @moduledoc false
    use PropertyDamage.Command
    alias PropertyDamage.Test.ExpansionRun
    defstruct [:tag, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{tag: ExpansionRun.tag_gen(), amount: StreamData.integer(2..1_000)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Refund do
    @moduledoc false
    use PropertyDamage.Command
    alias PropertyDamage.Test.ExpansionRun
    defstruct [:tag, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{tag: ExpansionRun.tag_gen(), amount: StreamData.integer(2..1_000)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Authorize do
    @moduledoc false
    use PropertyDamage.Command, observables: [PropertyDamage.Test.ExpansionRun.Authorized]
    defstruct [:tag, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{tag: StreamData.constant(nil), amount: StreamData.integer(1..1_000)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Capture do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:tag, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{tag: StreamData.constant(nil), amount: StreamData.integer(1..1_000)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Credit do
    @moduledoc false
    # `memo` is never overridden: its value comes from the leaf's own draw.
    use PropertyDamage.Command, observables: [PropertyDamage.Test.ExpansionRun.Credited]
    defstruct [:tag, :amount, :part, :memo]

    @impl true
    def generator(overrides \\ %{}) do
      %{
        tag: StreamData.constant(nil),
        amount: StreamData.integer(0..1_000),
        part: StreamData.constant(0),
        memo: StreamData.integer(1..1_000_000_000)
      }
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Blocked do
    @moduledoc false
    # Listed in commands/0 with a `when:` that never holds, so as a leaf it
    # always fails its precondition.
    use PropertyDamage.Command
    defstruct [:tag]

    @impl true
    def generator(overrides \\ %{}) do
      %{tag: StreamData.constant(nil)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Ghost do
    @moduledoc false
    # A leaf that only ever follows Blocked, so it is never realized.
    use PropertyDamage.Command, observables: [PropertyDamage.Test.ExpansionRun.Haunted]
    defstruct [:tag]

    @impl true
    def generator(overrides \\ %{}) do
      %{tag: StreamData.constant(nil)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Broken do
    @moduledoc false
    # A leaf module that is not a command: it has no generator/1.
    defstruct [:tag]
  end

  # ==========================================================================
  # Projections
  # ==========================================================================

  defmodule World do
    @moduledoc false
    # The sequence projection. `roots` counts root events only.
    @behaviour PropertyDamage.Model.Projection

    alias PropertyDamage.Test.ExpansionRun, as: X

    @impl true
    def init, do: %{roots: 0, opened: false, authorizing: false, payments: 0}

    @impl true
    def apply(state, %X.Opened{}), do: %{state | opened: true, roots: state.roots + 1}
    def apply(state, %X.Authorized{}), do: %{state | authorizing: true}

    def apply(state, %X.Captured{}),
      do: %{state | authorizing: false, payments: state.payments + 1}

    def apply(state, %X.Paid{}),
      do: %{state | payments: state.payments + 1, roots: state.roots + 1}

    def apply(state, %event{}) when event in [X.Noised, X.Refunded, X.Voided],
      do: %{state | roots: state.roots + 1}

    def apply(state, _other), do: state
  end

  defmodule Totals do
    @moduledoc false
    # The folded totals every variant is compared on after every root. A
    # root's expansions all fold to the same totals.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.ExpansionRun, as: X

    @impl true
    def init, do: %{paid: 0, refunded: 0, by: nil, sink: nil}

    @impl true
    def apply(state, %X.Paid{amount: a} = e), do: learn(%{state | paid: state.paid + a}, e)
    def apply(state, %X.Captured{amount: a} = e), do: learn(%{state | paid: state.paid + a}, e)

    def apply(state, %X.Refunded{amount: a} = e),
      do: learn(%{state | refunded: state.refunded + a}, e)

    def apply(state, %X.Credited{amount: a} = e),
      do: learn(%{state | refunded: state.refunded + a}, e)

    def apply(state, %{by: _} = e), do: learn(state, e)
    def apply(state, _other), do: state

    defp learn(state, %{by: by, sink: sink}) when not is_nil(by),
      do: %{state | by: by, sink: sink}

    defp learn(state, _event), do: state

    @compare every: 1
    def totals(state, _root) do
      VariantSupport.record(state.sink, {:compared, state.by})
      {state.paid, state.refunded}
    end
  end

  defmodule CaptureSeen do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: PropertyDamage.Test.ExpansionRun.Capture
    def assert_capture_seen(_state, _capture), do: :ok
  end

  defmodule CreditSeen do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: PropertyDamage.Test.ExpansionRun.Credited
    def assert_credit_seen(_state, _event), do: :ok
  end

  defmodule SecondCreditFails do
    @moduledoc false
    # Fails on the event of the second leaf of a Refund rewrite.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @check every: PropertyDamage.Test.ExpansionRun.Credited
    def assert_not_second_part(_state, %{part: part}) do
      if part == 1, do: PropertyDamage.fail!("the second credit"), else: :ok
    end
  end

  defmodule EveryTwo do
    @moduledoc false
    # Records each firing of its `every: {2, :command}` check under the variant's name.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{by: nil, sink: nil}

    @impl true
    def apply(state, %{by: by, sink: sink}) when not is_nil(by), do: %{state | by: by, sink: sink}
    def apply(state, _), do: state

    @check every: {2, :command}
    def assert_sampled(state, _item) do
      VariantSupport.record(state.sink, {:every2, state.by})
      :ok
    end
  end

  # ==========================================================================
  # Adapter
  # ==========================================================================

  defmodule RecordingAdapter do
    @moduledoc false
    # Config keys:
    #
    #   :name        target name
    #   :recorder    the shared recorder
    #   :bug         :credit - every Credited answers its amount plus one;
    #                :credit_after_payment - the same, once this execution
    #                has run a Pay or a Capture
    #   :fail_part   a Credit with this `part` answers {:error, :refused}
    use PropertyDamage.Adapter

    alias PropertyDamage.Export.HTTPSpec
    alias PropertyDamage.Test.ExpansionRun, as: X

    @impl true
    def setup(config) do
      VariantSupport.record(config[:recorder], {:setup, config[:name]})
      {:ok, Map.put(config, :payments, :atomics.new(1, []))}
    end

    @impl true
    def teardown(ctx) do
      VariantSupport.record(ctx[:recorder], {:teardown, ctx[:name]})
      :ok
    end

    @impl true
    def execute(command, ctx, _runtime) do
      VariantSupport.record(ctx[:recorder], {:execute, ctx[:name], command})

      if refused?(command, ctx), do: {:error, :refused}, else: {:ok, [answer(command, ctx)]}
    end

    defp refused?(%X.Credit{part: part}, %{fail_part: part}), do: true
    defp refused?(_command, _ctx), do: false

    def http_spec(command, _ctx) do
      name = command.__struct__ |> Module.split() |> List.last() |> String.downcase()
      %HTTPSpec{method: :post, path: "/#{name}", body: Map.take(command, [:amount, :part])}
    end

    defp answer(%X.Noise{} = c, ctx), do: event(X.Noised, c, ctx)
    defp answer(%X.Open{} = c, ctx), do: event(X.Opened, c, ctx)
    defp answer(%X.Void{} = c, ctx), do: event(X.Voided, c, ctx)
    defp answer(%X.Blocked{} = c, ctx), do: event(X.Stuck, c, ctx)
    defp answer(%X.Ghost{} = c, ctx), do: event(X.Haunted, c, ctx)
    defp answer(%X.Refund{} = c, ctx), do: event(X.Refunded, c, ctx)
    defp answer(%X.Authorize{} = c, ctx), do: event(X.Authorized, c, ctx)

    defp answer(%X.Pay{} = c, ctx) do
      :atomics.add(ctx.payments, 1, 1)
      event(X.Paid, c, ctx)
    end

    defp answer(%X.Capture{} = c, ctx) do
      :atomics.add(ctx.payments, 1, 1)
      event(X.Captured, c, ctx)
    end

    defp answer(%X.Credit{} = c, ctx) do
      skew =
        case ctx[:bug] do
          :credit -> 1
          :credit_after_payment -> if :atomics.get(ctx.payments, 1) > 0, do: 1, else: 0
          _ -> 0
        end

      %{event(X.Credited, c, ctx) | amount: c.amount + skew}
    end

    defp event(module, command, ctx) do
      struct(module,
        tag: command.tag,
        amount: Map.get(command, :amount),
        part: Map.get(command, :part),
        by: ctx[:name],
        sink: ctx[:recorder]
      )
    end
  end

  # ==========================================================================
  # Expansion functions
  # ==========================================================================

  @doc false
  # Refund: the identity, then a two-leaf rewrite that credits the amount in
  # two parts.
  def refund_two(%Refund{} = refund, _state), do: [[refund], credits(refund)]

  @doc false
  # Refund: only the two-leaf rewrite, so every Refund root expands.
  def refund_rewrite(%Refund{} = refund, _state), do: [credits(refund)]

  @doc false
  # Refund: the identity, the rewrite, and an entry whose first leaf always
  # fails its precondition.
  def refund_three(%Refund{tag: tag} = refund, _state) do
    [
      [refund],
      credits(refund),
      [{Blocked, overrides: %{tag: tag}}, {Ghost, overrides: %{tag: tag}}]
    ]
  end

  @doc false
  # Pay: the identity, then Authorize and Capture.
  def pay_two(%Pay{} = pay, _state), do: [[pay], authorize_capture(pay)]

  @doc false
  # Pay: only Authorize and Capture.
  def pay_rewrite(%Pay{} = pay, _state), do: [authorize_capture(pay)]

  @doc false
  # A root with no expansion in any state: it runs as itself, forced.
  def none(_root, _state), do: []

  defp credits(%Refund{tag: tag, amount: n}) do
    a = div(n, 2)

    [
      {Credit, overrides: %{tag: tag, amount: a, part: 0}},
      {Credit, overrides: %{tag: tag, amount: n - a, part: 1}}
    ]
  end

  defp authorize_capture(%Pay{tag: tag, amount: n}) do
    [{Authorize, overrides: %{tag: tag, amount: n}}, {Capture, overrides: %{tag: tag, amount: n}}]
  end

  # ==========================================================================
  # Models
  # ==========================================================================

  @doc false
  # Defines `module` as a model. Options (all optional):
  #
  #   :commands     commands/0 (default `[Noise, Refund]`)
  #   :expansions   expansions/0; `nil` defines no callback (default nil)
  #   :checks       check_projections/0 (default `[Totals]`)
  #   :setup        setup_each/0; `nil` defines no callback (default nil)
  #   :teardown     teardown_each/0; `nil` defines no callback (default nil)
  #   :terminate    `true` defines terminate_early?/3: it sends
  #                 `{:terminate_consulted, command}` to the calling process
  #                 and answers true for a Credit or a Credited event
  def define_model!(module, opts \\ []) do
    :persistent_term.put({__MODULE__, module}, %{
      commands: Keyword.get(opts, :commands, [Noise, Refund]),
      expansions: Keyword.get(opts, :expansions),
      checks: Keyword.get(opts, :checks, [Totals]),
      setup: Keyword.get(opts, :setup),
      teardown: Keyword.get(opts, :teardown)
    })

    support = __MODULE__
    expansions? = Keyword.get(opts, :expansions) != nil
    setup? = Keyword.get(opts, :setup) != nil
    teardown? = Keyword.get(opts, :teardown) != nil
    terminate? = Keyword.get(opts, :terminate, false)

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          @moduledoc false
          @behaviour PropertyDamage.Model

          def commands, do: unquote(support).spec(unquote(module), :commands)

          def command_sequence_projection, do: unquote(World)

          def check_projections, do: unquote(support).spec(unquote(module), :checks)

          def simulator, do: unquote(support)

          if unquote(expansions?) do
            def expansions, do: unquote(support).spec(unquote(module), :expansions)
          end

          if unquote(setup?) do
            def setup_each, do: unquote(support).spec(unquote(module), :setup)
          end

          if unquote(teardown?) do
            def teardown_each, do: unquote(support).spec(unquote(module), :teardown)
          end

          if unquote(terminate?) do
            def terminate_early?(_state, command, events) do
              send(self(), {:terminate_consulted, command})

              match?(%PropertyDamage.Test.ExpansionRun.Credit{}, command) or
                Enum.any?(events, &match?(%PropertyDamage.Test.ExpansionRun.Credited{}, &1))
            end
          end
        end
      end
    )

    module
  end

  @doc false
  # A model whose every root sequence is Pay, Refund, Void, for sampling:
  #
  #   Pay[0] = [Pay]                  Pay[1] = [Authorize, Capture]
  #   Refund[0] = [Refund]            Refund[1] = [Credit, Credit]
  #   Refund[2] = [Blocked, Ghost]    never realized: Blocked's `when:` never holds
  #   Void                            no entry in any state: always forced
  #
  # Authorize's event (Authorized) is handled by no check, Credit's (Credited)
  # is, and Ghost's (Haunted) is handled by none and never reached.
  def define_sampling_model!(module) do
    define_model!(module,
      commands: [
        {Pay, when: &(&1.roots == 0)},
        {Refund, when: &(&1.roots == 1)},
        {Void, when: &(&1.roots == 2)},
        {Capture, when: & &1.authorizing},
        {Blocked, when: fn _state -> false end}
      ],
      expansions: [{Pay, &pay_two/2}, {Refund, &refund_three/2}, {Void, &none/2}],
      checks: [Totals, CreditSeen]
    )
  end

  @doc false
  def spec(module, key), do: :persistent_term.get({__MODULE__, module})[key]

  @doc false
  # The simulator every fixture model shares: each command answers one event.
  def simulate(%Noise{tag: t}, _state), do: [%Noised{tag: t}]
  def simulate(%Open{tag: t}, _state), do: [%Opened{tag: t}]
  def simulate(%Void{tag: t}, _state), do: [%Voided{tag: t}]
  def simulate(%Blocked{tag: t}, _state), do: [%Stuck{tag: t}]
  def simulate(%Ghost{tag: t}, _state), do: [%Haunted{tag: t}]
  def simulate(%Pay{tag: t, amount: a}, _state), do: [%Paid{tag: t, amount: a}]
  def simulate(%Refund{tag: t, amount: a}, _state), do: [%Refunded{tag: t, amount: a}]
  def simulate(%Authorize{tag: t, amount: a}, _state), do: [%Authorized{tag: t, amount: a}]
  def simulate(%Capture{tag: t, amount: a}, _state), do: [%Captured{tag: t, amount: a}]

  def simulate(%Credit{tag: t, amount: a, part: p}, _state),
    do: [%Credited{tag: t, amount: a, part: p}]

  def simulate(_command, _state), do: []

  # ==========================================================================
  # Targets and the recorder
  # ==========================================================================

  @doc false
  # A target entry. `opts` holds extra target keys such as `expansion:`.
  def target(name, recorder, config \\ %{}, opts \\ []) do
    {RecordingAdapter,
     [name: name, config: Map.merge(%{name: name, recorder: recorder}, config)] ++ opts}
  end

  @doc false
  # The commands `name` executed, one list per execution of that target (each
  # `setup/1` starts one), in order.
  def segments(entries, name) do
    entries
    |> Enum.filter(fn entry -> tuple_size(entry) >= 2 and elem(entry, 1) == name end)
    |> Enum.reduce([], fn
      {:setup, _}, acc -> [[] | acc]
      {:execute, _, command}, [current | rest] -> [[command | current] | rest]
      _other, acc -> acc
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  @doc false
  # Groups consecutive commands by their root's tag: `[{tag, [command]}]`.
  def by_root(commands) do
    commands
    |> Enum.chunk_by(& &1.tag)
    |> Enum.map(fn [first | _] = group -> {first.tag, group} end)
  end

  @doc false
  # The command modules of a group.
  def modules(group), do: Enum.map(group, & &1.__struct__)

  @doc false
  # The last segment of a module name.
  def short(module), do: module |> Module.split() |> List.last()

  @doc false
  # The root commands `model` generates for `seed` (run 0).
  def roots(model, seed, max_commands) do
    model
    |> Generator.generate_sequence(max_commands: max_commands)
    |> Generator.generate_value(Generator.run_seed(seed, 0))
    |> Sequence.to_list()
  end

  @doc false
  # The first seed in `range` whose roots satisfy `predicate`, or nil.
  def find_seed(model, max_commands, range, predicate) do
    Enum.find(range, fn seed -> predicate.(roots(model, seed, max_commands)) end)
  end

  @doc false
  # Runs `fun` and returns `{:raised, message}`, `{:error, text}` for an error
  # result (the report's terminal text and its reason), or `{:passed, result}`.
  def outcome(fun) do
    case fun.() do
      {:error, %FailureReport{} = report} ->
        {:error,
         Formatter.format(report, :terminal, color: false) <>
           "\n" <> inspect(report.failure_reason)}

      {:error, other} ->
        {:error, inspect(other)}

      other ->
        {:passed, other}
    end
  rescue
    error -> {:raised, Exception.message(error)}
  end

  @doc false
  # Calls a function the code under test may not define yet.
  def call(module, function, args), do: apply(module, function, args)
end
