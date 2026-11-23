defmodule PropertyDamage.Next.LanesShrinkerTest do
  # Drives the shrinker on plans with two lanes through a stand-in build and
  # execute: a journal's live picks are its steps, a schedule entry is an
  # integer the shrinker can lower, and each test's execute answers which
  # step fails. The tests pin which slots the first pass empties, which
  # step counts as the same or an earlier one across lanes, and that a
  # candidate differing only in its schedule is executed.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next.{Journal, Plan, Shrinker, Step}

  @reason {:check, :broken, "broken"}

  defp journal(steps, max_steps, lane_steps, schedule \\ %{}) do
    picks = Map.new(steps, &{{&1, :pick}, {:pick, 1}})

    schedule =
      Map.new(schedule, fn {step, value} -> {{step, :schedule, 1}, {:integer, value, 0..4}} end)

    %Journal{
      seed: 1,
      max_steps: max_steps,
      entries: Map.merge(picks, schedule),
      lanes: %{count: 2, steps: lane_steps, yields: 1}
    }
  end

  defp build(journal) do
    live =
      for({{step, :pick}, {:pick, _}} <- journal.entries, do: step)
      |> Enum.sort()

    lanes = live |> Enum.map(&elem(&1, 0)) |> Enum.filter(&(&1 > 0)) |> Enum.uniq()

    scheduled =
      if length(lanes) == 2,
        do:
          for(
            {1, _slot} = step <- live,
            Map.has_key?(journal.entries, {step, :schedule, 1}),
            do: step
          ),
        else: []

    schedule =
      Map.new(scheduled, fn step ->
        {:integer, value, _range} = journal.entries[{step, :schedule, 1}]
        {step, [value]}
      end)

    plan = %Plan{
      journal: journal,
      steps: Enum.map(live, &%Step{key: &1, spec_id: 1, command: :command}),
      schedule: schedule
    }

    drawn = Enum.map(live, &{&1, :pick}) ++ Enum.map(scheduled, &{&1, :schedule, 1})
    {plan, drawn}
  end

  defp keys(plan), do: Enum.map(plan.steps, & &1.key)

  # Fails at the first step of `order` that the plan holds.
  defp fails_at_first(order), do: fails(for step <- order, do: {step, [step]})

  # Fails at the step of the first rule `{step, needed}` whose needed steps
  # the plan all holds.
  defp fails(rules) do
    fn plan ->
      case Enum.find(rules, fn {_step, needed} -> Enum.all?(needed, &(&1 in keys(plan))) end) do
        nil -> :ok
        {step, _needed} -> {:error, step, @reason}
      end
    end
  end

  defp shrink(journal, step, execute, max_runs \\ 100) do
    {plan, drawn} = build(journal)
    best = %{plan: plan, drawn: drawn, step: step, reason: @reason}
    Shrinker.shrink(best, &build/1, execute, max_runs)
  end

  defp recording do
    test = self()

    fn plan ->
      send(test, {:executed, keys(plan)})
      :ok
    end
  end

  # The steps of the first candidate executed.
  defp first_executed do
    receive do
      {:executed, steps} -> steps
    after
      0 -> nil
    end
  end

  describe "the first pass" do
    test "after a prefix step empties the later prefix slots and every lane slot" do
      steps = [{0, 1}, {0, 2}, {1, 1}, {1, 2}, {2, 1}, {2, 2}]
      shrink(journal(steps, 2, 2), {0, 1}, recording())

      assert first_executed() == [{0, 1}]
    end

    test "after a lane step empties only the later slots of that lane" do
      steps = [{0, 1}, {1, 1}, {1, 2}, {1, 3}, {2, 1}, {2, 2}, {2, 3}]
      shrink(journal(steps, 1, 3), {1, 1}, recording())

      assert first_executed() == [{0, 1}, {1, 1}, {2, 1}, {2, 2}, {2, 3}]
    end
  end

  describe "the same step or an earlier one" do
    test "a prefix step is earlier than a lane step" do
      steps = [{0, 1}, {0, 2}, {1, 1}, {2, 1}]
      execute = fails([{{1, 1}, [{1, 1}, {0, 2}]}, {{0, 2}, [{0, 2}]}])

      {final, _runs} = shrink(journal(steps, 2, 1), {1, 1}, execute)

      assert final.step == {0, 2}
    end

    test "a step of the other lane at a lower slot is earlier" do
      steps = [{0, 1}, {1, 1}, {1, 2}, {2, 1}, {2, 2}, {2, 3}]
      execute = fails([{{2, 3}, [{2, 3}, {1, 2}]}, {{1, 2}, [{1, 2}]}])

      {final, _runs} = shrink(journal(steps, 1, 3), {2, 3}, execute)

      assert final.step == {1, 2}
    end

    test "a step of the other lane at the same slot is not later" do
      steps = [{0, 1}, {1, 1}, {2, 1}]
      execute = fails_at_first([{1, 1}, {2, 1}])

      {final, _runs} = shrink(journal(steps, 1, 1), {1, 1}, execute)

      assert final.step == {2, 1}
    end

    test "a step of the other lane at a higher slot is later" do
      steps = [{0, 1}, {1, 1}, {1, 2}, {2, 1}, {2, 2}, {2, 3}]
      execute = fails_at_first([{1, 2}, {2, 3}])

      {final, _runs} = shrink(journal(steps, 1, 3), {1, 2}, execute)

      assert final.step == {1, 2}
    end
  end

  test "a candidate that changes only the schedule is executed, so a schedule value is lowered" do
    steps = [{0, 1}, {1, 1}, {2, 1}]

    execute = fn plan ->
      case plan.schedule do
        %{{1, 1} => [value]} when value >= 1 -> {:error, {2, 1}, @reason}
        _other -> :ok
      end
    end

    {final, _runs} = shrink(journal(steps, 1, 1, %{{1, 1} => 3}), {2, 1}, execute)

    assert final.plan.schedule == %{{1, 1} => [1]}
  end
end
