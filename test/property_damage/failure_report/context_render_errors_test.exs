defmodule PropertyDamage.FailureReport.ContextRenderErrorsTest do
  # The items of the "What this checks" section are read before the sections
  # are built. A raise while reading them leaves the context section out, as a
  # raise in any other section does, and the document names it under
  # `render_errors`.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Test.ReportLayout, as: L

  defp document(report), do: report |> Formatter.format(:json) |> Jason.decode!()

  test "a context whose items raise yields the document with a render error" do
    base = L.report(:did_not_converge)
    broken = %{base | trace: %{base.trace | expansion: %{"b" => [choice()]}}}

    {document, log} =
      with_log(fn -> document(broken) end)

    assert [%{"section" => "context", "message" => message}] = document["render_errors"]
    assert message =~ "alice_refund"
    assert log =~ "the context section could not be built"
    assert document["context"] == []
    refute Enum.any?(document["sections"], &(&1["title"] == "What this checks"))
    assert [_ | _] = document["failure"]["fields"], "control: the other sections still build"
  end

  # A variant that ran its first root as an expansion entry of a command module
  # whose name is not an Elixir alias, which the Path item cannot shorten.
  defp choice do
    %{
      root: 0,
      entry: "refund as credits",
      module: :alice_refund,
      index: 0,
      leaves?: false,
      commands: []
    }
  end
end
