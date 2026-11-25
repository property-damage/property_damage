defmodule PropertyDamage.Corpus.Measure do
  @moduledoc """
  Runs one entry over its seeds and records the raw numbers per seed.

  Each seed is run twice with the same plan cap (the entry's own `plan_cap`
  when it sets one, otherwise the one given): once with the entry's bug on
  and once with it off. A per-seed row holds:

    * `:seed`
    * `:found?` - the bug-on run found the bug and the seeded bug's path ran
      in the run that reproduced it.
    * `:unexplained?` - the bug-on run failed, but the seeded bug did not fire.
    * `:plans_until_found`, `:shrink_runs` - the engine's counts, `nil` and
      `0` when `:found?` is false.
    * `:reached_minimum?` - the shrunk plan equals the entry's `minimum` under
      the entry's `compare` rule. Always false for an entry without a minimum.
    * `:clean?` - the bug-off run passed and the bug never fired.
    * `:kept` - the sites both runs put on the engine's kept list, sorted
      and without repeats; `[]` for an engine that answers none.
    * `:line` - only when the bug-on run answered one: the guardrail line it
      found (see `PropertyDamage.Corpus.Entry`).
    * `:reached_minimum_at` - only for an entry with a minimum whose engine
      has a shrink budget (it implements `run/4` of
      `PropertyDamage.Corpus.Engine`): a map from each budget of
      `budgets/0` to whether a bug-on run with that shrink budget found the
      bug with it firing and shrank to the entry's minimum. Each budget is
      its own bug-on run on the same seed and plan cap.
  """

  alias PropertyDamage.Corpus.Entry

  # The shrink budgets of the smallest-plan columns. `:default` is the
  # budget the testing library applies when the run names none.
  @budgets [16, 32, :default]

  @type row :: %{
          required(:seed) => integer(),
          required(:found?) => boolean(),
          required(:unexplained?) => boolean(),
          required(:plans_until_found) => pos_integer() | nil,
          required(:shrink_runs) => non_neg_integer(),
          required(:reached_minimum?) => boolean(),
          required(:clean?) => boolean(),
          required(:kept) => [map()],
          optional(:line) => String.t(),
          optional(:reached_minimum_at) => %{budget() => boolean()}
        }

  @type budget :: pos_integer() | :default

  @doc "The shrink budgets measured for an entry with a minimum, in column order."
  @spec budgets() :: [budget()]
  def budgets, do: @budgets

  @doc """
  Measures `entry` on each of its seeds, generating at most `plan_cap` plans per
  run, or the entry's own `plan_cap` when it has one.
  """
  @spec entry(Entry.t(), pos_integer()) :: [row()]
  def entry(%Entry{} = entry, plan_cap) do
    cap = entry.plan_cap || plan_cap
    Enum.map(entry.seeds, &seed(entry, &1, cap))
  end

  @doc "Measures `entry` on one seed."
  @spec seed(Entry.t(), integer(), pos_integer()) :: row()
  def seed(%Entry{engine: engine} = entry, seed, plan_cap) do
    on = engine.run(entry, seed, plan_cap)
    off = engine.run(%{entry | bug: nil}, seed, plan_cap)
    hit? = on.found? and on.bug_fired?

    row = %{
      seed: seed,
      found?: hit?,
      unexplained?: on.found? and not on.bug_fired?,
      plans_until_found: if(hit?, do: on.plans_until_found),
      shrink_runs: if(hit?, do: on.shrink_runs, else: 0),
      reached_minimum?: hit? and matches_minimum?(entry, on.shrunk),
      clean?: not off.found? and off.fires == 0,
      kept: (Map.get(on, :kept, []) ++ Map.get(off, :kept, [])) |> Enum.uniq() |> Enum.sort()
    }

    row = if on[:line], do: Map.put(row, :line, on.line), else: row

    if budgeted?(entry),
      do: Map.put(row, :reached_minimum_at, reached_at(entry, seed, plan_cap)),
      else: row
  end

  defp budgeted?(%Entry{minimum: nil}), do: false

  defp budgeted?(%Entry{engine: engine}),
    do: Code.ensure_loaded?(engine) and function_exported?(engine, :run, 4)

  defp reached_at(%Entry{engine: engine} = entry, seed, plan_cap) do
    Map.new(@budgets, fn budget ->
      on = engine.run(entry, seed, plan_cap, budget)
      {budget, on.found? and on.bug_fired? and matches_minimum?(entry, on.shrunk)}
    end)
  end

  @doc "Whether `shrunk` equals the entry's smallest failing plan under its `compare` rule."
  @spec matches_minimum?(Entry.t(), [map()] | nil) :: boolean()
  def matches_minimum?(_entry, nil), do: false
  def matches_minimum?(%Entry{minimum: nil}, _shrunk), do: false

  def matches_minimum?(%Entry{minimum: minimum, compare: compare}, shrunk) do
    normalize(shrunk, compare) == normalize(minimum, compare)
  end

  defp normalize(plan, :exact), do: plan

  defp normalize(plan, :ignore_ids) do
    Enum.map(plan, fn command ->
      command |> Enum.reject(fn {_field, value} -> value == :id end) |> Map.new()
    end)
  end

  defp normalize(plan, {:ignore_fields, fields}) do
    Enum.map(plan, &Map.drop(&1, fields))
  end
end
