defmodule PropertyDamage.ReplayArtifactAppModulesTest do
  # A replay artifact can name an atom that only an unlisted module of the
  # project holds, such as a constants module the model does not list. Inside
  # this suite the module is loaded already, so the replay runs in a new OS
  # process, as a regression test run alone would.
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.ReplayConstants

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  test "an atom of an unlisted module of a loaded application replays in a fresh VM", %{
    tmp_dir: dir
  } do
    {:error, _report} =
      PropertyDamage.run(
        model: ReplayConstants.Model,
        targets: [ReplayConstants.Adapter],
        seed: 1,
        max_runs: 5,
        replay_dir: dir
      )

    assert [artifact] = Path.wildcard(Path.join(dir, "*.replay.exs"))
    assert File.read!(artifact) =~ ~r/status: :replay_constant_(open|closed)/

    code = """
    try do
      {:error, report} =
        PropertyDamage.run(
          model: PropertyDamage.Test.ReplayConstants.Model,
          targets: [PropertyDamage.Test.ReplayConstants.Adapter],
          only: [replay: hd(System.argv())],
          replay_dir: false
        )

      IO.puts("REPLAYED kind=\#{report.report_kind}")
    rescue
      e in ArgumentError -> IO.puts("RAISED " <> Exception.message(e))
    end
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "-e", code, artifact],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    refute output =~ "RAISED", output
    assert output =~ "REPLAYED kind=check_failed", output
  end
end
