defmodule PropertyDamage.ExecutorExecutedCaptureTest do
  @moduledoc """
  DR-033: the executor accumulates the concrete resolved commands actually sent
  to the adapter, keyed branch-aware by `%Sequence.Position{}`, on the run
  result's `executed` map. Always on. Feeds `RunTrace.executed` /
  `RunTrace.Step.executed_command`.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Executor, RunTrace, Sequence}
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.{ExecutorModel, SimpleAdapter}

  describe "executed capture (DR-033)" do
    test "linear run keys each executed command by its prefix position" do
      commands = [
        %CreateItem{name: "A", quantity: 1},
        %CreateItem{name: "B", quantity: 2},
        %CreateItem{name: "C", quantity: 3}
      ]

      {:ok, result} = Executor.run(commands, ExecutorModel, SimpleAdapter)

      assert result.executed == %{
               %Position{section: :prefix, offset: 0} => %CreateItem{name: "A", quantity: 1},
               %Position{section: :prefix, offset: 1} => %CreateItem{name: "B", quantity: 2},
               %Position{section: :prefix, offset: 2} => %CreateItem{name: "C", quantity: 3}
             }
    end

    test "branching run captures prefix, per-branch, and suffix positions (merged)" do
      seq =
        Sequence.branching(
          [%CreateItem{name: "P", quantity: 0}],
          [
            [%CreateItem{name: "A0", quantity: 1}, %CreateItem{name: "A1", quantity: 2}],
            [%CreateItem{name: "B0", quantity: 3}]
          ],
          [%CreateItem{name: "S", quantity: 9}]
        )

      {:ok, result} = Executor.run(seq, ExecutorModel, SimpleAdapter)

      # Prefix, both branches (branch-disambiguated positions), and the suffix
      # are all present, keyed by their structured position.
      assert result.executed[%Position{section: :prefix, offset: 0}] ==
               %CreateItem{name: "P", quantity: 0}

      assert result.executed[%Position{section: {:branch, 0}, offset: 0}] ==
               %CreateItem{name: "A0", quantity: 1}

      assert result.executed[%Position{section: {:branch, 0}, offset: 1}] ==
               %CreateItem{name: "A1", quantity: 2}

      assert result.executed[%Position{section: {:branch, 1}, offset: 0}] ==
               %CreateItem{name: "B0", quantity: 3}

      assert result.executed[%Position{section: :suffix, offset: 0}] ==
               %CreateItem{name: "S", quantity: 9}

      # 1 prefix + 2 + 1 branch + 1 suffix = 5 distinct positions.
      assert map_size(result.executed) == 5
    end

    test "executed flows into RunTrace.Step.executed_command" do
      commands = [%CreateItem{name: "A", quantity: 1}, %CreateItem{name: "B", quantity: 2}]
      {:ok, result} = Executor.run(commands, ExecutorModel, SimpleAdapter)

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
