defmodule PropertyDamage.ExecutorExecutedCaptureTest do
  @moduledoc """
  DR-033: the executor accumulates the concrete resolved commands actually sent
  to the adapter, keyed by `%Sequence.Position{}`, on the run
  result's `executed` map. Always on. Feeds `RunTrace.executed` /
  `RunTrace.Step.executed_command`.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{RunTrace, Sequence}
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.{ExecutorModel, SimpleAdapter, StepRun}

  describe "executed capture (DR-033)" do
    test "linear run keys each executed command by its prefix position" do
      commands = [
        %CreateItem{name: "A", quantity: 1},
        %CreateItem{name: "B", quantity: 2},
        %CreateItem{name: "C", quantity: 3}
      ]

      {:ok, result} = StepRun.run(commands, ExecutorModel, SimpleAdapter)

      assert result.executed == %{
               %Position{section: :prefix, offset: 0} => %CreateItem{name: "A", quantity: 1},
               %Position{section: :prefix, offset: 1} => %CreateItem{name: "B", quantity: 2},
               %Position{section: :prefix, offset: 2} => %CreateItem{name: "C", quantity: 3}
             }
    end

    test "executed flows into RunTrace.Step.executed_command" do
      commands = [%CreateItem{name: "A", quantity: 1}, %CreateItem{name: "B", quantity: 2}]
      {:ok, result} = StepRun.run(commands, ExecutorModel, SimpleAdapter)

      trace =
        RunTrace.new(
          plan: Sequence.linear(commands),
          event_log: result.event_log,
          executed: result.executed,
          outcome: :pass
        )

      steps = RunTrace.steps(trace)
      assert Enum.map(steps, & &1.executed_command) == commands
      # `command` stays the symbolic plan command; here they coincide (no markers).
      assert Enum.map(steps, & &1.command) == commands
      # A bare trace never marks a failed step.
      refute Enum.any?(steps, & &1.failed?)
    end
  end
end
