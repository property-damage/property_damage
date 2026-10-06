defmodule PropertyDamage.ExpansionCoverageTest do
  # Coverage recorded from a failure report counts what the reference target
  # executed: the leaves of the roots it ran as expansions under their own
  # modules, and each expanded root by the entry it chose.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Coverage, FailureReport}
  alias PropertyDamage.Test.ExpansionRun, as: X
  alias PropertyDamage.Test.ExpansionRun.{Credit, Refund, SecondCreditFails, Totals}

  test "a failure report's coverage counts the reference's leaves and entries" do
    model =
      X.define_model!(ExpansionCoverage.LeafFailure,
        expansions: [{Refund, &X.refund_rewrite/2}],
        checks: [Totals, SecondCreditFails]
      )

    seed =
      X.find_seed(model, 6, 1..2_000, &Enum.any?(&1, fn root -> match?(%Refund{}, root) end)) ||
        flunk("no seed in 1..2000 generates a Refund root")

    assert {:error, %FailureReport{} = report} =
             PropertyDamage.run(
               model: model,
               targets: [X.target("solo", nil)],
               compare: [converge_within: 30],
               seed: seed,
               max_runs: 1,
               max_commands: 6,
               shrink: false,
               validate: false
             )

    ran = Map.fetch!(report.expansions, "solo")
    executed = Enum.flat_map(ran, & &1.leaves)
    assert Credit in executed

    tracker = Coverage.from_result({:error, report}, model)

    assert tracker.command_counts == Enum.frequencies(executed)
    assert MapSet.member?(tracker.command_modules, Credit)
    assert Coverage.command_coverage(tracker) <= 100.0

    rewrites = Enum.count(ran, &(&1.entry == "Refund[0]"))

    assert tracker |> Coverage.stats() |> Map.fetch!(:expansion_counts) ==
             %{Refund => %{"Refund[0]" => rewrites}}
  end
end
