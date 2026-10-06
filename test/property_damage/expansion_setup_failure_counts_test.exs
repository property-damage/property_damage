defmodule PropertyDamage.ExpansionSetupFailureCountsTest do
  # A failure report's expansion counts describe the roots the failing run
  # executed. A setup command that fails stops the run before its first root,
  # so the report counts and lists no expansion choice.
  use ExUnit.Case, async: false

  import PropertyDamage.Test.VariantSupport, only: [start_recorder: 0, recorded: 1]

  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.Expansion, as: A

  test "a setup command failure counts and lists no expansion choice" do
    model =
      A.define_model!(PropertyDamage.ExpansionSetupFailureCountsTest.Model,
        commands: [A.Pay],
        expansions: [{A.Pay, &A.pay_expansions/2}],
        setup: [A.Open]
      )

    recorder = start_recorder()
    target = A.target("solo", recorder, :random, %{fail: %{A.Open => :error}})

    assert {:error, %FailureReport{} = report} =
             A.run(model, [target], seed: 3, max_runs: 1, max_commands: 6, shrink: false)

    executed = for {:execute, "solo", command, _} <- recorded(recorder), do: command.__struct__

    assert report.kind == :setup_failed
    assert report.failed_at_index == nil
    assert executed == [A.Open]
    assert report.expansions == %{"solo" => []}
    assert report.expansion_counts == %{"solo" => %{}}
  end
end
