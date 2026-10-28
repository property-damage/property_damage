defmodule PropertyDamage.Log.LogFixturesReplayTest do
  # `LogFixtures.run/3` drives a saved replay artifact: it passes no `seed:`
  # when the caller gives `only: [replay: path]`, because the artifact records
  # the seed and the run rejects a second one.
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.TmpPath

  setup do
    F.compile!()
    dir = TmpPath.unique("pd_fixtures_replay")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "run/3 replays an artifact an earlier run/3 saved", %{dir: dir} do
    targets = [F.target("alice", %{quiet: true, fail_at: 1})]
    artifact = F.report!(F.Model, targets, replay_dir: dir)
    assert artifact.replay_status == :written

    assert {:error, %FailureReport{} = replayed} =
             F.run(F.Model, targets, only: [replay: artifact.replay_path])

    assert replayed.seed == artifact.seed
  end
end
