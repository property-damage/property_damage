defmodule PropertyDamage.Corpus.Table do
  @moduledoc """
  Summarizes per-seed rows into one line per entry and renders the tables.

  The summary of an entry over its seeds holds:

    * `:found` - seeds where the bug was found, out of `:seeds`.
    * `:found_after` - mean plans generated until the bug was found, over the
      seeds that found it (`nil` when none did).
    * `:shrink_runs` - mean shrink runs, over the same seeds.
    * `:reached_minimum` - seeds whose shrunk plan equals the entry's minimum.

  A result may carry `skipped: reason` (an entry that was not run; it has no
  rows, is shown as `skipped: <reason>` and is ignored when judging soundness)
  or `regression: true` (an entry without a hand-written minimum; its
  reached-minimum cell shows `-` and it is sound without finding the bug, as
  long as it is clean and has no unexplained failure) or `guardrail: true`
  (also shown with `-`; it is sound only when every seed found its line and
  the control run was clean).

  The rendered text holds no timings and no process identifiers, so equal
  rows render to equal text.
  """

  alias PropertyDamage.Corpus.Measure

  @type result :: %{
          required(:entry) => String.t(),
          required(:rows) => [Measure.row()],
          optional(:skipped) => String.t(),
          optional(:regression) => true,
          optional(:guardrail) => true
        }

  @type summary :: %{
          seeds: non_neg_integer(),
          found: non_neg_integer(),
          found_after: float() | nil,
          shrink_runs: float() | nil,
          reached_minimum: non_neg_integer(),
          unexplained: non_neg_integer(),
          dirty_off: non_neg_integer()
        }

  @headers ["entry", "found", "found after", "shrink runs", "reached minimum"]

  @doc "Summarizes the rows of one entry."
  @spec summarize([Measure.row()]) :: summary()
  def summarize(rows) do
    found = Enum.filter(rows, & &1.found?)

    %{
      seeds: length(rows),
      found: length(found),
      found_after: mean(found, & &1.plans_until_found),
      shrink_runs: mean(found, & &1.shrink_runs),
      reached_minimum: Enum.count(rows, & &1.reached_minimum?),
      unexplained: Enum.count(rows, & &1.unexplained?),
      dirty_off: Enum.count(rows, &(not &1.clean?))
    }
  end

  @doc """
  Whether every row is a sound measurement: found, explained, and clean with the
  bug off. A regression result need not find the bug. A skipped result has no rows.
  """
  @spec sound?([result()]) :: boolean()
  def sound?(results) do
    Enum.all?(results, fn
      %{guardrail: true, rows: rows} -> Enum.all?(rows, &(&1.found? and &1.clean?))
      %{regression: true, rows: rows} -> Enum.all?(rows, &(&1.clean? and not &1.unexplained?))
      %{rows: rows} -> Enum.all?(rows, &(&1.found? and &1.clean?))
    end)
  end

  @doc """
  Judges a run against a saved table. Returns `:ok`, or `{:error, reasons}` with
  one message per problem.

  The run passes when every result is clean (nothing fails with the bug off,
  and no failure lacks the seeded bug firing; a seed that finds nothing is not
  a problem here), no seed row of a run entry differs from the saved table,
  and every entry that ran is in the saved table. Skipped results are not
  compared.
  """
  @spec judge_against([result()], [result()]) :: :ok | {:error, [String.t()]}
  def judge_against(baseline, results) do
    base = Map.new(baseline, &{&1.entry, &1})
    run = Enum.reject(results, &Map.has_key?(&1, :skipped))
    known = Enum.filter(run, &match?(%{rows: _}, base[&1.entry]))
    known = Enum.reject(known, &Map.has_key?(base[&1.entry], :skipped))

    changed =
      Enum.sum(
        for %{entry: name, rows: rows} <- known do
          before = base[name].rows
          seeds_changed(before, rows) + abs(length(before) - length(rows))
        end
      )

    reasons =
      Enum.reject(
        [
          if(Enum.all?(run, &clean_result?/1), do: nil, else: "clean violation"),
          if(changed == 0, do: nil, else: "#{changed} seeds changed"),
          if(length(known) == length(run),
            do: nil,
            else: "entry missing from the baseline: " <> missing_names(run, known)
          )
        ],
        &is_nil/1
      )

    if reasons == [], do: :ok, else: {:error, reasons}
  end

  defp clean_result?(%{rows: rows}), do: Enum.all?(rows, &(&1.clean? and not &1.unexplained?))

  defp missing_names(run, known) do
    run |> Enum.map(& &1.entry) |> Kernel.--(Enum.map(known, & &1.entry)) |> Enum.join(", ")
  end

  @doc "Renders one summary line per entry, plus a line for each kind of problem."
  @spec render([result()]) :: String.t()
  def render(results) do
    run = Enum.reject(results, &Map.has_key?(&1, :skipped))
    summaries = Enum.map(run, &{&1.entry, summarize(&1.rows)})

    lines =
      Enum.map(results, fn
        %{entry: name, skipped: reason} ->
          [name, "skipped: #{reason}", "", "", ""]

        %{entry: name, rows: rows} = result ->
          s = summarize(rows)

          [
            name,
            "#{s.found}/#{s.seeds}",
            plans(s.found_after),
            number(s.shrink_runs),
            reached(result, s)
          ]
      end)

    [align([@headers | lines]) | problems(summaries)] |> Enum.join("\n")
  end

  @doc """
  Renders the change of `current` against a `baseline`: each entry's means
  and counts as `before -> after`, and how many seeds differ in any raw number.
  """
  @spec render_diff([result()], [result()]) :: String.t()
  def render_diff(baseline, current) do
    base = Map.new(baseline, &{&1.entry, &1})
    comparable = Enum.filter(current, &comparable?(&1, base))

    lines =
      Enum.map(comparable, fn %{entry: name, rows: rows} = result ->
        diff_line(name, base[name].rows, rows, result)
      end)

    notes = Enum.flat_map(current, &diff_note(&1, base))

    [
      align([
        ["entry", "found", "found after", "shrink runs", "reached minimum", "seeds changed"]
        | lines
      ])
      | notes
    ]
    |> Enum.join("\n")
  end

  # A skipped entry has no rows to compare, on either side.
  defp comparable?(result, base) do
    case Map.fetch(base, result.entry) do
      {:ok, before} -> not Map.has_key?(before, :skipped) and not Map.has_key?(result, :skipped)
      :error -> false
    end
  end

  defp diff_note(%{entry: name, skipped: reason}, _base), do: ["#{name}: skipped: #{reason}"]

  defp diff_note(%{entry: name}, base) do
    case Map.fetch(base, name) do
      {:ok, %{skipped: _}} -> ["#{name}: skipped in the baseline"]
      {:ok, _} -> []
      :error -> ["#{name}: not in the baseline"]
    end
  end

  defp reached(%{regression: true}, _summary), do: "-"
  defp reached(_result, s), do: "#{s.reached_minimum}/#{s.seeds}"

  defp diff_line(name, before, now, result) do
    {b, a} = {summarize(before), summarize(now)}

    [
      name,
      change(b.found, a.found, &Integer.to_string/1),
      change(b.found_after, a.found_after, &plans/1),
      change(b.shrink_runs, a.shrink_runs, &number/1),
      if(result[:regression],
        do: "-",
        else: change(b.reached_minimum, a.reached_minimum, &Integer.to_string/1)
      ),
      "#{seeds_changed(before, now)}/#{length(now)}"
    ]
  end

  defp seeds_changed(before, now) do
    now |> Enum.zip(before) |> Enum.count(fn {a, b} -> a != b end)
  end

  defp change(same, same, show), do: show.(same)
  defp change(before, now, show), do: "#{show.(before)} -> #{show.(now)}"

  defp problems(summaries) do
    for {name, s} <- summaries,
        {count, text} <- [
          {s.unexplained, "failed without the seeded bug firing"},
          {s.dirty_off, "failed or fired with the bug off"}
        ],
        count > 0,
        do: "#{name}: #{count} seed(s) #{text}"
  end

  # A row without the number (a guardrail found by a raise has no plan
  # number) is left out of the mean.
  defp mean(rows, fun) do
    case rows |> Enum.map(fun) |> Enum.reject(&is_nil/1) do
      [] -> nil
      values -> Enum.sum(values) / length(values)
    end
  end

  defp plans(nil), do: "-"
  defp plans(value), do: number(value) <> " plans"

  defp number(nil), do: "-"
  defp number(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  defp align(rows) do
    widths =
      rows
      |> Enum.zip_with(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    Enum.map_join(rows, "\n", fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
      |> String.trim_trailing()
    end)
  end
end
