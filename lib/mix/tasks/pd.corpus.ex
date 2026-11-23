defmodule Mix.Tasks.Pd.Corpus do
  @moduledoc """
  Measures how well an engine finds and shrinks the seeded bugs of a corpus.

  A corpus is a directory of small systems, each with one bug behind a switch,
  a model, and the hand-written smallest failing plan (an entry may instead be
  a regression entry or a skipped entry, see below). For every entry the
  task runs 20 seeds with the bug on, and the same seeds with the bug off,
  and prints three numbers per entry:

    * found after: plans generated until the bug is found (mean over the
      seeds that found it).
    * shrink runs: runs spent shrinking (mean over the same seeds).
    * reached minimum: seeds whose shrunk plan equals the entry's smallest
      failing plan, out of the seeds run.

  A regression entry sets `minimum: nil`: it has no hand-written smallest plan
  and records what the engine does on its seed set. It shows `-` in the
  reached-minimum cell, and the task does not fail when it finds nothing (it
  still fails on an unexplained failure or a dirty bug-off run). It may set
  `plan_cap` to pin the plan cap it was recorded under; that replaces `--cap`
  for the entry. An entry with `skip: "reason"` is not run; the table shows
  `skipped: reason` and a saved table records `%{entry: name, rows: [], skipped:
  reason}`. See `PropertyDamage.Corpus.Entry`.

  A guardrail entry sets `expect` instead of a minimum: its model commits one
  mistake that PD must catch, by raising an error or by a line of the run
  report. It counts a seed as found when that happens, runs its `control`
  pair when the bug is off, and shows `-` in the reached-minimum cell. The
  task prints the line found under `guardrail lines:`, and exits non-zero if
  a seed does not find it. See `PropertyDamage.Corpus.Entry`.

  After the table, the task lists each entry's kept sites: the places where
  the engine drew a value it cannot fit when the value it depends on
  changes (see `PropertyDamage.Next.Engine`). An entry with none is not
  listed, and a saved table does not record them.

  A `found` column counts the seeds that found the bug within the plan cap.
  A seed that does not find it is counted there, never left out.

  ## Usage

      mix pd.corpus
      mix pd.corpus --only lost_full_refund --cap 100
      mix pd.corpus --save tmp/table.exs
      mix pd.corpus --baseline tmp/table.exs
      MIX_ENV=test mix pd.corpus --dir corpus/next --both-engines

  ## Options

      --dir PATH        Corpus directory. Default `corpus`. Shared modules load
                        from `PATH/support/*.exs`; every `PATH/*.exs` is an entry,
                        except files named `baseline_*`, which are saved tables.
      --only NAME       Run only the named entry. May be repeated.
      --cap N           Most plans generated per run. Default 200.
      --save PATH       Write the measured table to PATH as an Elixir term file
                        holding the seeds, the commit and its dirty flag, the
                        engine, the plan cap and the raw per-seed numbers.
      --baseline PATH   After the table, print the change against the table
                        saved at PATH.
      --both-engines    Also run every entry of `PropertyDamage.Corpus.Engine.Next`
                        on `PropertyDamage.Corpus.Engine.NextSource`, the
                        StreamData source engine. See "Two engines" below.

  ## Two engines

  With `--both-engines`, an entry of `PropertyDamage.Corpus.Engine.Next` gets
  two rows: one on that engine and one on
  `PropertyDamage.Corpus.Engine.NextSource`. The table gains an engine column,
  every result carries the name of the engine it ran on (a saved table
  records it, and `--baseline` matches a row by its entry and engine), and
  the kept sites print per engine, with `none` for an engine that kept none.
  Entries of other engines keep one row.

  The source engine needs the patched StreamData that only the test
  environment loads, so run these rows with `MIX_ENV=test`. Anywhere else the
  task prints why and exits non-zero before running any entry.

  The printed table has no timings and no process identifiers: equal seeds
  give equal tables.

  Without `--baseline`, the task exits non-zero when a bug-on run finds
  nothing on some seed, when a run fails without the seeded bug firing, or when
  a run with the bug off fails or fires the bug.

  With `--baseline`, a seed that finds nothing is a measured result, not an
  error. The task exits non-zero only when a run is not clean (the previous
  two cases that involve a failure), when a seed row of an entry that ran
  differs from the saved table, or when an entry that ran is not in the saved
  table. The reason is printed on stderr. `--save` still writes the table.
  """

  use Mix.Task

  alias PropertyDamage.Corpus.{Baseline, Engine, Loader, Measure, Table}

  @shortdoc "Measure finding and shrinking of seeded bugs"

  @default_cap 200

  @impl true
  def run(args) do
    if exec(args) == :error, do: System.halt(1)
  end

  # Testable seam: `run/1` turns an `:error` status into a non-zero halt.
  @doc false
  @spec exec([String.t()]) :: :ok | :error
  def exec(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          dir: :string,
          only: [:string, :keep],
          cap: :integer,
          save: :string,
          baseline: :string,
          both_engines: :boolean
        ]
      )

    if invalid == [] do
      Mix.Task.run("app.start")
      measure(opts)
    else
      Mix.shell().error("Unknown or malformed option: #{inspect(invalid)}")
      :error
    end
  end

  defp measure(opts) do
    cap = Keyword.get(opts, :cap, @default_cap)
    dir = Keyword.get(opts, :dir, "corpus")
    both? = Keyword.get(opts, :both_engines, false)

    with :ok <- check_engines(both?),
         {:ok, baseline} <- load_baseline(opts[:baseline]),
         {:ok, entries} <- Loader.load(dir, Keyword.get_values(opts, :only)) do
      entries = if both?, do: Enum.flat_map(entries, &on_both_engines/1), else: entries
      results = Enum.map(entries, &result(&1, cap))
      results = if both?, do: Enum.zip_with(entries, results, &put_engine/2), else: results
      report(results, entries, cap, baseline, opts[:save], both?)
    else
      {:error, message} ->
        Mix.shell().error(message)
        :error
    end
  end

  defp check_engines(false), do: :ok
  defp check_engines(true), do: Engine.NextSource.check_stream_data()

  defp on_both_engines(%{engine: Engine.Next} = entry),
    do: [entry, %{entry | engine: Engine.NextSource}]

  defp on_both_engines(entry), do: [entry]

  # A skipped entry names no engine; every other result records its engine.
  defp put_engine(%{skip: reason}, result) when is_binary(reason), do: result
  defp put_engine(entry, result), do: Map.put(result, :engine, entry.engine.name())

  defp result(%{skip: reason} = entry, _cap) when is_binary(reason),
    do: %{entry: entry.name, rows: [], skipped: reason}

  defp result(%{expect: expect} = entry, cap) when not is_nil(expect),
    do: entry |> measured(cap) |> Map.merge(%{regression: true, guardrail: true})

  defp result(%{minimum: nil} = entry, cap),
    do: entry |> measured(cap) |> Map.put(:regression, true)

  defp result(entry, cap), do: measured(entry, cap)

  # The entry's rows, with the kept sites of every row moved to the result.
  defp measured(entry, cap) do
    rows = Measure.entry(entry, cap)
    kept = rows |> Enum.flat_map(&Map.get(&1, :kept, [])) |> Enum.uniq() |> Enum.sort()
    line = Enum.find_value(rows, &Map.get(&1, :line))

    %{
      entry: entry.name,
      rows: Enum.map(rows, &Map.drop(&1, [:kept, :line])),
      kept: kept,
      line: line
    }
  end

  defp load_baseline(nil), do: {:ok, nil}
  defp load_baseline(path), do: Baseline.load(path)

  defp report(results, entries, cap, baseline, save_path, both?) do
    run = Enum.reject(entries, &is_binary(&1.skip))
    engines = run |> Enum.map(& &1.engine.name()) |> Enum.uniq()
    seeds = run |> Enum.flat_map(& &1.seeds) |> Enum.uniq() |> Enum.sort()

    Mix.shell().info(
      "plan cap: #{cap}; seeds: #{inspect(seeds)}; engine: #{Enum.join(engines, ", ")}\n"
    )

    Mix.shell().info(Table.render(results))
    print_kept(results, both?)
    print_lines(results)
    results = Enum.map(results, &Map.drop(&1, [:kept, :line]))
    if baseline, do: print_diff(baseline, results, cap)
    saved? = is_nil(save_path) or save(save_path, Baseline.build(results, engines, cap, seeds))

    if verdict(results, baseline) and saved?, do: :ok, else: :error
  end

  # With a baseline, the run passes when it is clean and equal to the saved
  # table; seeds that find nothing are then measured, not errors. Without one,
  # the run must also find the bug on every seed.
  defp verdict(results, nil), do: Table.sound?(results)

  defp verdict(results, baseline) do
    case Table.judge_against(baseline.results, results) do
      :ok ->
        true

      {:error, reasons} ->
        Enum.each(reasons, &Mix.shell().error("baseline check failed: " <> &1))
        false
    end
  end

  defp print_kept(results, false) do
    lines =
      for %{entry: name, kept: [_ | _] = kept} <- results,
          site <- kept,
          do: "  #{name}: #{describe_site(site)}"

    if lines != [], do: Mix.shell().info(Enum.join(["\nkept sites:" | lines], "\n"))
  end

  # One section per engine, in the order the engines ran; an engine that kept
  # no site says `none`.
  defp print_kept(results, true) do
    engines = results |> Enum.flat_map(&List.wrap(Map.get(&1, :engine))) |> Enum.uniq()

    sections =
      for engine <- engines do
        lines =
          for %{engine: ^engine, entry: name, kept: kept} <- results,
              site <- kept,
              do: "  #{name}: #{describe_site(site)}"

        header = "kept sites (#{engine}):"
        if lines == [], do: header <> " none", else: Enum.join([header | lines], "\n")
      end

    Mix.shell().info(Enum.join(["" | sections], "\n"))
  end

  defp print_lines(results) do
    lines =
      for %{entry: name, line: line} = result when is_binary(line) <- results,
          do: "  #{name}#{engine_suffix(result)}: #{line}"

    if lines != [], do: Mix.shell().info(Enum.join(["\nguardrail lines:" | lines], "\n"))
  end

  defp engine_suffix(%{engine: engine}) when is_binary(engine), do: " (#{engine})"
  defp engine_suffix(_result), do: ""

  defp describe_site(%{site: :assign, command: module, key: key, spec: id}),
    do: "#{inspect(module)}, assign #{inspect(key)} of spec #{id}"

  defp describe_site(%{command: module, key: key}),
    do: "#{inspect(module)}, field #{inspect(key)}"

  defp print_diff(baseline, results, cap) do
    sha = baseline.commit.sha || "unknown commit"
    dirty = if baseline.commit.dirty?, do: ", dirty", else: ""

    Mix.shell().info(
      "\nchange against the baseline (#{sha}#{dirty}; plan cap #{baseline.plan_cap}" <>
        if(baseline.plan_cap == cap, do: "", else: ", differs from this run's #{cap}") <> "):\n"
    )

    Mix.shell().info(Table.render_diff(baseline.results, results))
  end

  defp save(path, baseline) do
    case Baseline.save(path, baseline) do
      :ok ->
        Mix.shell().info("\nsaved the table to #{path}")
        true

      {:error, reason} ->
        Mix.shell().error("Cannot save to #{path}: #{inspect(reason)}")
        false
    end
  end
end
