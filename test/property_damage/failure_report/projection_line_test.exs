defmodule PropertyDamage.FailureReport.ProjectionLineTest do
  # The Failure section of a check failure names the projection whose check
  # failed, in the line after the Check field: in the terminal report, in the
  # markdown report and, as a "projection" key, in the JSON report. A failure
  # that no check judges prints no line, and its JSON object has no key
  # (a check failure that has no projection has the key set to null).
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport}
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.ReportLayout, as: L

  defp json_failure(report) do
    report |> Formatter.format(:json) |> Jason.decode!() |> Map.fetch!("failure")
  end

  # The Failure section's lines (fence lines included) and its fields.
  defp failure_lines(text), do: L.section(text, "Failure")

  defp failure_fields(text), do: text |> failure_lines() |> L.fields()

  defp with_reason(report, reason),
    do: %{report | failure_reason: reason, kind: FailureReport.kind_of(reason)}

  defp assert_line_after_check(text, projection) do
    lines = failure_lines(text)
    at = Enum.find_index(lines, &Regex.match?(~r/^Check {2,}\S/, &1))
    assert at, "no Check line in:\n#{Enum.join(lines, "\n")}"

    assert Enum.at(lines, at + 1) =~ ~r/^Projection {2,}#{Regex.escape(projection)}$/,
           "the line after Check is not the Projection line:\n#{Enum.join(lines, "\n")}"

    assert [%{value: ^projection, column: column}] = L.fields_labeled(text, "Projection")
    assert [%{column: ^column}] = L.fields_labeled(text, "Check")
    refute projection =~ "Elixir."
  end

  defp assert_no_projection_line(text) do
    assert L.fields_labeled(text, "Projection") == []
    refute Enum.any?(failure_lines(text), &String.starts_with?(&1, "Projection"))
  end

  for {kind, projection} <- [
        {:check_failed, "PropertyDamage.Test.Compare.Plain"},
        {:poll_timeout, "PropertyDamage.Test.ReportLayout.Eventual.Status"}
      ] do
    describe "the report of a #{kind} failure" do
      test "prints the Projection line after the Check field in the terminal" do
        assert_line_after_check(L.plain(L.report(unquote(kind))), unquote(projection))
      end

      test "prints the Projection line after the Check field in the markdown" do
        assert_line_after_check(L.markdown(L.report(unquote(kind))), unquote(projection))
      end

      test "carries the projection in the failure object of the JSON" do
        assert %{"projection" => unquote(projection)} = json_failure(L.report(unquote(kind)))
      end
    end
  end

  describe "a check failure that has no projection" do
    test "prints no Projection line in the terminal or the markdown" do
      report = L.hand_built()
      assert %Failure{type: %Failure.Check{kind: :check_failed}} = report.failure_reason

      for text <- [L.plain(report), L.markdown(report)] do
        assert [%{value: "settled_amount"}] = L.fields_labeled(text, "Check")
        assert_no_projection_line(text)
      end
    end

    test "has the projection key set to null in the JSON" do
      failure = json_failure(L.hand_built())

      assert Map.has_key?(failure, "projection")
      assert Map.fetch!(failure, "projection") == nil
    end

    test "of a run that no check judged (a repeated command) prints no line and has a null key" do
      report = L.report(:idempotency)

      assert %Failure{type: %Failure.Check{kind: :idempotency_violation}} = report.failure_reason
      assert_no_projection_line(L.plain(report))

      failure = json_failure(report)
      assert Map.has_key?(failure, "projection")
      assert Map.fetch!(failure, "projection") == nil
    end
  end

  describe "a check failure built with a projection that is not loaded" do
    test "prints the module as inspect/1 shows it" do
      reason = Failure.check_failed(:settled_amount, "negative settlement", MyApp.Ledger)
      report = with_reason(L.hand_built(), reason)

      assert_line_after_check(L.plain(report), "MyApp.Ledger")
      assert_line_after_check(L.markdown(report), "MyApp.Ledger")
      assert %{"projection" => "MyApp.Ledger"} = json_failure(report)
    end
  end

  describe "a failure that is not a check failure" do
    test "of a divergence prints no Projection line and has no projection key" do
      report = L.report(:diverged)
      assert report.kind == :diverged

      assert_no_projection_line(L.plain(report))
      assert_no_projection_line(L.markdown(report))
      refute Map.has_key?(json_failure(report), "projection")
    end

    test "of a poll error prints no Projection line and has no projection key" do
      report = with_reason(L.hand_built(), Failure.poll_error(%RuntimeError{message: "boom"}))

      assert %Failure{type: %Failure.Execution{kind: :poll_error}} = report.failure_reason
      assert_no_projection_line(L.plain(report))
      assert_no_projection_line(L.markdown(report))
      refute Map.has_key?(json_failure(report), "projection")
    end
  end

  test "the Failure section of a poll error still has its own fields" do
    # The guard that the poll error report renders at all: a missing section
    # would pass the no-line checks above for the wrong reason.
    report = with_reason(L.hand_built(), Failure.poll_error(%RuntimeError{message: "boom"}))

    assert [%{label: "Failure", value: "poll error"} | _] = failure_fields(L.plain(report))
  end
end
