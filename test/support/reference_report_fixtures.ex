defmodule PropertyDamage.Test.ReferenceReport do
  @moduledoc false
  # Fixtures for the reference side of a comparison failure report: the
  # reference target's trace, its projection state at the failing boundary
  # and why the shrinker stopped.
  #
  # The projections and adapters build on `PropertyDamage.Test.Compare`
  # (`Pay`, `Paid`, `Settled`, `PayAdapter`), `PropertyDamage.Test.SetupCommands`
  # (teardown commands) and `PropertyDamage.Test.ExpansionRun` (expansion
  # leaves). Every event these adapters answer names the target in `by`, so
  # a test can tell the reference's events from the variant's.

  alias PropertyDamage.Test.{Compare, ExpansionRun, SetupCommands}
  alias PropertyDamage.Test.Compare.{Paid, PayAdapter, Settled}

  # ==========================================================================
  # Projections
  # ==========================================================================

  defmodule Ledger do
    @moduledoc false
    # The settled total of every Pay, compared at every root; pending while a
    # Pay has not settled.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{unsettled: %{}, settled: 0, by: nil}

    @impl true
    def apply(s, %Paid{n: n, amount: a, by: by}),
      do: %{s | unsettled: Map.put(s.unsettled, n, a), by: by}

    def apply(s, %Settled{n: n, amount: a}),
      do: %{s | unsettled: Map.delete(s.unsettled, n), settled: s.settled + a}

    def apply(s, _other), do: s

    @compare every: 1
    def totals(s, _root) do
      if s.unsettled == %{}, do: %{settled: s.settled}, else: {:pending, :unsettled}
    end
  end

  defmodule Settles do
    @moduledoc false
    # The settlement of each Pay by its number. At a root's boundary only that
    # root's own settlement is compared, so a settlement still on its way for
    # an earlier root does not hold the comparison up.
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{settled: %{}, by: nil}

    @impl true
    def apply(s, %Paid{by: by}), do: %{s | by: by}
    def apply(s, %Settled{n: n, amount: a}), do: %{s | settled: Map.put(s.settled, n, a)}
    def apply(s, _other), do: s

    @compare every: 1
    def own_settlement(s, %{n: n}), do: Map.get(s.settled, n)
  end

  defmodule Tally do
    @moduledoc false
    # Counts the Act roots and the teardown commands' Noted events it folds;
    # a variant whose Acted events carry `mode: :shift` reports its count
    # shifted by 100.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.SetupCommands.{Acted, Noted}

    @impl true
    def init, do: %{acts: 0, noted: 0, by: nil, mode: :plain}

    @impl true
    def apply(s, %Acted{by: by, mode: mode}), do: %{s | acts: s.acts + 1, by: by, mode: mode}
    def apply(s, %Noted{}), do: %{s | noted: s.noted + 1}
    def apply(s, _other), do: s

    @compare every: 1
    def acts(s, _root), do: if(s.mode == :shift, do: s.acts + 100, else: s.acts)
  end

  defmodule LeafTally do
    @moduledoc false
    # Folds the Credit leaf commands themselves (not only their events), so
    # a state that leaves out an expansion's leaf folds shows it.
    use PropertyDamage.Model.Projection

    alias PropertyDamage.Test.ExpansionRun.{Credit, Credited}

    @impl true
    def init, do: %{credit_commands: 0, credited: 0, by: nil}

    @impl true
    def apply(s, %Credit{}), do: %{s | credit_commands: s.credit_commands + 1}

    def apply(s, %Credited{amount: a, by: by}),
      do: %{s | credited: s.credited + a, by: by}

    def apply(s, _other), do: s

    @compare every: 1
    def credited(s, _root), do: s.credited
  end

  # ==========================================================================
  # Adapters
  # ==========================================================================

  defmodule FirstExecutionAdapter do
    @moduledoc false
    # A PayAdapter whose `at:` modes (`config.first_at`) apply only in the
    # first execution that the shared `config.executions` counter sees; every
    # later execution settles each Pay at once. A divergence it causes is
    # found by the exploration run and never again: no shrink attempt and no
    # reproduction repeats it.
    use PropertyDamage.Adapter

    @impl true
    def setup(config) do
      at =
        if :atomics.add_get(config.executions, 1, 1) == 1,
          do: Map.get(config, :first_at, %{}),
          else: %{}

      PayAdapter.setup(Map.put(config, :at, at))
    end

    @impl true
    def teardown(ctx), do: PayAdapter.teardown(ctx)

    @impl true
    def execute(command, ctx, runtime), do: PayAdapter.execute(command, ctx, runtime)
  end

  defmodule TimeoutAdapter do
    @moduledoc false
    # Every Pay outlasts the adapter's per-command timeout.
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def timeout(_command), do: {30, :milliseconds}

    @impl true
    def execute(_command, _ctx, _runtime) do
      Process.sleep(1_000)
      {:ok, []}
    end
  end

  defmodule NoBackendAdapter do
    @moduledoc false
    # setup/1 fails, so no command runs.
    use PropertyDamage.Adapter

    @impl true
    def setup(_config), do: {:error, :no_backend}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(_command, _ctx, _runtime), do: {:ok, []}
  end

  # ==========================================================================
  # Models and targets
  # ==========================================================================

  @doc false
  # A Pay model compared on `projection`, defined on first use.
  def pay_model(module, projection) do
    if Code.ensure_loaded?(module),
      do: module,
      else: Compare.define_model!(module, [projection])
  end

  @doc false
  # A model of Act roots after the standard setup commands, with one
  # teardown command (Cleanup, whose event is Noted), compared on Tally.
  def teardown_model(module) do
    if Code.ensure_loaded?(module) do
      module
    else
      SetupCommands.define_model!(module,
        setup: SetupCommands.standard_setup(),
        teardown: [{SetupCommands.Cleanup, overrides: %{thing_id: "fixture"}}],
        checks: [Tally]
      )
    end
  end

  @doc false
  # A model of Noise and Refund roots in which every Refund expands into two
  # Credit leaves, compared on LeafTally.
  def leaf_model(module) do
    if Code.ensure_loaded?(module) do
      module
    else
      ExpansionRun.define_model!(module,
        commands: [ExpansionRun.Noise, ExpansionRun.Refund],
        expansions: [{ExpansionRun.Refund, &ExpansionRun.refund_rewrite/2}],
        checks: [LeafTally]
      )
    end
  end

  @doc false
  # A PayAdapter target named `name` that holds no pid, so a report of its
  # run can be saved and loaded in any VM.
  def pay_target(name, config \\ %{}) do
    {PayAdapter, name: name, config: Map.merge(%{name: name}, config)}
  end

  @doc false
  # A FirstExecutionAdapter target named `name`.
  def first_execution_target(name, first_at) do
    {FirstExecutionAdapter,
     name: name, config: %{name: name, first_at: first_at, executions: :atomics.new(1, [])}}
  end

  @doc false
  # The options every run here shares: one run, no validation, no replay
  # artifact, and a short convergence bound.
  def run(model, targets, extra \\ []) do
    [
      model: model,
      targets: targets,
      max_runs: 1,
      max_commands: 3,
      seed: 4_242,
      validate: false,
      shrink: false,
      replay_dir: false,
      compare: [converge_within: 50]
    ]
    |> Keyword.merge(extra)
    |> PropertyDamage.run()
  end

  @doc false
  # A field of a struct that may not declare it yet.
  def field(term, key), do: Map.fetch!(term, key)

  @doc false
  # Calls a function the code under test may not define yet.
  def call(module, function, args), do: apply(module, function, args)

  @doc false
  # The `by` of every event of `module` in `entries`, in order.
  def by_of(entries, module) do
    for %{event: %{__struct__: ^module, by: by}} <- entries, do: by
  end
end
