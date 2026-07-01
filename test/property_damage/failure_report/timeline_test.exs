defmodule PropertyDamage.FailureReport.TimelineTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.FailureReport
  alias PropertyDamage.FailureReport.Timeline
  alias PropertyDamage.Sequence

  defmodule CreateOrder do
    defstruct [:id]
  end

  defmodule PaymentConfirmed do
    defstruct [:id]
  end

  defmodule Alpha, do: defstruct(id: nil)
  defmodule Beta, do: defstruct(id: nil)
  defmodule Gamma, do: defstruct(id: nil)
  defmodule Delta, do: defstruct(id: nil)

  # prefix [Alpha] ++ branches [[Beta], [Gamma]] ++ suffix [Delta].
  # Flattened reading order: Alpha=0, Beta=1, Gamma=2, Delta=3.
  # The executor numbers BOTH branch commands from prefix_len (=1), so Beta and
  # Gamma share executor command_index 1, disambiguated only by branch_id. A
  # failure in branch 1 (Gamma) is recorded as failed_at_index: 1, branch_id: 1,
  # whose flattened index is 2, so `idx == failed_at_index` would mismark Beta.
  defp branch_failure_report do
    FailureReport.new(
      seed: 1,
      run_number: 1,
      original_sequence: Sequence.branching([%Alpha{}], [[%Beta{}], [%Gamma{}]], [%Delta{}]),
      shrunk_sequence: Sequence.branching([%Alpha{}], [[%Beta{}], [%Gamma{}]], [%Delta{}]),
      failed_at_index: 1,
      branch_id: 1,
      failure_reason: {:branch_failure, 1, {:check_failed, :TestCheck, "boom"}},
      model: TestModel,
      adapter: TestAdapter
    )
  end

  defp report_with_async_event do
    FailureReport.new(
      seed: 1,
      run_number: 1,
      original_sequence: Sequence.linear([%CreateOrder{id: 1}]),
      shrunk_sequence: Sequence.linear([%CreateOrder{id: 1}]),
      failed_at_index: 0,
      failure_reason: {:check_failed, :TestCheck, "boom"},
      event_log: [
        %Entry{timestamp: 1, command_index: 0, event: %CreateOrder{id: 1}, source: :command},
        # Injector events carry command_index: nil; they must not vanish.
        %Entry{
          timestamp: 2,
          command_index: nil,
          event: %PaymentConfirmed{id: 1},
          source: :injector,
          injector_adapter: PaymentWebhook
        }
      ],
      model: TestModel,
      adapter: TestAdapter
    )
  end

  describe "format_event_timeline/2" do
    test "shows async events that have no command index" do
      output = Timeline.format_event_timeline(report_with_async_event(), color: false)

      # The injector event is not attributable to a command, but it still
      # belongs in the timeline rather than being silently dropped.
      assert output =~ "PaymentConfirmed"
    end

    test "shows the source badge for a command-attributed non-command event" do
      report =
        FailureReport.new(
          seed: 1,
          run_number: 1,
          original_sequence: Sequence.linear([%CreateOrder{id: 1}]),
          shrunk_sequence: Sequence.linear([%CreateOrder{id: 1}]),
          failed_at_index: 0,
          failure_reason: {:check_failed, :TestCheck, "boom"},
          event_log: [
            %Entry{timestamp: 1, command_index: 0, event: %CreateOrder{id: 1}, source: :command},
            # A nemesis event recorded against command 0 (non-nil command_index):
            # it must render with its NEM badge, not as a bare command output, so
            # fault injection stays visible.
            %Entry{
              timestamp: 2,
              command_index: 0,
              event: %PaymentConfirmed{id: 1},
              source: :nemesis,
              nemesis_module: SomeNemesis
            }
          ],
          model: TestModel,
          adapter: TestAdapter
        )

      output = strip_ansi(Timeline.format_event_timeline(report, color: false))

      assert output =~ "NEM"
      assert output =~ "CMD"
    end

    test "marks the branch failure on its flattened command, not the index collision" do
      output = strip_ansi(Timeline.format_event_timeline(branch_failure_report(), color: false))

      # Gamma is the failing branch-1 command (flattened index 2). Beta shares
      # the executor command index (1) but is in branch 0 and must NOT be
      # marked. This is the branch-aware fix: failed? is resolved by position,
      # not by comparing the flattened ordinal to failed_at_index.
      assert output =~ "[2] Gamma ► FAILURE"
      refute output =~ "Beta ► FAILURE"
    end
  end

  describe "format/2 branch marking" do
    test "marks the failing branch cell, not a same-index cell in another branch" do
      output = strip_ansi(Timeline.format(branch_failure_report(), color: false))

      # Only the branch-1 (Gamma) cell carries the ► marker.
      assert output =~ "Gamma ►"
      refute output =~ "Beta ►"
    end
  end

  # `reset/0` emits its escape unconditionally even under `color: false`, so
  # strip all ANSI to assert on plain text.
  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")
end
