defmodule Mix.Tasks.Pd.ExplainWithCleanupTest do
  # async: false because the tests point TMPDIR, which is global to the VM, at
  # a private directory.
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport.CommandRunner
  alias PropertyDamage.Test.ExplainSupport, as: E
  alias PropertyDamage.Test.TmpPath

  @root Path.expand("../../..", __DIR__)

  setup do
    dir = TmpPath.unique("pd_cleanup")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    previous = System.get_env("TMPDIR")

    on_exit(fn ->
      if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
    end)

    private = Path.join(dir, "tmp")
    File.mkdir_p!(private)
    {:ok, dir: dir, private: private}
  end

  describe "CommandRunner.run/4 removes its temp files before it returns" do
    test "after a command that exits 0", %{private: private} do
      System.put_env("TMPDIR", private)
      assert {:ok, "hi\n"} = CommandRunner.run("cat > /dev/null; echo hi", "in", 10_000)
      assert File.ls!(private) == []
    end

    test "after a command that exits non-zero", %{private: private} do
      System.put_env("TMPDIR", private)
      assert {:exit, 3, ""} = CommandRunner.run("cat > /dev/null; exit 3", "in", 10_000)
      assert File.ls!(private) == []
    end

    test "after a timeout", %{private: private} do
      System.put_env("TMPDIR", private)
      assert {:timeout, _} = CommandRunner.run("cat > /dev/null; sleep 30", "in", 300)
      assert File.ls!(private) == []
    end
  end

  test "a failing mix pd.explain --with run leaves no temp files behind", %{
    dir: dir,
    private: private
  } do
    page = E.copy(dir, "page.html")
    cmd = "cat > /dev/null; echo not json"

    {_out, status} =
      System.cmd("mix", ["pd.explain", page, "--with", cmd, "--attempts", "1"],
        cd: @root,
        env: [{"MIX_QUIET", "1"}, {"MIX_ENV", "test"}, {"TMPDIR", private}],
        stderr_to_stdout: true
      )

    assert status == 1
    # Mix keeps its own lock files in the tmp dir.
    assert private |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "pd_explain_")) == []
  end
end
