defmodule PropertyDamage.FailureReport.ProjectionsLegendTest do
  # The Projections heading names a side only when that side has state: a
  # report saved before the reference's state was recorded prints `+` lines
  # only, and its legend must not name a reference no line shows.
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.ReportLayout, as: L

  defp heading(report), do: L.heading(L.plain(report), "Projections at ")

  test "a divergence without a reference state names the variant only" do
    report = %{L.report(:diverged) | reference_state_at_failure: nil}
    heading = heading(report)

    assert heading =~ ~s(+ variant "b")
    refute heading =~ "reference"
    refute heading =~ "- "
  end

  test "a divergence with both states names both sides, as before" do
    heading = heading(L.report(:diverged))

    assert heading =~ ~s(- reference "a", + variant "b")
  end

  test "a check failure without a state before names the state after only" do
    report = %{L.report(:hand_built) | state_before_failure: nil}
    heading = heading(report)

    assert heading =~ "+ after"
    refute heading =~ "before"
  end

  test "a check failure with both states keeps the before and after legend" do
    assert heading(L.report(:hand_built)) =~ "- before, + after"
  end
end
