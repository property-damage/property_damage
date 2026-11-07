defmodule PropertyDamage.LeafStateTest do
  # The projection state at a leaf of an expanded root: the root's prefix cut plus
  # the leaves of that root through this leaf.
  use ExUnit.Case, async: true

  alias PropertyDamage.{FailureReport, RunTrace}
  alias PropertyDamage.RunTrace.Step
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.ReportLayout, as: L

  defp leaf_report do
    report = L.report(:leaf_check)
    assert %Step{position: %Position{section: {:leaf, _}}} = FailureReport.failure_step(report)
    report
  end

  test "verify_projections/1 returns :ok for a pure projection failing at a leaf" do
    assert :ok = FailureReport.verify_projections(leaf_report())
  end

  test "state_at/2 and state_before/2 at a leaf at a leaf equal the run's own snapshots" do
    report = leaf_report()
    %Step{position: position} = FailureReport.failure_step(report)

    after_leaf = RunTrace.state_at(report.trace, position)
    before_leaf = RunTrace.state_before(report.trace, position)

    assert map_size(after_leaf) > 0
    assert after_leaf == report.state_at_failure
    assert before_leaf == report.state_before_failure
  end
end
