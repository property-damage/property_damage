defmodule PropertyDamage.Log.LogFilterTest do
  # Tag filters on the failure report's log lines (DR-054 decisions 10, 11
  # and 14): `log: [only: tags, except: tags]` hides whole lines by tag in the
  # terminal and markdown reports, on every path that builds a report, and
  # in `PropertyDamage.ExUnit.format_failure/2`. The report prints the filter
  # it applied and warns about a tag no line carries. A filter is a view of a
  # finished report: it never changes how a run keeps lines.
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.TmpPath

  setup do
    F.compile!()
    dir = TmpPath.unique("pd_log_filter")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # The report printed with `log` as the format's filter.
  defp plain(report, log), do: Formatter.format(report, :terminal, color: false, log: log)

  defp shown(report, log), do: report |> plain(log) |> F.step_zero_shown()

  defp provenance(text) do
    for line <- String.split(text, "\n"), String.contains?(line, "Log filter"), do: line
  end

  defp warnings(text) do
    for line <- String.split(text, "\n"), String.contains?(line, "Log warning"), do: line
  end

  describe "only:" do
    test "shows the lines that carry a listed tag and every untagged line" do
      report = F.filter_report!()

      assert shown(report, only: [:headers]) == ["plain line", "accept: json"]
      assert shown(report, only: [:seed]) == ["plain line", "SEED-HIDDEN"]

      assert shown(report, only: [:http]) == [
               "plain line",
               "GET /a",
               "accept: json",
               "BODY-HIDDEN"
             ]

      assert shown(report, only: [:seed, :headers]) == [
               "plain line",
               "accept: json",
               "SEED-HIDDEN"
             ]
    end
  end

  describe "except:" do
    test "hides the lines that carry a listed tag and keeps the untagged ones" do
      report = F.filter_report!()

      assert shown(report, except: [:body]) == [
               "plain line",
               "GET /a",
               "accept: json",
               "SEED-HIDDEN"
             ]

      assert shown(report, except: [:http]) == ["plain line", "SEED-HIDDEN"]
    end

    test "wins over only: for a line that carries both" do
      report = F.filter_report!()

      assert shown(report, only: [:http], except: [:body]) ==
               ["plain line", "GET /a", "accept: json"]
    end
  end

  describe "whole lines" do
    test "a shown line prints exactly as without the filter, offsets included" do
      report = F.filter_report!()
      unfiltered = report |> F.plain() |> F.listing(nil)
      hidden = ["GET /a", "BODY-HIDDEN", "SEED-HIDDEN"]

      filtered = report |> plain(only: [:headers]) |> F.listing(nil)

      assert Enum.any?(unfiltered, &String.contains?(&1, "GET /a")), "control: they print"
      assert filtered == Enum.reject(unfiltered, fn line -> Enum.any?(hidden, &(line =~ &1)) end)
    end

    test "a multi-line message keeps every line when shown and none when hidden" do
      script = %{0 => [{:log_http, "hidden one\nhidden two"}, {:log_seed, "first\nsecond"}]}
      report = F.filter_report!([], %{script: script})
      text = plain(report, only: [:seed])

      F.assert_string_continues(F.listing(text, nil), "first", "second")
      refute text =~ "hidden one"
      refute text =~ "hidden two"
    end
  end

  describe "the provenance line" do
    test "is printed once in terminal and markdown, naming the tags and the log: option" do
      report = F.filter_report!(log: [only: [:http], except: [:body]])

      for text <- [F.plain(report), F.markdown(report)] do
        assert [line] = provenance(text)
        assert line =~ "only: [:http]"
        assert line =~ "except: [:body]"
        assert line =~ "log:"
        refute line =~ "PD_LOG"
      end
    end

    test "is absent without a filter" do
      report = F.filter_report!()

      for text <- [F.plain(report), F.markdown(report)], do: refute(text =~ "Log filter")
    end

    test "colored output holds the same text" do
      report = F.filter_report!(log: [only: [:http]])
      assert F.strip_ansi(F.colored(report)) == F.plain(report)
    end
  end

  describe "the unknown-tag warning" do
    test "names each listed tag no line carries, once, in the order given" do
      report = F.filter_report!(log: [only: [:sed, :http, :sed], except: [:zed, :sed]])

      for text <- [F.plain(report), F.markdown(report)] do
        assert [line] = warnings(text)
        assert line =~ ":sed, :zed"
        refute line =~ ":http"
      end
    end

    test "is not printed when every listed tag is carried" do
      report = F.filter_report!(log: [only: [:http, :seed], except: [:body]])

      for text <- [F.plain(report), F.markdown(report)], do: refute(text =~ "Log warning")
    end

    test "counts a tag only a setup line carries as known" do
      lines = [F.line("seeded", tags: [:ledger])]
      report = F.filter_report!(setup_log: lines, log: [only: [:ledger]])

      refute F.plain(report) =~ "Log warning"
    end
  end

  describe "the option" do
    test "is accepted by run/1 and kept on the report" do
      report = F.filter_report!(log: [only: [:http], except: [:body]])

      assert F.field(report, :log_filter) == [only: [:http], except: [:body]]
      assert F.step_zero_shown(F.plain(report)) == ["plain line", "GET /a", "accept: json"]
    end

    test "invalid values raise a NimbleOptions error that names the key" do
      for {key, bad} <- [
            only: [],
            except: [],
            only: :http,
            only: ["http"],
            except: [1],
            only: [:http, "body"]
          ] do
        error =
          assert_raise NimbleOptions.ValidationError, fn ->
            F.run(F.Model, [F.target("alice")], log: [{key, bad}])
          end

        assert Exception.message(error) =~ ":#{key}"
        refute Exception.message(error) =~ "unknown options"
      end
    end

    test "control: an unknown key under log: is still an option error" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          F.run(F.Model, [F.target("alice")], log: [bogus: [:http]])
        end

      assert Exception.message(error) =~ ":bogus"
    end

    test "keep_attempts: beside a filter keeps the gap counts" do
      config = %{quiet: true, spin_at: 5, spin_detail: true, fail_at: 1}
      targets = [F.target("alice", config)]

      plain_report = F.report!(F.SpinModel, targets, log: [keep_attempts: 3])

      filtered =
        F.report!(F.SpinModel, [F.target("alice", config)],
          log: [only: [:http], keep_attempts: 3]
        )

      gap = {:gap, "... 1 attempt omitted (2 lines)"}

      assert gap in F.step_zero_shown(F.plain(plain_report)), "control: the gap prints"
      assert gap in F.step_zero_shown(F.plain(filtered))
      assert F.step_zero_shown(F.plain(filtered)) == F.step_zero_shown(F.plain(plain_report))
    end

    test "a filter never changes the lines a run keeps" do
      report = F.filter_report!(log: [only: [:headers]])

      messages =
        F.messages(F.trace_lines(report.trace, Position.prefix(0)))

      assert messages == ["plain line", "GET /a", "accept: json", "BODY-HIDDEN", "SEED-HIDDEN"]
    end
  end

  describe "format_failure" do
    test "/2 honors log: and the report's own filter is replaced, never merged" do
      report = F.filter_report!(log: [only: [:http]])

      text =
        report |> PropertyDamage.ExUnit.format_failure(log: [only: [:seed]]) |> F.strip_ansi()

      assert F.step_zero_shown(text) == ["plain line", "SEED-HIDDEN"]
      assert [line] = provenance(text)
      assert line =~ ":seed"
      refute line =~ ":http"
    end

    test "/2 on a report with no filter filters it" do
      report = F.filter_report!()

      text =
        report |> PropertyDamage.ExUnit.format_failure(log: [except: [:http]]) |> F.strip_ansi()

      assert F.step_zero_shown(text) == ["plain line", "SEED-HIDDEN"]
    end

    test "/1 prints the run's in-code filter" do
      report = F.filter_report!(log: [only: [:headers]])
      text = report |> PropertyDamage.ExUnit.format_failure() |> F.strip_ansi()

      assert F.step_zero_shown(text) == ["plain line", "accept: json"]
      assert [line] = provenance(text)
      assert line =~ "log:"
    end

    test "/2 rejects keep_attempts: and any other key with an ArgumentError" do
      report = F.filter_report!()

      for bad <- [[keep_attempts: 2], [only: [:http], keep_attempts: 2], [bogus: [:a]]] do
        assert_raise ArgumentError, ~r/log:|keep_attempts|only|except/, fn ->
          PropertyDamage.ExUnit.format_failure(report, log: bad)
        end
      end
    end

    test "/2 validates its filter like the run option" do
      report = F.filter_report!()

      for bad <- [[only: []], [except: [1]], [only: :http]] do
        assert_raise NimbleOptions.ValidationError, fn ->
          PropertyDamage.ExUnit.format_failure(report, log: bad)
        end
      end
    end
  end

  describe "the paths that build a report" do
    test "shrink_further/2 keeps the report's filter" do
      lines = [F.line("seeded", tags: [:seed])]

      report =
        F.report!(F.CapModel, [F.target("alice", %{quiet: true})],
          setup_log: lines,
          log: [only: [:headers]],
          max_commands: 12,
          max_runs: 20,
          seed: 7
        )

      assert {:ok, further} = PropertyDamage.shrink_further(report)
      assert F.field(further, :log_filter) == [only: [:headers]]
      assert [_line] = provenance(F.plain(further))
    end

    test "the replay call honors log:", %{dir: dir} do
      config = %{quiet: true, fail_at: 1, script: F.filter_script()}
      targets = [F.target("alice", config)]
      artifact = F.report!(F.Model, targets, replay_dir: dir)
      assert artifact.replay_status == :written

      assert {:error, replayed} =
               PropertyDamage.run(
                 model: F.Model,
                 targets: targets,
                 only: [replay: artifact.replay_path],
                 replay_dir: false,
                 validate: false,
                 log: [only: [:seed]]
               )

      text = F.plain(replayed)
      assert F.step_zero_shown(text) == ["plain line", "SEED-HIDDEN"]
      assert [line] = provenance(text)
      assert line =~ "log:"
    end

    test "an only: [run: n] report carries the filter" do
      report = F.filter_report!(only: [run: 1], log: [except: [:seed]])
      assert F.field(report, :log_filter) == [except: [:seed]]
    end
  end

  describe "setup lines and adapter notes" do
    defp setup_lines do
      at = System.monotonic_time(:millisecond) - 60_000

      [
        F.line("first seed", tags: [:seed], at: at),
        F.line("second row", tags: [:seed, :rows], at: at + 7)
      ]
    end

    defp setup_entries(text), do: text |> F.section("Setup") |> F.trimmed() |> F.items()

    test "are filtered by the same rule, and offsets do not move" do
      report = F.filter_report!(setup_log: setup_lines())

      full = for {:entry, e} <- setup_entries(F.plain(report)), do: e
      assert Enum.map(full, & &1.offset) == [0, 7]

      only_rows = for {:entry, e} <- setup_entries(plain(report, only: [:rows])), do: e
      assert Enum.map(only_rows, &{&1.message, &1.offset}) == [{"second row", 7}]
    end

    test "the Setup section disappears when the filter hides all of its lines" do
      report = F.filter_report!(setup_log: setup_lines())

      assert F.plain(report) =~ "## Setup", "control: the section prints"
      refute plain(report, only: [:http]) =~ "## Setup"
      refute plain(report, except: [:seed]) =~ "## Setup"
    end

    test "the adapter setup/1 note disappears when the filter hides its lines" do
      report = F.filter_report!([], %{setup_log: true, teardown_log: true})
      note = fn text -> text |> F.listing(nil) |> F.note_block("adapter setup/1") end

      assert note.(F.plain(report)), "control: it prints"
      assert note.(plain(report, only: [:setup]))
      refute note.(plain(report, only: [:http]))
      refute note.(plain(report, except: [:setup]))
    end

    test "the adapter teardown/1 note keeps its untagged line under any filter" do
      report = F.filter_report!([], %{teardown_log: true})
      text = plain(report, only: [:http])

      assert F.note_block(F.listing(text, nil), "adapter teardown/1")
    end
  end
end
