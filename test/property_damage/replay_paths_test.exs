defmodule PropertyDamage.ReplayPathsTest do
  # Every path that re-executes a failure reads each target's concrete
  # sequence from the report's `replay` term, so it works for every recorded
  # target, leaves included, even when the report's trace no longer holds the
  # choices: re-shrinking, step-by-step replay, trigger isolation and the
  # exports. A saved report carries the term, its path and the run, in a
  # format version older files cannot be mistaken for.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Analysis, Export, Failure, FailureReport, Persistence, Replay}
  alias PropertyDamage.Export.StepPlan
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.ReplayFixtures, as: R

  @model F.Model
  @seed 2
  @max_commands 8
  @version 14

  @base_url "http://localhost:4000"

  # "second" carries the bug: the failure is a divergence in "second" at a
  # root where it ran the rewrite's leaves.
  defp second_bug, do: [F.target("ref"), F.target("second", :random, %{bug: :credit})]

  # "ref" carries the bug: the failure is a divergence reported in "second"
  # at a root where the reference ran the rewrite's leaves.
  defp ref_bug, do: [F.target("ref", :random, %{bug: :credit}), F.target("second")]

  defp failing(targets) do
    assert {:error, %FailureReport{} = report} =
             R.run(@model, targets,
               seed: @seed,
               max_runs: 1,
               max_commands: @max_commands,
               replay_dir: R.tmp_dir!()
             )

    F.drain()
    report
  end

  # A single-target check failure where the one target ran the rewrite.
  defp check_failing do
    assert {:error, report} =
             R.run(R.CheckModel, [R.target("solo", :random, %{bug: :check})],
               seed: 1,
               max_runs: 1,
               max_commands: 6,
               replay_dir: R.tmp_dir!()
             )

    F.drain()
    report
  end

  defp term(report), do: R.field(report, :replay)

  defp without_traced(report, names) do
    %{report | trace: %{report.trace | expansion: Map.drop(report.trace.expansion, names)}}
  end

  defp without_trace_choices(report), do: %{report | trace: %{report.trace | expansion: nil}}

  defp identity(report),
    do: {report.kind, Failure.name(report.failure_reason), report.variant.index}

  defp leaves_at(report, name, root) do
    report |> term() |> Map.fetch!(:choices) |> Map.fetch!(name) |> Enum.at(root)
  end

  describe "shrink_further/2" do
    test "re-shrinks a report whose second target ran leaves, keeping the failure" do
      report = failing(second_bug())
      assert %{entry: "Refund[1]"} = leaves_at(report, "second", report.failed_at_index)

      assert {:ok, again} = PropertyDamage.shrink_further(report, max_time_ms: 5_000)
      assert identity(again) == identity(report)
    end

    test "reads the replay term when the trace does not record the target" do
      report = report_without_second()

      assert {:ok, again} = PropertyDamage.shrink_further(report, max_time_ms: 5_000)
      assert identity(again) == identity(report)
      F.drain()
    end

    test "raises naming replay_dir: when the report records neither the term nor the expansions" do
      report =
        second_bug()
        |> failing()
        |> R.put_field(:replay, nil)
        |> Map.put(:expansions, nil)

      assert {:raised, %ArgumentError{message: message}} =
               F.outcome(fn -> PropertyDamage.shrink_further(report, max_time_ms: 5_000) end)

      assert message =~ "replay_dir:"
      F.drain()
    end
  end

  defp report_without_second do
    report = failing(second_bug())
    stripped = without_traced(report, ["second"])
    refute Map.has_key?(stripped.trace.expansion, "second")
    stripped
  end

  describe "Replay" do
    test "run/2 on the second target steps through its leaves, one step each" do
      report = second_bug() |> failing() |> without_trace_choices()
      recorded = Enum.flat_map(term(report).choices["second"], & &1.commands)

      assert {:ok, steps} =
               Replay.run(report, targets: [F.target("second", :random, %{bug: :credit})])

      assert Enum.map(steps, & &1.command) == recorded
      assert length(steps) == length(recorded)
      assert Enum.any?(steps, &(&1.leaf_index != nil))
      F.drain()
    end

    test "start/2 steps through the second target's leaves until done" do
      report = second_bug() |> failing() |> without_trace_choices()
      recorded = Enum.flat_map(term(report).choices["second"], & &1.commands)

      assert {:ok, session} =
               Replay.start(report, targets: [F.target("second", :random, %{bug: :credit})])

      {commands, session} = step_all(session, [])
      :ok = Replay.stop(session)

      assert commands == recorded
      F.drain()
    end
  end

  defp step_all(session, acc) do
    case Replay.step(session) do
      {:ok, session, step} -> step_all(session, [step.command | acc])
      {:done, session} -> {Enum.reverse(acc), session}
    end
  end

  describe "Analysis.isolate_trigger/2" do
    test "varies the reference's concrete commands when the reference ran leaves" do
      report = failing(ref_bug())
      at_failure = leaves_at(report, "ref", report.failed_at_index)
      assert %{entry: "Refund[1]"} = at_failure

      assert {:ok, result} = Analysis.isolate_trigger(report)
      assert result.trigger_command in at_failure.commands
      F.drain()
    end

    test "still refuses a non-reference target that ran leaves" do
      report = failing(second_bug())

      assert {:raised, %ArgumentError{message: message}} =
               F.outcome(fn ->
                 Analysis.isolate_trigger(report,
                   targets: [F.target("second", :random, %{bug: :credit})]
                 )
               end)

      assert message =~ "isolate_trigger/2"
      assert message =~ ~s("second")
    end
  end

  describe "export" do
    test "the step plan holds the reference's leaves from the replay term" do
      report = failing(ref_bug())
      stripped = without_trace_choices(report)
      ref = Enum.flat_map(term(report).choices["ref"], & &1.commands)

      roots = for %{phase: :root, command: command} <- StepPlan.build(stripped, nil), do: command
      assert roots == ref
      assert Enum.any?(roots, &is_struct(&1, F.Credit))
    end

    test "each script holds the reference's leaves from the replay term" do
      report = check_failing()
      stripped = without_trace_choices(report)
      assert %{entry: "Refund[1]"} = leaves_at(report, "solo", report.failed_at_index)

      roots = for %{phase: :root, command: command} <- StepPlan.build(stripped, nil), do: command
      assert roots == Enum.flat_map(term(report).choices["solo"], & &1.commands)

      for language <- [:elixir, :python, :curl] do
        script = Export.to_script(stripped, language, base_url: @base_url)
        assert script =~ "Credit", "the #{language} script does not run the leaves"
      end

      assert Export.to_livebook(stripped, base_url: @base_url) =~ "Credit"
    end

    test "the ExUnit export replays the artifact when the report has one" do
      report = check_failing()
      path = R.replay_path!(report)

      assert Export.to_exunit(report) =~ "only: [replay: #{inspect(path)}]"
    end

    test "the ExUnit export runs the seed when the report has no artifact" do
      report = check_failing() |> R.put_field(:replay_path, nil)
      exunit = Export.to_exunit(report)

      assert exunit =~ "seed: #{report.seed}"
      refute exunit =~ "only: [replay:"
    end
  end

  describe "persistence" do
    test "a saved report round-trips the replay term, its path and the run" do
      report = failing(second_bug())
      {:ok, path} = Persistence.save(report, R.tmp_dir!())

      assert <<"PD", @version, _rest::binary>> = File.read!(path)
      assert {:ok, loaded} = Persistence.load(path)

      for field <- [:replay, :replay_path, :run] do
        assert Map.fetch!(loaded, field) == Map.fetch!(report, field)
      end

      assert R.field(loaded, :replay) == R.term!(R.replay_path!(report))
    end

    test "a file of format version 13 is refused" do
      report = failing(second_bug())
      {:ok, path} = Persistence.save(report, R.tmp_dir!())

      <<"PD", _version, rest::binary>> = File.read!(path)
      File.write!(path, <<"PD", 13, rest::binary>>)

      assert Persistence.load(path) == {:error, {:unsupported_format_version, 13, @version}}
    end

    test "a version-14 file whose report lacks the replay field is refused" do
      report = failing(second_bug())
      {:ok, path} = Persistence.save(report, R.tmp_dir!())

      <<"PD", @version, _checksum::32, payload::binary>> = File.read!(path)
      envelope = :erlang.binary_to_term(payload)
      stripped = %{envelope | report: Map.delete(envelope.report, :replay)}
      binary = :erlang.term_to_binary(stripped, [:compressed])
      File.write!(path, <<"PD", @version, :erlang.crc32(binary)::32, binary::binary>>)

      assert {:error, reason} = Persistence.load(path)
      assert R.reason_text(reason) =~ "replay"
    end
  end

  describe "fixture smoke" do
    test "with the bug in the reference, the reference ran leaves at the failing root" do
      assert {:error, report} =
               R.smoke_run(
                 model: @model,
                 targets: ref_bug(),
                 seed: @seed,
                 max_runs: 1,
                 max_commands: @max_commands,
                 compare: [converge_within: 1]
               )

      F.drain()
      assert report.variant.name == "second"
      assert %{entry: "Refund[1]"} = Enum.at(report.expansions["ref"], report.failed_at_index)
    end

    test "CheckModel fails in its one target where it ran the rewrite" do
      assert {:error, report} =
               R.smoke_run(
                 model: R.CheckModel,
                 targets: [R.target("solo", :random, %{bug: :check})],
                 seed: 1,
                 max_runs: 1,
                 max_commands: 6
               )

      F.drain()
      assert report.kind == :check_failed
      assert %{entry: "Refund[1]"} = Enum.at(report.expansions["solo"], report.failed_at_index)
    end
  end
end
