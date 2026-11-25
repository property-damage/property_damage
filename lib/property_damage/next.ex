defmodule PropertyDamage.Next do
  @moduledoc """
  The new engine's entry points.

  The test case of the new engine is a journal: one entry per draw, keyed
  by where generation made it. `plan/3` builds a plan from a seed, or
  rebuilds it from a journal, without executing anything. `run/1` builds
  and executes plans until one fails or the plan budget is spent, and
  `replay/2` rebuilds the plan of a saved journal, or of its saved binary,
  and executes it once.

  ## Two paths of one command

  A model may state, in `expansions/0`, other ways to run some of its
  commands: for each listed command module, a function of the command as
  drawn and the predicted state that returns the command's paths, the
  command alone first (see `PropertyDamage.Next.Model`). Every step of a
  listed module then draws the pick of its path into the journal, under
  `{step, :path}`, and each value the picked path draws under
  `{step, :path, name}`; the step holds the path as `{index, commands}`.

  Such a model runs each plan twice, against two setups of the one adapter:
  the reference runs every step as drawn, and the variant runs, for each
  step, the commands of its path. After each step every
  `@compare every: 1` observation of the model's projections is evaluated
  on both executions, and the first that disagrees fails the plan with
  `{:diverged, name, step_key, reference_value, variant_value}`. Lowering a
  pick moves a step toward its plain path, so a divergence shrinks to the
  steps whose paths it needs. A model without `expansions/0` runs each plan
  once, and its journals are those it had before paths existed.

      alias PropertyDamage.Next.Gen

      def expansions, do: [{Refund, &refund_paths/2}]

      # A refund of 2 or more as itself, or as two refunds whose first part
      # PD draws.
      def refund_paths(%Refund{amount: amount} = refund, _state) when amount >= 2 do
        [
          [refund],
          {%{first: Gen.integer(1..(amount - 1))},
           fn %{first: first} -> [%{refund | amount: first}, %{refund | amount: amount - first}] end}
        ]
      end

      def refund_paths(refund, _state), do: [[refund]]
  """

  require Logger

  alias PropertyDamage.Next.Engine.Native

  alias PropertyDamage.Next.{
    AssignCounts,
    Checks,
    DependentStreamDataError,
    Execution,
    Failure,
    Generation,
    Journal,
    Model,
    ModelChangedError,
    Plan,
    Report,
    Shrinker
  }

  @plan_opts [
    max_steps: 20,
    engine: Native,
    dependent_stream_data: :warn,
    lanes: 1,
    lane_steps: nil,
    yields: nil
  ]
  @run_opts [
    :model,
    :adapter,
    :seed,
    config: %{},
    ignored_assigns: [],
    never_drawn: :report,
    max_steps: 20,
    max_plans: 100,
    engine: Native,
    shrink: true,
    max_shrink_runs: 100,
    dependent_stream_data: :warn,
    lanes: 1,
    lane_steps: nil,
    yields: nil
  ]
  @replay_opts [
    :model,
    :adapter,
    config: %{},
    ignored_assigns: [],
    max_steps: 20,
    engine: Native,
    dependent_stream_data: :warn,
    lanes: 1,
    lane_steps: nil,
    yields: nil
  ]

  @doc """
  Builds the plan of `model` from a seed, or rebuilds it from a journal.

  From a seed, every draw is fresh and the plan's journal records each one.
  From a journal, generation runs again against its entries: a stored value
  that still fits is kept, and a stored pick that is no longer offered
  withdraws its slot. A journal recorded on a different spec list raises
  `PropertyDamage.Next.ModelChangedError`.

  A journal records the number of slots its plan had, and a plan rebuilt
  from it has that many slots.

  A plan may have two lanes. After the `:max_steps` slots of the prefix,
  lane 1 and lane 2 hold `:lane_steps` slots each, and their steps
  interleave on a schedule that PD draws into the journal and simulates in
  one process (see `PropertyDamage.Next.Plan` for `schedule`, and
  `PropertyDamage.Next.Adapter` for the places a step lets the other lane
  in). Each lane is generated from the predicted state after the prefix,
  and folds only its own steps: a `when:` in a lane holds when that lane
  runs alone after the prefix, so a step can name a value of the prefix or
  of an earlier step of its own lane, never one of the other lane.

  Options:

    * `:max_steps` - the number of slots, or with two lanes the number of
      prefix slots (default 20). Given with a journal, it must equal the
      journal's number of slots, or `ArgumentError` is raised
    * `:lanes` - `1` (default): every step runs one after another; `2`:
      after the prefix, two lanes run on a simulated schedule
    * `:lane_steps` - the number of slots in each lane, a non-negative
      integer (default 3 with `lanes: 2`)
    * `:yields` - the most times one step in a lane may yield, a
      non-negative integer (default 1 with `lanes: 2`). PD draws one
      schedule value for each point a lane-1 step may have, so the bound
      lets the whole schedule be drawn before anything runs

  `:lane_steps` or `:yields` given without `lanes: 2` raises
  `ArgumentError`. A model that exports `expansions/0` may build a plan
  with two lanes, but `run/1` and `replay/2` refuse to execute one: paths
  run on one lane. A journal records its lanes: one lane when it holds no
  lanes, as every journal saved before lanes existed does. A plan rebuilt
  from it has the lanes it recorded, and each of `:lanes`, `:lane_steps`
  and `:yields` the caller gives must equal the journal's, or
  `ArgumentError` is raised.

  For a model that exports `expansions/0`, the statement is checked first
  (`ArgumentError` naming the model unless it lists `{module, fun/2}` pairs,
  each module a command module of the specs, once), and each step of a
  listed module gets its path; a paths function whose first path is not the
  command alone raises `ArgumentError` naming the command module.
    * `:engine` - the module that draws each value (default
      `PropertyDamage.Next.Engine.Native`)
    * `:dependent_stream_data` - `:warn` (default) or `:raise`: what to do
      when a `from/2` function or a dependent assign returns a StreamData
      generator the engine cannot fit. `:warn` draws it, logs one warning
      per site and lists the site in the plan's `kept`; `:raise` raises
      `PropertyDamage.Next.DependentStreamDataError` at its first draw. See
      `PropertyDamage.Next.Engine`.
  """
  @spec plan(module(), integer() | Journal.t(), keyword()) :: Plan.t()
  def plan(model, seed_or_journal, opts \\ []) when is_atom(model) do
    plan_opts =
      opts
      |> Keyword.validate!(@plan_opts)
      |> slots!(seed_or_journal, opts)
      |> lanes!(seed_or_journal, opts)

    mode!(plan_opts[:dependent_stream_data])
    specs = Model.specs!(model)
    Model.expansions!(model, specs)
    plan = build(model, specs, seed_or_journal, plan_opts)
    warn(plan.kept, [])
    plan
  end

  @doc """
  Builds plans of `model` and executes each against the adapter, until a
  plan fails or `:max_plans` plans have passed.

  Plan 1 is built from `:seed`; every later plan from a seed derived from
  `:seed` and the plan's number alone, so the same options build the same
  plans. Each plan gets its own execution: the adapter's `setup/2`, one
  `execute/3` per step, then `teardown/1` if the adapter defines it. After
  each step the model's check projections and its command-sequence
  projection fold the events the adapter returned, and their checks run; a
  projection named in both roles folds and checks once.

  A model that exports `expansions/0` gets two executions per plan, each
  with its own `setup/2`, its own minted values and its own `teardown/1`:
  the reference, set up first, and the variant. They run in lockstep: the
  reference runs a step's command, then the variant runs each command of
  the step's path, each its own `execute/3` with the step's assigns, folded
  and checked as a step is. Then the `@compare every: 1` observations are
  evaluated on each execution's state, in projection order then
  declaration order, each given the step's command as drawn, made concrete
  in that execution. A value agrees when it equals the reference's, or,
  for an observation with `using:`, when the relation answers `true`; the
  first that disagrees fails the plan at that step with
  `{:diverged, name, step_key, reference_value, variant_value}`. An
  observation that raises fails it with `{:raise, exception}`, and a
  `{:pending, _}` value is compared as any value, without waiting. A
  failure of either execution fails the plan at that step with its own
  reason, and a failing setup of either with step `nil`.

  With `lanes: 2`, the prefix steps run first, each to completion, and
  then the two lanes' steps run interleaved as the plan's schedule says. A
  lane step's events fold, and the checks run, when the step completes, so
  steps of the two lanes fold in the order they complete. The checks see
  the real events only; a model meant for lanes states bounds over the
  folded state rather than comparing a step with its lane's prediction.

  Returns `{:ok, report}` when every plan passed, or
  `{:error, %PropertyDamage.Next.Failure{}}` for the first plan that
  failed, shrunk unless `shrink: false`; its journal replays the final
  plan with `replay/2`. Both carry a `PropertyDamage.Next.Report`: for a
  failure, in its `report` field. The report holds the plan count, the
  withdrawn slots, the `kept` sites where PD's engine drew a dependent
  StreamData generator it cannot fit (see `PropertyDamage.Next.Engine`; a
  warning names each site once per run), the specs each layer changed, the
  specs the search never drew, and, per target, how many steps set each
  assign and how often the adapter acknowledged it. For a model with
  paths, `plans` counts plans, not executions, and the assign counts cover
  every `execute/3` call of both executions, so a step whose path has two
  commands counts once for the reference and twice for the variant.
  `PropertyDamage.Next.Report.format/1` renders it as text.

  A run whose plans all passed still fails in two cases, each a
  `%Failure{}` with `plan`, `journal` and `step` set to `nil`:

    * an assign some step set was acknowledged by no port, and the target
      does not list it in `:ignored_assigns`. The reason is
      `{:unacknowledged_assigns, rows}`, the rows being those of the
      report for each such key. This catches a fault the model draws and
      the adapter silently ignores. A plan that failed first wins; its
      report still carries the counts
    * `never_drawn: :fail` is given and the search never drew some spec.
      The reason is `{:never_drawn, rows}`

  The shrink edits the failing plan's journal and rebuilds each candidate
  plan from the edited journal by generation, so every candidate is a plan
  the model can build; each is executed. It removes steps in blocks,
  lowers values (an integer to its lower bound first, then by bisection; a
  member toward the first of its list; a StreamData value down its shrink
  tree), and lets generation withdraw a step whose pick is no longer
  offered. A candidate is kept when it fails the same way: the same failed
  check, the same adapter error (its tag, for a tagged tuple), the same
  exception module or a divergence of the same observation, at the same
  step or an earlier one. A path pick is a member entry whose first member
  is the plain path, so lowering it moves a step toward its command as
  drawn. The same run gives
  the same final plan and the same number of shrink runs.

  Options:

    * `:model` - the model module (required)
    * `:adapter` - the adapter module (required)
    * `:seed` - an integer (required)
    * `:config` - passed to the adapter's `setup/2` (default `%{}`)
    * `:ignored_assigns` - the assign keys the target's adapter never acts
      on (default `[]`). `:adapter`, `:config` and `:ignored_assigns`
      describe the run's one target. A key that no spec of the model sets
      raises `ArgumentError` before the first plan; an adapter that
      acknowledges an ignored key raises
      `PropertyDamage.Next.AcknowledgedIgnoredAssignError` (see
      `PropertyDamage.Next.Runtime.ack/2`)
    * `:never_drawn` - `:report` (default) lists the specs the search never
      drew in the report; `:fail` also fails a run that passed, as above
    * `:max_steps` - the number of slots per plan, or with two lanes the
      number of prefix slots (default 20)
    * `:lanes`, `:lane_steps`, `:yields` - as for `plan/3`: `lanes: 2`
      adds two lanes of `:lane_steps` slots (default 3) after the prefix,
      whose steps may each yield at most `:yields` times (default 1)
    * `:max_plans` - the most plans to build (default 100)
    * `:engine` - the module that draws each value (default
      `PropertyDamage.Next.Engine.Native`)
    * `:shrink` - whether to shrink the failing plan (default `true`)
    * `:max_shrink_runs` - the most plans executed while shrinking, the
      final execution of the shrunk plan included (default 100). When the
      budget ends the search, the failure's `shrink_ended` is `:cap` and
      `PropertyDamage.Next.Failure.format/1` says the plan may shrink
      further
    * `:dependent_stream_data` - `:warn` (default) or `:raise`, as for
      `plan/3`

  An adapter that acknowledges an assign its step did not set raises
  `PropertyDamage.Next.AcknowledgedUnsetAssignError` out of this function;
  like the ignored case, it is misuse of PD and is neither a failure nor
  shrunk.

  Raises `ArgumentError` when the model's check projections or its
  command-sequence projection declare a check form this engine does not run
  yet; it runs `@check every: N` and `@check every: CommandModule`, and
  `@compare every: 1` on a model that exports `expansions/0`. Every other
  `@compare` form raises, and so does `@compare every: 1` on a model
  without `expansions/0`. Two lanes with `expansions/0` raise
  `ArgumentError`: paths run on one lane.
  """
  @spec run(keyword()) :: {:ok, Report.t()} | {:error, Failure.t()}
  def run(opts) do
    opts = Keyword.validate!(opts, @run_opts)
    model = module!(opts, :model)
    adapter = module!(opts, :adapter)
    seed = seed!(opts[:seed])
    max_steps!(opts[:max_steps])
    plan_opts = opts |> Keyword.take(Keyword.keys(@plan_opts)) |> lanes!(seed, opts)
    max_plans = max_plans!(opts[:max_plans])
    shrink = shrink!(opts[:shrink])
    max_shrink_runs = max_shrink_runs!(opts[:max_shrink_runs])
    mode!(opts[:dependent_stream_data])
    never_drawn!(opts[:never_drawn])
    specs = Model.specs!(model)
    paths = paths!(model, specs, plan_opts)
    ignored = ignored!(opts[:ignored_assigns], specs)
    projections = Checks.load!(model)
    table = AssignCounts.new()

    try do
      searched =
        search(model, specs, seed, max_plans, plan_opts, table, fn plan, counts ->
          Execution.run(plan, adapter, opts[:config], projections,
            ignored: ignored,
            counts: counts,
            paths: paths
          )
        end)

      counts = AssignCounts.rows(table)

      ctx = %{
        model: model,
        specs: specs,
        plan_opts: plan_opts,
        shrink: shrink,
        max_shrink_runs: max_shrink_runs,
        never_drawn: opts[:never_drawn],
        ignored: ignored,
        adapter: adapter,
        counts: counts,
        execute:
          &Execution.run(&1, adapter, opts[:config], projections,
            ignored: ignored,
            paths: paths
          )
      }

      finish(searched, ctx)
    after
      AssignCounts.delete(table)
    end
  end

  defp search(model, specs, seed, max_plans, plan_opts, table, execute) do
    seen = %{plans: 0, warned: [], drawn: MapSet.new(), eligible: MapSet.new(), withdrawn: []}

    Enum.reduce_while(1..max_plans, seen, fn number, seen ->
      {plan, drawn} = trace(model, specs, plan_seed(seed, number), plan_opts)
      seen = observe(seen, plan, number)

      case execute.(plan, table) do
        :ok ->
          {:cont, seen}

        {:error, step, reason} ->
          {:halt, {%{plan: plan, drawn: drawn, step: step, reason: reason}, seen}}
      end
    end)
  end

  # What the search has seen after plan `number`: the plan count, the kept
  # sites warned about, the specs drawn or offered at some slot, and the
  # slots withdrawn.
  defp observe(seen, plan, number) do
    %{
      seen
      | plans: number,
        warned: warn(plan.kept, seen.warned),
        drawn: Enum.reduce(plan.steps, seen.drawn, &MapSet.put(&2, &1.spec_id)),
        eligible: Enum.reduce(plan.eligible, seen.eligible, &MapSet.put(&2, &1)),
        withdrawn: seen.withdrawn ++ plan.withdrawn
    }
  end

  defp finish({found, seen}, ctx) when is_map(found) do
    base = report(seen, ctx)
    build = &trace(ctx.model, ctx.specs, &1, ctx.plan_opts)

    {final, runs, ended, dropped, warned} =
      if ctx.shrink do
        shrink(found, build, ctx.execute, ctx.max_shrink_runs, seen.warned)
      else
        {found, 0, nil, 0, seen.warned}
      end

    failure = %{
      failure(final, seen.plans, found, runs, dropped)
      | kept: warned,
        shrink_ended: ended
    }

    report = %{base | kept: warned, withdrawn: failure.withdrawn}
    {:error, %{failure | report: report}}
  end

  defp finish(seen, ctx) do
    report = report(seen, ctx)
    rows = Map.fetch!(report.assigns, ctx.adapter)

    case {unacknowledged(rows, ctx.ignored), report.never_drawn, ctx.never_drawn} do
      {[_ | _] = unacknowledged, _never_drawn, _mode} ->
        {:error, no_plan(report, {:unacknowledged_assigns, unacknowledged})}

      {[], [_ | _] = never_drawn, :fail} ->
        {:error, no_plan(report, {:never_drawn, never_drawn})}

      _passed ->
        {:ok, report}
    end
  end

  # The report of the search, before a shrink changes `kept` and `withdrawn`.
  defp report(seen, ctx) do
    never_drawn =
      for spec <- ctx.specs, spec.id not in seen.drawn do
        reason = if spec.id in seen.eligible, do: :never_chosen, else: :never_eligible
        %{spec: spec.id, command: spec.command, reason: reason}
      end

    %Report{
      plans: seen.plans,
      withdrawn: seen.withdrawn,
      kept: seen.warned,
      layers: Report.layers(ctx.specs),
      never_drawn: never_drawn,
      assigns: Map.put_new(ctx.counts, ctx.adapter, [])
    }
  end

  # The rows of each key that some step set and no port acknowledged, on
  # any command, and that the target does not ignore.
  defp unacknowledged(rows, ignored) do
    silent =
      rows
      |> Enum.group_by(& &1.key)
      |> Enum.filter(fn {key, key_rows} ->
        key not in ignored and Enum.sum(Enum.map(key_rows, & &1.set)) > 0 and
          Enum.sum(Enum.map(key_rows, & &1.acknowledged)) == 0
      end)
      |> Enum.map(&elem(&1, 0))

    Enum.filter(rows, &(&1.key in silent))
  end

  # A failure of a run whose plans all passed: no plan is to blame.
  defp no_plan(report, reason),
    do: %Failure{reason: reason, report: report, kept: report.kept}

  # Shrinks `found`, warning about each kept site of a candidate plan that
  # no earlier plan of the run named, and counting the candidates whose
  # rebuild raised: the shrinker skips those without a run. It calls `build`
  # once per candidate, so the sites warned about so far and the raises
  # counted so far live in the process dictionary for the length of the
  # shrink.
  defp shrink(found, build, execute, max_shrink_runs, warned) do
    slot = {__MODULE__, :warned, make_ref()}
    Process.put(slot, {warned, 0})

    build = fn journal ->
      {plan, drawn} = build_counting(build, journal, slot)
      {warned, dropped} = Process.get(slot)
      Process.put(slot, {warn(plan.kept, warned), dropped})
      {plan, drawn}
    end

    try do
      {final, runs, ended} = Shrinker.search(found, build, execute, max_shrink_runs)
      {warned, dropped} = Process.get(slot)
      {final, runs, ended, dropped, warned}
    after
      Process.delete(slot)
    end
  end

  defp build_counting(build, journal, slot) do
    build.(journal)
  rescue
    exception ->
      {warned, dropped} = Process.get(slot)
      Process.put(slot, {warned, dropped + 1})
      reraise exception, __STACKTRACE__
  end

  # Logs one warning for each site of `kept` not in `warned`; returns the
  # sites warned about, in the order first seen.
  defp warn(kept, warned) do
    Enum.reduce(kept, warned, fn site, warned ->
      if site in warned do
        warned
      else
        Logger.warning(DependentStreamDataError.warning(site))
        warned ++ [site]
      end
    end)
  end

  @doc """
  Rebuilds the plan of `journal` and executes it once.

  `journal` is a `%PropertyDamage.Next.Journal{}` or a binary saved by
  `PropertyDamage.Next.Journal.to_binary/1`. A binary is loaded with
  `PropertyDamage.Next.Journal.from_binary/2` given the `:model` option, so
  a journal saved in another VM replays without loading the model's modules
  first.

  The plan is built as `plan/3` rebuilds it, so a journal saved from a
  failure gives back the failing plan. A journal recorded on a different
  spec list raises `PropertyDamage.Next.ModelChangedError` before the
  adapter is called. Returns `{:ok, %{plans: 1}}` or
  `{:error, %PropertyDamage.Next.Failure{}}` with `plan_number` 1. `kept`
  in either lists the plan's kept sites, as for `run/1`.

  Options are those of `run/1` without `:seed` and `:max_plans`. The
  journal records the number of slots, so `:max_steps` is not needed; if
  given, it must equal the journal's number of slots, or `ArgumentError`
  is raised. The journal also records its lanes, so `:lanes`,
  `:lane_steps` and `:yields` are not needed either; each one given must
  equal what the journal recorded, or `ArgumentError` is raised. The
  replay runs the journal's schedule, so a deterministic adapter replays a
  two-lane plan in the same interleaving. For a model that exports
  `expansions/0`, the journal's path entries rebuild each step's path, and
  the replay runs the reference and the variant as `run/1` does, so a saved
  divergence replays to the same divergence.
  """
  @spec replay(Journal.t() | binary(), keyword()) ::
          {:ok, %{plans: 1, kept: [map()]}} | {:error, Failure.t()}
  def replay(binary, opts) when is_binary(binary) do
    model = opts |> Keyword.validate!(@replay_opts) |> module!(:model)
    binary |> Journal.from_binary(model: model) |> replay(opts)
  end

  def replay(%Journal{} = journal, opts) do
    validated = Keyword.validate!(opts, @replay_opts)
    model = module!(validated, :model)
    adapter = module!(validated, :adapter)

    plan_opts =
      validated
      |> Keyword.take(Keyword.keys(@plan_opts))
      |> slots!(journal, opts)
      |> lanes!(journal, opts)

    mode!(plan_opts[:dependent_stream_data])
    specs = Model.specs!(model)
    paths = paths!(model, specs, plan_opts)
    ignored = ignored!(validated[:ignored_assigns], specs)
    plan = build(model, specs, journal, plan_opts)
    kept = warn(plan.kept, [])
    projections = Checks.load!(model)
    execution_opts = [ignored: ignored, paths: paths]

    case Execution.run(plan, adapter, validated[:config], projections, execution_opts) do
      :ok ->
        {:ok, %{plans: 1, kept: kept}}

      {:error, step, reason} ->
        found = %{plan: plan, step: step, reason: reason}
        {:error, %{failure(found, 1, found, 0, 0) | kept: kept}}
    end
  end

  # Whether `model` states paths, its expansions/0 checked. Paths run on one
  # lane: how a variant path would interleave with another lane is not
  # defined, so executing two lanes with paths raises. Building such a plan
  # is allowed, so the prefix of a two-lane plan stays comparable with the
  # one-lane plan of the same seed for every model.
  defp paths!(model, specs, plan_opts) do
    paths? = Model.expansions!(model, specs) != nil

    if paths? and plan_opts[:lanes] == 2 do
      raise ArgumentError,
            "#{inspect(model)} exports expansions/0, and paths run on one lane: " <>
              "the :lanes option or the journal gives 2 lanes"
    end

    paths?
  end

  # The `:ignored_assigns` option: a list of keys, each set by some spec.
  defp ignored!(keys, specs) do
    unless is_list(keys) and Enum.all?(keys, &is_atom/1) do
      raise ArgumentError,
            "the :ignored_assigns option is a list of assign keys, got: #{inspect(keys)}"
    end

    set = specs |> Enum.flat_map(&Map.keys(&1.assigns)) |> MapSet.new()

    case Enum.reject(keys, &(&1 in set)) do
      [] ->
        keys

      unknown ->
        raise ArgumentError,
              "the :ignored_assigns option names #{inspect(unknown)}, " <>
                "but no spec of the model sets #{if match?([_], unknown), do: "that key", else: "those keys"}"
    end
  end

  # The seed of plan `number` of a run started from `seed`: the run's seed
  # for plan 1, and for every later plan a value that depends on the two
  # numbers alone.
  defp plan_seed(seed, 1), do: seed
  defp plan_seed(seed, number), do: :erlang.phash2({:plan, seed, number}, 4_294_967_296)

  defp build(model, specs, seed_or_journal, opts),
    do: model |> trace(specs, seed_or_journal, opts) |> elem(0)

  defp trace(model, specs, seed_or_journal, opts) do
    journal = journal!(seed_or_journal, Journal.fingerprint(specs), model)
    Generation.trace(model, specs, journal, opts)
  end

  # The failure of `final`, a plan and the step and reason of its
  # execution, found as plan `number` of the run, whose first failing plan
  # was `found`. `runs` and `dropped` are the shrink's executions and the
  # candidates it dropped.
  defp failure(final, number, found, runs, dropped) do
    %Failure{
      plan_number: number,
      seed: found.plan.journal.seed,
      plan: final.plan,
      journal: final.plan.journal,
      withdrawn: final.plan.withdrawn,
      step: final.step,
      reason: final.reason,
      shrink_runs: runs,
      shrink_dropped: dropped,
      original: %{
        plan: found.plan,
        journal: found.plan.journal,
        step: found.step,
        reason: found.reason,
        withdrawn: found.plan.withdrawn
      }
    }
  end

  defp journal!(seed, fingerprint, _model) when is_integer(seed),
    do: %Journal{seed: seed, entries: %{}, fingerprint: fingerprint}

  defp journal!(%Journal{fingerprint: fingerprint} = journal, fingerprint, _model), do: journal

  defp journal!(%Journal{fingerprint: recorded}, fingerprint, model),
    do: raise(ModelChangedError, model: model, expected: recorded, actual: fingerprint)

  defp journal!(other, _fingerprint, _model) do
    raise ArgumentError,
          "a plan is built from an integer seed or a journal, got: #{inspect(other)}"
  end

  defp module!(opts, key) do
    case opts[key] do
      module when is_atom(module) and module not in [nil, true, false] ->
        module

      other ->
        raise ArgumentError, "the #{inspect(key)} option is a module, got: #{inspect(other)}"
    end
  end

  defp seed!(seed) when is_integer(seed), do: seed

  defp seed!(other),
    do: raise(ArgumentError, "the :seed option is an integer, got: #{inspect(other)}")

  # The plan options with the number of slots settled: a journal's own when
  # it records one, else the :max_steps option. A :max_steps option the
  # caller gave must then match the journal's.
  defp slots!(plan_opts, %Journal{max_steps: recorded}, given) when is_integer(recorded) do
    case Keyword.fetch(given, :max_steps) do
      {:ok, ^recorded} ->
        :ok

      {:ok, other} ->
        raise ArgumentError,
              "the journal was recorded with max_steps #{recorded}, " <>
                "but the :max_steps option is #{inspect(other)}"

      :error ->
        :ok
    end

    Keyword.put(plan_opts, :max_steps, recorded)
  end

  defp slots!(plan_opts, _seed_or_journal, _given) do
    max_steps!(plan_opts[:max_steps])
    plan_opts
  end

  # The plan options with the lanes settled: `:lanes` is 1 or 2, and with
  # two lanes `:lane_steps` and `:yields` are integers, the defaults filled
  # in. A journal fixes all three, so a lane option the caller gave must
  # match what the journal recorded; one lane is what a journal without
  # lanes recorded.
  defp lanes!(plan_opts, seed_or_journal, given) do
    lanes = lane_count!(plan_opts[:lanes])
    lane_steps = count!(plan_opts[:lane_steps], "lane_steps")
    yields = count!(plan_opts[:yields], "yields")

    settled =
      case seed_or_journal do
        %Journal{lanes: recorded} ->
          recorded!(recorded, lanes, lane_steps, yields, given)

        _seed ->
          {lanes, lane_steps, yields}
      end

    case settled do
      {1, steps, _count} when steps != nil ->
        raise ArgumentError, "the :lane_steps option needs lanes: 2"

      {1, nil, count} when count != nil ->
        raise ArgumentError, "the :yields option needs lanes: 2"

      {1, nil, nil} ->
        Keyword.merge(plan_opts, lanes: 1, lane_steps: nil, yields: nil)

      {2, steps, count} ->
        Keyword.merge(plan_opts, lanes: 2, lane_steps: steps || 3, yields: count || 1)
    end
  end

  defp recorded!(recorded, lanes, lane_steps, yields, given) do
    {count, steps, max_yields} =
      case recorded do
        nil -> {1, nil, nil}
        %{count: count, steps: steps, yields: max_yields} -> {count, steps, max_yields}
      end

    if Keyword.has_key?(given, :lanes), do: same!(:lanes, count, lanes)

    if count == 1 do
      {1, lane_steps, yields}
    else
      if lane_steps != nil, do: same!(:lane_steps, steps, lane_steps)
      if yields != nil, do: same!(:yields, max_yields, yields)
      {count, steps, max_yields}
    end
  end

  defp same!(_key, recorded, recorded), do: :ok

  defp same!(key, recorded, given) do
    raise ArgumentError,
          "the journal was recorded with #{key} #{recorded}, " <>
            "but the #{inspect(key)} option is #{inspect(given)}"
  end

  defp lane_count!(lanes) when lanes in [1, 2], do: lanes

  defp lane_count!(other),
    do: raise(ArgumentError, "the :lanes option is 1 or 2, got: #{inspect(other)}")

  defp count!(nil, _name), do: nil
  defp count!(n, _name) when is_integer(n) and n >= 0, do: n

  defp count!(other, name),
    do: raise(ArgumentError, "#{name} is a non-negative integer, got: #{inspect(other)}")

  defp max_steps!(n) when is_integer(n) and n >= 0, do: n

  defp max_steps!(other),
    do: raise(ArgumentError, "max_steps is a non-negative integer, got: #{inspect(other)}")

  defp max_plans!(n) when is_integer(n) and n > 0, do: n

  defp max_plans!(other),
    do: raise(ArgumentError, "max_plans is a positive integer, got: #{inspect(other)}")

  defp shrink!(flag) when is_boolean(flag), do: flag

  defp shrink!(other),
    do: raise(ArgumentError, "the :shrink option is a boolean, got: #{inspect(other)}")

  defp never_drawn!(mode) when mode in [:report, :fail], do: mode

  defp never_drawn!(other) do
    raise ArgumentError, "the :never_drawn option is :report or :fail, got: #{inspect(other)}"
  end

  defp mode!(mode) when mode in [:warn, :raise], do: mode

  defp mode!(other) do
    raise ArgumentError,
          "the :dependent_stream_data option is :warn or :raise, got: #{inspect(other)}"
  end

  defp max_shrink_runs!(n) when is_integer(n) and n > 0, do: n

  defp max_shrink_runs!(other),
    do: raise(ArgumentError, "max_shrink_runs is a positive integer, got: #{inspect(other)}")
end
