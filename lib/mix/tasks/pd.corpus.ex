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

  ## Shrink budget columns

  The columns above use the harness's own shrink budget, large enough that
  the budget rarely ends a shrink. A smaller budget can leave the shrunk
  plan short of the minimum, so for an entry with a minimum whose engine has
  a shrink budget (the engines of `PropertyDamage.Next`), the table gains
  one column per budget: `reached at 16`, `reached at 32` and `reached at
  default`. Each counts the seeds whose shrunk plan equals the entry's
  minimum when the shrink may execute at most that many plans; `default` is
  the budget `PropertyDamage.Next.run/1` applies when the run names none.
  Every budget is a bug-on run of its own on the same seed and plan cap,
  so a cell says exactly what a run with that `max_shrink_runs` gives. Other
  entries show `-`. A saved table records the flags per seed under
  `:reached_minimum_at`. See `PropertyDamage.Corpus.Measure`.

  ## Usage

      mix pd.corpus
      mix pd.corpus --only lost_full_refund --cap 100
      mix pd.corpus --save tmp/table.exs
      mix pd.corpus --baseline tmp/table.exs
      MIX_ENV=test mix pd.corpus --dir corpus/next --both-engines --gate corpus/next/baseline_next.exs
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
      --gate PATH       After the table, judge the run against the table saved
                        at PATH and fail only on a regression. See "The gate"
                        below. Not combined with `--baseline`.
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

  ## The gate

  `--baseline` fails on any change, so it suits a table that must not move.
  `--gate` fails only when a change is for the worse, so CI can hold the
  corpus to a saved table without failing a change that improves it. The
  saved table `corpus/next/baseline_next.exs` holds `corpus/next` on both
  engines, and CI runs:

      MIX_ENV=test mix pd.corpus --dir corpus/next --both-engines --gate corpus/next/baseline_next.exs

  The run fails, naming the entry, engine and seed with the old and the new
  value on stderr, when against the saved table:

    * a seed's shrink runs rise;
    * a seed no longer reaches the entry's smallest plan, under the
      harness's budget or under one of the shrink budget columns;
    * a seed no longer finds the bug;
    * a run is not clean (a failure without the seeded bug firing, or a
      failure or a fire with the bug off);
    * the entries, engines, seeds or plan cap differ from the table.

  A seed that finds nothing is a measured result, as with `--baseline`. A
  change for the better (fewer shrink runs, a seed that now finds the bug or
  reaches a smallest plan) and a change in plans until found are listed and
  do not fail; the task then says the table is out of date and prints the
  command that saves it again. A table saved before the shrink budget
  columns existed is refused with the same advice. See
  `PropertyDamage.Corpus.Gate`.

  When a change raises shrink runs or loses a smallest plan on purpose, save
  the table again in the same change and say in the change why the numbers
  moved:

      MIX_ENV=test mix pd.corpus --dir corpus/next --both-engines --save corpus/next/baseline_next.exs
  """

  use Mix.Task

  alias PropertyDamage.Corpus.{Baseline, Engine, Gate, Loader, Measure, Table}

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
          gate: :string,
          both_engines: :boolean
        ]
      )

    if invalid == [] do
      Mix.Task.run("app.start")
      measure(opts, args)
    else
      Mix.shell().error("Unknown or malformed option: #{inspect(invalid)}")
      :error
    end
  end

  defp measure(opts, args) do
    cap = Keyword.get(opts, :cap, @default_cap)
    dir = Keyword.get(opts, :dir, "corpus")
    both? = Keyword.get(opts, :both_engines, false)

    with :ok <- one_comparison(opts),
         :ok <- check_engines(both?, args),
         {:ok, baseline} <- load_baseline(opts[:baseline] || opts[:gate]),
         {:ok, entries} <- Loader.load(dir, Keyword.get_values(opts, :only)) do
      entries = if both?, do: Enum.flat_map(entries, &on_both_engines/1), else: entries
      results = Enum.map(entries, &result(&1, cap))
      results = if both?, do: Enum.zip_with(entries, results, &put_engine/2), else: results
      compare = if opts[:gate], do: {:gate, baseline, args}, else: baseline
      report(results, entries, cap, compare, opts[:save], both?)
    else
      {:error, message} ->
        Mix.shell().error(message)
        :error
    end
  end

  defp one_comparison(opts) do
    if opts[:baseline] && opts[:gate],
      do: {:error, "--baseline and --gate each compare against a saved table; pass one of them"},
      else: :ok
  end

  defp check_engines(false, _args), do: :ok

  defp check_engines(true, args),
    do: Engine.NextSource.check_stream_data(Engine.NextSource.loader(), args)

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
    if is_map(baseline), do: print_diff(baseline, results, cap)
    saved? = is_nil(save_path) or save(save_path, Baseline.build(results, engines, cap, seeds))

    if verdict(results, baseline, cap) and saved?, do: :ok, else: :error
  end

  # With a baseline, the run passes when it is clean and equal to the saved
  # table; seeds that find nothing are then measured, not errors. Without one,
  # the run must also find the bug on every seed.
  defp verdict(results, nil, _cap), do: Table.sound?(results)

  defp verdict(results, {:gate, table, args}, cap) do
    case Gate.judge(table, results, cap) do
      {:ok, %{regressions: regressions, changes: changes}} ->
        print_gate(regressions, changes, args)
        regressions == []

      {:error, message} ->
        Mix.shell().error("gate: " <> message)
        false
    end
  end

  defp verdict(results, baseline, _cap) do
    case Table.judge_against(baseline.results, results) do
      :ok ->
        true

      {:error, reasons} ->
        Enum.each(reasons, &Mix.shell().error("baseline check failed: " <> &1))
        false
    end
  end

  defp print_gate(regressions, changes, args) do
    Enum.each(regressions, &Mix.shell().error("gate: regression: " <> &1))

    if changes != [] do
      env = if "--both-engines" in args, do: "MIX_ENV=test ", else: ""
      save = args |> gate_to_save() |> Enum.join(" ")

      Mix.shell().info(
        Enum.join(
          ["\nchanges against the saved table that do not fail the gate:"] ++
            Enum.map(changes, &("  " <> &1)) ++
            ["The saved table is out of date. Save it again with `#{env}mix pd.corpus #{save}`."],
          "\n"
        )
      )
    end

    verdict =
      if regressions == [], do: "passed", else: "failed: #{length(regressions)} regression(s)"

    Mix.shell().info("\ngate #{verdict}")
  end

  # The arguments of this run with `--gate PATH` turned into `--save PATH`.
  defp gate_to_save(["--gate", path | rest]), do: ["--save", path | gate_to_save(rest)]
  defp gate_to_save(["--gate=" <> path | rest]), do: ["--save", path | gate_to_save(rest)]
  defp gate_to_save([arg | rest]), do: [arg | gate_to_save(rest)]
  defp gate_to_save([]), do: []

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
