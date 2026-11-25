defmodule Mix.Tasks.Pd.CorpusGateTest do
  # The shrink budget columns of `mix pd.corpus` and the `--gate` option that
  # fails a run only on a regression against a saved table.
  #
  # async: false because the task runs "app.start" and prints to stdout, which
  # is captured, and the corpus modules load once for the whole VM.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Corpus, as: CorpusTask
  alias PropertyDamage.Corpus.{Baseline, Entry, FireLog, Gate, Loader, Measure}
  alias PropertyDamage.Next
  alias PropertyDamage.Next.Test.Terms
  alias PropertyDamage.Test.TmpPath

  @next_corpus "corpus/next"
  @native "property_damage_next"
  @source "property_damage_next_source"
  @plan_cap 200

  describe "the shrink budget columns" do
    setup do
      {:ok, [%Entry{} = entry]} = Loader.load(@next_corpus, ["fifth_refund"])
      {:ok, entry: entry}
    end

    test "each flag equals a direct run with that max_shrink_runs", %{entry: entry} do
      flags =
        for seed <- entry.seeds do
          row = Measure.seed(entry, seed, @plan_cap)

          direct =
            Map.new(Measure.budgets(), fn budget ->
              budget_opts = if budget == :default, do: [], else: [max_shrink_runs: budget]
              {budget, direct_reaches_minimum?(entry, seed, budget_opts)}
            end)

          assert row.reached_minimum_at == direct, "seed #{seed}"
          direct
        end

      # Control: the budgets give different answers on this entry, so equal
      # flags are not equal by construction.
      assert Enum.any?(flags, &(&1[16] != &1[32]))
    end

    test "an entry without a minimum records no flags" do
      {:ok, [entry]} = Loader.load(@next_corpus, ["ledger"])
      row = Measure.seed(entry, 1, 2)
      refute Map.has_key?(row, :reached_minimum_at)
    end

    test "the table prints a column per budget" do
      dir = corpus_of("rejected_set", [1, 2])
      output = capture_io(fn -> assert CorpusTask.exec(["--dir", dir]) == :ok end)

      assert output =~ ~r/reached minimum\s+reached at 16\s+reached at 32\s+reached at default$/m
      assert output =~ ~r/^rejected_set\s+.*\s2\/2\s+2\/2\s+2\/2\s+2\/2$/m
    end
  end

  # Runs the entry's model without the harness, under `budget_opts`, and says
  # whether the shrunk plan is the entry's minimum.
  defp direct_reaches_minimum?(entry, seed, budget_opts) do
    {:ok, log} = FireLog.start_link()

    outcome =
      try do
        Next.run(
          [
            model: entry.model,
            adapter: entry.adapter,
            config: %{bug: entry.bug, fire_log: log},
            seed: seed,
            max_steps: entry.max_commands,
            max_plans: @plan_cap
          ] ++ budget_opts
        )
      after
        FireLog.stop(log)
      end

    case outcome do
      {:error, %Next.Failure{plan: plan}} -> Measure.matches_minimum?(entry, plain(plan))
      {:ok, _report} -> false
    end
  end

  defp plain(plan) do
    for %Next.Step{command: %module{} = command} <- Terms.steps_of(plan) do
      command
      |> Map.from_struct()
      |> Map.new(fn
        {field, %Next.Placeholder{}} -> {field, :id}
        pair -> pair
      end)
      |> Map.put(
        :command,
        module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
      )
    end
  end

  describe "Gate.judge/3" do
    test "an unchanged table passes with nothing to report" do
      assert {:ok, %{regressions: [], changes: []}} = Gate.judge(table(), results(), @plan_cap)
    end

    test "a pure improvement passes and lists every change" do
      now =
        edit_row(results(), "a", @native, 1, fn row ->
          %{row | shrink_runs: 7, plans_until_found: 2}
        end)

      saved =
        edit_row(table().results, "a", @native, 1, fn row ->
          %{
            row
            | reached_minimum?: false,
              reached_minimum_at: %{row.reached_minimum_at | 16 => false}
          }
        end)

      saved = edit_row(saved, "a", @source, 2, &not_found/1)

      assert {:ok, %{regressions: [], changes: changes}} =
               Gate.judge(%{table() | results: saved}, now, @plan_cap)

      assert changes == [
               "a (#{@native}) seed 1: shrink runs 10 -> 7",
               "a (#{@native}) seed 1: plans until found 1 -> 2",
               "a (#{@native}) seed 1: smallest plan not reached -> reached",
               "a (#{@native}) seed 1: smallest plan at 16 shrink runs not reached -> reached",
               "a (#{@source}) seed 2: finds the bug",
               "a (#{@source}) seed 2: smallest plan not reached -> reached"
               | Enum.map(
                   [16, 32, :default],
                   &"a (#{@source}) seed 2: smallest plan at #{&1} shrink runs not reached -> reached"
                 )
             ]
    end

    test "shrink runs that rise fail, naming entry, engine, seed and both values" do
      now = edit_row(results(), "a", @source, 2, &%{&1 | shrink_runs: 11})

      assert regressions(now) == ["a (#{@source}) seed 2: shrink runs 10 -> 11"]
    end

    test "a seed that no longer reaches the smallest plan fails" do
      now = edit_row(results(), "a", @native, 1, &%{&1 | reached_minimum?: false})

      assert regressions(now) == ["a (#{@native}) seed 1: smallest plan reached -> not reached"]
    end

    for budget <- [16, 32, :default] do
      @budget budget
      test "a seed that no longer reaches the smallest plan at #{budget} shrink runs fails" do
        now =
          edit_row(results(), "a", @native, 2, fn row ->
            %{row | reached_minimum_at: %{row.reached_minimum_at | @budget => false}}
          end)

        assert regressions(now) == [
                 "a (#{@native}) seed 2: smallest plan at #{@budget} shrink runs reached -> not reached"
               ]
      end
    end

    test "a seed that stops finding the bug fails" do
      now = edit_row(results(), "a", @native, 2, &not_found/1)

      assert ["a (#{@native}) seed 2: stops finding the bug" | _flags] = regressions(now)
    end

    test "a seed that is not clean fails" do
      now = edit_row(results(), "a", @native, 1, &%{&1 | clean?: false})
      now = edit_row(now, "a", @source, 1, &%{&1 | unexplained?: true})

      assert regressions(now) == [
               "a (#{@native}) seed 1: failed or fired with the bug off",
               "a (#{@source}) seed 1: failed without the seeded bug firing"
             ]
    end

    test "an entry, engine or seed that differs from the table fails" do
      [native, source] = results()

      assert regressions([native]) == ["a (#{@source}): in the table, not run"]

      assert regressions([native, source, %{native | entry: "b"}]) == [
               "b (#{@native}): run, not in the table"
             ]

      assert regressions([native, %{source | engine: "other"}]) == [
               "a (other): run, not in the table",
               "a (#{@source}): in the table, not run"
             ]

      assert regressions([native, %{source | rows: tl(source.rows)}]) == [
               "a (#{@source}) seed 1: in the table, not run"
             ]

      assert regressions([native, %{source | rows: source.rows ++ [row(3)]}]) == [
               "a (#{@source}) seed 3: run, not in the table"
             ]
    end

    test "a plan cap that differs from the table fails" do
      assert {:ok, %{regressions: ["plan cap: 200 in the table, 50 in the run"]}} =
               Gate.judge(table(), results(), 50)
    end

    test "a table saved without the budget flags is refused, saying to save it again" do
      saved =
        for result <- table().results,
            do: %{result | rows: Enum.map(result.rows, &Map.delete(&1, :reached_minimum_at))}

      assert {:error, message} = Gate.judge(%{table() | results: saved}, results(), @plan_cap)
      assert message =~ "a (#{@native}), a (#{@source})"
      assert message =~ "Save the table again with --save"
    end
  end

  describe "--gate" do
    @describetag :tmp_dir

    test "passes twice on an unchanged table, with identical output", %{tmp_dir: tmp} do
      {args, path} = saved_run(tmp)

      first = capture_io(fn -> assert CorpusTask.exec(args ++ ["--gate", path]) == :ok end)
      second = capture_io(fn -> assert CorpusTask.exec(args ++ ["--gate", path]) == :ok end)

      assert first == second
      assert first =~ "gate passed"
    end

    test "fails on a regression and names it on stderr", %{tmp_dir: tmp} do
      {args, path} = saved_run(tmp)
      {:ok, saved} = Baseline.load(path)
      [%{rows: [first | rest]} = result] = saved.results
      lowered = %{first | shrink_runs: first.shrink_runs - 1}
      :ok = Baseline.save(path, %{saved | results: [%{result | rows: [lowered | rest]}]})

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CorpusTask.exec(args ++ ["--gate", path]) == :error end)
        end)

      assert stderr =~
               "gate: regression: rejected_set seed 1: shrink runs #{lowered.shrink_runs} -> #{first.shrink_runs}"
    end

    test "passes on an improvement and prints how to save the table again", %{tmp_dir: tmp} do
      {args, path} = saved_run(tmp)
      {:ok, saved} = Baseline.load(path)
      [%{rows: [first | rest]} = result] = saved.results
      raised = %{first | shrink_runs: first.shrink_runs + 1}
      :ok = Baseline.save(path, %{saved | results: [%{result | rows: [raised | rest]}]})

      output = capture_io(fn -> assert CorpusTask.exec(args ++ ["--gate", path]) == :ok end)

      assert output =~
               "rejected_set seed 1: shrink runs #{raised.shrink_runs} -> #{first.shrink_runs}"

      assert output =~ "Save it again with `mix pd.corpus #{Enum.join(args, " ")} --save #{path}`"
      assert output =~ "gate passed"
    end

    test "is not combined with --baseline", %{tmp_dir: tmp} do
      {args, path} = saved_run(tmp)

      stderr =
        capture_io(:stderr, fn ->
          assert CorpusTask.exec(args ++ ["--gate", path, "--baseline", path]) == :error
        end)

      assert stderr =~ "pass one of them"
    end
  end

  # Saves a table of rejected_set on two seeds; returns the run's arguments
  # and the table's path.
  defp saved_run(tmp) do
    dir = corpus_of("rejected_set", [1, 2])
    path = Path.join(tmp, "table.exs")
    args = ["--dir", dir]
    capture_io(fn -> assert CorpusTask.exec(args ++ ["--save", path]) == :ok end)
    {args, path}
  end

  # A corpus directory holding one copy of a `corpus/next` entry, cut to
  # `seeds`. Its modules are already loaded, so the directory needs no support.
  defp corpus_of(name, seeds) do
    dir = TmpPath.unique("pd_corpus_gate")
    File.mkdir_p!(Path.join(dir, "support"))
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, [entry]} = Loader.load(@next_corpus, [name])

    File.write!(
      Path.join(dir, name <> ".exs"),
      inspect(%{entry | seeds: seeds}, limit: :infinity)
    )

    dir
  end

  defp regressions(now) do
    assert {:ok, %{regressions: regressions}} = Gate.judge(table(), now, @plan_cap)
    regressions
  end

  defp row(seed) do
    %{
      seed: seed,
      found?: true,
      unexplained?: false,
      plans_until_found: 1,
      shrink_runs: 10,
      reached_minimum?: true,
      clean?: true,
      reached_minimum_at: %{16 => true, 32 => true, default: true}
    }
  end

  defp not_found(row) do
    %{
      row
      | found?: false,
        plans_until_found: nil,
        shrink_runs: 0,
        reached_minimum?: false,
        reached_minimum_at: Map.new(row.reached_minimum_at, fn {budget, _} -> {budget, false} end)
    }
  end

  defp results do
    for engine <- [@native, @source], do: %{entry: "a", engine: engine, rows: [row(1), row(2)]}
  end

  defp table do
    %{
      seeds: [1, 2],
      commit: %{sha: nil, dirty?: false},
      engine: [@native, @source],
      plan_cap: @plan_cap,
      results: results()
    }
  end

  defp edit_row(results, entry, engine, seed, fun) do
    for result <- results do
      if result.entry == entry and result.engine == engine,
        do: %{result | rows: Enum.map(result.rows, &if(&1.seed == seed, do: fun.(&1), else: &1))},
        else: result
    end
  end
end
