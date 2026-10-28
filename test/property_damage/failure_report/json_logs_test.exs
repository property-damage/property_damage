defmodule PropertyDamage.FailureReport.JsonLogsTest do
  # The `:json` format builds the `logs` key from the listing alone: a report
  # whose Failure section cannot be built (here, a projection whose
  # `__compares__/0` raises when the section reads its relation) still formats
  # as JSON, with the same `logs` as a report that builds.
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.ReportLayout, as: L

  defmodule RaisingProjection do
    @moduledoc false
    def __compares__, do: raise("the relations of alice cannot be read")
  end

  defp with_key(report, key) do
    type = %{report.failure_reason.type | key: key}
    %{report | failure_reason: %{report.failure_reason | type: type}}
  end

  defp logs_of(report),
    do: report |> Formatter.format(:json) |> Jason.decode!() |> Map.get("logs")

  test "a report whose Failure section raises still formats as JSON with the same logs" do
    base = L.report(:did_not_converge)
    broken = with_key(base, {RaisingProjection, :totals})

    assert_raise RuntimeError, ~r/relations of alice/, fn ->
      Formatter.format(broken, :terminal)
    end

    logs = logs_of(broken)

    assert logs == logs_of(base)
    assert [_ | _] = logs["target"]["steps"], "control: the logs hold the failing target's steps"
  end
end
