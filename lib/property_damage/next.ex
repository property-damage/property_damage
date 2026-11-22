defmodule PropertyDamage.Next do
  @moduledoc """
  The new engine's entry points.

  The test case of the new engine is a journal: one entry per draw, keyed
  by where generation made it. `plan/3` builds a plan from a seed, or
  rebuilds it from a journal, without executing anything. `run/1` builds
  and executes plans until one fails or the plan budget is spent, and
  `replay/2` rebuilds the plan of a saved journal and executes it once.
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
    Plan
  }

  @plan_opts [max_steps: 20, engine: Native]
  @run_opts [:model, :adapter, :seed, config: %{}, max_steps: 20, max_plans: 100, engine: Native]
  @replay_opts [:model, :adapter, config: %{}, max_steps: 20, engine: Native]

  @doc """
  Builds the plan of `model` from a seed, or rebuilds it from a journal.

  From a seed, every draw is fresh and the plan's journal records each one.
  From a journal, generation runs again against its entries: a stored value
  that still fits is kept, and a stored pick that is no longer offered
  withdraws its slot. A journal recorded on a different spec list raises
  `PropertyDamage.Next.ModelChangedError`.

  Options:

    * `:max_steps` - the number of slots (default 20)
    * `:engine` - the module that draws each value (default
      `PropertyDamage.Next.Engine.Native`)
  """
  @spec plan(module(), integer() | Journal.t(), keyword()) :: Plan.t()
  def plan(model, seed_or_journal, opts \\ []) when is_atom(model) do
    opts = Keyword.validate!(opts, @plan_opts)
    max_steps!(opts[:max_steps])
    build(model, Model.specs!(model), seed_or_journal, opts)
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
  failed; its journal replays that plan with `replay/2`.

  Options:

    * `:model` - the model module (required)
    * `:adapter` - the adapter module (required)
    * `:seed` - an integer (required)
    * `:config` - passed to the adapter's `setup/2` (default `%{}`)
    * `:max_steps` - the number of slots per plan (default 20)
    * `:max_plans` - the most plans to build (default 100)
    * `:engine` - the module that draws each value (default
      `PropertyDamage.Next.Engine.Native`)

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
    specs = Model.specs!(model)
    projections = Checks.load!(model)
    plan_opts = Keyword.take(opts, Keyword.keys(@plan_opts))

    Enum.reduce_while(1..max_plans, nil, fn number, nil ->
      plan = build(model, specs, plan_seed(seed, number), plan_opts)

      case Execution.run(plan, adapter, opts[:config], projections) do
        :ok -> {:cont, nil}
        {:error, step, reason} -> {:halt, failure(plan, number, step, reason)}
      end
    end)
    |> case do
      nil -> {:ok, %{plans: max_plans}}
      %Failure{} = failure -> {:error, failure}
    end
  end

  @doc """
  Rebuilds the plan of `journal` and executes it once.

  The plan is built as `plan/3` rebuilds it, so a journal saved from a
  failure gives back the failing plan. A journal recorded on a different
  spec list raises `PropertyDamage.Next.ModelChangedError` before the
  adapter is called. Returns `{:ok, %{plans: 1}}` or
  `{:error, %PropertyDamage.Next.Failure{}}` with `plan_number` 1.

  Options are those of `run/1` without `:seed` and `:max_plans`. The
  journal does not record the number of slots: pass the `:max_steps` the
  journal was recorded with.
  """
  @spec replay(Journal.t(), keyword()) :: {:ok, %{plans: 1}} | {:error, Failure.t()}
  def replay(%Journal{} = journal, opts) do
    opts = Keyword.validate!(opts, @replay_opts)
    model = module!(opts, :model)
    adapter = module!(opts, :adapter)
    max_steps!(opts[:max_steps])
    plan_opts = Keyword.take(opts, Keyword.keys(@plan_opts))
    plan = build(model, Model.specs!(model), journal, plan_opts)
    projections = Checks.load!(model)

    case Execution.run(plan, adapter, opts[:config], projections) do
      :ok -> {:ok, %{plans: 1}}
      {:error, step, reason} -> {:error, failure(plan, 1, step, reason)}
    end
  end

  # The seed of plan `number` of a run started from `seed`: the run's seed
  # for plan 1, and for every later plan a value that depends on the two
  # numbers alone.
  defp plan_seed(seed, 1), do: seed
  defp plan_seed(seed, number), do: :erlang.phash2({:plan, seed, number}, 4_294_967_296)

  defp build(model, specs, seed_or_journal, opts) do
    journal = journal!(seed_or_journal, Journal.fingerprint(specs), model)
    Generation.build(model, specs, journal, opts)
  end

  defp failure(%Plan{} = plan, number, step, reason) do
    %Failure{
      plan_number: number,
      seed: plan.journal.seed,
      plan: plan,
      journal: plan.journal,
      withdrawn: plan.withdrawn,
      step: step,
      reason: reason
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

  defp max_steps!(n) when is_integer(n) and n >= 0, do: n

  defp max_steps!(other),
    do: raise(ArgumentError, "max_steps is a non-negative integer, got: #{inspect(other)}")

  defp max_plans!(n) when is_integer(n) and n > 0, do: n

  defp max_plans!(other),
    do: raise(ArgumentError, "max_plans is a positive integer, got: #{inspect(other)}")
end
