defmodule PropertyDamage.ReproductionTargetsTest do
  # The reproduction command names every target with the `expansion:` mode it
  # ran, so pasting it runs an `:identity` or `:reference` target the way the
  # failing run did instead of as the default `:random`.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Options, Sequence}
  alias PropertyDamage.Test.ExpansionFor, as: F

  defp report(targets) do
    sequence = Sequence.linear([%F.Refund{amount: 10}])

    FailureReport.new(
      seed: 7,
      run_number: 0,
      failed_at_index: 0,
      failure_reason: Failure.check_failed(:refund_total, "totals differ"),
      original_sequence: sequence,
      model: F.Model,
      targets: targets
    )
  end

  defp modes(source) do
    {entries, _binding} = Code.eval_string(source)
    {:ok, targets} = Options.validate_targets(entries)
    Map.new(targets, &{&1.name, &1.expansion})
  end

  test "names each target's expansion: mode when it is not :random" do
    targets = [
      {F.Recorder, name: "ref", expansion: :random},
      {F.Recorder, name: "plain", expansion: :identity},
      {F.Recorder, name: "copy", expansion: :reference}
    ]

    report = report(targets)
    command = FailureReport.reproduction_command(report)

    assert command =~
             ~s|{PropertyDamage.Test.ExpansionFor.Recorder, name: "plain", expansion: :identity}|

    assert command =~
             ~s|{PropertyDamage.Test.ExpansionFor.Recorder, name: "copy", expansion: :reference}|

    refute command =~ "expansion: :random"

    assert modes(FailureReport.targets_source(report)) ==
             %{"ref" => :random, "plain" => :identity, "copy" => :reference}
  end
end
