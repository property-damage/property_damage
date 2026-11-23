defmodule Mix.Tasks.Pd.CorpusEnginesTest do
  # `mix pd.corpus --both-engines`: every entry on the new engine also runs on
  # the StreamData source engine, one row per engine.
  #
  # async: false because the task runs "app.start" and prints to stdout, which
  # is captured, and the corpus modules load once for the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Corpus, as: CorpusTask
  alias PropertyDamage.Corpus.{Baseline, Engine, Loader}
  alias PropertyDamage.Test.TmpPath

  @next_corpus "corpus/next"
  @native "property_damage_next"
  @source "property_damage_next_source"

  setup_all do
    {:ok, entries} = Loader.load(@next_corpus)
    {:ok, entries: Map.new(entries, &{&1.name, &1})}
  end

  # A corpus directory holding one copy of a `corpus/next` entry, cut to
  # `seeds`. Its modules are already loaded, so the directory needs no support.
  defp corpus_of(name, seeds) do
    dir = TmpPath.unique("pd_corpus_engines")
    File.mkdir_p!(Path.join(dir, "support"))
    on_exit(fn -> File.rm_rf!(dir) end)

    text = File.read!(Path.join(@next_corpus, name <> ".exs"))
    {entry, _binding} = Code.eval_string(text)

    File.write!(
      Path.join(dir, name <> ".exs"),
      inspect(%{entry | seeds: seeds}, limit: :infinity)
    )

    dir
  end

  describe "without --both-engines" do
    test "an entry of the new engine prints one row and no engine column" do
      dir = corpus_of("rejected_set", [1, 2])
      output = capture_io(fn -> assert CorpusTask.exec(["--dir", dir]) == :ok end)

      assert output =~ ~r/^entry\s+found\s+found after/m
      assert output =~ ~r/^rejected_set\s+2\/2/m
      refute output =~ @source
    end
  end

  describe "with --both-engines" do
    @describetag :patched_stream_data

    test "prints one row per engine for an entry of the new engine" do
      dir = corpus_of("rejected_set", [1, 2])

      output =
        capture_io(fn -> assert CorpusTask.exec(["--dir", dir, "--both-engines"]) == :ok end)

      assert output =~ "engine: #{@native}, #{@source}"
      assert output =~ ~r/^entry\s+engine\s+found\s+found after/m
      assert output =~ ~r/^rejected_set\s+#{@native}\s+2\/2/m
      assert output =~ ~r/^rejected_set\s+#{@source}\s+2\/2/m
    end

    test "prints the kept sites per engine, with none on the source engine" do
      dir = corpus_of("lost_full_refund", [1])

      output =
        capture_io(fn -> assert CorpusTask.exec(["--dir", dir, "--both-engines"]) == :ok end)

      assert output =~
               "kept sites (#{@native}):\n  lost_full_refund: Corpus.Next.Scheme.Refund, field :amount"

      assert output =~ "kept sites (#{@source}): none"
    end

    @tag :tmp_dir
    test "a saved table records the engine of each row and a baseline run matches it", %{
      tmp_dir: tmp
    } do
      dir = corpus_of("rejected_set", [1, 2])
      path = Path.join(tmp, "table.exs")
      args = ["--dir", dir, "--both-engines"]

      capture_io(fn -> assert CorpusTask.exec(args ++ ["--save", path]) == :ok end)

      assert {:ok, saved} = Baseline.load(path)
      assert saved.engine == [@native, @source]

      assert [
               %{entry: "rejected_set", engine: @native},
               %{entry: "rejected_set", engine: @source}
             ] =
               saved.results

      output = capture_io(fn -> assert CorpusTask.exec(args ++ ["--baseline", path]) == :ok end)
      assert output =~ ~r/^rejected_set\s+#{@native}\s+.*\s0\/2$/m
      assert output =~ ~r/^rejected_set\s+#{@source}\s+.*\s0\/2$/m
    end

    @tag :tmp_dir
    test "a row changed on one engine only is counted against that engine", %{tmp_dir: tmp} do
      dir = corpus_of("rejected_set", [1, 2])
      path = Path.join(tmp, "table.exs")
      args = ["--dir", dir, "--both-engines"]
      capture_io(fn -> assert CorpusTask.exec(args ++ ["--save", path]) == :ok end)

      {:ok, saved} = Baseline.load(path)
      [native, %{rows: [first | rest]} = source] = saved.results
      edited = [native, %{source | rows: [%{first | shrink_runs: first.shrink_runs + 1} | rest]}]
      :ok = Baseline.save(path, %{saved | results: edited})

      {stderr, output} =
        with_stdout(fn ->
          capture_io(:stderr, fn ->
            assert CorpusTask.exec(args ++ ["--baseline", path]) == :error
          end)
        end)

      assert stderr =~ "1 seeds changed"
      assert output =~ ~r/^rejected_set\s+#{@native}\s+.*\s0\/2$/m
      assert output =~ ~r/^rejected_set\s+#{@source}\s+.*\s1\/2$/m
    end
  end

  describe "the patched StreamData check" do
    defmodule ActiveStreamData do
      @moduledoc false
      def load, do: raise("an active patch is not loaded again")
      def active?, do: true
    end

    defmodule LoadableStreamData do
      @moduledoc false
      def load, do: Process.put(__MODULE__, true) && :ok
      def active?, do: Process.get(__MODULE__, false)
    end

    defmodule SkippedStreamData do
      @moduledoc false
      def load, do: :skipped
      def active?, do: false
    end

    defmodule BrokenStreamData do
      @moduledoc false
      def load, do: {:error, "no patch executable on PATH"}
      def active?, do: false
    end

    test "passes when the patch is active, or once the loader activates it" do
      assert Engine.NextSource.check_stream_data(ActiveStreamData) == :ok
      assert Engine.NextSource.check_stream_data(LoadableStreamData) == :ok
    end

    test "refuses, naming how to run the rows, when the patch is absent or not active" do
      for loader <- [Module.concat(__MODULE__, Missing), SkippedStreamData, BrokenStreamData] do
        assert {:error, message} = Engine.NextSource.check_stream_data(loader)
        assert message =~ "MIX_ENV=test mix pd.corpus --dir corpus/next --both-engines"
      end

      assert {:error, message} = Engine.NextSource.check_stream_data(BrokenStreamData)
      assert message =~ "no patch executable on PATH"
    end
  end

  describe "the refusal of the source rows" do
    test "names the --dir and the arguments that were passed" do
      dir = corpus_of("rejected_set", [1])
      args = ["--dir", dir, "--only", "rejected_set", "--both-engines"]
      loader = Module.concat(__MODULE__, Missing)

      assert {:error, message} = Engine.NextSource.check_stream_data(loader, args)
      assert message =~ "`MIX_ENV=test mix pd.corpus #{Enum.join(args, " ")}`"
      refute message =~ "corpus/next"
    end
  end

  describe "nested_price on the new engine" do
    test "finds the bug with it firing, keeps the price site, and never fails with the bug off",
         %{entries: entries} do
      entry = Map.fetch!(entries, "nested_price")
      site = %{site: :field, command: Corpus.Next.Pricing.Refund, key: :price, spec: nil}

      for seed <- 1..3 do
        on = Engine.Next.run(entry, seed, 200)
        assert on.found? and on.bug_fired?, "seed #{seed}"
        assert on.kept == [site]

        off = Engine.Next.run(%{entry | bug: nil}, seed, 200)
        refute off.found?
        assert off.fires == 0
      end
    end

    @tag :patched_stream_data
    test "on the source engine, finds the bug with it firing and keeps no site", %{
      entries: entries
    } do
      entry = Map.fetch!(entries, "nested_price")

      for seed <- 1..3 do
        on = Engine.NextSource.run(entry, seed, 200)
        assert on.found? and on.bug_fired?, "seed #{seed}"
        assert on.kept == []

        off = Engine.NextSource.run(%{entry | bug: nil}, seed, 200)
        refute off.found?
        assert off.fires == 0
      end
    end
  end

  # Runs `fun` capturing stdout; returns `{fun's result, stdout}`.
  defp with_stdout(fun) do
    parent = self()
    output = capture_io(fn -> send(parent, {:result, fun.()}) end)
    assert_received {:result, result}
    {result, output}
  end
end
