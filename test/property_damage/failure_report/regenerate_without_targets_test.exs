defmodule PropertyDamage.FailureReport.RegenerateWithoutTargetsTest do
  # A report that records no target has no name to regenerate a variant with,
  # so it prints no Regenerate comment and call, in either format.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Sequence}
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.ExpansionFor, as: F

  defp report(targets) do
    FailureReport.new(
      seed: 7,
      run_number: 0,
      failed_at_index: 0,
      failure_reason: Failure.check_failed(:refund_total, "totals differ"),
      original_sequence: Sequence.linear([%F.Refund{amount: 10}]),
      model: F.Model,
      targets: targets
    )
  end

  test "expansion_command/1 returns nil for a report without targets" do
    assert FailureReport.expansion_command(report([])) == nil
  end

  test "the terminal and markdown reports print no nil name and no Regenerate lines" do
    report = report([])

    for text <- [
          Formatter.format(report, :terminal, color: false),
          Formatter.format(report, :markdown)
        ] do
      refute text =~ "Regenerate the failing variant:"
      refute text =~ "Expansion.for"
      refute text =~ "nil"
    end
  end

  test "a report with a target still prints the Regenerate comment and call" do
    report = report([{F.Recorder, name: "alice"}])

    assert FailureReport.expansion_command(report) =~ ~s|, 1, "alice")|

    text = Formatter.format(report, :terminal, color: false)
    assert text =~ "Regenerate the failing variant:"
    assert text =~ "Expansion.for"
  end
end
