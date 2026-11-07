defmodule PropertyDamage.AnalysisFidelityTest do
  @moduledoc """
  `Analysis.isolate_trigger/2` lists the field values that make a failure go
  away, so each value must be judged by running the commands the way the
  campaign ran them.

  The fixture (`PropertyDamage.Test.BoundaryDrain`) charges the account after
  every command step, through an injector the target declares. The campaign
  overdraws on the third command, with an amount of 15, because both earlier
  charges have folded by then. A rerun that has no injector, or folds a charge
  after the next command instead of at the boundary, sees a larger credit and
  accepts amounts that still fail.
  """
  # The fixture's event box is one named process.
  use ExUnit.Case, async: false

  alias PropertyDamage.{Analysis, FailureReport, Sequence}
  alias PropertyDamage.Test.BoundaryDrain, as: Drain
  alias PropertyDamage.Test.RunnerSupport

  @entries [{Drain.Adapter, injectors: [Drain.Injector]}]

  setup do
    start_supervised!(%{id: Drain.Box, start: {Drain.Box, :start, []}})

    {:error, %FailureReport{} = report} =
      PropertyDamage.run(
        model: Drain.Model,
        targets: @entries,
        seed: 1,
        max_runs: 1,
        max_commands: 4,
        run_nonce: 1,
        verbose: false,
        replay_dir: false
      )

    %{report: report}
  end

  # The values `isolate_trigger/2` tries for an integer field.
  defp candidates(amount) do
    [0, 1, amount - 1, amount + 1, div(amount, 2)]
    |> Enum.filter(&(&1 != amount and &1 >= 0))
    |> Enum.uniq()
  end

  # The candidates that leave the shrunk sequence passing when it runs through
  # the lockstep scheduler, as the campaign runs it.
  defp passing_candidates(report) do
    shrunk = FailureReport.shrunk_sequence(report)
    commands = Sequence.to_list(shrunk)
    {trigger, earlier} = List.pop_at(commands, -1)

    for amount <- candidates(trigger.amount),
        sequence = candidate(earlier ++ [%{trigger | amount: amount}], shrunk),
        outcome = run(sequence),
        is_nil(outcome.failure) do
      amount
    end
    |> Enum.sort()
  end

  defp candidate(commands, shrunk) do
    commands
    |> Sequence.linear()
    |> Sequence.with_registry(shrunk.registry)
    |> Map.put(:setup, shrunk.setup)
  end

  defp run(sequence) do
    Drain.Box.reset()

    RunnerSupport.scheduler_run(
      %{model: Drain.Model, targets: RunnerSupport.targets(@entries), sequence: sequence},
      seed: 1
    )
  end

  describe "the fixture" do
    test "control: the campaign overdraws on the third command with an amount of 15", %{
      report: report
    } do
      assert report.failed_at_index == 2

      assert [%{amount: 0}, %{amount: 0}, %{amount: 15}] =
               report |> FailureReport.shrunk_sequence() |> Sequence.to_list()
    end

    test "control: through the scheduler, small amounts pass and the larger ones still fail", %{
      report: report
    } do
      assert candidates(15) |> Enum.sort() == [0, 1, 7, 14, 16]
      assert passing_candidates(report) == [0, 1, 7]
    end
  end

  describe "isolate_trigger/2" do
    test "lists the amounts that pass when the commands run as the campaign ran them", %{
      report: report
    } do
      assert {:ok, %{trigger_index: 2, changes: changes}} = Analysis.isolate_trigger(report)

      fixed = changes |> Enum.map(& &1.fixed) |> Enum.sort()

      assert fixed == passing_candidates(report)
      assert fixed == [0, 1, 7]
    end
  end
end
