defmodule PropertyDamage.RunTraceTest do
  @moduledoc """
  DR-033: RunTrace as the execution record, and FailureReport's accessors /
  delegation over the embedded trace.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.{FailureReport, RunTrace, Sequence}
  alias PropertyDamage.Sequence.Position

  defmodule Cmd, do: defstruct([:id])
  defmodule Ev, do: defstruct([:tag])

  defp trace do
    RunTrace.new(
      seed: 1,
      run_number: 0,
      plan: Sequence.linear([%Cmd{id: 0}, %Cmd{id: 1}]),
      plan_source: :generated,
      event_log: [
        %Entry{timestamp: 1, command_index: 0, event: %Ev{tag: :e0}, source: :command},
        %Entry{
          timestamp: 2,
          command_index: nil,
          event: %Ev{tag: :async},
          source: :injector,
          injector_adapter: Hook
        },
        %Entry{timestamp: 3, command_index: 1, event: %Ev{tag: :e1}, source: :command}
      ],
      outcome: :pass
    )
  end

  describe "RunTrace" do
    test "new/1 computes the plan fingerprint from the plan" do
      t = trace()
      assert t.plan_fingerprint == Sequence.fingerprint(t.plan)
      assert RunTrace.plan_fingerprint(t.plan) == t.plan_fingerprint
    end

    test "new/1 does not auto-detect source_revision" do
      assert RunTrace.new(plan: Sequence.linear([])).source_revision == nil
    end

    test "steps/1 attributes command entries by position, never marking failed" do
      steps = RunTrace.steps(trace())
      assert Enum.map(steps, & &1.flattened_index) == [0, 1]

      assert Enum.map(steps, fn s -> Enum.map(s.entries, & &1.event) end) == [
               [%Ev{tag: :e0}],
               [%Ev{tag: :e1}]
             ]

      refute Enum.any?(steps, & &1.failed?)
    end

    test "async_entries/1 returns only the command-unattributed entries" do
      assert [%Entry{event: %Ev{tag: :async}, source: :injector}] =
               RunTrace.async_entries(trace())
    end

    test "event_entries_at/2 addresses entries by index and position" do
      t = trace()
      assert [%Entry{event: %Ev{tag: :e1}}] = RunTrace.event_entries_at(t, 1)

      assert [%Entry{event: %Ev{tag: :e0}}] =
               RunTrace.event_entries_at(t, %Position{section: :prefix, offset: 0})
    end
  end

  describe "FailureReport delegation over the trace" do
    defp report do
      FailureReport.new(
        seed: 1,
        run_number: 0,
        original_sequence: Sequence.linear([%Cmd{id: 0}, %Cmd{id: 1}]),
        shrunk_sequence: Sequence.linear([%Cmd{id: 0}, %Cmd{id: 1}]),
        failed_at_index: 1,
        failure_reason: {:check_failed, :Inv, "boom"},
        event_log: [
          %Entry{timestamp: 1, command_index: 0, event: %Ev{tag: :e0}, source: :command},
          %Entry{
            timestamp: 2,
            command_index: nil,
            event: %Ev{tag: :async},
            source: :injector,
            injector_adapter: Hook
          },
          %Entry{timestamp: 3, command_index: 1, event: %Ev{tag: :e1}, source: :command}
        ]
      )
    end

    test "accessors read through the embedded trace" do
      r = report()
      assert FailureReport.shrunk_sequence(r) == r.trace.plan
      assert FailureReport.event_log(r) == r.trace.event_log
      assert FailureReport.async_entries(r) == RunTrace.async_entries(r.trace)
    end

    test "steps share the trace's data, with the report overlaying the failed step" do
      r = report()
      report_steps = FailureReport.steps(r)
      trace_steps = RunTrace.steps(r.trace)

      # Same positions, commands, and entries as the bare trace...
      assert Enum.map(report_steps, & &1.position) == Enum.map(trace_steps, & &1.position)

      assert Enum.map(report_steps, fn s -> Enum.map(s.entries, & &1.event) end) ==
               Enum.map(trace_steps, fn s -> Enum.map(s.entries, & &1.event) end)

      # ...but only the report localizes the failure (failed_at_index overlay).
      assert Enum.map(report_steps, & &1.failed?) == [false, true]
      assert Enum.map(trace_steps, & &1.failed?) == [false, false]
    end
  end
end
