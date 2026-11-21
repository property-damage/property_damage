defmodule Mix.Tasks.Pd.Corpus do
  @moduledoc """
  Measures how well an engine finds and shrinks the seeded bugs of a corpus.

  A corpus is a directory of small systems, each with one bug behind a switch,
  a model, and the hand-written smallest failing plan. For every entry the
  task runs 20 seeds with the bug on, and the same seeds with the bug off,
  and prints three numbers per entry:

    * found after: plans generated until the bug is found (mean over the
      seeds that found it).
    * shrink runs: runs spent shrinking (mean over the same seeds).
    * reached minimum: seeds whose shrunk plan equals the entry's smallest
      failing plan, out of the seeds run.

  A `found` column counts the seeds that found the bug within the plan cap.
  A seed that does not find it is counted there, never left out.

  ## Usage

      mix pd.corpus
      mix pd.corpus --only lost_full_refund --cap 100
      mix pd.corpus --save tmp/table.exs
      mix pd.corpus --baseline tmp/table.exs

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

  The printed table has no timings and no process identifiers: equal seeds
  give equal tables.

  The task exits non-zero when a bug-on run finds nothing on some seed, when a
  run fails without the seeded bug firing, or when a run with the bug off
  fails or fires the bug.
  """

  use Mix.Task

  alias PropertyDamage.Corpus.{Baseline, Loader, Measure, Table}

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
          baseline: :string
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

    with {:ok, baseline} <- load_baseline(opts[:baseline]),
         {:ok, entries} <- Loader.load(dir, Keyword.get_values(opts, :only)) do
      results = Enum.map(entries, &%{entry: &1.name, rows: Measure.entry(&1, cap)})
      report(results, entries, cap, baseline, opts[:save])
    else
      {:error, message} ->
        Mix.shell().error(message)
        :error
    end
  end

  defp load_baseline(nil), do: {:ok, nil}
  defp load_baseline(path), do: Baseline.load(path)

  defp report(results, entries, cap, baseline, save_path) do
    engines = entries |> Enum.map(& &1.engine.name()) |> Enum.uniq()
    seeds = entries |> Enum.flat_map(& &1.seeds) |> Enum.uniq() |> Enum.sort()

    Mix.shell().info(
      "plan cap: #{cap}; seeds: #{inspect(seeds)}; engine: #{Enum.join(engines, ", ")}\n"
    )

    Mix.shell().info(Table.render(results))
    if baseline, do: print_diff(baseline, results, cap)
    saved? = is_nil(save_path) or save(save_path, Baseline.build(results, engines, cap, seeds))

    if Table.sound?(results) and saved?, do: :ok, else: :error
  end

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
