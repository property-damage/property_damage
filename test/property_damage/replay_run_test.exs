defmodule PropertyDamage.ReplayRunTest do
  # How a run under `only:` treats what surrounds the one run it executes: an
  # artifact recorded for another model is refused before any setup, a replay
  # that fails another way than the artifact records says so, and the seed
  # library's seeds are not run.
  use ExUnit.Case, async: true

  alias PropertyDamage.SeedLibrary
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.ReplayFixtures, as: R

  @seed 2
  @max_commands 8

  defp targets, do: [F.target("ref"), F.target("second", :random, %{bug: :credit})]

  defp artifact! do
    assert {:error, report} =
             R.run(F.Model, targets(),
               seed: @seed,
               max_runs: 1,
               max_commands: @max_commands,
               replay_dir: R.tmp_dir!()
             )

    F.drain()
    {report, R.replay_path!(report)}
  end

  test "an artifact of another model is an option error naming both, before any setup" do
    {_report, path} = artifact!()

    assert {:raised, %ArgumentError{message: message}} =
             F.outcome(fn ->
               R.run(R.CleanModel, targets(), only: [replay: path], replay_dir: false)
             end)

    assert message =~ inspect(F.Model)
    assert message =~ inspect(R.CleanModel)
    refute_received {:setup, _}
  end

  test "a replay that fails at another root than the artifact records says it did not reproduce" do
    {report, path} = artifact!()
    recorded = "root_index: #{report.failed_at_index}"
    text = File.read!(path)
    assert text =~ recorded
    File.write!(path, String.replace(text, recorded, "root_index: 99"))

    assert {:error, replayed} =
             R.run(F.Model, targets(), only: [replay: path], replay_dir: R.tmp_dir!())

    F.drain()
    assert replayed.failed_at_index == report.failed_at_index
    printed = R.text(replayed)
    assert printed =~ "did not reproduce"
    refute printed =~ "artifact reproduced"
  end

  test "only: runs the run it names and none of the seed library's seeds" do
    path = Path.join(R.tmp_dir!(), "seeds.json")
    {:ok, library} = SeedLibrary.add_seed(SeedLibrary.new(), 12_345)
    :ok = SeedLibrary.save(library, path)

    passing = [F.target("ref"), F.target("second")]

    assert {:ok, _stats} =
             R.run(F.Model, passing,
               seed: @seed,
               max_commands: @max_commands,
               seed_library: path,
               only: [run: 2],
               replay_dir: false
             )

    messages = F.drain()
    assert F.setups(messages, "ref") == 1
    assert F.setups(messages, "second") == 1
  end
end
