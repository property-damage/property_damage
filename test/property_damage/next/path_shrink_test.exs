defmodule PropertyDamage.Next.PathShrinkTest do
  # A divergence shrinks like any other failure: the plain path is the first
  # of a step's paths, so lowering the pick moves a step toward its command
  # as drawn, and a value a path draws is lowered as any drawn value is.
  #
  # The smallest plan of the refund system, derived by hand: a refund of 1
  # has only its plain path, so a split needs a refund of 2, which needs a
  # payment of 2; the split is 1 + 1. The reference credits 2, the variant
  # credits 1 and then, for the payment's second refund, 0.
  #
  # The totals observed change with every payment and refund amount, so the
  # divergence found first carries other values than the smallest one. Two
  # divergences of one observation are the same kind of failure whatever
  # values they carry; a shrink that compared the values too would keep no
  # candidate that lowers an amount.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Failure
  alias PropertyDamage.Next.Test.Paths
  alias PropertyDamage.Next.Test.Paths.{Pay, Recorded, Refund, SplitModel}

  @seeds 1..5

  defp run(seed) do
    Next.run(
      model: SplitModel,
      adapter: Paths.Adapter,
      seed: seed,
      max_steps: 8,
      max_plans: 200,
      config: %{bug: :short_second_refund}
    )
  end

  defp failure!(seed) do
    assert {:error, %Failure{} = failure} = run(seed)
    failure
  end

  # Asserts that `failure` holds the smallest plan derived above.
  defp assert_smallest(%Failure{plan: plan, journal: journal} = failure) do
    assert [%{command: %Pay{amount: 2}} = pay, %{command: %Refund{amount: 2} = refund} = split] =
             plan.steps

    assert Recorded.path(pay) == {0, [pay.command]}
    assert Recorded.path(split) == {1, [%{refund | amount: 1}, %{refund | amount: 1}]}

    assert journal.entries[{pay.key, :path}] == {:member, 0, 0}
    assert journal.entries[{split.key, :path}] == {:member, 1, 1}
    assert journal.entries[{split.key, :path, :first}] == {:integer, 1, 1..1}

    assert failure.step == split.key

    assert failure.reason ==
             {:diverged, :totals, split.key, %{paid: 2, refunded: 2}, %{paid: 2, refunded: 1}}
  end

  test "a divergence shrinks to the smallest plan: payment 2, refund 2 split as 1 + 1" do
    for seed <- @seeds, do: assert_smallest(failure!(seed))
  end

  test "every step whose split the failure does not need ends on its plain path" do
    lowered =
      for seed <- @seeds do
        failure = failure!(seed)
        [needed] = Enum.filter(failure.plan.steps, &(&1.key == failure.step))

        assert Recorded.pick(needed) != 0

        for step <- failure.plan.steps, step.key != failure.step do
          assert Recorded.pick(step) == 0
          assert failure.journal.entries[{step.key, :path}] == {:member, 0, 0}
        end

        # Whether the plan found first held a step other than the failing
        # one on a path other than its plain one.
        Enum.any?(failure.original.plan.steps, fn step ->
          step.key != failure.original.step and Recorded.pick(step) not in [0, nil]
        end)
      end

    assert Enum.any?(lowered), "no plan found first held a split it did not need"
  end

  test "a divergence carrying other values than the smallest still shrinks to the smallest plan" do
    moved =
      for seed <- @seeds do
        failure = failure!(seed)
        {:diverged, :totals, _step, reference, variant} = failure.original.reason

        assert_smallest(failure)

        {reference, variant} != {%{paid: 2, refunded: 2}, %{paid: 2, refunded: 1}}
      end

    assert Enum.count(moved, & &1) >= 3
  end

  test "two shrinks of the same run give the same final plan and the same number of shrink runs" do
    for seed <- [1, 2] do
      first = failure!(seed)
      second = failure!(seed)

      assert second.plan.steps == first.plan.steps
      assert second.journal == first.journal
      assert second.reason == first.reason
      assert second.shrink_runs == first.shrink_runs
      assert first.shrink_runs > 0
    end
  end

  test "the final journal replays to the final plan and the same divergence" do
    failure = failure!(3)

    assert {:error, %Failure{} = again} =
             Next.replay(failure.journal,
               model: SplitModel,
               adapter: Paths.Adapter,
               config: %{bug: :short_second_refund}
             )

    assert again.plan.steps == failure.plan.steps
    assert again.step == failure.step
    assert again.reason == failure.reason
  end
end
