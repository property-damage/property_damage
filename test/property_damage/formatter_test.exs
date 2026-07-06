defmodule PropertyDamage.FailureReport.FormatterTest do
  @moduledoc """
  Coverage for all four FailureReport.Formatter output formats (terminal,
  markdown, json, compact), which previously had no dedicated tests.
  """
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Sequence}
  alias PropertyDamage.FailureReport.Formatter

  defmodule CreateAccount do
    defstruct [:currency]
  end

  defp sut_failure do
    seq = Sequence.linear([%CreateAccount{currency: :USD}])

    FailureReport.new(
      seed: 512_902_757,
      run_number: 3,
      failed_at_index: 0,
      failure_reason: Failure.assertion_failed(:NonNegativeBalance, "Balance cannot be negative"),
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
      assert decoded["failure"]["type"] == "assertion_failed"
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
end
