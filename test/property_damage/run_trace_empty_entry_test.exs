defmodule PropertyDamage.RunTraceEmptyEntryTest do
  # An expansion entry may hold no commands: the root then runs nothing. The
  # step listing of a failure on such a root must show no leaf for it and must
  # not walk a count-down range over its (empty) leaf indices.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0]

  alias PropertyDamage.FailureReport
  alias PropertyDamage.FailureReport.{Formatter, HTML}
  alias PropertyDamage.Test.ExpansionRun, as: X
  alias PropertyDamage.Test.ExpansionRun.Refund

  # Every Refund root runs either nothing or itself.
  defp model! do
    module = Module.concat(__MODULE__, EmptyOrIdentity)

    if Code.ensure_loaded?(module),
      do: module,
      else:
        X.define_model!(module, expansions: [{Refund, fn refund, _state -> [[], [refund]] end}])
  end

  # The first diverged run whose failing root ran no commands on one variant.
  defp report_failing_on_empty_entry! do
    model = model!()

    Enum.find_value(1..200, fn seed ->
      recorder = start_recorder()
      targets = [X.target("alpha", recorder), X.target("beta", recorder, %{bug: :credit})]

      result =
        PropertyDamage.run(
          model: model,
          targets: targets,
          compare: [converge_within: 30],
          max_runs: 1,
          max_commands: 8,
          validate: false,
          seed: seed,
          shrink: false
        )

      with {:error, %FailureReport{} = report} <- result,
           true <- empty_entry_at_failure?(report) do
        report
      else
        _other -> nil
      end
    end) || flunk("no seed in 1..200 fails on a root whose entry has no commands")
  end

  defp empty_entry_at_failure?(report) do
    report.expansions
    |> Map.values()
    |> Enum.any?(fn roots -> match?(%{leaves: []}, Enum.at(roots, report.failed_at_index)) end)
  end

  test "the step listing of a failure on an empty entry lists no leaf and warns of nothing" do
    report = report_failing_on_empty_entry!()

    {{steps, terminal, markdown, html}, stderr} =
      with_io(:stderr, fn ->
        {FailureReport.steps(report), Formatter.format(report, :terminal, color: false),
         Formatter.format(report, :markdown, []), HTML.render(report)}
      end)

    assert stderr == ""
    refute Enum.any?(steps, &match?(%{position: %{offset: -1}}, &1))
    assert terminal =~ "Seed"
    assert markdown != "" and html != ""
  end
end
