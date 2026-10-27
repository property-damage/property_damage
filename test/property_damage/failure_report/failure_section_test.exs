defmodule PropertyDamage.FailureReport.FailureSectionTest do
  # Details of the terminal report the layout tests leave open: which fields
  # a latency failure prints, how a multi-line command keeps its marks, which
  # values the Reproduction note names, and how an `Other failure` line reads.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport}
  alias PropertyDamage.Test.ReportLayout, as: L

  defp target_fields(report), do: report |> L.plain() |> L.fields_labeled("Target")

  defp other_failure_block(text) do
    lines = L.section(text, "Failure")
    start = Enum.find_index(lines, &String.starts_with?(&1, "Other failure"))
    [first | rest] = Enum.drop(lines, start)
    Enum.join([first | Enum.take_while(rest, &String.starts_with?(&1, " "))], "\n")
  end

  defp count(text, fragment), do: length(String.split(text, fragment)) - 1

  describe "a latency failure" do
    test "in a run of one target prints no Target field" do
      assert target_fields(L.report(:latency_exceeded)) == []
    end

    test "in a run of two targets prints the Target field once" do
      base = L.report(:latency_exceeded)
      [{adapter, entry}] = base.targets
      report = %{base | targets: base.targets ++ [{adapter, Keyword.put(entry, :name, "bob")}]}

      assert [%{value: ~s("solo")}] = target_fields(report)
    end
  end

  describe "a command that prints over several lines" do
    test "keeps its notes and the failing mark outside the printed value" do
      report = L.report(:leaf_check)
      lines = report |> L.plain() |> L.section("Minimal Reproduction")
      at = Enum.find_index(lines, &String.starts_with?(&1, "►"))

      assert Enum.at(lines, at) =~ ~r/◄── failed$/u

      value =
        lines
        |> Enum.drop(at + 1)
        |> Enum.take_while(&(not Regex.match?(~r/^\s+\+\d+\.\d{2}s\s|^\s*(►\s*)?\[/u, &1)))
        |> Enum.join("\n")

      failing = Enum.find(FailureReport.steps(report), & &1.failed?).command

      printed =
        try do
          value |> Code.eval_string() |> elem(0)
        rescue
          error ->
            flunk("the lines under the ► line are not the command:\n#{value}\n#{inspect(error)}")
        end

      assert printed == failing
    end
  end

  describe "the Reproduction note" do
    test "names a pid inside a tuple and inside a keyword list by element index" do
      base = L.report(:check_failed)
      [{adapter, entry}] = base.targets
      pid = self()

      for {config, path} <- [
            {%{name: "a", server: {:ok, pid}}, "config.server.1"},
            {%{name: "a", opts: [server: pid]}, "config.opts.0.1"}
          ] do
        report = %{base | targets: [{adapter, Keyword.put(entry, :config, config)}]}
        text = report |> L.plain() |> L.section("Reproduction") |> Enum.join("\n")

        assert text =~ "# targets holds a pid at #{path}; rebuild the list as the test does."
      end
    end
  end

  describe "an Other failure line" do
    test "tied to no root names no root" do
      base = L.report(:latency_exceeded)
      other = %{variant: %{name: "bob", index: 1}, root: nil, failure: base.failure_reason}
      block = %{base | other_failures: [other]} |> L.plain() |> other_failure_block()

      assert block =~ ~s(latency exceeded p99 in target "bob" \(index 1\): )
      refute block =~ "root"
    end

    test "for a divergence names the observation once and prints the two values" do
      failure = L.report(:diverged).failure_reason
      other = %{variant: %{name: "carol", index: 2}, root: 1, failure: failure}
      report = %{L.report(:check_failed) | other_failures: [other]}
      block = report |> L.plain() |> other_failure_block()
      name = FailureReport.format_name(Failure.name(failure))

      assert count(block, name) == 1
      refute block =~ "left:"
      refute block =~ "right:"

      assert block =~
               ~s(diverged #{name} in target "carol" \(index 2\) at root 1  ) <>
                 ~s("a"  #{inspect(failure.type.reference_value)}  ) <>
                 ~s("carol"  #{inspect(failure.type.variant_value)})
    end
  end
end
