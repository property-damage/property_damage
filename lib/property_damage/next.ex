defmodule PropertyDamage.Next do
  @moduledoc """
  The new engine's entry points.

  The test case of the new engine is a journal: one entry per draw, keyed
  by where generation made it. `plan/3` builds a plan from a seed, or
  rebuilds it from a journal, without executing anything. `run/1` builds
  and executes plans until one fails or the plan budget is spent, and
  `replay/2` rebuilds the plan of a saved journal, or of its saved binary,
  and executes it once.
  """

  alias PropertyDamage.Next.Engine.Native

  alias PropertyDamage.Next.{
    Checks,
    Execution,
    Failure,
    Generation,
    Journal,
    Model,
    ModelChangedError,
    Plan,
    Shrinker
  }

  @plan_opts [max_steps: 20, engine: Native]
  @run_opts [
    :model,
    :adapter,
    :seed,
    config: %{},
    max_steps: 20,
    max_plans: 100,
    engine: Native,
    shrink: true,
    max_shrink_runs: 1000
  ]
  @replay_opts [:model, :adapter, config: %{}, max_steps: 20, engine: Native]

  @doc """
  Builds the plan of `model` from a seed, or rebuilds it from a journal.

  From a seed, every draw is fresh and the plan's journal records each one.
  From a journal, generation runs again against its entries: a stored value
  that still fits is kept, and a stored pick that is no longer offered
  withdraws its slot. A journal recorded on a different spec list raises
  `PropertyDamage.Next.ModelChangedError`.

  A journal records the number of slots its plan had, and a plan rebuilt
  from it has that many slots.

  Options:

    * `:max_steps` - the number of slots (default 20). Given with a
      journal, it must equal the journal's number of slots, or
      `ArgumentError` is raised
    * `:engine` - the module that draws each value (default
      `PropertyDamage.Next.Engine.Native`)
  """
  @spec plan(module(), integer() | Journal.t(), keyword()) :: Plan.t()
  def plan(model, seed_or_journal, opts \\ []) when is_atom(model) do
    plan_opts = opts |> Keyword.validate!(@plan_opts) |> slots!(seed_or_journal, opts)
    build(model, Model.specs!(model), seed_or_journal, plan_opts)
  end

  @doc """
  Builds plans of `model` and executes each against the adapter, until a
  plan fails or `:max_plans` plans have passed.

  Plan 1 is built from `:seed`; every later plan from a seed derived from
  `:seed` and the plan's number alone, so the same options build the same
  plans. Each plan gets its own execution: the adapter's `setup/2`, one
  `execute/3` per step, then `teardown/1` if the adapter defines it. After
  each step the model's check projections fold the events the adapter
  returned, and their checks run.

  Returns `{:ok, %{plans: n}}` when every plan passed, or
  `{:error, %PropertyDamage.Next.Failure{}}` for the first plan that
  failed, shrunk unless `shrink: false`; its journal replays the final
  plan with `replay/2`.

  The shrink edits the failing plan's journal and rebuilds each candidate
  plan from the edited journal by generation, so every candidate is a plan
  the model can build; each is executed. It removes steps in blocks,
  lowers values (an integer to its lower bound first, then by bisection; a
  member toward the first of its list; a StreamData value down its shrink
  tree), and lets generation withdraw a step whose pick is no longer
  offered. A candidate is kept when it fails the same way: the same failed
  check, the same adapter error (its tag, for a tagged tuple) or the same
  exception module, at the same step or an earlier one. The same run gives
  the same final plan and the same number of shrink runs.

  Options:

    * `:model` - the model module (required)
    * `:adapter` - the adapter module (required)
    * `:seed` - an integer (required)
    * `:config` - passed to the adapter's `setup/2` (default `%{}`)
    * `:max_steps` - the number of slots per plan (default 20)
    * `:max_plans` - the most plans to build (default 100)
    * `:engine` - the module that draws each value (default
      `PropertyDamage.Next.Engine.Native`)
    * `:shrink` - whether to shrink the failing plan (default `true`)
    * `:max_shrink_runs` - the most plans executed while shrinking, the
      final execution of the shrunk plan included (default 1000)

  Raises `ArgumentError` when the model's check projections declare a check
  form this engine does not run yet; it runs `@check every: N` and
  `@check every: CommandModule`.
  """
  @spec run(keyword()) :: {:ok, %{plans: pos_integer()}} | {:error, Failure.t()}
  def run(opts) do
    opts = Keyword.validate!(opts, @run_opts)
    model = module!(opts, :model)
    adapter = module!(opts, :adapter)
    seed = seed!(opts[:seed])
    max_steps!(opts[:max_steps])
    max_plans = max_plans!(opts[:max_plans])
    shrink = shrink!(opts[:shrink])
    max_shrink_runs = max_shrink_runs!(opts[:max_shrink_runs])
    specs = Model.specs!(model)
    projections = Checks.load!(model)
    plan_opts = Keyword.take(opts, Keyword.keys(@plan_opts))
    execute = &Execution.run(&1, adapter, opts[:config], projections)

    Enum.reduce_while(1..max_plans, nil, fn number, nil ->
      {plan, drawn} = trace(model, specs, plan_seed(seed, number), plan_opts)

      case execute.(plan) do
        :ok ->
          {:cont, nil}

        {:error, step, reason} ->
          {:halt, {number, %{plan: plan, drawn: drawn, step: step, reason: reason}}}
      end
    end)
    |> case do
      nil ->
        {:ok, %{plans: max_plans}}

      {number, found} when shrink ->
        build = &trace(model, specs, &1, plan_opts)
        {final, runs} = Shrinker.shrink(found, build, execute, max_shrink_runs)
        {:error, failure(final, number, found, runs)}

      {number, found} ->
        {:error, failure(found, number, found, 0)}
    end
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
  `{:error, %PropertyDamage.Next.Failure{}}` with `plan_number` 1.

  Options are those of `run/1` without `:seed` and `:max_plans`. The
  journal records the number of slots, so `:max_steps` is not needed; if
  given, it must equal the journal's number of slots, or `ArgumentError`
  is raised.
  """
  @spec replay(Journal.t() | binary(), keyword()) :: {:ok, %{plans: 1}} | {:error, Failure.t()}
  def replay(binary, opts) when is_binary(binary) do
    model = opts |> Keyword.validate!(@replay_opts) |> module!(:model)
    binary |> Journal.from_binary(model: model) |> replay(opts)
  end

  def replay(%Journal{} = journal, opts) do
    validated = Keyword.validate!(opts, @replay_opts)
    model = module!(validated, :model)
    adapter = module!(validated, :adapter)

    plan_opts =
      validated |> Keyword.take(Keyword.keys(@plan_opts)) |> slots!(journal, opts)

    plan = build(model, Model.specs!(model), journal, plan_opts)
    projections = Checks.load!(model)

    case Execution.run(plan, adapter, validated[:config], projections) do
      :ok ->
        {:ok, %{plans: 1}}

      {:error, step, reason} ->
        found = %{plan: plan, step: step, reason: reason}
        {:error, failure(found, 1, found, 0)}
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
  # was `found`.
  defp failure(final, number, found, runs) do
    %Failure{
      plan_number: number,
      seed: found.plan.journal.seed,
      plan: final.plan,
      journal: final.plan.journal,
      withdrawn: final.plan.withdrawn,
      step: final.step,
      reason: final.reason,
      shrink_runs: runs,
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

  defp max_steps!(n) when is_integer(n) and n >= 0, do: n

  defp max_steps!(other),
    do: raise(ArgumentError, "max_steps is a non-negative integer, got: #{inspect(other)}")

  defp max_plans!(n) when is_integer(n) and n > 0, do: n

  defp max_plans!(other),
    do: raise(ArgumentError, "max_plans is a positive integer, got: #{inspect(other)}")

  defp shrink!(flag) when is_boolean(flag), do: flag

  defp shrink!(other),
    do: raise(ArgumentError, "the :shrink option is a boolean, got: #{inspect(other)}")

  defp max_shrink_runs!(n) when is_integer(n) and n > 0, do: n

  defp max_shrink_runs!(other),
    do: raise(ArgumentError, "max_shrink_runs is a positive integer, got: #{inspect(other)}")
end
