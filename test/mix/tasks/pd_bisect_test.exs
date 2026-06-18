defmodule Mix.Tasks.Pd.BisectTest do
  # async: false because the arg-handling tests capture stdout and the
  # integration tests shell out to git against a throwaway repo.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pd.Bisect

  # The git orchestration is proven against a throwaway repo: a tracked
  # `behavior.txt` flips from "good" to "bad" at a KNOWN commit, and the per-commit
  # "test" handed to `git bisect run` keys on that file. This exercises the real
  # bisect + reset + first-bad-commit reporting without needing a live SUT. The
  # arg/guard logic is exercised separately through `exec/1`.

  # A run command for `git bisect run` that classifies a commit by behavior.txt:
  # exit 1 (bad) when the file says "bad", exit 0 (good) otherwise.
  @marker_cmd ["sh", "-c", ~s|if [ "$(cat behavior.txt)" = bad ]; then exit 1; else exit 0; fi|]

  # ----------------------------------------------------------------------------
  # Throwaway git repo: 6 commits, behavior flips to "bad" at the 4th (c4).
  # ----------------------------------------------------------------------------

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit!(repo, behavior, message) do
    File.write!(Path.join(repo, "behavior.txt"), behavior)
    # A unique per-commit file guarantees a tree change even when behavior.txt is
    # unchanged (consecutive "good" commits), so each `git commit` succeeds.
    File.write!(Path.join(repo, "step_#{message}.txt"), message)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-m", message])
    git!(repo, ["rev-parse", "HEAD"])
  end

  defp build_repo do
    repo = Path.join(System.tmp_dir!(), "pd_bisect_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--quiet"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test"])
    git!(repo, ["config", "commit.gpgsign", "false"])

    c1 = commit!(repo, "good", "c1")
    branch = git!(repo, ["rev-parse", "--abbrev-ref", "HEAD"])
    c2 = commit!(repo, "good", "c2")
    c3 = commit!(repo, "good", "c3")
    c4 = commit!(repo, "bad", "c4")
    c5 = commit!(repo, "bad", "c5")
    c6 = commit!(repo, "bad", "c6")

    %{repo: repo, branch: branch, shas: %{c1: c1, c2: c2, c3: c3, c4: c4, c5: c5, c6: c6}}
  end

  setup do
    %{repo: repo} = ctx = build_repo()
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, ctx}
  end

  # Run `fun`, returning {status, captured_stdout}.
  defp with_output(fun) do
    parent = self()
    output = capture_io(fn -> send(parent, {:status, fun.()}) end)
    assert_received {:status, status}
    {status, output}
  end

  describe "orchestrate/4 (the git engine)" do
    test "finds the exact first bad commit", %{repo: repo, shas: shas} do
      assert {:ok, %{kind: :found, sha: sha}} =
               Bisect.orchestrate(repo, shas.c1, shas.c6, @marker_cmd)

      assert sha == shas.c4
    end

    test "restores the original branch after a successful run", %{
      repo: repo,
      shas: shas,
      branch: branch
    } do
      {:ok, _} = Bisect.orchestrate(repo, shas.c1, shas.c6, @marker_cmd)

      # Back on the original branch (not detached), with a clean tree.
      assert git!(repo, ["rev-parse", "--abbrev-ref", "HEAD"]) == branch
      assert git!(repo, ["status", "--porcelain"]) == ""
      refute File.exists?(Path.join(repo, ".git/BISECT_LOG"))
    end

    test "restores the branch even when the bisect run aborts", %{
      repo: repo,
      shas: shas,
      branch: branch
    } do
      # Exit 128 tells `git bisect run` to abort; no first-bad-commit is produced.
      abort_cmd = ["sh", "-c", "exit 128"]

      assert {:error, _reason} = Bisect.orchestrate(repo, shas.c1, shas.c6, abort_cmd)

      # The `after` block must still have reset the bisect.
      assert git!(repo, ["rev-parse", "--abbrev-ref", "HEAD"]) == branch
      refute File.exists?(Path.join(repo, ".git/BISECT_LOG"))
    end

    test "a dirty working tree errors and never starts a bisect", %{repo: repo, shas: shas} do
      File.write!(Path.join(repo, "behavior.txt"), "uncommitted change")

      assert {:error, :dirty_tree} = Bisect.orchestrate(repo, shas.c1, shas.c6, @marker_cmd)

      # No bisect was started.
      refute File.exists?(Path.join(repo, ".git/BISECT_LOG"))
    end

    test "an invalid --good ref errors cleanly", %{repo: repo, shas: shas} do
      assert {:error, {:bad_ref, "no-such-ref"}} =
               Bisect.orchestrate(repo, "no-such-ref", shas.c6, @marker_cmd)
    end

    test "an invalid --bad ref errors cleanly", %{repo: repo, shas: shas} do
      assert {:error, {:bad_ref, "no-such-ref"}} =
               Bisect.orchestrate(repo, shas.c1, "no-such-ref", @marker_cmd)
    end
  end

  describe "copy_to_tmp/1 and cleanup_tmp/1 (trap: tracked file vanishes on checkout)" do
    test "copies the failure outside the source dir and cleans up", %{repo: repo} do
      source = Path.join(repo, "failure.pd")
      File.write!(source, "saved failure contents")

      dest = Bisect.copy_to_tmp(source)

      assert File.exists?(dest)
      assert Path.basename(dest) == "failure.pd"
      # Lives under the system temp dir, outside the (repo) working tree.
      assert String.starts_with?(dest, System.tmp_dir!())
      refute String.starts_with?(dest, repo)
      assert File.read!(dest) == "saved failure contents"

      :ok = Bisect.cleanup_tmp(dest)
      refute File.exists?(dest)
    end
  end

  describe "exec/1 argument handling" do
    test "missing --good returns :error" do
      {status, output} = with_output(fn -> Bisect.exec(["some.pd"]) end)

      assert status == :error
      assert output =~ "--good REF is required"
    end

    test "no file path returns :error" do
      {status, output} = with_output(fn -> Bisect.exec(["--good", "abc"]) end)

      assert status == :error
      assert output =~ "a failure file path is required"
    end

    test "too many file paths returns :error" do
      {status, output} = with_output(fn -> Bisect.exec(["a.pd", "b.pd", "--good", "abc"]) end)

      assert status == :error
      assert output =~ "expected exactly one failure file path"
    end

    test "an unknown option returns :error" do
      {status, output} = with_output(fn -> Bisect.exec(["a.pd", "--good", "abc", "--nope"]) end)

      assert status == :error
      assert output =~ "invalid option"
    end

    test "a nonexistent failure file returns :error", %{repo: repo} do
      missing = Path.join(repo, "nope.pd")
      {status, output} = with_output(fn -> Bisect.exec([missing, "--good", "abc"]) end)

      assert status == :error
      assert output =~ "failure file not found"
    end
  end
end
