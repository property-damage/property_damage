defmodule Mix.Tasks.Pd.Bisect do
  @moduledoc """
  Find the first commit where a saved PropertyDamage failure starts reproducing.

  Given a `.pd` failure file and a known-good commit, this drives `git bisect`
  over the history between that commit and a known-bad one (`HEAD` by default),
  replaying the saved failure at each candidate commit and classifying it from
  the replay's exit code. It reports the first commit where the bug appears, then
  restores the working tree.

  This is an orchestrator over `git bisect run` and `mix pd.replay`; it adds no
  engine logic of its own. Each per-commit replay runs in a fresh `mix pd.replay`
  subprocess (fresh compile, fresh BEAM), so the result is honest across the
  recompilation each checkout requires.

  ## Usage

      mix pd.bisect path/to/failure.pd --good <ref> [--bad <ref>] [--verbose]

  - `--good REF` (required): a commit/tag/branch where the bug is known absent.
  - `--bad REF` (default `HEAD`): a commit where the bug is known present.
  - `--verbose`: pass `--verbose` through to each `mix pd.replay`.

  The failure file records its own model and adapter, so no `--model` /
  `--adapter` flags are needed.

  ## How a commit is classified

  Bisect needs each commit sorted into good / bad / skip. `mix pd.replay` supplies
  exactly that via its exit code:

  - **0** — every command passed: the bug is *fixed* at this commit (good).
  - **1** — a command failed its check or errored: the bug *reproduces* (bad).
  - **125** — the replay could not run at all (the commit does not compile, the
    model/adapter do not exist yet, the file fails to load, or the sequence is
    branching): *indeterminate*, so `git bisect` **skips** it rather than blaming
    it.

  The 125 = skip case is load-bearing. Commits older than the bug often predate
  the model/adapter modules entirely, so the replay cannot run there. Marking such
  an ancestor "bad" would push the reported regression earlier than the truth and
  corrupt the result; skipping keeps the search honest. If skipped commits cluster
  at the good/bad boundary, `git bisect` reports a set of candidates rather than a
  single commit, which this task surfaces as-is.

  ## What this bisects (and why it is version-robust)

  This replays the saved **concrete shrunk sequence**, not a re-generation from
  the seed. That matters because the saved command structs are replayed verbatim,
  so the bisect stays correct even across commits that changed generators,
  command weights, or `when:` predicates (DR-023). Bisecting by *seed* would
  silently produce a different sequence after any such drift and is therefore not
  offered here. The only requirement is that the saved command structs still exist
  as modules at each tested commit (commits where they do not are skipped, as
  above).

  ## Traps this task handles for you

  - **Tracked failure files vanish on checkout.** If the `.pd` lives inside the
    repo, it may not exist at the `good` commit. The file is copied to a temp path
    *outside* the working tree before bisecting and replayed from there.
  - **A dirty working tree breaks bisect.** Uncommitted changes are detected up
    front; the task errors with a hint and never starts a bisect in that state.
  - **Leaving the repo mid-bisect.** `git bisect reset` always runs at the end,
    on success, error, and exception, so the working tree returns to where it
    started.

  ## Exit code

  - **0** when a first bad commit (or a candidate set) is identified.
  - **non-zero** only on an orchestration error: a dirty tree, an invalid
    `--good`/`--bad` ref, a git failure, or a bisect that produced no verdict.

  ## Examples

      # Find where a saved failure first appears, from a known-good tag to HEAD
      mix pd.bisect failures/currency-bug.pd --good v0.1.0

      # Bound both ends explicitly
      mix pd.bisect failures/currency-bug.pd --good abc1234 --bad def5678
  """

  use Mix.Task

  @shortdoc "Find the first commit where a saved failure reproduces (git bisect)"

  @impl true
  def run(args) do
    args |> exec() |> halt_on_status()
  end

  # Run the bisect and return its status (`:ok` or `:error`) without halting.
  # This is the testable arg/wiring seam; the git orchestration itself is in
  # `orchestrate/4`, which tests drive directly against a throwaway repo.
  #
  # `:ok` (zero) means a commit (or candidate set) was identified; `:error`
  # (non-zero) means an orchestration error (dirty tree, bad ref, git failure,
  # no verdict, usage).
  @doc false
  @spec exec([String.t()]) :: :ok | :error
  def exec(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args, strict: [good: :string, bad: :string, verbose: :boolean])

    if invalid != [] do
      print_color(:red, "Error: invalid option #{inspect(hd(invalid))}\n")
      print_usage()
      :error
    else
      dispatch(argv, opts)
    end
  end

  defp dispatch([path], opts) do
    cond do
      is_nil(opts[:good]) ->
        print_color(:red, "Error: --good REF is required\n")
        print_usage()
        :error

      not File.exists?(path) ->
        print_color(:red, "Error: failure file not found: #{path}\n")
        print_hint("Check the path. List saved failures with PropertyDamage.list_failures/1.")
        :error

      true ->
        do_bisect(path, opts[:good], opts[:bad] || "HEAD", opts)
    end
  end

  defp dispatch([], _opts) do
    print_color(:red, "Error: a failure file path is required\n")
    print_usage()
    :error
  end

  defp dispatch(_argv, _opts) do
    print_color(:red, "Error: expected exactly one failure file path\n")
    print_usage()
    :error
  end

  defp halt_on_status(:error), do: System.halt(1)
  defp halt_on_status(_), do: :ok

  defp do_bisect(path, good, bad, opts) do
    repo = File.cwd!()

    IO.puts("")
    print_header("PropertyDamage Bisect")
    IO.puts("")
    IO.puts("Failure:  #{path}")
    IO.puts("Good:     #{good}")
    IO.puts("Bad:      #{bad}")
    IO.puts("")

    # Copy the failure outside the working tree so checking out older commits
    # cannot make it disappear (it may be tracked under failures/).
    tmp = copy_to_tmp(path)

    try do
      case orchestrate(repo, good, bad, replay_command(tmp, opts)) do
        {:ok, result} ->
          print_result(repo, result)
          :ok

        {:error, reason} ->
          print_orchestration_error(reason)
          :error
      end
    after
      cleanup_tmp(tmp)
    end
  end

  defp replay_command(tmp_file, opts) do
    base = ["mix", "pd.replay", tmp_file]
    if opts[:verbose], do: base ++ ["--verbose"], else: base
  end

  @doc false
  # Copy the failure file to a unique temp directory outside any working tree and
  # return the absolute destination path.
  @spec copy_to_tmp(String.t()) :: String.t()
  def copy_to_tmp(path) do
    dir = Path.join(System.tmp_dir!(), "pd_bisect_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dest = Path.join(dir, Path.basename(path))
    File.cp!(path, dest)
    dest
  end

  @doc false
  @spec cleanup_tmp(String.t()) :: :ok
  def cleanup_tmp(tmp_file) do
    File.rm_rf(Path.dirname(tmp_file))
    :ok
  end

  @doc false
  # The git orchestration, isolated from CLI/file concerns so it can be tested
  # against a throwaway repo with an arbitrary `run_cmd`. Validates a clean tree
  # and both refs, drives `git bisect`, and ALWAYS resets afterward.
  #
  # `run_cmd` is the command list handed to `git bisect run` (e.g.
  # `["mix", "pd.replay", path]`). Returns `{:ok, result}` with the first bad
  # commit (or candidate set) or `{:error, reason}`.
  @spec orchestrate(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def orchestrate(repo, good, bad, run_cmd) do
    with :ok <- ensure_clean_tree(repo),
         {:ok, _good_sha} <- verify_ref(repo, good),
         {:ok, _bad_sha} <- verify_ref(repo, bad) do
      run_bisect(repo, good, bad, run_cmd)
    end
  end

  defp ensure_clean_tree(repo) do
    case git(repo, ["status", "--porcelain"]) do
      {"", 0} -> :ok
      {_out, 0} -> {:error, :dirty_tree}
      {out, _status} -> {:error, {:git_failed, out}}
    end
  end

  defp verify_ref(repo, ref) do
    case git(repo, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]) do
      {sha, 0} -> {:ok, String.trim(sha)}
      _ -> {:error, {:bad_ref, ref}}
    end
  end

  defp run_bisect(repo, good, bad, run_cmd) do
    with {_, 0} <- git(repo, ["bisect", "start"]),
         {_, 0} <- git(repo, ["bisect", "bad", bad]),
         {_, 0} <- git(repo, ["bisect", "good", good]) do
      {output, _status} = git(repo, ["bisect", "run" | run_cmd])
      parse_bisect_output(output)
    else
      {output, _status} -> {:error, {:git_failed, output}}
    end
  after
    # Always return the tree to its starting point, even on error/exception.
    git(repo, ["bisect", "reset"])
  end

  defp parse_bisect_output(output) do
    cond do
      match = Regex.run(~r/^([0-9a-f]{7,40}) is the first bad commit/m, output) ->
        {:ok, %{kind: :found, sha: Enum.at(match, 1)}}

      String.contains?(output, "first bad commit could be any of") ->
        {:ok, %{kind: :ambiguous, candidates: parse_candidates(output)}}

      true ->
        {:error, {:no_verdict, output}}
    end
  end

  defp parse_candidates(output) do
    ~r/^([0-9a-f]{40})$/m
    |> Regex.scan(output)
    |> Enum.map(&Enum.at(&1, 1))
  end

  defp git(repo, args) do
    System.cmd("git", args, cd: repo, stderr_to_stdout: true)
  end

  defp print_result(repo, %{kind: :found, sha: sha}) do
    print_color(:green, "First bad commit: #{short_sha(sha)}\n")

    case git(repo, ["show", "-s", "--format=  %h  %an  %ad%n  %s", sha]) do
      {detail, 0} -> IO.puts(String.trim_trailing(detail))
      _ -> IO.puts("  #{sha}")
    end

    IO.puts("")
    print_hint("This is the first commit where the saved failure reproduces.")
  end

  defp print_result(_repo, %{kind: :ambiguous, candidates: candidates}) do
    print_color(:yellow, "Could not pin down a single first bad commit.\n")
    IO.puts("  Some commits could not be tested (skipped). The first bad commit is one of:")

    for sha <- candidates do
      IO.puts("  - #{short_sha(sha)}")
    end

    IO.puts("")
    print_hint("Skipped commits surround the boundary; narrow the range or test them by hand.")
  end

  defp print_orchestration_error(:dirty_tree) do
    print_color(:red, "Error: the working tree has uncommitted changes\n")
    print_hint("Commit or stash first; bisect checks out other commits and would lose them.")
  end

  defp print_orchestration_error({:bad_ref, ref}) do
    print_color(:red, "Error: not a valid commit: #{ref}\n")
    print_hint("Pass an existing commit, tag, or branch for --good / --bad.")
  end

  defp print_orchestration_error({:no_verdict, output}) do
    print_color(:red, "Error: git bisect did not identify a first bad commit\n")
    print_tail(output)

    print_hint(
      "The replay may have been unable to run at every commit, or all commits were skipped."
    )
  end

  defp print_orchestration_error({:git_failed, output}) do
    print_color(:red, "Error: a git command failed during bisect\n")
    print_tail(output)
    print_hint("Check that --good is an ancestor of --bad and both are valid commits.")
  end

  defp print_tail(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.take(-8)
    |> Enum.each(fn line -> IO.puts("  #{line}") end)
  end

  defp short_sha(sha), do: String.slice(sha, 0, 12)

  defp print_hint(text) do
    print_color(:cyan, "    Hint: #{text}\n")
  end

  defp print_header(text) do
    border = String.duplicate("=", String.length(text) + 4)
    IO.puts(border)
    IO.puts("  #{text}")
    IO.puts(border)
  end

  defp print_color(color, text) do
    if IO.ANSI.enabled?() do
      IO.puts([color_code(color), text, IO.ANSI.reset()])
    else
      IO.puts(text)
    end
  end

  defp color_code(:red), do: IO.ANSI.red()
  defp color_code(:green), do: IO.ANSI.green()
  defp color_code(:yellow), do: IO.ANSI.yellow()
  defp color_code(:cyan), do: IO.ANSI.cyan()

  defp print_usage do
    IO.puts("""

    Usage: mix pd.bisect FILE --good REF [OPTIONS]

    Arguments:
      FILE    Path to a saved .pd failure file

    Options:
      --good REF    Required. A commit/tag/branch where the bug is known absent.
      --bad REF     A commit where the bug is known present (default: HEAD).
      --verbose     Pass --verbose through to each mix pd.replay.

    Examples:
      mix pd.bisect failures/currency-bug.pd --good v0.1.0
      mix pd.bisect failures/currency-bug.pd --good abc1234 --bad def5678
    """)
  end
end
