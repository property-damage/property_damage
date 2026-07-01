defmodule PropertyDamage.FailureReport.StepTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.FailureReport
  alias PropertyDamage.FailureReport.Step
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
      failure_reason: {:check_failed, :Inv, "boom"},
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

  # A branched failure report. Structure:
  #   prefix : [P0]
  #   branch0: [B0a, B1a]
  #   branch1: [B0b, B1b]   <- B1b FAILS
  #   suffix : [S0]
  # Executor indices overlap across branches (both first commands are index 1),
  # so branch_id is the only disambiguator. The failure is at branch 1's second
  # command: executor index 2, branch_id 1, flattened index 4.
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
      failure_reason: {:branch_failure, 1, {:check_failed, :Inv, "boom"}},
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

  # A non-localized failure (e.g. a teardown safety check): failed_at_index nil.
  defp teardown_report do
    FailureReport.new(
      seed: 1,
      run_number: 1,
      original_sequence: Sequence.linear([%Cmd{id: 0}, %Cmd{id: 1}]),
      shrunk_sequence: Sequence.linear([%Cmd{id: 0}, %Cmd{id: 1}]),
      failed_at_index: nil,
      failure_reason: {:check_failed, :SettledInvariant, "whole-run"},
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

    test "disambiguates entries across branches that share a command_index" do
      steps = FailureReport.steps(branched_report())

      by_position = Map.new(steps, &{&1.position, &1})
      events_at = fn position -> Enum.map(by_position[position].entries, & &1.event) end

      # Both branches' first command have executor command_index 1; each step
      # must get only its own branch's event.
      assert events_at.(%Position{section: {:branch, 0}, offset: 0}) == [%Ev{tag: :b0a}]
      assert events_at.(%Position{section: {:branch, 1}, offset: 0}) == [%Ev{tag: :b0b}]
      assert events_at.(%Position{section: {:branch, 0}, offset: 1}) == [%Ev{tag: :b1a}]
      assert events_at.(%Position{section: {:branch, 1}, offset: 1}) == [%Ev{tag: :b1b}]
    end

    test "marks exactly the localized failure step, by position not by index" do
      steps = FailureReport.steps(branched_report())

      failed = Enum.filter(steps, & &1.failed?)

      # Exactly one failed step, and it is B1b: flattened index 4, NOT the
      # executor index 2. A naive flattened_index == failed_at_index check would
      # wrongly flag branch 0's second command (flattened index 2).
      assert [step] = failed
      assert step.command == %Cmd{id: :b1b}
      assert step.position == %Position{section: {:branch, 1}, offset: 1}
      assert step.flattened_index == 4
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

    test "branch failure: flattened index, not the executor failed_at_index" do
      # B1b failed: executor failed_at_index 2, but flattened index 4.
      assert FailureReport.failure_index(branched_report()) == 4
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

    test "branch id and source are preserved on each entry" do
      steps = FailureReport.steps(branched_report())
      by_position = Map.new(steps, &{&1.position, &1})

      assert [%Entry{source: :command, branch_id: 1, event: %Ev{tag: :b1b}}] =
               by_position[%Position{section: {:branch, 1}, offset: 1}].entries

      assert [%Entry{source: :command, branch_id: 0, event: %Ev{tag: :b0a}}] =
               by_position[%Position{section: {:branch, 0}, offset: 0}].entries
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
      report = branched_report()

      assert [%Entry{branch_id: 1, event: %Ev{tag: :b1b}}] =
               FailureReport.event_entries_at(report, %Position{section: {:branch, 1}, offset: 1})

      assert [%Entry{event: %Ev{tag: :s0}}] =
               FailureReport.event_entries_at(report, %Position{section: :suffix, offset: 0})
    end
  end
end
