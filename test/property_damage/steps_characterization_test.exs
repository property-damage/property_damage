defmodule PropertyDamage.StepsCharacterizationTest do
  @moduledoc """
  Move-invariant characterization of `FailureReport.steps/1` /
  `event_entries_at/2` / `failure_step/1` / `failure_index/1` (DR-033 Phase 2).

  Locks the observable output of the step-query interface BEFORE it moves onto
  `RunTrace`, so the move (and the `%FailureReport.Step{}` → `%RunTrace.Step{}`
  rename) is proven to change nothing. Deliberately asserts only by *field
  value* — never by matching the step struct's module name — so the same
  checks bind identically before and after the rename.
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
      failure_reason: Failure.check_failed(:Inv, "boom"),
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

  defp teardown_report do
    FailureReport.new(
      seed: 1,
      run_number: 1,
      original_sequence: Sequence.linear([%Cmd{id: 0}, %Cmd{id: 1}]),
      shrunk_sequence: Sequence.linear([%Cmd{id: 0}, %Cmd{id: 1}]),
      failed_at_index: nil,
      failure_reason: Failure.check_failed(:SettledInvariant, "whole-run"),
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

    test "teardown (non-localized) report marks no failed step" do
      steps = FailureReport.steps(teardown_report())
      refute Enum.any?(steps, & &1.failed?)
      assert Enum.map(steps, & &1.flattened_index) == [0, 1]
    end
  end

  describe "entries are full EventLog.Entry structs with provenance" do
    test "linear entries carry their source" do
      entries = FailureReport.steps(linear_report()) |> Enum.flat_map(& &1.entries)
      assert Enum.all?(entries, &match?(%Entry{}, &1))
      assert Enum.map(entries, & &1.source) == [:command, :command, :command]
    end
  end

  describe "event_entries_at/2 lock" do
    test "by flattened index and by position" do
      report = linear_report()

      assert [%Entry{event: %Ev{tag: :e2}}] = FailureReport.event_entries_at(report, 2)

      assert [%Entry{event: %Ev{tag: :e1}}] =
               FailureReport.event_entries_at(report, %Position{section: :prefix, offset: 1})

      assert FailureReport.event_entries_at(report, 99) == []
    end
  end

  describe "failure_step/1 and failure_index/1 lock" do
    test "linear" do
      assert FailureReport.failure_index(linear_report()) == 1
      assert FailureReport.failure_step(linear_report()).command == %Cmd{id: 1}
    end

    test "non-localized: nil" do
      assert FailureReport.failure_index(teardown_report()) == nil
      assert FailureReport.failure_step(teardown_report()) == nil
    end
  end
end
