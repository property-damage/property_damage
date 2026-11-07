defmodule PropertyDamage.FailureReport.StepTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.Failure
  alias PropertyDamage.FailureReport
  alias PropertyDamage.RunTrace.Step
  alias PropertyDamage.Sequence
  alias PropertyDamage.Sequence.Position

  defmodule Cmd, do: defstruct([:id])
  defmodule Ev, do: defstruct([:tag])

  # A linear failure report: 3 commands, the middle one fails, one command event
  # each plus an injector event with no command index.
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
        # Injector event: no command_index, belongs to no step.
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

  # A non-localized failure (e.g. a teardown safety check): failed_at_index nil.
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

  describe "steps/1" do
    test "returns one step per command in flattened order" do
      steps = FailureReport.steps(linear_report())

      assert length(steps) == 3
      assert Enum.map(steps, & &1.flattened_index) == [0, 1, 2]
      assert Enum.map(steps, & &1.command) == [%Cmd{id: 0}, %Cmd{id: 1}, %Cmd{id: 2}]

      assert Enum.map(steps, & &1.position) == [
               %Position{section: :prefix, offset: 0},
               %Position{section: :prefix, offset: 1},
               %Position{section: :prefix, offset: 2}
             ]
    end

    test "attaches command entries by position; injector events belong to no step" do
      steps = FailureReport.steps(linear_report())

      assert Enum.map(steps, fn step -> Enum.map(step.entries, & &1.event) end) == [
               [%Ev{tag: :e0}],
               [%Ev{tag: :e1}],
               [%Ev{tag: :e2}]
             ]

      # The async injector event (command_index nil) is attached nowhere.
      refute Enum.any?(steps, fn step ->
               Enum.any?(step.entries, &(&1.event.tag == :async))
             end)
    end
  end

  describe "failure_step/1" do
    test "returns the localized failure step" do
      step = FailureReport.failure_step(linear_report())

      assert %Step{failed?: true, flattened_index: 1, command: %Cmd{id: 1}} = step
    end

    test "returns nil for a non-localized failure (failed_at_index nil)" do
      assert FailureReport.failure_step(teardown_report()) == nil
      refute Enum.any?(FailureReport.steps(teardown_report()), & &1.failed?)
    end
  end

  describe "failure_index/1" do
    test "linear failure: flattened index equals the executor index" do
      assert FailureReport.failure_index(linear_report()) == 1
    end

    test "non-localized failure: nil" do
      assert FailureReport.failure_index(teardown_report()) == nil
    end
  end

  describe "entries carry per-event provenance (candidate 8b)" do
    test "a step's entries are full EventLog.Entry structs, not bare events" do
      steps = FailureReport.steps(linear_report())

      entries = Enum.flat_map(steps, & &1.entries)
      assert Enum.all?(entries, &match?(%Entry{}, &1))

      # The provenance that bare events dropped survives: each entry still knows
      # its source, and the event struct is reachable by projecting `.event`.
      assert Enum.map(entries, & &1.source) == [:command, :command, :command]
      assert Enum.map(entries, & &1.event) == [%Ev{tag: :e0}, %Ev{tag: :e1}, %Ev{tag: :e2}]
    end
  end

  describe "event_entries_at/2" do
    test "addresses entries by flattened index" do
      report = linear_report()

      assert [%Entry{source: :command, event: %Ev{tag: :e0}}] =
               FailureReport.event_entries_at(report, 0)

      assert [%Entry{source: :command, event: %Ev{tag: :e2}}] =
               FailureReport.event_entries_at(report, 2)

      assert FailureReport.event_entries_at(report, 99) == []
    end

    test "addresses entries by Position" do
      report = linear_report()

      assert [%Entry{source: :command, event: %Ev{tag: :e1}}] =
               FailureReport.event_entries_at(report, %Position{section: :prefix, offset: 1})

      assert FailureReport.event_entries_at(report, %Position{section: :prefix, offset: 9}) == []
    end
  end
end
