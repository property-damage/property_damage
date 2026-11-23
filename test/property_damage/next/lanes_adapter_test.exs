defmodule PropertyDamage.Next.LanesAdapterTest do
  # What an adapter may do in a plan with two lanes: never yield, yield in
  # the prefix, yield up to the :yields option in a lane, acknowledge
  # assigns while another step is open, and fail while another step is
  # open.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.AcknowledgedUnsetAssignError
  alias PropertyDamage.Next.Test.Lanes
  alias PropertyDamage.Next.Test.Lanes.{Ack, Adapter, Deposit, OnceModel, Withdraw}

  @lanes [lanes: 2, lane_steps: 3, yields: 1]

  # The parts of a step when each withdrawal yields `yields` times.
  defp points(%Deposit{id: id}, _yields), do: [{id, 1}]
  defp points(%Withdraw{id: id}, yields), do: for(point <- 1..(yields + 1), do: {id, point})

  defp in_lane(plan, lane), do: Enum.filter(plan.steps, &match?(%{key: {^lane, _slot}}, &1))

  defp replay_points(journal, model, config) do
    config = Map.put(config, :recorder, self())
    result = Next.replay(journal, model: model, adapter: Adapter, config: config)
    assert [%{points: points, teardowns: 1}] = Lanes.executions()
    {result, points}
  end

  # Keeps the points of the given step ids, in the order they ran.
  defp only(points, steps) do
    ids = Enum.map(steps, & &1.command.id)
    Enum.filter(points, fn {id, _point} -> id in ids end)
  end

  describe "an adapter that never yields" do
    test "runs each step of a two-lane plan as one part, prefix first and each lane in slot order" do
      plan = Next.plan(Lanes.Model, 1, [max_steps: 2] ++ @lanes)
      prefix = in_lane(plan, 0)

      {result, points} = replay_points(plan.journal, Lanes.Model, %{yields: 0, bug: :race})

      assert {:ok, _} = result
      assert Enum.sort(points) == Enum.sort(for step <- plan.steps, do: {step.command.id, 1})
      assert Enum.take(points, length(prefix)) == Enum.flat_map(prefix, &points(&1.command, 0))

      for lane <- [1, 2] do
        steps = in_lane(plan, lane)
        assert only(points, steps) == Enum.flat_map(steps, &points(&1.command, 0))
      end
    end

    test "finds no race, since nothing runs between a check and its apply" do
      assert {:ok, _report} =
               Next.run(
                 [
                   model: Lanes.Model,
                   adapter: Adapter,
                   seed: 1,
                   max_steps: 2,
                   max_plans: 100,
                   config: %{yields: 0, bug: :race}
                 ] ++ @lanes
               )
    end
  end

  describe "a yield in the prefix" do
    test "has its continuation called at once in a one-lane plan, however many times the step yields" do
      plan = Next.plan(Lanes.Model, 1, max_steps: 8)
      assert Enum.any?(plan.steps, &match?(%Withdraw{}, &1.command))

      {result, points} = replay_points(plan.journal, Lanes.Model, %{yields: 3})

      assert {:ok, _} = result
      assert points == Enum.flat_map(plan.steps, &points(&1.command, 3))

      assert {:ok, _report} =
               Next.run(
                 model: Lanes.Model,
                 adapter: Adapter,
                 seed: 1,
                 max_steps: 8,
                 max_plans: 20,
                 config: %{yields: 3}
               )
    end

    test "has its continuation called at once in a two-lane plan, before any lane step starts" do
      plan = Next.plan(Lanes.Model, 6, [max_steps: 4] ++ @lanes)
      prefix = in_lane(plan, 0)
      assert Enum.any?(prefix, &match?(%Withdraw{}, &1.command))

      {result, points} = replay_points(plan.journal, Lanes.Model, %{yields: 1})
      expected = Enum.flat_map(prefix, &points(&1.command, 1))

      assert {:ok, _} = result
      assert Enum.take(points, length(expected)) == expected
    end
  end

  describe "yields in a lane" do
    @once [model: OnceModel, adapter: Adapter, seed: 1, max_steps: 1, lanes: 2, lane_steps: 1]

    test "up to the :yields option pass" do
      assert {:ok, _} = Next.run(@once ++ [yields: 2, max_plans: 20, config: %{yields: 2}])
    end

    test "one more than the :yields option fails the step with an ArgumentError" do
      assert {:error, failure} =
               Next.run(@once ++ [yields: 1, max_plans: 1, shrink: false, config: %{yields: 2}])

      assert failure.step in [{1, 1}, {2, 1}]
      assert {:raise, %ArgumentError{message: message}} = failure.reason

      assert message ==
               "#{inspect(Adapter)}.execute/3 yielded more than 1 times in one step of a lane; " <>
                 "raise the :yields option"
    end
  end

  describe "acknowledgments while two steps are open" do
    @ack [max_steps: 0, lanes: 2, lane_steps: 1, yields: 1]

    # A seed whose plan holds Alpha in lane 1 and Beta in lane 2, run as
    # Alpha 1, Beta 1, Alpha 2, Beta 2.
    defp ack_seed do
      Enum.find(1..5_000, fn seed ->
        plan = Next.plan(Ack.Model, seed, @ack)

        match?(
          [%{key: {1, 1}, command: %Ack.Alpha{}}, %{key: {2, 1}, command: %Ack.Beta{}}],
          Enum.sort_by(plan.steps, & &1.key)
        ) and Lanes.get(plan, :schedule) == %{{1, 1} => [0, 1]}
      end)
    end

    defp ack_run(seed, mode) do
      Next.run(
        [
          model: Ack.Model,
          adapter: Ack.Adapter,
          seed: seed,
          max_plans: 1,
          config: %{mode: mode, recorder: self()}
        ] ++ @ack
      )
    end

    test "count for the step whose part made them" do
      seed = ack_seed()
      assert is_integer(seed)

      assert {:ok, report} = ack_run(seed, :own)

      assert [%{points: [{Ack.Alpha, 1}, {Ack.Beta, 1}, {Ack.Alpha, 2}, {Ack.Beta, 2}]}] =
               Lanes.executions()

      assert Enum.sort(report.assigns[Ack.Adapter]) ==
               Enum.sort([
                 %{command: Ack.Alpha, key: :alpha, set: 1, acknowledged: 1},
                 %{command: Ack.Beta, key: :beta, set: 1, acknowledged: 1}
               ])
    end

    test "of an assign only the other open step set raises AcknowledgedUnsetAssignError" do
      seed = ack_seed()
      assert is_integer(seed)

      error = assert_raise AcknowledgedUnsetAssignError, fn -> ack_run(seed, :cross) end

      assert error.key == :beta
      assert error.assigns == [:alpha]
    end
  end

  describe "a failure in lane 2 while lane 1 has an open step" do
    test "never calls lane 1's continuation and tears down once" do
      plan = Next.plan(OnceModel, 1, max_steps: 1, lanes: 2, lane_steps: 1, yields: 1)

      assert [
               %{command: %Deposit{id: d}},
               %{command: %Withdraw{id: a}},
               %{command: %Withdraw{id: b}}
             ] =
               Enum.sort_by(plan.steps, & &1.key)

      # Lane 1 checks, then lane 2 starts and fails at once.
      journal = Lanes.with_schedule(plan.journal, %{{1, 1} => [0, 1]})
      {result, points} = replay_points(journal, OnceModel, %{fail_id: b})

      assert {:error, failure} = result
      assert failure.step == {2, 1}
      assert failure.reason == {:adapter_error, :seeded_failure}
      assert points == [{d, 1}, {a, 1}, {b, 1}]
    end
  end
end
