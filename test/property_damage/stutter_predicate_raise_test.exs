defmodule PropertyDamage.StutterPredicateRaiseTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, Runner, Sequence, Stutter}
  alias PropertyDamage.Test.Compare
  alias PropertyDamage.Test.Compare.{PayModel, StutterAdapter}
  alias PropertyDamage.Test.RunnerSupport

  test "a using: relation that raises is a check failure naming the exception, as in a comparison" do
    target = {StutterAdapter, name: "s", config: %{test_pid: self(), retry: :same}}

    result =
      Compare.run(
        PayModel,
        [target],
        max_commands: 1,
        stutter: [
          probability: 1.0,
          max_repeats: 1,
          delay_ms: 0,
          using: fn _original, _retry -> raise "relation blew up" end
        ]
      )

    assert {:error, report} = result
    reason = PropertyDamage.FailureReport.failure_reason(report)
    assert Failure.kind(reason) == :check_failed
    assert Failure.name(reason) == :stutter
    assert %RuntimeError{message: "relation blew up"} = Failure.detail(reason)
  end

  test "a shrink candidate runs with stutter forced on for a raising relation's failure" do
    config =
      Stutter.parse_config(
        probability: 0.0,
        max_repeats: 1,
        delay_ms: 0,
        using: fn _original, _retry -> raise "relation blew up" end
      )

    sequence = RunnerSupport.plan_for(PayModel, 7, 0, 3)

    plan = %{
      commands: Sequence.to_list(sequence),
      variants: nil,
      setup_commands: sequence.setup,
      teardown_commands: sequence.teardown,
      placeholder_registry: sequence.registry
    }

    context = %Runner.Context{
      model: PayModel,
      targets:
        RunnerSupport.targets([
          {StutterAdapter, name: "s", config: %{test_pid: self(), retry: :same}}
        ]),
      seed: 7,
      stutter_config: config
    }

    reproduced = Runner.shrink_oracle(context, {:check_failed, :stutter, 0})
    other = Runner.shrink_oracle(context, {:check_failed, :balance, 0})

    assert %{status: :failed, signature: {:check_failed, :stutter, 0}} = reproduced.(plan, 1)
    assert %{status: :passed} = other.(plan, 1)
  end
end
