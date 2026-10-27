defmodule PropertyDamage.Log.SetupLogTest do
  # `setup_log:` (DR-054 decision 8): the lines a test captured before the
  # run, printed once in a Setup section between Failure and Minimal
  # Reproduction, labeled as shared by every run. The option takes only the
  # lines `PropertyDamage.Log.capture/1` returns. The lines live in memory:
  # no saved report, replay artifact or compact output carries one, and the
  # JSON output holds them under `logs` only.
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport.Formatter
  alias PropertyDamage.Persistence
  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.TmpPath

  setup do
    F.compile!()
    dir = TmpPath.unique("pd_setup_log")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp quiet(config \\ %{}), do: Map.merge(%{quiet: true}, config)

  defp check_report(extra \\ []) do
    F.report!(F.Model, [F.target("alice", quiet(%{fail_at: 1}))], extra)
  end

  defp diverged_report(extra) do
    targets = [F.target("alice", quiet()), F.target("bob", quiet(%{skew_at: 1}))]
    report = F.report!(F.Model, targets, extra)
    assert report.kind == :diverged
    report
  end

  defp reports(extra), do: [check_report(extra), diverged_report(extra)]

  defp headings(text) do
    for "## " <> heading <- String.split(text, "\n"), do: heading
  end

  defp heading_index(text, name),
    do: text |> headings() |> Enum.find_index(&String.starts_with?(&1, name))

  describe "the option" do
    test "defaults to no lines" do
      assert F.field(check_report(), :setup_log, :missing) == []
    end

    test "takes a list of Line structs and the report keeps them as a value" do
      lines = F.setup_lines()
      assert F.field(check_report(setup_log: lines), :setup_log) == lines
    end

    test "anything else is an option error that names setup_log: and capture/1" do
      for invalid <- [:not_a_list, "text", [F.line("ok"), :not_a_line], [%{message: "a map"}]] do
        error =
          assert_raise NimbleOptions.ValidationError, fn ->
            F.run(F.Model, [F.target("alice")], setup_log: invalid)
          end

        assert Exception.message(error) =~ "setup_log:"
        assert Exception.message(error) =~ "PropertyDamage.Log.capture/1"
      end
    end
  end

  describe "the Setup section" do
    test "sits right after Failure and before Minimal Reproduction, once, on every kind" do
      for report <- reports(setup_log: F.setup_lines()) do
        text = F.plain(report)
        failure = heading_index(text, "Failure")
        setup = heading_index(text, "Setup")

        assert setup == failure + 1
        assert heading_index(text, "Minimal Reproduction") == setup + 1
        assert Enum.count(headings(text), &String.starts_with?(&1, "Setup")) == 1
        assert length(String.split(text, "seeded 3 accounts")) == 2
      end
    end

    test "opens with the label, then prints each line in the line form in timestamp order" do
      for report <- reports(setup_log: F.setup_lines()) do
        body = report |> F.plain() |> F.section("Setup") |> F.trimmed()

        assert hd(body) =~ "shared by every run"
        F.assert_line_form(body)

        entries = for {:entry, e} <- F.items(body), do: e

        assert Enum.map(entries, & &1.message) ==
                 ["opening the ledger", "%{alice: 100, bob: 0}", "seeded 3 accounts"]

        assert Enum.map(entries, & &1.tags) == [[], ["seed", "rows"], ["seed"]]
        assert Enum.map(entries, & &1.offset) == [0, 3, 125]
      end
    end

    test "lines with one timestamp keep the order they were given" do
      at = System.monotonic_time(:millisecond)
      lines = [F.line("given first", at: at), F.line("given second", at: at)]
      body = lines |> then(&F.plain(check_report(setup_log: &1))) |> F.section("Setup")

      messages = for {:entry, e} <- F.items(F.trimmed(body)), do: e.message
      assert messages == ["given first", "given second"]
    end

    test "is absent without setup_log: and with an empty one" do
      for extra <- [[], [setup_log: []]], report <- reports(extra) do
        refute F.plain(report) =~ "## Setup"
        refute F.markdown(report) =~ "## Setup"
      end
    end

    test "markdown carries the plain section body in one fence" do
      for report <- reports(setup_log: F.setup_lines()) do
        plain = F.plain(report)
        markdown = F.markdown(report)

        assert F.fenced_body(markdown, "Setup") == F.trimmed(F.section(plain, "Setup"))
        assert heading_index(markdown, "Setup") == heading_index(markdown, "Failure") + 1
      end
    end

    test "a setup line does not shift the event offsets of any target" do
      for report <- reports(setup_log: F.setup_lines()) do
        without = Map.put(report, :setup_log, [])

        assert F.listings(F.plain(report)) == F.listings(F.plain(without))
      end
    end

    test "colored output holds the same text" do
      report = check_report(setup_log: F.setup_lines())
      assert F.strip_ansi(F.colored(report)) == F.plain(report)
    end

    test "a function message is called when the report is formatted" do
      line = F.line(fn -> "computed late" end)
      body = F.plain(check_report(setup_log: [line])) |> F.section("Setup") |> F.trimmed()

      assert [%{message: "computed late"}] = for({:entry, e} <- F.items(body), do: e)
    end
  end

  describe "shrink_further/2" do
    test "keeps the setup lines of the report it was given" do
      lines = F.setup_lines()
      targets = [F.target("alice", quiet())]
      extra = [setup_log: lines, max_commands: 12, max_runs: 20, seed: 7]
      report = F.report!(F.CapModel, targets, extra)
      assert length(report.trace.plan.prefix) == 12, "control: the report is not shrunk"

      assert {:ok, further} = PropertyDamage.shrink_further(report)
      assert length(further.trace.plan.prefix) < 12, "control: it shrank"
      assert further.setup_log == lines
      assert F.plain(further) =~ "## Setup"
    end
  end

  describe "the replay path" do
    test "only: [replay: path] with setup_log: prints the Setup section", %{dir: dir} do
      targets = [F.target("alice", quiet(%{fail_at: 1}))]
      artifact = F.report!(F.Model, targets, replay_dir: dir)
      assert artifact.replay_status == :written

      assert {:error, replayed} =
               PropertyDamage.run(
                 model: F.Model,
                 targets: targets,
                 only: [replay: artifact.replay_path],
                 replay_dir: false,
                 validate: false,
                 setup_log: F.setup_lines()
               )

      text = F.plain(replayed)
      assert heading_index(text, "Setup") == heading_index(text, "Failure") + 1
      assert text =~ "seeded 3 accounts"
    end
  end

  describe "memory only" do
    defp sentinel_lines, do: [F.line(F.sentinel()), F.line(%{note: F.sentinel()})]

    # The decoded term of a saved file, inspected in full.
    defp saved_text(path) do
      bytes = File.read!(path)
      assert <<"PD", 15, _checksum::32, term::binary>> = bytes
      inspect(:erlang.binary_to_term(term), limit: :infinity, printable_limit: :infinity)
    end

    test "a saved and loaded report has setup_log: []", %{dir: dir} do
      lines = sentinel_lines()
      report = diverged_report(setup_log: lines)
      assert F.field(report, :setup_log) == lines
      assert F.plain(report) =~ F.sentinel(), "control: the report prints the sentinel"

      assert {:ok, path} = Persistence.save(report, dir)
      refute saved_text(path) =~ F.sentinel()

      loaded =
        case Persistence.load(path) do
          {:ok, loaded} -> loaded
          {:ok, loaded, _warnings} -> loaded
        end

      assert loaded.setup_log == []
      refute F.plain(loaded) =~ "## Setup"
    end

    test "a replay artifact holds no setup line", %{dir: dir} do
      report =
        F.report!(F.Model, [F.target("alice", quiet(%{fail_at: 1}))],
          replay_dir: dir,
          setup_log: sentinel_lines()
        )

      assert report.replay_status == :written
      files = Enum.filter(Path.wildcard(Path.join(dir, "**/*")), &File.regular?/1)
      assert files != [], "control: the directory holds the artifact"
      for file <- files, do: refute(File.read!(file) =~ F.sentinel(), "#{file} holds it")
    end

    test "the JSON holds the setup lines under logs only, and compact holds none" do
      report = check_report(setup_log: sentinel_lines())
      assert F.plain(report) =~ F.sentinel(), "control: the report prints the sentinel"

      json = report |> Formatter.format(:json) |> Jason.decode!()
      assert Jason.encode!(json["logs"]["setup"]) =~ F.sentinel()
      refute json |> Map.delete("logs") |> Jason.encode!() =~ F.sentinel()
      refute Formatter.format(report, :compact) =~ F.sentinel()
    end
  end
end
