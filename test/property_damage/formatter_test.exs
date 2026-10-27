defmodule PropertyDamage.FailureReport.FormatterTest do
  @moduledoc """
  Coverage for all four FailureReport.Formatter output formats (terminal,
  markdown, json, compact), which previously had no dedicated tests.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.{Failure, FailureReport, Placeholder, Sequence}
  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Sequence.Position

  defmodule CreateAccount do
    defstruct [:currency]
  end

  defmodule Observed do
    defstruct [:tag]
  end

  defmodule UseAccount do
    defstruct [:account_id, :note]
  end

  defp sut_failure do
    seq = Sequence.linear([%CreateAccount{currency: :USD}])

    FailureReport.new(
      seed: 512_902_757,
      run_number: 3,
      failed_at_index: 0,
      failure_reason: Failure.check_failed(:NonNegativeBalance, "Balance cannot be negative"),
      original_sequence: seq,
      shrunk_sequence: seq
    )
  end

  describe "format/3 across all formats" do
    test ":terminal renders a non-empty report naming the failure" do
      out = Formatter.format(sut_failure(), :terminal, color: false)
      assert is_binary(out) and out != ""
      assert out =~ "NonNegativeBalance"
      assert out =~ "512902757"
    end

    test ":markdown renders markdown headings" do
      out = Formatter.format(sut_failure(), :markdown)
      assert is_binary(out)
      assert out =~ "#"
      assert out =~ "NonNegativeBalance"
    end

    test ":json renders valid, decodable JSON carrying the seed and type" do
      out = Formatter.format(sut_failure(), :json)
      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["location"]["seed"] == 512_902_757
      assert decoded["failure"]["type"] == "check_failed"
    end

    test ":compact renders a single concise line/string" do
      out = Formatter.format(sut_failure(), :compact)
      # Formatter.format/2 is typed binary(), so an is_binary/1 guard here is
      # statically always-true; assert the meaningful property (non-empty).
      assert out != ""
    end

    test "every format tolerates a minimal report without crashing" do
      minimal =
        FailureReport.new(
          seed: 1,
          run_number: 0,
          failed_at_index: 0,
          failure_reason: :some_reason,
          original_sequence: Sequence.linear([]),
          shrunk_sequence: Sequence.linear([])
        )

      for fmt <- [:terminal, :markdown, :json, :compact] do
        assert is_binary(Formatter.format(minimal, fmt, color: false))
      end
    end
  end

  describe "color: false" do
    test ":terminal output contains no ANSI escape bytes (I1)" do
      out = Formatter.format(sut_failure(), :terminal, color: false)
      refute out =~ "\e[", "plain output leaked an ANSI escape sequence"
    end
  end

  # A report whose event log holds one event per source, all attributed to
  # the failing command.
  defp report_with_sources(sources) do
    seq = Sequence.linear([%CreateAccount{currency: :USD}])

    entries =
      for {source, index} <- Enum.with_index(sources) do
        %Entry{timestamp: index, command_index: 0, event: %Observed{tag: source}, source: source}
      end

    FailureReport.new(
      seed: 1,
      run_number: 1,
      failed_at_index: 0,
      failure_reason: Failure.check_failed(:NonNegativeBalance, "Balance cannot be negative"),
      original_sequence: seq,
      shrunk_sequence: seq,
      event_log: entries
    )
  end

  describe "event source badges" do
    test "names a poller-delivered, a telemetry and an injected event" do
      out =
        Formatter.format(
          report_with_sources([:resource_poller, :telemetry, :injected]),
          :terminal,
          color: false
        )

      assert out =~ "POL"
      assert out =~ "TEL"
      assert out =~ "EMT"
      refute out =~ "???", "an event source printed as unknown"
    end
  end

  describe "command arguments" do
    defp placeholder(offset) do
      %Placeholder{
        path: [:account_id],
        position: %Position{section: :setup, offset: offset},
        event_index: 0
      }
    end

    defp report_with_command(command) do
      seq = Sequence.linear([command])

      FailureReport.new(
        seed: 1,
        run_number: 1,
        failed_at_index: 0,
        failure_reason: Failure.check_failed(:NonNegativeBalance, "Balance cannot be negative"),
        original_sequence: seq,
        shrunk_sequence: seq
      )
    end

    test "two placeholders print as two whole ids" do
      first =
        Formatter.format(report_with_command(%UseAccount{account_id: placeholder(0)}), :terminal,
          color: false
        )

      second =
        Formatter.format(report_with_command(%UseAccount{account_id: placeholder(1)}), :terminal,
          color: false
        )

      assert first =~ inspect(placeholder(0))
      assert second =~ inspect(placeholder(1))
    end

    test "a wide value prints in full, with no marker" do
      # Values print whole (DR-055 decision 10), not cut to a width.
      wide = %{some_long_key_name: :another_long_value}
      assert String.length(inspect(wide)) > 30

      out =
        Formatter.format(report_with_command(%UseAccount{note: wide}), :terminal, color: false)

      assert out =~ "note: %{some_long_key_name: :another_long_value}"
      refute out =~ "..."
    end
  end
end
