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
  end
end
