defmodule PropertyDamage.FailureReport.TimelineTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.Failure
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
      failure_reason: Failure.check_failed(:TestCheck, "boom"),
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
      targets: [{TestAdapter, []}]
    )
  end

  describe "format_event_timeline/2" do
    test "shows async events that have no command index" do
      output = Timeline.format_event_timeline(report_with_async_event(), color: false)

      # The injector event is not attributable to a command, but it still
      # belongs in the timeline rather than being silently dropped.
      assert output =~ "PaymentConfirmed"
    end

    test "names a poller-delivered, a telemetry and an injected event" do
      entries =
        for {source, index} <- Enum.with_index([:resource_poller, :telemetry, :injected]) do
          %Entry{
            timestamp: index,
            command_index: 0,
            event: %PaymentConfirmed{id: index},
            source: source
          }
        end

      report =
        FailureReport.new(
          seed: 1,
          run_number: 1,
          original_sequence: Sequence.linear([%CreateOrder{id: 1}]),
          shrunk_sequence: Sequence.linear([%CreateOrder{id: 1}]),
          failed_at_index: 0,
          failure_reason: Failure.check_failed(:TestCheck, "boom"),
          event_log: entries,
          model: TestModel,
          targets: [{TestAdapter, []}]
        )

      output = Timeline.format_event_timeline(report, color: false)

      assert output =~ "POL"
      assert output =~ "TEL"
      assert output =~ "EMT"
      refute output =~ "???", "an event source printed as unknown"
    end

    test "shows the source badge for a command-attributed non-command event" do
      report =
        FailureReport.new(
          seed: 1,
          run_number: 1,
          original_sequence: Sequence.linear([%CreateOrder{id: 1}]),
          shrunk_sequence: Sequence.linear([%CreateOrder{id: 1}]),
          failed_at_index: 0,
          failure_reason: Failure.check_failed(:TestCheck, "boom"),
          event_log: [
            %Entry{timestamp: 1, command_index: 0, event: %CreateOrder{id: 1}, source: :command},
            # A mock event recorded against command 0 (non-nil command_index):
            # it must render with its MOC badge, not as a bare command output, so
            # the mock's contribution stays visible.
            %Entry{
              timestamp: 2,
              command_index: 0,
              event: %PaymentConfirmed{id: 1},
              source: :mock
            }
          ],
          model: TestModel,
          targets: [{TestAdapter, []}]
        )

      output = strip_ansi(Timeline.format_event_timeline(report, color: false))

      assert output =~ "MOC"
      assert output =~ "CMD"
    end
  end

  # `reset/0` emits its escape unconditionally even under `color: false`, so
  # strip all ANSI to assert on plain text.
  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  describe "color: false" do
    test "the event timeline emits no escape bytes" do
      output = Timeline.format_event_timeline(report_with_async_event(), color: false)
      refute output =~ "\e[", "plain output leaked an ANSI escape sequence"
    end

    test "a linear timeline emits no escape bytes" do
      report = report_with_async_event()
      refute Timeline.format(report, color: false) =~ "\e["
    end
  end
end
