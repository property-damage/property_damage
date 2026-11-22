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
  """

  alias PropertyDamage.Corpus.Entry

  @type row :: %{
          seed: integer(),
          found?: boolean(),
          unexplained?: boolean(),
          plans_until_found: pos_integer() | nil,
          shrink_runs: non_neg_integer(),
          reached_minimum?: boolean(),
          clean?: boolean()
        }

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

    %{
      seed: seed,
      found?: hit?,
      unexplained?: on.found? and not on.bug_fired?,
      plans_until_found: if(hit?, do: on.plans_until_found),
      shrink_runs: if(hit?, do: on.shrink_runs, else: 0),
      reached_minimum?: hit? and matches_minimum?(entry, on.shrunk),
      clean?: not off.found? and off.fires == 0
    }
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
