defmodule PropertyDamage.StepsCharacterizationTest do
  @moduledoc """
  Move-invariant characterization of `FailureReport.steps/1` /
  `event_entries_at/2` / `failure_step/1` / `failure_index/1` (DR-033 Phase 2).

  Locks the observable output of the step-query interface BEFORE it moves onto
  `RunTrace`, so the move (and the `%FailureReport.Step{}` → `%RunTrace.Step{}`
  rename) is proven to change nothing. Deliberately asserts only by *field
  value* — never by matching the step struct's module name — so the same
  assertions bind identically before and after the rename.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.Failure
  alias PropertyDamage.FailureReport
  alias PropertyDamage.Sequence
  alias PropertyDamage.Sequence.Position

  defmodule Cmd, do: defstruct([:id])
  defmodule Ev, do: defstruct([:tag])

  defp linear_report do
    FailureReport.new(
      seed: 1,
      run_number: 1,
      original_sequence: Sequence.linear([%Cmd{id: 0}, %Cmd{id: 1}, %Cmd{id: 2}]),
      shrunk_sequence: Sequence.linear([%Cmd{id: 0}, %Cmd{id: 1}, %Cmd{id: 2}]),
      failed_at_index: 1,
      failure_reason: Failure.assertion_failed(:Inv, "boom"),
      event_log: [
        %Entry{timestamp: 1, command_index: 0, event: %Ev{tag: :e0}, source: :command},
        %Entry{timestamp: 2, command_index: 1, event: %Ev{tag: :e1}, source: :command},
        %Entry{
          timestamp: 3,
          command_index: nil,
          event: %Ev{tag: :async},
          source: :injector,
          injector_adapter: SomeWebhook
        },
        %Entry{timestamp: 4, command_index: 2, event: %Ev{tag: :e2}, source: :command}
      ]
    )
  end

  defp branched_report do
    seq =
      Sequence.branching(
        [%Cmd{id: :p0}],
        [[%Cmd{id: :b0a}, %Cmd{id: :b1a}], [%Cmd{id: :b0b}, %Cmd{id: :b1b}]],
        [%Cmd{id: :s0}]
      )

    FailureReport.new(
      seed: 1,
      run_number: 1,
      original_sequence: seq,
      shrunk_sequence: seq,
      failed_at_index: 2,
      failure_reason: Failure.in_branch(Failure.assertion_failed(:Inv, "boom"), 1),
      event_log: [
        %Entry{timestamp: 1, command_index: 0, event: %Ev{tag: :p0}, source: :command},
        %Entry{
          timestamp: 2,
          command_index: 1,
          branch_id: 0,
          event: %Ev{tag: :b0a},
          source: :command
        },
        %Entry{
          timestamp: 3,
          command_index: 2,
          branch_id: 0,
          event: %Ev{tag: :b1a},
          source: :command
        },
        %Entry{
          timestamp: 4,
          command_index: 1,
          branch_id: 1,
          event: %Ev{tag: :b0b},
          source: :command
        },
        %Entry{
          timestamp: 5,
          command_index: 2,
          branch_id: 1,
          event: %Ev{tag: :b1b},
          source: :command
        },
        %Entry{timestamp: 6, command_index: 5, event: %Ev{tag: :s0}, source: :command}
      ]
    )
  end

  defp teardown_report do
    FailureReport.new(
      seed: 1,
      run_number: 1,
      original_sequence: Sequence.linear([%Cmd{id: 0}, %Cmd{id: 1}]),
      shrunk_sequence: Sequence.linear([%Cmd{id: 0}, %Cmd{id: 1}]),
      failed_at_index: nil,
      failure_reason: Failure.assertion_failed(:SettledInvariant, "whole-run"),
      event_log: [
        %Entry{timestamp: 1, command_index: 0, event: %Ev{tag: :e0}, source: :command},
        %Entry{timestamp: 2, command_index: 1, event: %Ev{tag: :e1}, source: :command}
      ]
    )
  end

  # Project a step to a plain tuple of its observable fields (module-name-agnostic).
  defp shape(step) do
    {step.position, step.flattened_index, step.command, Enum.map(step.entries, & &1.event),
     step.label, step.failed?}
  end

  describe "steps/1 full-shape lock" do
    test "linear report" do
      assert Enum.map(FailureReport.steps(linear_report()), &shape/1) == [
               {%Position{section: :prefix, offset: 0}, 0, %Cmd{id: 0}, [%Ev{tag: :e0}], nil,
                false},
               {%Position{section: :prefix, offset: 1}, 1, %Cmd{id: 1}, [%Ev{tag: :e1}], nil,
                true},
               {%Position{section: :prefix, offset: 2}, 2, %Cmd{id: 2}, [%Ev{tag: :e2}], nil,
                false}
             ]
    end

    test "branched report" do
      assert Enum.map(FailureReport.steps(branched_report()), &shape/1) == [
               {%Position{section: :prefix, offset: 0}, 0, %Cmd{id: :p0}, [%Ev{tag: :p0}], nil,
                false},
               {%Position{section: {:branch, 0}, offset: 0}, 1, %Cmd{id: :b0a}, [%Ev{tag: :b0a}],
                nil, false},
               {%Position{section: {:branch, 0}, offset: 1}, 2, %Cmd{id: :b1a}, [%Ev{tag: :b1a}],
                nil, false},
               {%Position{section: {:branch, 1}, offset: 0}, 3, %Cmd{id: :b0b}, [%Ev{tag: :b0b}],
                nil, false},
               {%Position{section: {:branch, 1}, offset: 1}, 4, %Cmd{id: :b1b}, [%Ev{tag: :b1b}],
                nil, true},
               {%Position{section: :suffix, offset: 0}, 5, %Cmd{id: :s0}, [%Ev{tag: :s0}], nil,
                false}
             ]
    end

    test "teardown (non-localized) report marks no failed step" do
      steps = FailureReport.steps(teardown_report())
      refute Enum.any?(steps, & &1.failed?)
      assert Enum.map(steps, & &1.flattened_index) == [0, 1]
    end
  end

  describe "entries are full EventLog.Entry structs with provenance" do
    test "linear entries carry source and branch_id" do
      entries = FailureReport.steps(linear_report()) |> Enum.flat_map(& &1.entries)
      assert Enum.all?(entries, &match?(%Entry{}, &1))
      assert Enum.map(entries, & &1.source) == [:command, :command, :command]
    end
  end

  describe "event_entries_at/2 lock" do
    test "by flattened index and by position" do
      report = branched_report()

      assert [%Entry{branch_id: 1, event: %Ev{tag: :b1b}}] =
               FailureReport.event_entries_at(report, 4)

      assert [%Entry{event: %Ev{tag: :s0}}] =
               FailureReport.event_entries_at(report, %Position{section: :suffix, offset: 0})

      assert FailureReport.event_entries_at(report, 99) == []
    end
  end

  describe "failure_step/1 and failure_index/1 lock" do
    test "linear" do
      assert FailureReport.failure_index(linear_report()) == 1
      assert FailureReport.failure_step(linear_report()).command == %Cmd{id: 1}
    end

    test "branch: flattened index, not executor index" do
      assert FailureReport.failure_index(branched_report()) == 4
      assert FailureReport.failure_step(branched_report()).command == %Cmd{id: :b1b}
    end

    test "non-localized: nil" do
      assert FailureReport.failure_index(teardown_report()) == nil
      assert FailureReport.failure_step(teardown_report()) == nil
    end
  end
end
