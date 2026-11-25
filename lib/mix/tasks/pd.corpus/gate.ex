defmodule PropertyDamage.Corpus.Gate do
  @moduledoc """
  Judges a corpus run against a saved table and fails only on a regression.

  `mix pd.corpus --gate PATH` uses it. The run and the table are matched by
  entry and engine, then seed by seed. A regression is any of:

    * a seed whose shrink runs rise, among the seeds found in both;
    * a seed that reached the entry's smallest plan in the table and does
      not now;
    * a seed that reached the smallest plan under a shrink budget of
      `PropertyDamage.Corpus.Measure.budgets/0` in the table and does not
      now;
    * a seed that found the bug in the table and does not now;
    * a seed that failed without the seeded bug firing, or failed or fired
      with the bug off (the run is not clean);
    * an entry, engine or seed in the table and not in the run, or the
      reverse, or a plan cap that differs.

  A change the other way (fewer shrink runs, a seed that now finds the bug
  or reaches the smallest plan) is an improvement, and a change in plans
  until found is neither; both are listed and do not fail, but the table is
  then out of date and should be saved again.

  A table whose rows lack the smallest-plan flags of a budget the run
  measures was saved before those flags were recorded, and is refused.
  """

  alias PropertyDamage.Corpus.{Baseline, Measure, Table}

  @type verdict :: %{regressions: [String.t()], changes: [String.t()]}

  @doc """
  Compares `results`, measured with `plan_cap`, against the saved `table`.

  Returns `{:ok, verdict}`, with one line per regression and one per other
  change, or `{:error, message}` when the table cannot be judged against.
  """
  @spec judge(Baseline.t(), [Table.result()], pos_integer()) ::
          {:ok, verdict()} | {:error, String.t()}
  def judge(table, results, plan_cap) do
    saved = Map.new(table.results, &{key(&1), &1})

    case unflagged(saved, results) do
      [] ->
        {regressions, changes} = compare(table, saved, results, plan_cap)
        {:ok, %{regressions: regressions, changes: changes}}

      labels ->
        {:error,
         "The saved table records no smallest-plan flags under the shrink budgets " <>
           "#{Enum.join(Measure.budgets(), ", ")} for #{Enum.join(labels, ", ")}; " <>
           "it was saved before they were measured. Save the table again with --save."}
    end
  end

  # The results whose rows record budgets while the saved rows of the same
  # seed do not record the same ones.
  defp unflagged(saved, results) do
    for %{rows: rows} = result <- results,
        %{rows: before} <- List.wrap(saved[key(result)]),
        Enum.any?(rows, fn row -> lacks_flags?(row, Enum.find(before, &(&1.seed == row.seed))) end),
        do: label(result)
  end

  defp lacks_flags?(%{reached_minimum_at: flags}, %{} = before),
    do: Map.keys(Map.get(before, :reached_minimum_at, %{})) != Map.keys(flags)

  defp lacks_flags?(_row, _before_or_nil), do: false

  defp compare(table, saved, results, plan_cap) do
    ran = MapSet.new(results, &key/1)

    not_run =
      for result <- table.results,
          not MapSet.member?(ran, key(result)),
          do: "#{label(result)}: in the table, not run"

    cap =
      if table.plan_cap == plan_cap,
        do: [],
        else: ["plan cap: #{table.plan_cap} in the table, #{plan_cap} in the run"]

    {regressions, changes} =
      results
      |> Enum.map(&compare_result(&1, saved[key(&1)]))
      |> Enum.unzip()

    {cap ++ List.flatten(regressions) ++ not_run, List.flatten(changes)}
  end

  defp compare_result(result, nil), do: {["#{label(result)}: run, not in the table"], []}

  defp compare_result(%{skipped: _}, %{skipped: _}), do: {[], []}

  defp compare_result(%{skipped: _} = result, _before),
    do: {["#{label(result)}: skipped in the run, measured in the table"], []}

  defp compare_result(result, %{skipped: _}),
    do: {["#{label(result)}: skipped in the table, measured in the run"], []}

  defp compare_result(%{rows: rows} = result, %{rows: before}) do
    name = label(result)
    before = Map.new(before, &{&1.seed, &1})
    now = Map.new(rows, &{&1.seed, &1})

    seeds =
      for {seeds, text} <- [
            {Map.keys(before) -- Map.keys(now), "in the table, not run"},
            {Map.keys(now) -- Map.keys(before), "run, not in the table"}
          ],
          seed <- Enum.sort(seeds),
          do: "#{name} seed #{seed}: #{text}"

    {regressions, changes} =
      for %{seed: seed} = row <- rows, Map.has_key?(before, seed) do
        {failing, other} = compare_seed(row, before[seed])
        prefix = &"#{name} seed #{seed}: #{&1}"
        {Enum.map(failing, prefix), Enum.map(other, prefix)}
      end
      |> Enum.unzip()

    {seeds ++ List.flatten(regressions), List.flatten(changes)}
  end

  # One seed: the lines that fail the gate, and the lines that do not.
  defp compare_seed(now, before) do
    found = found(before.found?, now.found?)
    found_in_both? = before.found? and now.found?

    runs =
      if found_in_both?,
        do: rise(before.shrink_runs, now.shrink_runs, "shrink runs"),
        else: {[], []}

    plans =
      if found_in_both? and before.plans_until_found != now.plans_until_found,
        do: {[], ["plans until found #{before.plans_until_found} -> #{now.plans_until_found}"]},
        else: {[], []}

    flags =
      [{"smallest plan", before.reached_minimum?, now.reached_minimum?}] ++
        for {budget, reached?} <- budget_flags(now),
            do:
              {"smallest plan at #{budget} shrink runs", before.reached_minimum_at[budget],
               reached?}

    parts = [found, runs, plans, clean(now) | Enum.map(flags, &flag/1)]
    {Enum.flat_map(parts, &elem(&1, 0)), Enum.flat_map(parts, &elem(&1, 1))}
  end

  # The row's flags in the order of `Measure.budgets/0`; none for a row that
  # records no budgets.
  defp budget_flags(%{reached_minimum_at: flags}),
    do: for(budget <- Measure.budgets(), Map.has_key?(flags, budget), do: {budget, flags[budget]})

  defp budget_flags(_row), do: []

  defp found(true, false), do: {["stops finding the bug"], []}
  defp found(false, true), do: {[], ["finds the bug"]}
  defp found(_before, _now), do: {[], []}

  defp rise(before, now, what) when now > before, do: {["#{what} #{before} -> #{now}"], []}
  defp rise(before, now, what) when now < before, do: {[], ["#{what} #{before} -> #{now}"]}
  defp rise(_before, _now, _what), do: {[], []}

  defp flag({what, true, false}), do: {["#{what} reached -> not reached"], []}
  defp flag({what, false, true}), do: {[], ["#{what} not reached -> reached"]}
  defp flag(_same), do: {[], []}

  defp clean(row) do
    lines =
      for {bad?, text} <- [
            {row.unexplained?, "failed without the seeded bug firing"},
            {not row.clean?, "failed or fired with the bug off"}
          ],
          bad?,
          do: text

    {lines, []}
  end

  defp key(result), do: {result.entry, Map.get(result, :engine)}

  defp label(%{entry: name, engine: engine}), do: "#{name} (#{engine})"
  defp label(%{entry: name}), do: name
end
