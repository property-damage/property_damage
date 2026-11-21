defmodule PropertyDamage.Corpus.Table do
  @moduledoc """
  Summarizes per-seed rows into one line per entry and renders the tables.

  The summary of an entry over its seeds holds:

    * `:found` - seeds where the bug was found, out of `:seeds`.
    * `:found_after` - mean plans generated until the bug was found, over the
      seeds that found it (`nil` when none did).
    * `:shrink_runs` - mean shrink runs, over the same seeds.
    * `:reached_minimum` - seeds whose shrunk plan equals the entry's minimum.

  The rendered text holds no timings and no process identifiers, so equal
  rows render to equal text.
  """

  alias PropertyDamage.Corpus.Measure

  @type result :: %{entry: String.t(), rows: [Measure.row()]}

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

  @doc "Whether every row is a sound measurement: found, explained, and clean with the bug off."
  @spec sound?([result()]) :: boolean()
  def sound?(results) do
    Enum.all?(results, fn %{rows: rows} ->
      Enum.all?(rows, &(&1.found? and &1.clean?))
    end)
  end

  @doc "Renders one summary line per entry, plus a line for each kind of problem."
  @spec render([result()]) :: String.t()
  def render(results) do
    summaries = Enum.map(results, &{&1.entry, summarize(&1.rows)})

    lines =
      Enum.map(summaries, fn {name, s} ->
        [
          name,
          "#{s.found}/#{s.seeds}",
          plans(s.found_after),
          number(s.shrink_runs),
          "#{s.reached_minimum}/#{s.seeds}"
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
    base = Map.new(baseline, &{&1.entry, &1.rows})

    lines =
      Enum.flat_map(current, fn %{entry: name, rows: rows} ->
        case Map.fetch(base, name) do
          {:ok, before} -> [diff_line(name, before, rows)]
          :error -> []
        end
      end)

    missing = Enum.reject(current, &Map.has_key?(base, &1.entry))
    notes = Enum.map(missing, &"#{&1.entry}: not in the baseline")

    [
      align([
        ["entry", "found", "found after", "shrink runs", "reached minimum", "seeds changed"]
        | lines
      ])
      | notes
    ]
    |> Enum.join("\n")
  end

  defp diff_line(name, before, now) do
    {b, a} = {summarize(before), summarize(now)}

    [
      name,
      change(b.found, a.found, &Integer.to_string/1),
      change(b.found_after, a.found_after, &plans/1),
      change(b.shrink_runs, a.shrink_runs, &number/1),
      change(b.reached_minimum, a.reached_minimum, &Integer.to_string/1),
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

  defp mean([], _fun), do: nil
  defp mean(rows, fun), do: Enum.sum(Enum.map(rows, fun)) / length(rows)

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
