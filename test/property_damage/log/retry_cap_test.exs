defmodule PropertyDamage.Log.RetryCapTest do
  # The retry cap (DR-054 decision 13): a step keeps the lines of its first
  # attempt and of its last `keep_attempts` attempts, and the report prints
  # each gap with its count. The cap drops whole attempts, holds memory at the
  # sink, counts a stutter retry as an attempt of the same step, and
  # `log: [keep_attempts: n]` is validated like any run option.
  use ExUnit.Case, async: true

  alias PropertyDamage.Runtime.Sink
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.LogFixtures, as: F

  setup do
    F.compile!()
    :ok
  end

  # A run whose first root settles after `attempts` attempts, each logging
  # two lines; the second root fails, so the run reports.
  defp spin_report(attempts, extra \\ [], config \\ %{}) do
    config =
      Map.merge(%{quiet: true, spin_at: attempts, spin_detail: true, fail_at: 1}, config)

    F.report!(F.SpinModel, [F.target("alice", config)], extra)
  end

  defp step_zero(report), do: report |> F.plain() |> F.listing(nil) |> F.block("[0]")

  defp attempt_lines(range),
    do: Enum.flat_map(range, &["spin attempt #{&1}", "spin detail #{&1}"])

  describe "counts through a real settle run" do
    test "one attempt keeps all its lines and shows no gap" do
      assert report = spin_report(1)
      assert F.shown_logs(step_zero(report)) == attempt_lines(1..1)
    end

    test "four attempts keep all four and show no gap" do
      assert report = spin_report(4)
      assert F.shown_logs(step_zero(report)) == attempt_lines(1..4)
    end

    test "five attempts omit the second one" do
      assert report = spin_report(5)

      assert F.shown_logs(step_zero(report)) ==
               attempt_lines(1..1) ++
                 [{:gap, "... 1 attempt omitted (2 lines)"}] ++ attempt_lines(3..5)
    end

    test "300 attempts keep the first and 298 to 300 and count the 296 between" do
      assert report = spin_report(300)

      assert F.shown_logs(step_zero(report)) ==
               attempt_lines(1..1) ++
                 [{:gap, "... 296 attempts omitted (592 lines)"}] ++ attempt_lines(298..300)
    end

    test "keep_attempts: 5 keeps the first and 296 to 300 and omits 294" do
      assert report = spin_report(300, log: [keep_attempts: 5])

      assert F.shown_logs(step_zero(report)) ==
               attempt_lines(1..1) ++
                 [{:gap, "... 294 attempts omitted (588 lines)"}] ++ attempt_lines(296..300)
    end

    test "the gap holds the count with thousands separators" do
      assert report = spin_report(1_500)

      assert [{:gap, "... 1,496 attempts omitted (2,992 lines)"}] =
               report |> step_zero() |> F.shown_logs() |> Enum.filter(&is_tuple/1)
    end

    test "colored output holds the same gap text, and markdown carries it in the fence" do
      assert report = spin_report(5)

      assert F.strip_ansi(F.colored(report)) == F.plain(report)
      assert F.markdown(report) =~ "        ... 1 attempt omitted (2 lines)\n"
    end

    test "the trace holds the gap in its place among the step's lines" do
      assert report = spin_report(5)
      lines = F.trace_lines(report.trace, Position.prefix(0))

      assert [first, detail, gap, third | _rest] = lines
      assert F.messages([first, detail]) == ["spin attempt 1", "spin detail 1"]
      assert is_struct(gap, F.gap_module())
      assert {F.field(gap, :attempts), F.field(gap, :lines)} == {1, 2}
      assert F.field(third, :message) == "spin attempt 3"
    end
  end

  describe "the gap never splits a line" do
    test "the lines around it are whole lines of whole attempts" do
      assert report = spin_report(300, [], %{spin_multiline: true})
      entries = step_zero(report)
      at = Enum.find_index(entries, &(&1.kind == :gap))

      assert at
      assert Enum.at(entries, at - 1).message == "spin detail 1"
      assert Enum.at(entries, at + 1).message == "spin attempt 298"

      F.assert_string_continues(
        report |> F.plain() |> F.listing(nil),
        "first line",
        "second line"
      )

      first_at = Enum.find_index(entries, &(&1.message == "first line"))
      assert first_at < at
    end
  end

  describe "the sink holds at most keep_attempts + 1 attempts" do
    # Three lines per attempt, `attempts` attempts, a check after every write.
    defp drive(sink, attempts, bound) do
      for attempt <- 1..attempts, n <- 1..3 do
        :ok = Sink.add_line(sink, %{F.line("a#{attempt} l#{n}") | attempt: attempt})
        held = F.call(Sink, :attempts_held, [sink])
        assert held <= bound, "after attempt #{attempt} line #{n} the sink holds #{held}"
      end
    end

    defp gap_of(sink) do
      assert [gap] = Enum.filter(Sink.lines(sink), &is_struct(&1, F.gap_module()))
      gap
    end

    test "at most four with the default, through 1,000 attempts" do
      {:ok, sink} = F.call(Sink, :start_link, [[]])
      drive(sink, 1_000, 4)

      gap = gap_of(sink)
      assert {F.field(gap, :attempts), F.field(gap, :lines)} == {996, 2_988}

      kept = for line <- Sink.lines(sink), is_struct(line, F.line_module()), do: line.attempt
      assert kept == [1, 1, 1] ++ Enum.flat_map(998..1_000, &[&1, &1, &1])
      Sink.stop(sink)
    end

    test "at most n + 1 with keep_attempts: n" do
      for keep <- [1, 2, 5] do
        {:ok, sink} = F.call(Sink, :start_link, [[keep_attempts: keep]])
        drive(sink, 1_000, keep + 1)

        gap = gap_of(sink)
        assert {F.field(gap, :attempts), F.field(gap, :lines)} == {999 - keep, 3 * (999 - keep)}
        Sink.stop(sink)
      end
    end

    test "a line for an attempt already dropped is counted, not kept" do
      {:ok, sink} = F.call(Sink, :start_link, [[keep_attempts: 1]])
      drive(sink, 4, 2)
      before = gap_of(sink)

      :ok = Sink.add_line(sink, %{F.line("late") | attempt: 2})

      lines = Sink.lines(sink)
      refute "late" in F.messages(lines)
      gap = gap_of(sink)
      assert F.field(gap, :lines) == F.field(before, :lines) + 1
      assert F.field(gap, :attempts) == F.field(before, :attempts)
    end
  end

  describe "a stutter retry counts as an attempt of the step" do
    test "the first execution and the last keep_attempts of the combined order stay" do
      # Four settle attempts, then one stutter retry (attempt 5 of the
      # adapter) that answers another value, so the report is the idempotency
      # violation: with keep_attempts: 2 the step keeps 1, 4 and the retry.
      report =
        spin_report(
          4,
          [stutter: [probability: 1.0, max_repeats: 1, delay_ms: 0], log: [keep_attempts: 2]],
          %{spin_skew_retry: true}
        )

      assert F.plain(report) =~ "idempotency violation"

      assert F.shown_logs(step_zero(report)) ==
               attempt_lines(1..1) ++
                 [{:gap, "... 2 attempts omitted (4 lines)"}] ++ attempt_lines(4..5)
    end
  end

  describe "the log: option" do
    test "accepts keep_attempts: with a positive integer" do
      assert %PropertyDamage.FailureReport{} = spin_report(2, log: [keep_attempts: 1])
    end

    test "refuses a zero, a negative, a non-integer and an unknown key, naming the problem" do
      cases = [
        {[keep_attempts: 0], "keep_attempts"},
        {[keep_attempts: -2], "keep_attempts"},
        {[keep_attempts: 2.5], "keep_attempts"},
        {[keep_attempts: "3"], "keep_attempts"},
        {[keep: 3], "keep"}
      ]

      for {log, fragment} <- cases do
        error =
          assert_raise NimbleOptions.ValidationError, fn ->
            F.run(F.Model, [F.target("alice")], log: log)
          end

        message = Exception.message(error)
        assert message =~ "log", "#{inspect(log)}: #{message}"
        assert message =~ fragment, "#{inspect(log)}: #{message}"
        refute message =~ "unknown options [:log]", "#{inspect(log)}: #{message}"
      end
    end
  end

  # The cases `run/1` refuses, for the paths that take `log: [keep_attempts: n]`
  # after a run.
  @refused [keep_attempts: 0, keep_attempts: -2, keep_attempts: 2.5, keep_attempts: "3"]

  defp assert_refused(fun) do
    for {key, value} <- @refused do
      error = assert_raise NimbleOptions.ValidationError, fn -> fun.([{key, value}]) end
      message = Exception.message(error)
      assert message =~ "keep_attempts", "#{inspect(value)}: #{message}"
      refute message =~ "unknown options [:log]", "#{inspect(value)}: #{message}"
    end
  end

  describe "shrink_further/2 takes log: [keep_attempts: n]" do
    test "the further-shrunk report keeps the first and the last n attempts" do
      report = spin_report(300)

      assert {:ok, smaller} = PropertyDamage.shrink_further(report, log: [keep_attempts: 5])
      refute smaller == report

      assert F.shown_logs(step_zero(smaller)) ==
               attempt_lines(1..1) ++
                 [{:gap, "... 294 attempts omitted (588 lines)"}] ++ attempt_lines(296..300)
    end

    test "refuses the values run/1 refuses" do
      report = spin_report(2)
      assert_refused(&PropertyDamage.shrink_further(report, log: &1))
    end
  end

  describe "Replay.start/2 takes log: [keep_attempts: n]" do
    test "the session keeps the first and the last n attempts of a step" do
      report = spin_report(300)

      assert {:ok, session} = PropertyDamage.Replay.start(report, log: [keep_attempts: 5])
      assert {:ok, session, _step} = PropertyDamage.Replay.step(session)

      lines = Map.fetch!(session.exec_state.logs, Position.prefix(0))
      PropertyDamage.Replay.stop(session)

      assert [gap] = Enum.filter(lines, &is_struct(&1, F.gap_module()))
      assert {F.field(gap, :attempts), F.field(gap, :lines)} == {294, 588}
    end

    test "refuses the values run/1 refuses" do
      report = spin_report(2)
      assert_refused(&PropertyDamage.Replay.start(report, log: &1))
    end
  end
end
