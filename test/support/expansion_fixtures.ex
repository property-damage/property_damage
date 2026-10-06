defmodule PropertyDamage.Test.Expansion do
  @moduledoc false
  # Fixtures for expansions: a model's `expansions/0` rewrites a root command
  # into a sequence of leaf commands, drawn per variant.
  #
  # The domain is a ledger. A `Pay` root of amount `a` adds `a` to the total.
  # Every rewrite the tests list keeps that meaning: `Authorize` then
  # `Capture` of `a`, two `Credit`s summing to `a`, `Arm` then `Fire` of `a`.
  # `Ledger` compares the total at every root, so every variant agrees on it
  # whatever path it ran, while the recorder shows which commands ran.
  #
  # `Recorder` appends to a shared recorder
  # (`PropertyDamage.Test.VariantSupport.start_recorder/0`):
  #
  #   {:setup, name}                     setup/1 ran
  #   {:execute, name, command, events}  execute/3 ran with the resolved
  #                                      command and answered `events`
  #
  # It mints every `external()` id as "<target name>-<kind><counter>", so two
  # targets never answer the same id.
  #
  # Models are defined at runtime by `define_model!/2`; their callback lists
  # are kept in `:persistent_term`, so a spec may hold functions.

  import ExUnit.Assertions

  alias PropertyDamage.Generator
  alias PropertyDamage.Test.VariantSupport

  # ==========================================================================
  # Events
  # ==========================================================================

  defmodule Paid do
    @moduledoc false
    defstruct [:amount]
  end

  defmodule Authorized do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct [:amount, id: external()]
  end

  defmodule Captured do
    @moduledoc false
    defstruct [:authorization_id, :amount]
  end

  defmodule Credited do
    @moduledoc false
    defstruct [:amount]
  end

  defmodule Armed do
    @moduledoc false
    defstruct []
  end

  defmodule Opened do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct id: external()
  end

  defmodule Reserved do
    @moduledoc false
    import PropertyDamage, only: [external: 0]
    defstruct id: external()
  end

  defmodule Used do
    @moduledoc false
    defstruct [:account_id]
  end

  defmodule Looked do
    @moduledoc false
    defstruct [:total]
  end

  # ==========================================================================
  # Commands
  # ==========================================================================

  defmodule Pay do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(1..9)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Authorize do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(1..9)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Capture do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:authorization_id, :amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{authorization_id: StreamData.constant(nil), amount: StreamData.integer(1..9)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Credit do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(0..9)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Blocked do
    @moduledoc false
    # Listed in commands/0 behind a `when:` that never holds.
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(0..9)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Arm do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Fire do
    @moduledoc false
    # Listed in commands/0 behind `when: armed`.
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(0..9)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Skip do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(1..9)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Stuck do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:amount]

    @impl true
    def generator(overrides \\ %{}) do
      %{amount: StreamData.integer(1..9)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Open do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Reserve do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Confirm do
    @moduledoc false
    use PropertyDamage.Command
    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Use do
    @moduledoc false
    use PropertyDamage.Command
    defstruct [:account_id]

    @impl true
    def generator(overrides \\ %{}) do
      %{account_id: StreamData.constant(nil)}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Look do
    @moduledoc false
    use PropertyDamage.Command,
      execution: :probe,
      settle: %{timeout_ms: 200, interval_ms: 10, backoff: :linear}

    defstruct []

    @impl true
    def generator(overrides \\ %{}) do
      %{}
      |> Generator.merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  # ==========================================================================
  # Projections
  # ==========================================================================

  defmodule World do
    @moduledoc false
    # The sequence projection: the ledger total, whether an Arm leaf ran, and
    # the account ids opened so far (placeholders during generation).
    @behaviour PropertyDamage.Model.Projection

    @impl true
    def init, do: %{total: 0, armed: false, accounts: []}

    @impl true
    def apply(state, %Paid{amount: a}), do: %{state | total: state.total + a}
    def apply(state, %Captured{amount: a}), do: %{state | total: state.total + a}
    def apply(state, %Credited{amount: a}), do: %{state | total: state.total + a}
    def apply(state, %Armed{}), do: %{state | armed: true}
    def apply(state, %Opened{id: id}), do: %{state | accounts: state.accounts ++ [id]}
    def apply(state, _other), do: state
  end

  defmodule Ledger do
    @moduledoc false
    # Compares the total, the number of accounts opened and the number of
    # uses at every root. Never compares a raw id, which differs per target.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{total: 0, opened: 0, uses: 0}

    @impl true
    def apply(state, %Paid{amount: a}), do: %{state | total: state.total + a}
    def apply(state, %Captured{amount: a}), do: %{state | total: state.total + a}
    def apply(state, %Credited{amount: a}), do: %{state | total: state.total + a}
    def apply(state, %Opened{}), do: %{state | opened: state.opened + 1}
    def apply(state, %Used{}), do: %{state | uses: state.uses + 1}
    def apply(state, _other), do: state

    @compare every: 1
    def totals(state, _root), do: state
  end

  defmodule LedgerAtPay do
    @moduledoc false
    # Compares only after Pay roots: the schedule never reaches the end.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{total: 0}

    @impl true
    def apply(state, %Paid{amount: a}), do: %{state | total: state.total + a}
    def apply(state, %Captured{amount: a}), do: %{state | total: state.total + a}
    def apply(state, %Credited{amount: a}), do: %{state | total: state.total + a}
    def apply(state, _other), do: state

    @compare every: PropertyDamage.Test.Expansion.Pay
    def total(state, _root), do: state.total
  end

  defmodule LedgerAtPayEnd do
    @moduledoc false
    # Compares after Pay roots and at the final boundary.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{total: 0}

    @impl true
    def apply(state, %Paid{amount: a}), do: %{state | total: state.total + a}
    def apply(state, %Captured{amount: a}), do: %{state | total: state.total + a}
    def apply(state, %Credited{amount: a}), do: %{state | total: state.total + a}
    def apply(state, _other), do: state

    @compare every: [PropertyDamage.Test.Expansion.Pay, :end]
    def total(state, _root), do: state.total
  end

  # ==========================================================================
  # Adapter
  # ==========================================================================

  defmodule Recorder do
    @moduledoc false
    # Config keys:
    #
    #   :name      target name, the prefix of every id it mints
    #   :recorder  the shared recorder
    #   :fail      %{command_module => :error}
    use PropertyDamage.Adapter

    alias PropertyDamage.Test.Expansion

    alias PropertyDamage.Test.Expansion.{
      Arm,
      Armed,
      Authorize,
      Authorized,
      Blocked,
      Capture,
      Captured,
      Confirm,
      Credit,
      Credited,
      Fire,
      Look,
      Looked,
      Open,
      Opened,
      Paid,
      Pay,
      Reserve,
      Reserved,
      Skip,
      Stuck,
      Use,
      Used
    }

    @impl true
    def setup(config) do
      VariantSupport.record(config[:recorder], {:setup, config.name})
      {:ok, Map.merge(config, %{counter: :counters.new(1, []), total: :counters.new(1, [])})}
    end

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(command, ctx, _runtime) do
      case Map.get(Map.get(ctx, :fail, %{}), command.__struct__) do
        :error ->
          VariantSupport.record(ctx[:recorder], {:execute, ctx.name, command, :error})
          {:error, {:refused, command.__struct__}}

        nil ->
          events = answer(command, ctx)
          VariantSupport.record(ctx[:recorder], {:execute, ctx.name, command, events})
          {:ok, events}
      end
    end

    defp answer(%Pay{amount: a}, ctx), do: paid(ctx, a, %Paid{amount: a})
    defp answer(%Skip{amount: a}, ctx), do: paid(ctx, a, %Paid{amount: a})
    defp answer(%Stuck{amount: a}, ctx), do: paid(ctx, a, %Paid{amount: a})

    defp answer(%Authorize{amount: a}, ctx),
      do: [%Authorized{amount: a, id: Expansion.mint(ctx, "auth")}]

    defp answer(%Capture{authorization_id: id, amount: a}, ctx),
      do: paid(ctx, a, %Captured{authorization_id: id, amount: a})

    defp answer(%Credit{amount: a}, ctx), do: paid(ctx, a, %Credited{amount: a})
    defp answer(%Blocked{amount: a}, ctx), do: paid(ctx, a, %Credited{amount: a})
    defp answer(%Fire{amount: a}, ctx), do: paid(ctx, a, %Credited{amount: a})
    defp answer(%Arm{}, _ctx), do: [%Armed{}]
    defp answer(%Open{}, ctx), do: [%Opened{id: Expansion.mint(ctx, "open")}]
    defp answer(%Confirm{}, ctx), do: [%Opened{id: Expansion.mint(ctx, "open")}]
    defp answer(%Reserve{}, ctx), do: [%Reserved{id: Expansion.mint(ctx, "res")}]
    defp answer(%Use{account_id: id}, _ctx), do: [%Used{account_id: id}]
    defp answer(%Look{}, ctx), do: [%Looked{total: :counters.get(ctx.total, 1)}]

    defp paid(ctx, amount, event) do
      :counters.add(ctx.total, 1, amount)
      [event]
    end
  end

  # ==========================================================================
  # Models
  # ==========================================================================

  @doc false
  # The expansions of the payment example: the root itself (weight 3), or an
  # authorization of the amount followed by a capture of that authorization.
  def pay_expansions(%Pay{amount: a} = pay, _state) do
    [
      {[pay], weight: 3},
      [
        {Authorize, overrides: %{amount: a}},
        {Capture,
         overrides: fn _state, [%{events: [%Authorized{id: id}]}] ->
           %{authorization_id: id, amount: a}
         end}
      ]
    ]
  end

  @doc false
  # Three entries: the root itself, two credits summing to the amount, and an
  # authorization, its capture and a credit of zero.
  def three_way_expansions(%Pay{amount: a} = pay, _state) do
    half = div(a, 2)

    [
      [pay],
      [{Credit, overrides: %{amount: half}}, {Credit, overrides: %{amount: a - half}}],
      [
        {Authorize, overrides: %{amount: a}},
        {Capture,
         overrides: fn _state, [%{events: [%Authorized{id: id}]}] ->
           %{authorization_id: id, amount: a}
         end},
        {Credit, overrides: %{amount: 0}}
      ]
    ]
  end

  defmodule StaticModel do
    @moduledoc false
    # The payment example as an ordinary module, for runs in another OS process.
    @behaviour PropertyDamage.Model

    alias PropertyDamage.Test.Expansion
    alias PropertyDamage.Test.Expansion.{Ledger, Pay, World}

    def commands, do: [Pay]
    def expansions, do: [{Pay, &Expansion.pay_expansions/2}]
    def command_sequence_projection, do: World
    def check_projections, do: [Ledger]
    def simulator, do: Expansion
  end

  @doc false
  # Defines `module` as a model. Options (all optional):
  #
  #   :commands     commands/0 (default `[Pay]`)
  #   :expansions   expansions/0; `nil` defines no callback (default nil)
  #   :setup        setup_each/0; `nil` defines no callback (default nil)
  #   :checks       check_projections/0 (default `[Ledger]`)
  #   :terminate    a 3-arity function; defines terminate_early?/3 calling it
  def define_model!(module, opts \\ []) do
    :persistent_term.put({__MODULE__, module}, %{
      commands: Keyword.get(opts, :commands, [Pay]),
      expansions: Keyword.get(opts, :expansions),
      setup: Keyword.get(opts, :setup),
      checks: Keyword.get(opts, :checks, [Ledger]),
      terminate: Keyword.get(opts, :terminate)
    })

    support = __MODULE__
    expansions? = Keyword.get(opts, :expansions) != nil
    setup? = Keyword.get(opts, :setup) != nil
    terminate? = Keyword.get(opts, :terminate) != nil

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

          if unquote(terminate?) do
            def terminate_early?(state, command, events) do
              unquote(support).spec(unquote(module), :terminate).(state, command, events)
            end
          end
        end
      end
    )

    module
  end

  @doc false
  def spec(module, key), do: :persistent_term.get({__MODULE__, module})[key]

  # The simulator every fixture model shares.
  @doc false
  def simulate(%Pay{amount: a}, _state), do: [%Paid{amount: a}]
  def simulate(%Skip{amount: a}, _state), do: [%Paid{amount: a}]
  def simulate(%Stuck{amount: a}, _state), do: [%Paid{amount: a}]
  def simulate(%Authorize{amount: a}, _state), do: [%Authorized{amount: a}]

  def simulate(%Capture{authorization_id: id, amount: a}, _state),
    do: [%Captured{authorization_id: id, amount: a}]

  def simulate(%Credit{amount: a}, _state), do: [%Credited{amount: a}]
  def simulate(%Blocked{amount: a}, _state), do: [%Credited{amount: a}]
  def simulate(%Fire{amount: a}, _state), do: [%Credited{amount: a}]
  def simulate(%Arm{}, _state), do: [%Armed{}]
  def simulate(%Open{}, _state), do: [%Opened{}]
  def simulate(%Confirm{}, _state), do: [%Opened{}]
  def simulate(%Reserve{}, _state), do: [%Reserved{}]
  def simulate(%Use{account_id: id}, _state), do: [%Used{account_id: id}]
  def simulate(%Look{}, state), do: [%Looked{total: state.total}]
  def simulate(_command, _state), do: []

  # ==========================================================================
  # Helpers
  # ==========================================================================

  @doc false
  # A value unique to this target and run: the target name, a kind and a
  # counter.
  def mint(ctx, kind) do
    :counters.add(ctx.counter, 1, 1)
    "#{ctx.name}-#{kind}#{:counters.get(ctx.counter, 1)}"
  end

  @doc false
  # A Recorder target named `name`. `expansion` is left out of the entry when
  # nil, so the target takes the default.
  def target(name, recorder, expansion \\ nil, config \\ %{}) do
    opts = [name: name, config: Map.merge(%{name: name, recorder: recorder}, config)]
    opts = if expansion, do: opts ++ [expansion: expansion], else: opts
    {Recorder, opts}
  end

  @doc false
  def run(model, targets, extra \\ []) do
    [
      model: model,
      targets: targets,
      max_runs: 1,
      max_commands: 4,
      seed: 4_242,
      shrink: false,
      validate: false
    ]
    |> Keyword.merge(extra)
    |> PropertyDamage.run()
  end

  @doc false
  # The commands `name` executed, in order, across every run.
  def executed(entries, name),
    do: for({:execute, ^name, command, _events} <- entries, do: command)

  @doc false
  # `{command, events}` for every command `name` executed, in order.
  def answered(entries, name),
    do: for({:execute, ^name, command, events} <- entries, do: {command, events})

  @doc false
  # How many times any target's setup/1 ran.
  def setups(recorder),
    do: recorder |> VariantSupport.recorded() |> Enum.count(&match?({:setup, _}, &1))

  @doc false
  # Every executed command of every target, keyed by target name.
  def sequences(recorder, names) do
    entries = VariantSupport.recorded(recorder)
    Map.new(names, fn name -> {name, executed(entries, name)} end)
  end

  @doc false
  # The modules of `commands`.
  def modules(commands), do: Enum.map(commands, & &1.__struct__)

  @doc false
  # `command` with the fields that hold a value the target minted cleared:
  # those are the placeholders that resolve per variant.
  def without_ids(%Capture{} = command), do: %{command | authorization_id: nil}
  def without_ids(%Use{} = command), do: %{command | account_id: nil}
  def without_ids(command), do: command

  @doc false
  # The roots a run of `model` generates for `seed` and `run_number`, as the
  # generator draws them.
  def roots(model, seed, run_number, max_commands) do
    model
    |> Generator.generate_sequence(max_commands: max_commands)
    |> Generator.generate_value(Generator.run_seed(seed, run_number))
    |> PropertyDamage.Sequence.to_list()
  end

  @doc false
  # The per-variant expansion counters of run stats or a failure report:
  # `%{root_module => %{entry_key => count, forced: count}}` for `name`.
  def expansion_counts(stats_or_report, name) do
    stats_or_report |> Map.fetch!(:expansion_counts) |> Map.fetch!(name)
  end

  @doc false
  # The message of the exception `fun` raises; fails the test when it returns.
  def error_message(fun) do
    result = fun.()
    flunk("expected an error, got: #{inspect(result, limit: 8)}")
  rescue
    exception in [ExUnit.AssertionError] -> reraise exception, __STACKTRACE__
    exception -> Exception.message(exception)
  end

  @doc false
  # The sequences the static model's targets "a" and "b" execute for one seed:
  # computed here and, by the cross-process test, in a new OS process.
  def static_sequences(seed) do
    recorder = VariantSupport.start_recorder()

    {:ok, _stats} =
      run(StaticModel, [target("a", recorder), target("b", recorder)],
        seed: seed,
        max_runs: 3,
        max_commands: 5
      )

    sequences(recorder, ["a", "b"])
  end
end
