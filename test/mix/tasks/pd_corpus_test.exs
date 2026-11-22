# The corpus modules load before this file compiles, so the test modules below
# can refer to them.
for file <- Enum.sort(Path.wildcard("corpus/support/*.exs")), do: Code.require_file(file)

defmodule Mix.Tasks.Pd.CorpusTest do
  # async: false because the task runs "app.start" and prints to stdout, which
  # we capture, and the corpus modules load once for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Corpus.Scheme.RefundModel
  alias Mix.Tasks.Pd.Corpus, as: CorpusTask
  alias PropertyDamage.Corpus.{Baseline, Engine, Entry, FireLog, Loader, Measure, Table}
  alias PropertyDamage.Test.TmpPath

  @corpus "corpus"
  @seeds Enum.to_list(1..20)
  @plan_cap 200

  # A model whose expectation is deliberately wrong: it rejects every payment,
  # so it fails whether or not the seeded bug exists.
  defmodule AlwaysWrong do
    @moduledoc false
    use PropertyDamage.Model.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _event), do: state

    @check every: Corpus.Scheme.Pay
    def pay_is_never_ok(_state, _command),
      do: PropertyDamage.fail!("a deliberately wrong expectation")
  end

  defmodule WrongModel do
    @moduledoc false
    use PropertyDamage.Model

    @impl true
    def commands, do: RefundModel.commands()

    @impl true
    def command_sequence_projection, do: Corpus.Scheme.Projection

    @impl true
    def check_projections, do: [AlwaysWrong]

    @impl true
    def simulator, do: Corpus.Scheme.Simulator
  end

  setup_all do
    {:ok, entries} = Loader.load(@corpus)
    {:ok, entries: Map.new(entries, &{&1.name, &1})}
  end

  describe "the seeded bugs" do
    for name <- ["lost_full_refund", "double_credit", "rejected_set", "fifth_refund", "long_note"] do
      test "#{name}: found, with the bug fired, on every seed with the bug on; never with it off",
           %{entries: entries} do
        entry = Map.fetch!(entries, unquote(name))

        for seed <- @seeds do
          on = Engine.Run.run(entry, seed, @plan_cap)
          assert on.found?, "seed #{seed}: bug not found within #{@plan_cap} plans"
          assert on.bug_fired?, "seed #{seed}: failed without the seeded bug firing"
          assert on.fires > 0

          off = Engine.Run.run(%{entry | bug: nil}, seed, @plan_cap)
          refute off.found?, "seed #{seed}: failed with the bug off"
          refute off.bug_fired?
          assert off.fires == 0
        end
      end
    end

    test "each hand-written minimum makes the system misbehave with the bug on, and only then",
         %{entries: entries} do
      for name <- ["lost_full_refund", "double_credit"] do
        entry = entries[name]
        {on_balance, on_fires} = play_scheme(entry.minimum, entry.bug)
        {off_balance, off_fires} = play_scheme(entry.minimum, nil)

        assert {off_balance, off_fires} == {0, 0}, name
        assert on_balance != 0 and on_fires == 1, name
      end

      [%{value: value}] = entries["rejected_set"].minimum
      log = start_log()
      {:ok, store} = Corpus.KeyValue.start(bug: :rejected_set, fire_log: log)
      assert Corpus.KeyValue.set(store, "k0", value) == {:error, :rejected}
      assert FireLog.total(log) == 1

      {:ok, healthy} = Corpus.KeyValue.start(bug: nil, fire_log: log)
      assert Corpus.KeyValue.set(healthy, "k0", value) == :ok
      assert FireLog.total(log) == 1
    end
  end

  describe "the scheme bugs added later" do
    test "a refund of one less than the payment loses its credit, only with the bug on" do
      for {bug, expected} <- [{:offset_refund, {2, 1}}, {nil, {1, 0}}] do
        log = start_log()
        {:ok, scheme} = Corpus.Scheme.start(bug: bug, fire_log: log)
        {:ok, id} = Corpus.Scheme.pay(scheme, 2)
        {:ok, balance} = Corpus.Scheme.refund(scheme, id, 1)
        assert {balance, FireLog.total(log)} == expected
      end
    end

    test "the fifth refund of a payment loses its credit; the fourth does not" do
      log = start_log()
      {:ok, scheme} = Corpus.Scheme.start(bug: :fifth_refund, fire_log: log)
      {:ok, id} = Corpus.Scheme.pay(scheme, 5)

      balances = for _ <- 1..5, do: elem(Corpus.Scheme.refund(scheme, id, 1), 1)

      assert balances == [4, 3, 2, 1, 1]
      assert FireLog.total(log) == 1
    end

    test "a note over 40 characters is cut, only with the bug on" do
      for {bug, expected} <- [{:long_note, {40, 1}}, {nil, {41, 0}}] do
        log = start_log()
        {:ok, scheme} = Corpus.Scheme.start(bug: bug, fire_log: log)
        {:ok, id} = Corpus.Scheme.pay(scheme, 1)
        {:ok, 0, stored} = Corpus.Scheme.refund_noted(scheme, id, 1, String.duplicate("a", 41))
        assert {String.length(stored), FireLog.total(log)} == expected
      end

      {:ok, scheme} = Corpus.Scheme.start(bug: :long_note, fire_log: start_log())
      {:ok, id} = Corpus.Scheme.pay(scheme, 1)
      {:ok, 0, stored} = Corpus.Scheme.refund_noted(scheme, id, 1, String.duplicate("a", 40))
      assert String.length(stored) == 40
    end
  end

  describe "the control" do
    test "a wrong model fails, but the harness sees the seeded bug did not fire", %{
      entries: entries
    } do
      entry = %{entries["lost_full_refund"] | model: WrongModel, seeds: [1, 2, 3]}

      for row <- Measure.entry(entry, @plan_cap) do
        refute row.found?
        assert row.unexplained?
        refute row.clean?
      end
    end

    test "a bug-on run that finds nothing is counted as not found and fails the task" do
      output =
        capture_io(fn ->
          assert CorpusTask.exec(["--only", "lost_full_refund", "--cap", "1"]) == :error
        end)

      assert output =~ ~r/lost_full_refund\s+\d+\/20/
      refute output =~ ~r/lost_full_refund\s+20\/20/
    end
  end

  describe "measuring" do
    test "the same seeds give the same table, with no timings" do
      run = fn ->
        capture_io(fn -> assert CorpusTask.exec(["--only", "rejected_set"]) == :ok end)
      end

      first = run.()

      assert first == run.()
      assert first =~ ~r/rejected_set\s+20\/20/
      refute first =~ ~r/\d+ ?ms|#PID/
    end

    test "--dir loads the entries of another directory", %{entries: entries} do
      dir = TmpPath.unique("pd_corpus_dir")
      File.mkdir_p!(Path.join(dir, "support"))
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "mini.exs"), """
      %PropertyDamage.Corpus.Entry{
        name: "mini",
        engine: PropertyDamage.Corpus.Engine.Run,
        system: Corpus.KeyValue,
        bug: :rejected_set,
        model: Corpus.KeyValue.Model,
        adapter: Corpus.KeyValue.Adapter,
        minimum: #{inspect(entries["rejected_set"].minimum)},
        compare: {:ignore_fields, [:key]},
        seeds: [1, 2]
      }
      """)

      output = capture_io(fn -> assert CorpusTask.exec(["--dir", dir]) == :ok end)
      assert output =~ ~r/mini\s+2\/2/
    end

    test "--dir skips saved tables next to the entries", %{entries: entries} do
      dir = TmpPath.unique("pd_corpus_saved")
      File.mkdir_p!(Path.join(dir, "support"))
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "baseline_x.exs"), "%{seeds: [], results: []}\n")

      File.write!(Path.join(dir, "mini.exs"), """
      %PropertyDamage.Corpus.Entry{
        name: "mini",
        engine: PropertyDamage.Corpus.Engine.Run,
        system: Corpus.KeyValue,
        bug: :rejected_set,
        model: Corpus.KeyValue.Model,
        adapter: Corpus.KeyValue.Adapter,
        minimum: #{inspect(entries["rejected_set"].minimum)},
        seeds: [1]
      }
      """)

      assert {:ok, [%Entry{name: "mini"}]} = Loader.load(dir)
    end

    test "an unknown entry or directory is an error" do
      capture_io(:stderr, fn ->
        assert CorpusTask.exec(["--only", "nope"]) == :error
        assert CorpusTask.exec(["--dir", "no/such/dir"]) == :error
      end)
    end
  end

  describe "--save and --baseline" do
    @tag :tmp_dir
    test "a saved table holds the seeds, commit, engine, cap and per-seed rows", %{tmp_dir: tmp} do
      path = Path.join(tmp, "table.exs")

      capture_io(fn ->
        assert CorpusTask.exec(["--only", "rejected_set", "--cap", "50", "--save", path]) == :ok
      end)

      assert {:ok, saved} = Baseline.load(path)
      assert saved.seeds == @seeds
      assert saved.plan_cap == 50
      assert saved.engine == ["property_damage_run"]
      assert %{sha: _, dirty?: dirty} = saved.commit
      assert is_boolean(dirty)
      assert [%{entry: "rejected_set", rows: rows}] = saved.results
      assert Enum.map(rows, & &1.seed) == @seeds
      assert Enum.all?(rows, &Map.has_key?(&1, :plans_until_found))
    end

    @tag :tmp_dir
    test "--baseline prints the change against a saved table", %{tmp_dir: tmp} do
      path = Path.join(tmp, "table.exs")
      args = ["--only", "rejected_set", "--cap", "50"]
      capture_io(fn -> CorpusTask.exec(args ++ ["--save", path]) end)

      same = capture_io(fn -> CorpusTask.exec(args ++ ["--baseline", path]) end)
      assert same =~ "change against the baseline"
      assert same =~ "0/20"

      # A saved row with a different shrink count shows up as a changed seed.
      {:ok, saved} = Baseline.load(path)
      [%{rows: [first | rest]} = result] = saved.results

      edited = %{
        saved
        | results: [%{result | rows: [%{first | shrink_runs: first.shrink_runs + 100} | rest]}]
      }

      :ok = Baseline.save(path, edited)

      changed = capture_io(fn -> CorpusTask.exec(args ++ ["--baseline", path]) end)
      assert changed =~ "1/20"
    end

    test "an unreadable baseline is an error" do
      capture_io(:stderr, fn ->
        assert CorpusTask.exec(["--baseline", "no/such/file.exs"]) == :error
      end)
    end
  end

  describe "skipped and regression entries" do
    setup do
      dir = TmpPath.unique("pd_corpus_kinds")
      File.mkdir_p!(Path.join(dir, "support"))
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "parked.exs"), """
      %PropertyDamage.Corpus.Entry{name: "parked", skip: "waiting for a fix"}
      """)

      File.write!(Path.join(dir, "recorded.exs"), """
      %PropertyDamage.Corpus.Entry{
        name: "recorded",
        engine: PropertyDamage.Corpus.Engine.Run,
        system: Corpus.Scheme,
        bug: :lost_full_refund,
        model: Corpus.Scheme.RefundModel,
        adapter: Corpus.Scheme.Adapter,
        minimum: nil,
        plan_cap: 1,
        max_commands: 8,
        seeds: [1, 2, 3]
      }
      """)

      {:ok, dir: dir}
    end

    test "a skipped entry loads, is selectable and prints its reason without running", %{dir: dir} do
      assert {:ok, [%Entry{name: "parked", skip: "waiting for a fix"}]} =
               Loader.load(dir, ["parked"])

      output =
        capture_io(fn -> assert CorpusTask.exec(["--dir", dir, "--only", "parked"]) == :ok end)

      assert output =~ ~r/parked\s+skipped: waiting for a fix/
    end

    @tag :tmp_dir
    test "a skipped entry is saved with no rows and diffed without a crash", %{
      dir: dir,
      tmp_dir: tmp
    } do
      path = Path.join(tmp, "table.exs")
      args = ["--dir", dir, "--only", "parked"]
      capture_io(fn -> assert CorpusTask.exec(args ++ ["--save", path]) == :ok end)

      assert {:ok, %{results: [%{entry: "parked", rows: [], skipped: "waiting for a fix"}]}} =
               Baseline.load(path)

      output = capture_io(fn -> assert CorpusTask.exec(args ++ ["--baseline", path]) == :ok end)
      assert output =~ "parked: skipped: waiting for a fix"
    end

    test "a regression entry shows - for the minimum, pins its plan cap and passes with seeds not found",
         %{dir: dir} do
      output =
        capture_io(fn ->
          assert CorpusTask.exec(["--dir", dir, "--only", "recorded", "--cap", "200"]) == :ok
        end)

      # The pinned cap of 1 plan finds the bug on only some of these seeds; the
      # global cap of 200 finds it on all of them. The task still passes.
      assert output =~ ~r/recorded\s+[012]\/3\s.*\s-$/m
    end

    test "a regression entry never reaches a minimum and still fails on an unexplained run",
         %{dir: dir} do
      {:ok, [_parked, recorded]} = Loader.load(dir)
      recorded = %{recorded | plan_cap: nil, seeds: [1]}

      assert [%{found?: true, reached_minimum?: false}] = Measure.entry(recorded, @plan_cap)

      wrong = %{recorded | model: WrongModel}

      assert [%{found?: false, unexplained?: true}] = Measure.entry(wrong, @plan_cap)

      results = [%{entry: "recorded", rows: Measure.entry(wrong, @plan_cap), regression: true}]
      refute Table.sound?(results)
    end

    test "an entry that is neither skipped nor fully specified is an error", %{dir: dir} do
      File.write!(Path.join(dir, "half.exs"), ~s|%PropertyDamage.Corpus.Entry{name: "half"}\n|)

      assert {:error, message} = Loader.load(dir)
      assert message =~ "half.exs does not set engine, system, model, adapter"
    end
  end

  describe "entries" do
    test "carry the fields the harness needs", %{entries: entries} do
      assert Map.keys(entries) |> Enum.sort() == [
               "double_credit",
               "fifth_refund",
               "long_note",
               "lost_full_refund",
               "offset_refund",
               "rejected_set"
             ]

      for {_name, %Entry{} = entry} <- entries do
        assert entry.seeds == @seeds
        assert entry.engine == Engine.Run
        assert is_atom(entry.bug) and entry.bug != nil
      end
    end
  end

  defp start_log do
    {:ok, log} = FireLog.start_link()
    log
  end

  # Plays a minimum plan against a scheme started with `bug`. Returns the
  # balance of the payment after the plan and how often the bug fired.
  defp play_scheme(plan, bug) do
    log = start_log()
    {:ok, scheme} = Corpus.Scheme.start(bug: bug, fire_log: log)

    balance =
      Enum.reduce(plan, nil, fn
        %{command: :pay, amount: amount}, _balance ->
          {:ok, "pay_1"} = Corpus.Scheme.pay(scheme, amount)
          amount

        %{command: :refund, amount: amount, lose_response: lose}, _balance ->
          {:ok, balance} = Corpus.Scheme.refund(scheme, "pay_1", amount, lose_response: lose)
          balance
      end)

    {balance, FireLog.total(log)}
  end
end
