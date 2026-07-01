defmodule PropertyDamage.AnalysisTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Analysis
  alias PropertyDamage.FailureReport
  alias PropertyDamage.Sequence

  defmodule Alpha, do: defstruct(id: nil)
  defmodule Beta, do: defstruct(id: nil)
  defmodule Gamma, do: defstruct(id: nil)
  defmodule Delta, do: defstruct(id: nil)

  describe "explain/1 branch-aware trigger localization" do
    # prefix [Alpha] ++ branches [[Beta], [Gamma]] ++ suffix [Delta].
    # Flattened order: Alpha=0, Beta=1, Gamma=2, Delta=3. The executor numbers
    # both branch commands from prefix_len (=1), so a branch-1 failure records
    # failed_at_index: 1 (branch_id: 1) whose FLATTENED index is 2. Keying the
    # dependency graph by the executor index would mislabel Beta as the trigger.
    setup do
      seq = Sequence.branching([%Alpha{}], [[%Beta{}], [%Gamma{}]], [%Delta{}])

      report =
        FailureReport.new(
          seed: 1,
          run_number: 1,
          original_sequence: seq,
          shrunk_sequence: seq,
          failed_at_index: 1,
          failure_reason: {:branch_failure, 1, {:check_failed, :TestCheck, "boom"}}
        )

      %{report: report}
    end

    test "reports the flattened index of the failing command", %{report: report} do
      explanation = Analysis.explain(report)
      assert explanation.failure.command_index == 2
    end

    test "labels the branch-1 command (Gamma) as the trigger, not the index collision",
         %{report: report} do
      explanation = Analysis.explain(report)
      trigger = Enum.find(explanation.commands, &(&1.role == :trigger))

      assert trigger.index == 2
      assert trigger.command_name == "Gamma"

      beta = Enum.find(explanation.commands, &(&1.command_name == "Beta"))
      refute beta.role == :trigger
    end
  end
end
