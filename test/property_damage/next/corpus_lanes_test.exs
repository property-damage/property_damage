defmodule PropertyDamage.Next.CorpusLanesTest do
  # The racing refunds entry of the next corpus: two refunds of one payment,
  # each checked in one call and applied in a later one, run in two lanes.
  # The corpus engines find the race on every seed and find nothing with the
  # bug off. Each shrinks the failing plans, but not always to the entry's
  # smallest plan: the seeds that miss it are pinned below. The same entry
  # run in one lane never finds the race; each final journal replays to the
  # identical plan in a fresh VM.
  #
  # async: false because the corpus support files load once for the whole VM.
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag timeout: 900_000

  alias PropertyDamage.Corpus.{Engine, Entry, FireLog, Loader, Measure}
  alias PropertyDamage.Next
  alias PropertyDamage.Next.Engine.{Native, StreamDataSource}
  alias PropertyDamage.Next.Journal
  alias PropertyDamage.Next.Test.Lanes

  @corpus "corpus/next"
  @name "racing_refunds"
  @seeds 1..20
  @plan_cap 200

  setup_all do
    {:ok, [%Entry{name: @name} = entry]} = Loader.load(@corpus, [@name])
    {:ok, entry: entry}
  end

  defp seeds_where(rows, predicate), do: for(row <- rows, predicate.(row), do: row.seed)

  # A failing run of the entry with the options the corpus engine passes.
  defp failing_run(entry, seed, engine) do
    {:ok, log} = FireLog.start_link()

    try do
      Next.run(
        [
          model: entry.model,
          adapter: entry.adapter,
          config: %{bug: entry.bug, fire_log: log},
          seed: seed,
          max_steps: entry.max_commands,
          max_plans: @plan_cap,
          engine: engine
        ] ++ entry.run_opts
      )
    after
      FireLog.stop(log)
    end
  end

  for {engine, corpus_engine, misses} <- [
        {Native, Engine.Next, [8]},
        {StreamDataSource, Engine.NextSource, [17]}
      ] do
    @corpus_engine corpus_engine
    @engine engine
    @misses misses

    if engine == StreamDataSource, do: @tag(:patched_stream_data)

    test "#{inspect(corpus_engine)} finds the race on every seed, the same twice, and misses the smallest plan only on the pinned seeds",
         %{entry: entry} do
      entry = %{entry | engine: @corpus_engine}
      measure = fn -> Enum.map(@seeds, &Measure.seed(entry, &1, @plan_cap)) end
      rows = measure.()

      assert rows == measure.()
      assert seeds_where(rows, &(not &1.found?)) == []
      assert seeds_where(rows, & &1.unexplained?) == []

      # The lists are the measured misses. A seed lost or gained fails here.
      assert seeds_where(rows, &(not &1.reached_minimum?)) == @misses
    end

    # The shrinker misses the smallest plan on the pinned seeds. It lowers
    # two integer values by the same amount, but it has no candidate that
    # removes a step of a lane and moves that step's schedule value to a
    # later step of the same lane, and the miss of PD's own engine on seed 8
    # needs one. When an engine's pinned list is empty, this tag comes off
    # for that engine.
    @tag :known_defect
    if engine == StreamDataSource, do: @tag(:patched_stream_data)

    test "#{inspect(corpus_engine)} shrinks the race to the smallest plan on every seed",
         %{entry: entry} do
      entry = %{entry | engine: @corpus_engine}
      rows = Enum.map(@seeds, &Measure.seed(entry, &1, @plan_cap))

      assert seeds_where(rows, &(not &1.reached_minimum?)) == []
    end

    if engine == StreamDataSource, do: @tag(:patched_stream_data)

    test "#{inspect(corpus_engine)} finds nothing with the bug off", %{entry: entry} do
      off = %{entry | bug: nil}

      for seed <- @seeds do
        result = @corpus_engine.run(off, seed, @plan_cap)

        refute result.found?, "seed #{seed}: failed with the bug off"
        assert result.fires == 0
      end
    end

    if engine == StreamDataSource, do: @tag(:patched_stream_data)

    test "in one lane, the entry's model and adapter never find the race on #{inspect(engine)}",
         %{entry: entry} do
      for seed <- @seeds do
        {:ok, log} = FireLog.start_link()

        try do
          result =
            Next.run(
              model: entry.model,
              adapter: entry.adapter,
              config: %{bug: entry.bug, fire_log: log},
              seed: seed,
              lanes: 1,
              max_steps: 10,
              max_plans: @plan_cap,
              engine: @engine
            )

          assert {seed, elem(result, 0)} == {seed, :ok}
          assert FireLog.total(log) == 0
        after
          FireLog.stop(log)
        end
      end
    end
  end

  describe "in a fresh VM" do
    # The peer shares this VM's code path. The directory this VM loaded
    # StreamData from, the patched copy when the patch is active, goes to
    # the head of the peer's path before the peer loads StreamData.
    setup do
      paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})
      stream_data = StreamData |> :code.which() |> Path.dirname() |> String.to_charlist()
      false = :peer.call(peer, :code, :is_loaded, [StreamData])
      true = :peer.call(peer, :code, :add_patha, [stream_data])
      # Loading the entry compiles its support files, which needs Elixir running.
      {:ok, _apps} = :peer.call(peer, :application, :ensure_all_started, [:elixir])

      on_exit(fn ->
        try do
          :peer.stop(peer)
        catch
          :exit, _ -> :ok
        end
      end)

      %{peer: peer}
    end

    for engine <- [Native, StreamDataSource] do
      @engine engine
      if engine == StreamDataSource, do: @tag(:patched_stream_data)

      test "each final journal of the race replays to the identical plan on #{inspect(engine)}",
           %{entry: entry, peer: peer} do
        dir = Path.expand(@corpus)

        for seed <- @seeds do
          assert {:error, failure} = failing_run(entry, seed, @engine)
          binary = Journal.to_binary(failure.journal)

          remote =
            :peer.call(peer, Lanes.Peer, :replay_entry, [dir, @name, binary, @engine], 120_000)

          assert {seed, remote.journal} == {seed, failure.journal}
          assert remote.plan.steps == failure.plan.steps
          assert Lanes.get(remote.plan, :schedule) == Lanes.get(failure.plan, :schedule)
          assert {:error, again} = remote.replayed
          assert again.plan.steps == failure.plan.steps
          assert again.step == failure.step
          assert again.reason == failure.reason
        end
      end
    end
  end
end
