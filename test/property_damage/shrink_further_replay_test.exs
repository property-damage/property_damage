defmodule PropertyDamage.ShrinkFurtherReplayTest do
  # A further shrink describes the run it shrank to: its expansion counts
  # are that run's, not the earlier report's, and its replay term and
  # artifact hold it, replacing the artifact the report came with. A report
  # with an artifact exports an ExUnit test that replays it on every target.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Export, FailureReport, Sequence}
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.ReplayFixtures, as: R

  defp targets, do: [F.target("ref"), F.target("second", :random, %{bug: :credit})]

  # The unshrunk failure of seed 3: several Refund roots before the failing
  # one, which a further shrink drops, so the counts must change.
  defp unshrunk(dir) do
    assert {:error, %FailureReport{} = report} =
             R.run(F.Model, targets(),
               seed: 3,
               max_runs: 1,
               max_commands: 12,
               shrink: false,
               replay_dir: dir
             )

    F.drain()
    report
  end

  # What each target's `expansions` entries count, per root module.
  defp counted(report) do
    for {name, ran} <- report.expansions, into: %{} do
      entries = for %{entry: entry} <- ran, entry != nil, do: entry
      {name, %{F.Refund => Enum.frequencies(entries)}}
    end
  end

  test "the counts describe the further-shrunk run" do
    report = unshrunk(R.tmp_dir!())
    assert {:ok, further} = PropertyDamage.shrink_further(report, max_time_ms: 5_000)
    F.drain()

    assert report.expansion_counts != counted(further)
    assert further.expansion_counts == counted(further)
  end

  test "the replay term holds the further-shrunk run and its artifact replaces the earlier one" do
    dir = R.tmp_dir!()
    report = unshrunk(dir)
    assert {:ok, further} = PropertyDamage.shrink_further(report, max_time_ms: 5_000)
    F.drain()

    roots = further |> FailureReport.shrunk_sequence() |> Sequence.to_list()

    assert further.replay_path == report.replay_path
    assert further.replay_status == :written
    assert Enum.map(further.replay.roots, & &1.command) == roots
    assert R.term!(further.replay_path) == further.replay
    assert R.files(dir) == [R.artifact_name(report)]
  end

  test "an ExUnit export of a report with an artifact replays it on every target" do
    targets = [R.target("checked", :random, %{bug: :check}), R.target("plain")]

    assert {:error, report} =
             R.run(R.CheckModel, targets,
               seed: 1,
               max_runs: 1,
               max_commands: 6,
               replay_dir: R.tmp_dir!()
             )

    F.drain()
    exunit = Export.to_exunit(report)

    assert exunit =~ "targets: #{FailureReport.targets_source(report)}"
    assert exunit =~ "only: [replay: #{inspect(report.replay_path)}]"
    refute exunit =~ "seed: #{report.seed},"
  end
end
