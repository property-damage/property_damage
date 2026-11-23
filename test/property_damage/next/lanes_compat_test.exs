defmodule PropertyDamage.Next.LanesCompatTest do
  # A plan with one lane is the plan the engine built before it had lanes:
  # the same steps, entries, draw order and saved content, the same shrink,
  # and a saved journal without a lanes field loads as a one-lane journal.
  # The prefix of a two-lane plan is the one-lane plan of the same seed.
  #
  # async: false because the corpus support files load once for the whole VM.
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag timeout: 300_000

  alias PropertyDamage.Corpus.Loader
  alias PropertyDamage.Next
  alias PropertyDamage.Next.Engine.{Native, StreamDataSource}
  alias PropertyDamage.Next.{Journal, Placeholder}
  alias PropertyDamage.Next.Test.Lanes
  alias PropertyDamage.Next.Test.Lanes.RecordingEngine
  alias PropertyDamage.Next.Test.Shrink
  alias PropertyDamage.Next.Test.Shrink.{Stock, Till}

  @corpus "corpus/next"
  @seeds 1..20
  @format :property_damage_next_journal

  setup_all do
    {:ok, entries} = Loader.load(@corpus)

    one_lane =
      Enum.filter(entries, fn entry ->
        entry.skip == nil and entry.expect == nil and Keyword.get(entry.run_opts, :lanes, 1) == 1
      end)

    {:ok, entries: one_lane}
  end

  defp plan_opts(entry, extra) do
    entry.run_opts
    |> Keyword.take([:engine, :dependent_stream_data])
    |> Keyword.merge(max_steps: entry.max_commands)
    |> Keyword.merge(extra)
  end

  defp content(journal) do
    {@format, 3, content} = :erlang.binary_to_term(Journal.to_binary(journal))
    content
  end

  defp prefix_key?(key), do: match?({0, _slot}, elem(key, 0))

  describe "one lane given explicitly" do
    for engine <- [Native, StreamDataSource] do
      @engine engine
      if engine == StreamDataSource, do: @tag(:patched_stream_data)

      test "builds the plan built without the option, with no lanes and no schedule, on #{inspect(engine)}",
           %{entries: entries} do
        assert entries != []

        for entry <- entries, seed <- @seeds do
          without = Next.plan(entry.model, seed, plan_opts(entry, engine: @engine))
          with_one = Next.plan(entry.model, seed, plan_opts(entry, engine: @engine, lanes: 1))

          assert {entry.name, seed, with_one} == {entry.name, seed, without}
          assert Lanes.get(with_one.journal, :lanes) == nil
          assert Lanes.get(with_one, :schedule) == %{}
          assert Journal.to_binary(with_one.journal) == Journal.to_binary(without.journal)

          assert content(with_one.journal) |> Map.keys() |> Enum.sort() ==
                   [:entries, :fingerprint, :max_steps, :seed]
        end
      end
    end
  end

  describe "the prefix of a two-lane plan" do
    test "has the one-lane plan's steps and entries, drawn in the same order before any lane key",
         %{entries: entries} do
      for entry <- entries, seed <- @seeds do
        Lanes.drawn_keys()
        one = Next.plan(entry.model, seed, plan_opts(entry, engine: RecordingEngine))
        one_drawn = Lanes.drawn_keys()
        two = Next.plan(entry.model, seed, plan_opts(entry, engine: RecordingEngine, lanes: 2))
        two_drawn = Lanes.drawn_keys()

        prefix_steps = Enum.filter(two.steps, &match?(%{key: {0, _slot}}, &1))
        prefix_entries = Map.filter(two.journal.entries, fn {key, _entry} -> prefix_key?(key) end)

        assert {entry.name, seed, prefix_steps} == {entry.name, seed, one.steps}
        assert prefix_entries == one.journal.entries
        assert Enum.take(two_drawn, length(one_drawn)) == one_drawn
        refute two_drawn |> Enum.drop(length(one_drawn)) |> Enum.any?(&prefix_key?/1)
        assert Lanes.get(two.journal, :lanes) == %{count: 2, steps: 3, yields: 1}
      end
    end
  end

  describe "a saved journal without a lanes field" do
    test "loads as a one-lane journal and replays" do
      journal = Next.plan(Lanes.Model, 5, max_steps: 6).journal
      content = Map.take(journal, [:seed, :max_steps, :entries, :fingerprint])
      binary = :erlang.term_to_binary({@format, 3, content})

      loaded = Journal.from_binary(binary, model: Lanes.Model)

      assert Lanes.get(loaded, :lanes) == nil
      assert loaded == journal
      assert Next.plan(Lanes.Model, loaded) == Next.plan(Lanes.Model, journal)
      assert Lanes.get(Next.plan(Lanes.Model, loaded), :schedule) == %{}

      assert {:ok, _} =
               Next.replay(binary,
                 model: Lanes.Model,
                 adapter: Lanes.Adapter,
                 config: %{yields: 0}
               )
    end
  end

  describe "the one-lane shrink" do
    # Captured on the engine before it had lanes, with the shrink runs of the
    # rows that later shrinker candidates moved measured again: per row, the
    # fixture and seed, then the plan number, the shrink runs, the failing
    # step and the final plan's steps as {key, command}.
    @payment_5 %Placeholder{step: {0, 5}, event_index: 0, path: [:payment]}
    @payment_6 %Placeholder{step: {0, 6}, event_index: 0, path: [:payment]}

    @till_1 [
      {{0, 6}, %Till.Pay{amount: 1}},
      {{0, 8}, %Till.Refund{payment: @payment_6}},
      {{0, 10}, %Till.Refund{payment: @payment_6}},
      {{0, 12}, %Till.Refund{payment: @payment_6}},
      {{0, 13}, %Till.Refund{payment: @payment_6}},
      {{0, 14}, %Till.Refund{payment: @payment_6}}
    ]

    @till_2 [
      {{0, 5}, %Till.Pay{amount: 1}},
      {{0, 6}, %Till.Refund{payment: @payment_5}},
      {{0, 7}, %Till.Refund{payment: @payment_5}},
      {{0, 9}, %Till.Refund{payment: @payment_5}},
      {{0, 10}, %Till.Refund{payment: @payment_5}},
      {{0, 13}, %Till.Refund{payment: @payment_5}}
    ]

    @stock [
      {{0, 1}, %Stock.Put{key: :a, size: 3, tag: ""}},
      {{0, 2}, %Stock.Take{key: :a, count: 3}}
    ]

    @amount [{{0, 1}, %Shrink.Amount{amount: 37}}]
    @split [{{0, 1}, %Shrink.Split{cut: 1, rest: 100}}]
    @note [{{0, 1}, %Shrink.Note{text: "aa"}}]

    @rows %{
      Native => [
        {:amount, 1, 1, 20, {0, 1}, @amount},
        {:amount, 2, 1, 19, {0, 1}, @amount},
        {:split, 1, 11, 16, {0, 1}, @split},
        {:split, 2, 7, 18, {0, 1}, @split},
        {:note, 1, 2, 16, {0, 1}, @note},
        {:note, 2, 1, 21, {0, 1}, @note},
        {:till, 1, 2, 34, {0, 14}, @till_1},
        {:till, 2, 1, 35, {0, 13}, @till_2},
        {:stock, 1, 1, 24, {0, 2}, @stock},
        {:stock, 2, 1, 26, {0, 2}, @stock}
      ],
      StreamDataSource => [
        {:amount, 1, 1, 20, {0, 1}, @amount},
        {:amount, 2, 1, 20, {0, 1}, @amount},
        {:split, 1, 3, 15, {0, 1}, @split},
        {:split, 2, 1, 16, {0, 1}, @split},
        {:note, 1, 1, 16, {0, 1}, @note},
        {:note, 2, 1, 26, {0, 1}, @note},
        {:till, 1, 2, 34, {0, 14}, @till_1},
        {:till, 2, 1, 35, {0, 13}, @till_2},
        {:stock, 1, 1, 31, {0, 2}, @stock},
        {:stock, 2, 1, 32, {0, 2}, @stock}
      ]
    }

    defp fixture(:amount),
      do: {Shrink.AmountModel, Shrink.Adapter, 1, %{fails?: fn c, _ -> c.amount >= 37 end}}

    defp fixture(:split),
      do: {Shrink.SplitModel, Shrink.Adapter, 1, %{fails?: fn c, _ -> c.rest == 101 - c.cut end}}

    defp fixture(:note),
      do: {Shrink.NoteModel, Shrink.Adapter, 1, %{fails?: fn c, _ -> byte_size(c.text) >= 2 end}}

    defp fixture(:till), do: {Till.Model, Till.Adapter, 14, %{bug: true}}

    defp fixture(:stock) do
      {Stock.Model, Shrink.Adapter, 8,
       %{fails?: fn c, _ -> match?(%Stock.Take{count: n} when n >= 3, c) end}}
    end

    defp shrunk(name, seed, engine, extra) do
      {model, adapter, max_steps, config} = fixture(name)

      {:error, failure} =
        Next.run(
          [
            model: model,
            adapter: adapter,
            seed: seed,
            max_steps: max_steps,
            max_plans: 2_000,
            engine: engine,
            config: config
          ] ++ extra
        )

      steps = Enum.map(failure.plan.steps, &{&1.key, &1.command})
      {name, seed, failure.plan_number, failure.shrink_runs, failure.step, steps}
    end

    for engine <- [Native, StreamDataSource] do
      @engine engine
      if engine == StreamDataSource, do: @tag(:patched_stream_data)

      test "with lanes: 1 makes the shrink runs and reaches the plan and step it did before lanes, on #{inspect(engine)}" do
        for {name, seed, _number, _runs, _step, _steps} = row <- @rows[@engine] do
          assert shrunk(name, seed, @engine, []) == row
          assert shrunk(name, seed, @engine, lanes: 1) == row
        end
      end
    end
  end
end
