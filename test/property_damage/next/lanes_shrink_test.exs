defmodule PropertyDamage.Next.LanesShrinkTest do
  # The shrinker lowers a schedule value like any other journal entry. A
  # race keeps a step in each lane and a schedule that interleaves them; a
  # failure that one lane reaches on its own shrinks to one lane, or to the
  # schedule that runs lane 1 to its end before lane 2.
  #
  # The race fixture deposits once in the prefix and withdraws once in each
  # lane, each withdrawal yielding once between its check and its apply.
  # With values [v1, v2] for the two parts of the lane-1 withdrawal, the
  # race overdraws the account for [0, 1], [0, 2], [1, 0], [1, 1] and
  # [1, 2], and [0, 0] passes: both checks must run before either apply.
  # Lowering one value at a time from a failing schedule ends at [0, 1] or
  # [1, 0]; it ends at [0, 1] whenever v1 starts at 0.
  use ExUnit.Case, async: true

  @moduletag timeout: 300_000

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Engine.{Native, StreamDataSource}
  alias PropertyDamage.Next.Test.Lanes
  alias PropertyDamage.Next.Test.Lanes.{Adapter, Deposit, OnceModel, Withdraw}

  @once [
    model: OnceModel,
    adapter: Adapter,
    max_steps: 1,
    lanes: 2,
    lane_steps: 1,
    yields: 1,
    max_plans: 200
  ]

  defp lanes_with_steps(plan),
    do: plan.steps |> Enum.map(&elem(&1.key, 0)) |> Enum.filter(&(&1 > 0)) |> Enum.uniq()

  defp all_zero?(schedule),
    do: schedule |> Map.values() |> List.flatten() |> Enum.all?(&(&1 == 0))

  defp check_class({:check, name, _message}), do: {:check, name}

  for engine <- [Native, StreamDataSource] do
    @engine engine

    if engine == StreamDataSource, do: @tag(:patched_stream_data)

    test "a schedule value the race does not need is lowered, to a smallest failing schedule, on #{inspect(engine)}" do
      results =
        for seed <- 1..20 do
          config = %{bug: :race}

          assert {:error, failure} =
                   Next.run(@once ++ [seed: seed, engine: @engine, config: config])

          %{{1, 1} => original} = Lanes.schedule_of(failure.original.journal)
          %{{1, 1} => final} = Lanes.schedule_of(failure.journal)

          assert Lanes.get(failure.plan, :schedule) == %{{1, 1} => final}

          assert [
                   %{key: {0, 1}, command: %Deposit{amount: 1}},
                   %{key: {1, 1}, command: %Withdraw{amount: 1}},
                   %{key: {2, 1}, command: %Withdraw{amount: 1}}
                 ] = Enum.sort_by(failure.plan.steps, & &1.key)

          assert check_class(failure.reason) == {:check, :never_overdrawn}
          assert check_class(failure.original.reason) == {:check, :never_overdrawn}

          # No value rose, the final schedule is one from which lowering any
          # one value passes, and a start at v1 = 0 ends at the smallest.
          assert {seed, Enum.zip_with(final, original, &(&1 <= &2))} == {seed, [true, true]}
          assert {seed, final} in [{seed, [0, 1]}, {seed, [1, 0]}]
          if hd(original) == 0, do: assert({seed, final} == {seed, [0, 1]})

          if original not in [[0, 1], [1, 0]],
            do: assert({seed, final < original} == {seed, true})

          assert {:error, again} =
                   Next.replay(failure.journal,
                     model: OnceModel,
                     adapter: Adapter,
                     config: config,
                     engine: @engine
                   )

          assert again.step == failure.step
          assert again.reason == failure.reason

          {original, final}
        end

      # Some seed's first failing plan held a value the race did not need.
      assert Enum.any?(results, fn {original, final} -> final < original end)
    end
  end

  test "on the final plan of a race, the schedule of all zeros passes and each smallest failing schedule fails" do
    assert {:error, failure} = Next.run(@once ++ [seed: 1, config: %{bug: :race}])

    for {values, expected} <- [{[0, 0], :ok}, {[0, 1], :error}, {[1, 0], :error}] do
      journal = Lanes.with_schedule(failure.journal, %{{1, 1} => values})

      result =
        Next.replay(journal, model: OnceModel, adapter: Adapter, config: %{bug: :race})

      assert {values, elem(result, 0)} == {values, expected}
    end
  end

  for engine <- [Native, StreamDataSource] do
    @engine engine

    if engine == StreamDataSource, do: @tag(:patched_stream_data)

    test "a failure one lane reaches alone shrinks to one lane or to a schedule of zeros, on #{inspect(engine)}" do
      for seed <- 1..10 do
        assert {:error, failure} =
                 Next.run(@once ++ [seed: seed, engine: @engine, config: %{bug: :full_twice}])

        assert check_class(failure.reason) == {:check, :never_overdrawn}
        schedule = Lanes.get(failure.plan, :schedule)
        lanes = lanes_with_steps(failure.plan)

        assert {seed, length(lanes) < 2 or all_zero?(schedule)} == {seed, true}
      end
    end

    if engine == StreamDataSource, do: @tag(:patched_stream_data)

    test "a race keeps a step in each lane and a schedule that is not all zeros, on #{inspect(engine)}" do
      for seed <- 1..5 do
        assert {:error, failure} =
                 Next.run(
                   model: Lanes.Model,
                   adapter: Adapter,
                   seed: seed,
                   max_steps: 4,
                   lanes: 2,
                   lane_steps: 3,
                   yields: 1,
                   max_plans: 500,
                   engine: @engine,
                   config: %{bug: :race}
                 )

        schedule = Lanes.get(failure.plan, :schedule)

        assert {seed, Enum.sort(lanes_with_steps(failure.plan))} == {seed, [1, 2]}
        assert {seed, all_zero?(schedule)} == {seed, false}
      end
    end
  end
end
