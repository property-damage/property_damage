defmodule PropertyDamage.Log.ReportTest do
  # Log lines in the printed failure report (DR-054 decision 12, DR-055
  # decision 6): each line sits under the step that wrote it, merged with the
  # step's events by timestamp, as `+S.SSs log   [tags] message`; a value or
  # function is formatted when the report is formatted; lines written before
  # a timeout kill survive; each compared target lists its own lines.
  #
  # Timing: the interleaving test sleeps 20 ms between the things it orders
  # (timestamps are milliseconds); the timeout test uses a 30 ms adapter
  # timeout against a 1 s sleep.
  use ExUnit.Case, async: false

  alias PropertyDamage.{CommandTimeoutError, Failure, FailureReport}
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.LogFixtures, as: F

  setup do
    F.compile!()
    :ok
  end

  defp quiet(config), do: Map.merge(%{quiet: true}, config)

  test "lines written before a timeout kill print under the timed-out step, with their tags and offsets" do
    # Timeout-kill survival: the lines are in the command's sink, not the killed Task.
    script = %{
      0 => [
        {:log_http_url, "GET /accounts/alice"},
        {:log_http, "waiting for bob"},
        {:sleep, 1_000}
      ]
    }

    target = F.target("alice", quiet(%{script: script}), F.timeout_adapter())
    report = F.report!(F.Model, [target])

    assert report.kind == :execution_failed

    assert %Failure{type: %Failure.Execution{detail: %CommandTimeoutError{}}} =
             report.failure_reason

    expected = [{"GET /accounts/alice", ["http", "url"]}, {"waiting for bob", ["http"]}]
    listing = F.listing(F.plain(report), nil)
    F.assert_logs(listing, "[0]", expected)
    F.assert_offsets_ordered(F.block(listing, "[0]"))

    lines = F.trace_lines(report.trace, Position.prefix(0))
    assert F.messages(lines) == ["GET /accounts/alice", "waiting for bob"]
    assert Enum.map(lines, &F.field(&1, :tags)) == [[:http, :url], [:http]]
  end

  test "a string prints as written, a value as its inspect, and a function when the report is formatted" do
    # Message forms and late evaluation: an Agent read at format time, raised markers.
    agent = :"log_report_agent_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_link(fn -> "agent value during the run" end, name: agent)

    script = %{
      0 => [
        {:log, "a plain string"},
        {:value, %{account: "alice", balance: 42}},
        {:agent_fun, agent},
        :raising_fun,
        :owned_agent_fun
      ]
    }

    config = quiet(%{script: script, owned_agent: true, fail_at: 1})
    report = F.report!(F.Model, [F.target("alice", config)])
    Agent.update(agent, fn _ -> "agent value after the run" end)

    text = F.plain(report)

    assert [string, value, read, raised, stopped] =
             text |> F.listing(nil) |> F.block("[0]") |> F.logs()

    assert string.message == "a plain string"
    assert F.entry_text(value) =~ ~s(account: "alice")
    assert F.entry_text(value) =~ "balance: 42"
    assert read.message == "agent value after the run"
    assert raised.message =~ "(log line raised: "
    assert raised.message =~ "a log function raised on purpose"
    assert stopped.message =~ "(log line raised: "

    assert F.plain(report) == text, "formatting twice changed the text"

    colored =
      report |> F.colored() |> F.strip_ansi() |> F.listing(nil) |> F.block("[0]") |> F.logs()

    assert Enum.map(colored, &F.entry_text/1) ==
             Enum.map([string, value, read, raised, stopped], &F.entry_text/1)
  end

  describe "a divergence" do
    test "each target's listing holds its own lines, each under its step with the step's events" do
      # :diverged: the Reference listing holds alice's lines, the Variant listing bob's.
      targets = [F.target("alice"), F.target("bob", %{skew_at: 1})]
      report = F.report!(F.Model, targets)
      assert report.kind == :diverged
      text = F.plain(report)

      for {header, name} <- [{"Reference", "alice"}, {"Variant", "bob"}] do
        listing = F.listing(text, header)

        for label <- ["[0]", "[1]"] do
          n = label |> String.trim("[") |> String.trim("]")

          F.assert_entries(F.listing(text, header), label, [
            {:log, "ran act #{n} by #{name}"},
            {:event, ~s(by: "#{name}")}
          ])
        end

        assert Enum.all?(F.all_logs(listing), &String.ends_with?(&1.message, "by #{name}"))
      end
    end

    test "a three-target run prints the reference's and the diverging target's lines, not the agreeing one's" do
      # Only the third target diverges: the second target's lines are not printed.
      targets = [F.target("alice"), F.target("bob"), F.target("carol", %{skew_at: 1})]
      report = F.report!(F.Model, targets)
      text = F.plain(report)

      assert F.all_logs(F.listing(text, "Reference")) != []
      assert Enum.all?(F.all_logs(F.listing(text, "Reference")), &(&1.message =~ "by alice"))
      assert F.all_logs(F.listing(text, "Variant")) != []
      assert Enum.all?(F.all_logs(F.listing(text, "Variant")), &(&1.message =~ "by carol"))
      refute text =~ "by bob"
    end
  end

  test "lines and events of a step interleave by timestamp, from one origin" do
    # A line before an injected event, a line after it, then the returned event.
    script = %{
      0 => [{:log, "before"}, {:inject, "between"}, {:sleep, 20}, {:log, "after"}, {:sleep, 20}]
    }

    report = F.report!(F.Model, [F.target("alice", quiet(%{script: script, fail_at: 1}))])
    listing = F.listing(F.plain(report), nil)

    F.assert_entries(listing, "[0]", [
      {:log, "before"},
      {:event, "Injected"},
      {:log, "after"},
      {:event, "Done"}
    ])

    F.assert_all_offsets_ordered(listing)
    F.assert_first_log_at_zero(listing)
  end

  test "a log line prints at the event column, tags in brackets, and continues at its message column" do
    # The line form, in plain and colored text, and markdown mirrors the plain listing.
    big = Map.new(1..8, fn i -> {:"account_#{i}", String.duplicate("x", 12)} end)

    script = %{
      0 => [
        {:log_http_url, "GET /accounts/alice"},
        {:log, "first line\nsecond line"},
        {:value, big}
      ]
    }

    report = F.report!(F.Model, [F.target("alice", quiet(%{script: script, fail_at: 1}))])
    plain = F.plain(report)

    for text <- [plain, F.strip_ansi(F.colored(report))] do
      listing = F.listing(text, nil)
      F.assert_line_form(listing)

      F.assert_logs(F.listing(text, nil), "[0]", [
        {"GET /accounts/alice", ["http", "url"]},
        {"first line", []},
        {"%{", []}
      ])

      F.assert_untagged(listing, "first line")
      F.assert_string_continues(listing, "first line", "second line")
      F.assert_value_continues(listing, "account_8:")
    end

    F.assert_markdown_mirrors(F.markdown(report), plain)
  end

  describe "adapter setup lines" do
    test "a setup/1 that logs and fails shows its line under the adapter setup/1 note" do
      # The :setup_failed report keeps the adapter's setup lines.
      config = %{setup_log: true, fail_setup: true}
      report = F.report!(F.Model, [F.target("alice", config)])
      assert report.kind == :setup_failed

      listing = F.listing(F.plain(report), nil)
      F.assert_note_lines(listing, "adapter setup/1", "setup by alice")
      assert [line] = F.note_block(listing, "adapter setup/1")
      assert line.tags == ["setup"]
    end

    test "a setup/1 that logs and succeeds prints its line before the first step" do
      # The adapter setup/1 note and its lines precede the first step.
      report = F.report!(F.Model, [F.target("alice", %{setup_log: true, fail_at: 1})])
      assert report.kind == :check_failed

      listing = F.listing(F.plain(report), nil)
      F.assert_note_lines(listing, "adapter setup/1", "setup by alice")
    end
  end

  test "a shrunk report shows one line per execution of each reported step, and none from shrink attempts" do
    # Only the reported run's lines: no duplicates and no line of a removed command.
    report =
      F.report!(F.CapModel, [F.target("alice")],
        seed: 5,
        max_runs: 5,
        max_commands: 6,
        shrink: true
      )

    assert report.shrink_iterations > 0, "control: the failure shrank"
    steps = FailureReport.steps(report)
    listing = F.listing(F.plain(report), nil)

    for {step, {label, entries}} <- Enum.zip(steps, F.blocks(listing)) do
      assert F.logs(entries) |> Enum.map(& &1.message) == ["ran act #{step.command.n} by alice"],
             "under #{label}: #{inspect(Enum.map(F.logs(entries), & &1.message))}"
    end

    reported = MapSet.new(steps, &"ran act #{&1.command.n} by alice")

    for line <- F.all_logs(listing),
        do: assert(line.message in reported, "a line of a command not reported: #{line.message}")
  end

  test "lines of a setup command, a teardown command and an expansion leaf sit under their labels" do
    # [setup i], [teardown i] and [i.j] each hold their own command's line.
    report = F.report!(F.PhaseModel, [F.target("alice")])
    listing = F.listing(F.plain(report), nil)

    F.assert_logs(listing, "[setup 0]", [{"prepare by alice", []}])
    F.assert_logs(listing, "[0.0]", [{"part 0.0 by alice", []}])
    F.assert_logs(listing, "[0.1]", [{"part 0.1 by alice", []}])
    F.assert_logs(listing, "[teardown 0]", [{"tidy by alice", []}])
    F.assert_logs(listing, "[0]", [])
  end
end
