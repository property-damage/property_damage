defmodule PropertyDamage.Next.LanesScheduleTest do
  # A plan with two lanes runs its lanes' steps on a schedule that PD draws
  # into the journal: the same journal gives the same interleaving, in this
  # VM and in a fresh one, on both engines. The adapter records each part of
  # a step it runs, `{id, point}`, so a test reads the interleaving.
  use ExUnit.Case, async: true

  @moduletag timeout: 180_000

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Engine.{Native, StreamDataSource}
  alias PropertyDamage.Next.Journal
  alias PropertyDamage.Next.Test.Lanes
  alias PropertyDamage.Next.Test.Lanes.{Adapter, Deposit, OnceModel, RecordingEngine, Withdraw}

  @lanes [lanes: 2, lane_steps: 3, yields: 1]

  defp lane(plan, lane), do: Enum.filter(plan.steps, &match?(%{key: {^lane, _slot}}, &1))

  defp schedule_keys(journal) do
    journal.entries |> Map.keys() |> Enum.filter(&match?({_step, :schedule, _point}, &1))
  end

  # The parts a step of the lane adapter has with one yield: a deposit is
  # one part, a withdrawal two.
  defp points(%Deposit{id: id}), do: [{id, 1}]
  defp points(%Withdraw{id: id}), do: [{id, 1}, {id, 2}]

  defp replay_points(journal, model, config \\ %{}) do
    config = Map.put(config, :recorder, self())
    result = Next.replay(journal, model: model, adapter: Adapter, config: config)
    assert [%{points: points, teardowns: 1}] = Lanes.executions()
    {result, points}
  end

  defp ids(plan), do: Enum.map(plan.steps, & &1.command.id)

  describe "drawing the schedule" do
    for engine <- [Native, StreamDataSource] do
      @engine engine
      if engine == StreamDataSource, do: @tag(:patched_stream_data)

      test "the same seed and options build the same steps, schedule and journal on #{inspect(engine)}" do
        for seed <- 1..10 do
          opts = [max_steps: 3, engine: @engine] ++ @lanes
          first = Next.plan(Lanes.Model, seed, opts)
          again = Next.plan(Lanes.Model, seed, opts)

          assert first.steps == again.steps
          assert Lanes.get(first, :schedule) == Lanes.get(again, :schedule)
          assert first.journal == again.journal
        end
      end

      if engine == StreamDataSource, do: @tag(:patched_stream_data)

      test "one schedule key per point of each lane-1 step, drawn last, with values in range on #{inspect(engine)}" do
        for seed <- 1..30 do
          opts = [max_steps: 3, engine: @engine] ++ @lanes
          plan = Next.plan(Lanes.Model, seed, opts)
          lane1 = lane(plan, 1)

          # Every slot of this model offers a command, so both lanes hold steps.
          assert lane1 != [] and lane(plan, 2) != []

          expected = for %{key: step} <- lane1, point <- 1..2, do: {step, :schedule, point}
          assert Enum.sort(schedule_keys(plan.journal)) == Enum.sort(expected)

          values =
            Map.new(lane1, fn %{key: step} ->
              {step,
               for(point <- 1..2, do: elem(plan.journal.entries[{step, :schedule, point}], 1))}
            end)

          assert Lanes.get(plan, :schedule) == values
          assert values |> Map.values() |> List.flatten() |> Enum.all?(&(&1 in 0..6))
        end
      end
    end

    test "the schedule keys are drawn after every key of both lanes, by lane-1 slot, then point" do
      for seed <- 1..10 do
        Lanes.drawn_keys()
        plan = Next.plan(Lanes.Model, seed, [max_steps: 3, engine: RecordingEngine] ++ @lanes)
        drawn = Lanes.drawn_keys()

        expected = for %{key: step} <- lane(plan, 1), point <- 1..2, do: {step, :schedule, point}
        assert expected != []
        assert Enum.take(drawn, -length(expected)) == expected

        refute Enum.any?(
                 Enum.drop(drawn, -length(expected)),
                 &match?({_step, :schedule, _point}, &1)
               )
      end
    end

    test "a plan with an empty lane draws no schedule" do
      plan = Next.plan(Lanes.Model, 4, [max_steps: 2] ++ @lanes)
      assert lane(plan, 2) != []

      entries =
        plan.journal.entries
        |> Map.drop(schedule_keys(plan.journal))
        |> Map.merge(Map.new(1..3, &{{{2, &1}, :pick}, {:empty}}))

      rebuilt = Next.plan(Lanes.Model, %{plan.journal | entries: entries})

      assert lane(rebuilt, 2) == []
      assert lane(rebuilt, 1) == lane(plan, 1)
      assert schedule_keys(rebuilt.journal) == []
      assert Lanes.get(rebuilt, :schedule) == %{}
    end
  end

  describe "running a schedule" do
    test "with every schedule value 0, the prefix runs, then all of lane 1, then all of lane 2" do
      plan = Next.plan(Lanes.Model, 2, [max_steps: 2] ++ @lanes)
      assert lane(plan, 1) != [] and lane(plan, 2) != []
      assert Enum.uniq(ids(plan)) == ids(plan)

      zeros = Map.new(lane(plan, 1), &{&1.key, [0, 0]})
      journal = Lanes.with_schedule(plan.journal, zeros)
      assert Lanes.get(Next.plan(Lanes.Model, journal), :schedule) == zeros

      expected = plan.steps |> Enum.sort_by(& &1.key) |> Enum.flat_map(&points(&1.command))

      assert {{:ok, _}, ^expected} = replay_points(journal, Lanes.Model)
    end

    test "one withdrawal per lane interleaves as each schedule says" do
      plan = Next.plan(OnceModel, 1, max_steps: 1, lanes: 2, lane_steps: 1, yields: 1)

      assert [
               %{key: {0, 1}, command: %Deposit{id: d}},
               %{key: {1, 1}, command: %Withdraw{id: a}},
               %{key: {2, 1}, command: %Withdraw{id: b}}
             ] = Enum.sort_by(plan.steps, & &1.key)

      assert Enum.uniq([d, a, b]) == [d, a, b]

      cases = [
        {[0, 1], [{d, 1}, {a, 1}, {b, 1}, {a, 2}, {b, 2}]},
        {[1, 0], [{d, 1}, {b, 1}, {a, 1}, {a, 2}, {b, 2}]},
        {[2, 2], [{d, 1}, {b, 1}, {b, 2}, {a, 1}, {a, 2}]}
      ]

      for {values, expected} <- cases do
        journal = Lanes.with_schedule(plan.journal, %{{1, 1} => values})
        {{:ok, _}, points} = replay_points(journal, OnceModel)
        assert {values, points} == {values, expected}
      end
    end

    test "a two-lane failure's journal replays, as a struct and as a binary, in the same order to the same failure" do
      config = %{bug: :race, recorder: self()}

      assert {:error, failure} =
               Next.run(
                 [
                   model: Lanes.Model,
                   adapter: Adapter,
                   config: config,
                   seed: 1,
                   max_steps: 2,
                   max_plans: 500
                 ] ++ @lanes
               )

      final_points = Lanes.executions() |> List.last() |> Map.fetch!(:points)

      # Overdrawing needs both withdrawals checked before either applies, so
      # the failure is at a lane step and the schedule is not empty.
      assert {lane, _slot} = failure.step
      assert lane in [1, 2]
      assert Lanes.get(failure.plan, :schedule) != %{}

      for journal <- [failure.journal, Journal.to_binary(failure.journal)] do
        {{:error, again}, points} = replay_points(journal, Lanes.Model, %{bug: :race})

        assert points == final_points
        assert again.plan.steps == failure.plan.steps
        assert Lanes.get(again.plan, :schedule) == Lanes.get(failure.plan, :schedule)
        assert again.reason == failure.reason
        assert again.step == failure.step
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

      on_exit(fn ->
        try do
          :peer.stop(peer)
        catch
          :exit, _ -> :ok
        end
      end)

      %{peer: peer}
    end

    test "a two-lane journal naming only PD's atoms loads without the model", %{peer: peer} do
      content = %{
        seed: 1,
        max_steps: 0,
        entries: %{{{1, 1}, :schedule, 1} => {:integer, 0, 0..2}},
        fingerprint: nil,
        lanes: %{count: 2, steps: 1, yields: 1}
      }

      binary = :erlang.term_to_binary({:property_damage_next_journal, 3, content})
      remote = :peer.call(peer, Journal, :from_binary, [binary], 60_000)

      assert Lanes.get(remote, :lanes) == %{count: 2, steps: 1, yields: 1}
      assert remote.entries == content.entries
      assert remote == Journal.from_binary(binary)
    end

    for engine <- [Native, StreamDataSource] do
      @engine engine
      if engine == StreamDataSource, do: @tag(:patched_stream_data)

      test "a two-lane failure's binary replays to the identical plan, schedule, reason and step on #{inspect(engine)}",
           %{peer: peer} do
        config = %{bug: :race}

        assert {:error, failure} =
                 Next.run(
                   [
                     model: Lanes.Model,
                     adapter: Adapter,
                     config: config,
                     seed: 3,
                     max_steps: 2,
                     max_plans: 500,
                     engine: @engine
                   ] ++ @lanes
                 )

        assert Lanes.get(failure.journal, :lanes) == %{count: 2, steps: 3, yields: 1}
        assert schedule_keys(failure.journal) != []
        binary = Journal.to_binary(failure.journal)

        remote =
          :peer.call(
            peer,
            Lanes.Peer,
            :replay,
            [binary, Lanes.Model, Adapter, config, @engine],
            60_000
          )

        assert remote.journal == failure.journal
        assert remote.plan.steps == failure.plan.steps
        assert Lanes.get(remote.plan, :schedule) == Lanes.get(failure.plan, :schedule)
        assert {:error, again} = remote.replayed
        assert again.plan.steps == failure.plan.steps
        assert again.reason == failure.reason
        assert again.step == failure.step
      end
    end
  end
end
