defmodule PropertyDamage.FailureReport.JsonLogsTest do
  # A report whose Failure section cannot be built (here, a projection whose
  # `__compares__/0` raises when the section reads its relation) still formats
  # as JSON, with the same `logs` as a report that builds. The document names
  # the section under `render_errors` and the raise is logged.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.ReportLayout, as: L

  defmodule RaisingProjection do
    @moduledoc false
    def __compares__, do: raise("the relations of alice cannot be read")
  end

  defp with_key(report, key) do
    type = %{PropertyDamage.FailureReport.failure_reason(report).type | key: key}
    failure = %{PropertyDamage.FailureReport.failure_reason(report) | type: type}
    %{report | trace: %{report.trace | outcome: {:fail, failure}}}
  end

  defp logs_of(report),
    do: report |> Formatter.format(:json) |> Jason.decode!() |> Map.get("logs")

  test "a report whose Failure section raises still formats as JSON with the same logs" do
    base = L.report(:did_not_converge)
    broken = with_key(base, {RaisingProjection, :totals})

    assert_raise RuntimeError, ~r/relations of alice/, fn ->
      Formatter.format(broken, :terminal)
    end

    {document, log} =
      with_log(fn -> broken |> Formatter.format(:json) |> Jason.decode!() end)

    assert document["logs"] == logs_of(base)

    assert [_ | _] = document["logs"]["target"]["steps"],
           "control: the logs hold the failing target's steps"

    assert [%{"section" => "failure", "message" => message}] = document["render_errors"]
    assert message =~ "relations of alice"
    assert log =~ "the failure section could not be built"
    assert log =~ "relations of alice"
    assert document["failure"]["fields"] == []
    refute Enum.any?(document["sections"], &(&1["title"] == "Failure"))
  end

  test "a report that builds has no render errors" do
    document = :did_not_converge |> L.report() |> Formatter.format(:json) |> Jason.decode!()

    refute Map.has_key?(document, "render_errors")
    assert [_ | _] = document["failure"]["fields"]
  end
end
