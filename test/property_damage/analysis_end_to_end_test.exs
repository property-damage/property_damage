defmodule PropertyDamage.AnalysisEndToEndTest do
  # Drives Analysis over the report of a real failing campaign: a ledger whose
  # adapter debits twice on a large withdrawal.
  use ExUnit.Case, async: true

  alias PropertyDamage.Analysis
  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.Gauntlet, as: G

  @bug {:double_debit_from, 5}
  @placeholder "placeholder:id@%PropertyDamage.Sequence.Position{section: :prefix, offset: 0}"

  setup_all do
    {:error, %FailureReport{} = report} = G.run(G.Model, @bug)
    %{report: report}
  end

  test "the campaign passes against the correct adapter" do
    assert {:ok, _stats} = G.run(G.Model, :off)
  end

  describe "explain/1 on a failing campaign" do
    # Pinned: the failure type, check, message and flattened index; the command
    # count, order, names, indexes, roles, reasons and placeholder labels; the
    # dependency chain; the summary. These hold for the fixed seed and are what
    # a refactor of explain/1 must keep.
    #
    # Not pinned: the argument values of the shrunk commands (the shrinker may
    # settle on any amount from the defect threshold up, and may blank the
    # currency), and the placeholder's embedded id.
    test "pins the failure the campaign found", %{report: report} do
      explanation = Analysis.explain(report)

      assert explanation.failure == %{
               type: :check_failed,
               check: :balance_matches_ledger,
               message: "Reported balance differs from the ledger: %{drift: -7}",
               command_index: 2
             }
    end

    test "names every command with its role and reason", %{report: report} do
      explanation = Analysis.explain(report)

      assert Enum.map(explanation.commands, &{&1.index, &1.command_name, &1.role}) == [
               {0, "Open", :dependency},
               {1, "Deposit", :unknown},
               {2, "Withdraw", :trigger}
             ]

      assert Enum.map(explanation.commands, & &1.reason) == [
               "Provides state or values required by the failing command",
               "Kept by shrinking: removing it lost the failure; it may set up state the failing command reads",
               "Triggers balance_matches_ledger failure"
             ]

      assert Enum.map(explanation.commands, & &1.placeholders) == [
               %{},
               %{account_id: @placeholder},
               %{account_id: @placeholder}
             ]
    end

    test "chains the trigger back to the command that minted its account id", %{report: report} do
      explanation = Analysis.explain(report)

      assert explanation.dependency_chain == ["[0] Open", "[2] Withdraw"]

      assert explanation.summary ==
               "Shrunk to 3 commands.\nFailure triggered by: Withdraw at index 2\n" <>
                 "Dependencies: 1 command(s) required to set up state\n" <>
                 "Failure type: Invariant Violation: balance_matches_ledger"
    end

    test "keeps the deposit that only supplies a balance out of the chain", %{report: report} do
      explanation = Analysis.explain(report)
      deposit = Enum.find(explanation.commands, &(&1.command_name == "Deposit"))

      assert deposit.role == :unknown
      refute "[1] Deposit" in explanation.dependency_chain
    end

    test "carries the defect in the trigger command's amount", %{report: report} do
      explanation = Analysis.explain(report)
      trigger = Enum.find(explanation.commands, &(&1.role == :trigger))

      assert %G.Commands.Withdraw{amount: amount} = trigger.command
      assert amount >= 5
    end

    test "explains a different defect with its own failure type" do
      {:error, crash} = G.run(G.Model, :crash)
      explanation = Analysis.explain(crash)

      assert explanation.failure.type == :adapter_error
      assert explanation.failure.check == nil
      assert explanation.failure.message == "ledger unavailable"
      assert explanation.dependency_chain == ["[0] Open", "[2] Withdraw"]
    end
  end

  describe "format_explanation/1 on a real explanation" do
    test "renders the summary, the command breakdown and the chain", %{report: report} do
      text = report |> Analysis.explain() |> Analysis.format_explanation()

      assert text =~ "FAILURE ANALYSIS"
      assert text =~ "Failure triggered by: Withdraw at index 2"
      assert text =~ "[0] Open ← DEPENDENCY"
      assert text =~ "[2] Withdraw ← FAILURE TRIGGER"
      assert text =~ "    Triggers balance_matches_ledger failure"
      assert text =~ "DEPENDENCY CHAIN"
      assert text =~ "[0] Open → [2] Withdraw"
    end
  end

  describe "isolate_trigger/2 on a failing campaign" do
    test "returns the withdrawal as the trigger", %{report: report} do
      assert {:ok, result} = Analysis.isolate_trigger(report)

      assert %{trigger_command: trigger, trigger_index: 2, changes: changes, likely_cause: cause} =
               result

      assert %G.Commands.Withdraw{amount: amount} = trigger
      assert amount >= 5
      assert is_list(changes) and changes != []
      assert cause == "Amount-related issue: original amount #{amount} causes failure"
    end

    test "lists only amounts below the defect threshold as eliminating it", %{report: report} do
      {:ok, %{changes: changes}} = Analysis.isolate_trigger(report)

      assert Enum.all?(changes, &(&1.field == :amount))
      assert Enum.all?(changes, &(&1.fixed < 5))
      assert Enum.any?(changes, &(&1.fixed == 0))
      assert Enum.all?(changes, &(&1.description =~ "eliminates failure"))
    end

    test "lists every variation as eliminating the failure once the defect is gone",
         %{report: report} do
      {:ok, %{changes: with_bug}} = Analysis.isolate_trigger(report)

      {:ok, %{changes: without_bug}} =
        Analysis.isolate_trigger(report,
          targets: [{G.Adapter, config: %{bug: :off}}]
        )

      assert Enum.any?(without_bug, &(&1.fixed >= 5))
      assert length(without_bug) > length(with_bug)
    end

    test "finds no eliminating change when the failure does not depend on a field" do
      {:error, crash} = G.run(G.Model, :crash)

      assert {:ok, %{changes: [], trigger_index: 2, likely_cause: cause}} =
               Analysis.isolate_trigger(crash)

      assert cause =~ "Unable to isolate trigger through field variation"
    end
  end
end
