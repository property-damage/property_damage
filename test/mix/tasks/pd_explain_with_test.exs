defmodule Mix.Tasks.Pd.ExplainWithTest do
  # async: false because the task prints to stdout and stderr, which the tests
  # capture, and capturing stderr is global. The config tests also change the
  # application environment.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.ExplainSupport, as: E

  @fake Path.expand("../../fixtures/explain/with/fake_command.sh", __DIR__)
  @hang Path.expand("../../fixtures/explain/with/hang_command.sh", __DIR__)

  @config_line "using the command from config :property_damage, :explain_with\n"
  @bad_ids_lines [
    "failure:Nope: not in this page",
    "step:alice:[0] : not in this page",
    "section:Nowhere: not in this page"
  ]

  # --- helpers ---------------------------------------------------------------

  defp quote_arg(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  # The command string for a fake script that keeps its state in `dir`.
  defp fake_cmd(dir, script \\ @fake, env \\ []) do
    env = [{"PD_DIR", dir} | env]

    Enum.map_join(env, " ", fn {k, v} -> "#{k}=#{quote_arg(v)}" end) <>
      " sh " <> quote_arg(script)
  end

  defp answer(dir, n, text), do: File.write!(Path.join(dir, "answer.#{n}"), text)
  defp stdin_of(dir, n), do: File.read!(Path.join(dir, "stdin.#{n}"))
  defp calls(dir), do: dir |> Path.join("count") |> File.read() |> calls_count()
  defp calls_count({:ok, text}), do: text |> String.trim() |> String.to_integer()
  defp calls_count({:error, _}), do: 0

  defp setup_page(dir), do: E.copy(dir, "page.html")

  # What the existing --apply path writes for `fixture`, on a copy of the page.
  defp page_applied_with(dir, fixture) do
    copy_dir = Path.join(dir, "reference")
    File.mkdir_p!(copy_dir)
    page = E.copy(copy_dir, "page.html")
    out = E.apply_to(page, fixture)
    assert out.result == :ok
    File.read!(page)
  end

  defp applied_line(page, dir) do
    html = File.read!(Path.join(dir, "reference/page.html"))
    hash = E.bundle_hash(html)
    "applied the explanation to #{page} (bundle #{hash}, prompt version #{E.prompt_version()})\n"
  end

  defp alive?(pid) do
    {out, _} = System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)])
    out = String.trim(out)
    out != "" and not String.starts_with?(out, "Z")
  end

  defp pids(dir) do
    dir
    |> Path.join("pids")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.to_integer/1)
  end

  # Waits up to two seconds for every pid to be gone (a killed process needs a
  # moment to be reaped).
  defp assert_gone(pids) do
    deadline = System.monotonic_time(:millisecond) + 2000
    wait_gone(pids, deadline)
  end

  defp wait_gone(pids, deadline) do
    case Enum.filter(pids, &alive?/1) do
      [] ->
        :ok

      alive ->
        if System.monotonic_time(:millisecond) > deadline do
          Enum.each(alive, &System.cmd("kill", ["-KILL", Integer.to_string(&1)]))
          flunk("processes still alive after the timeout: #{inspect(alive)}")
        else
          Process.sleep(50)
          wait_gone(pids, deadline)
        end
    end
  end

  # The runner names its temp directories after the OS pid of this VM.
  defp tmp_leftovers do
    names = File.ls!(System.tmp_dir!())
    Enum.filter(names, &String.starts_with?(&1, "pd_explain_#{System.pid()}_"))
  end

  defp set_config(value) do
    previous = Application.fetch_env(:property_damage, :explain_with)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:property_damage, :explain_with, old)
        :error -> Application.delete_env(:property_damage, :explain_with)
      end
    end)

    Application.put_env(:property_damage, :explain_with, value)
  end

  defp valid_pretty, do: E.explanation_fixture("valid.json") |> Jason.encode!(pretty: true)

  # --- the answer is applied -------------------------------------------------

  describe "an answer that passes the checks" do
    @tag :tmp_dir
    test "a command that prints the explanation is applied after one attempt", %{tmp_dir: dir} do
      page = setup_page(dir)
      answer(dir, 1, E.fixture("valid.json"))
      expected = page_applied_with(dir, "valid.json")

      out = E.exec([page, "--with", fake_cmd(dir)])

      assert out.result == :ok
      assert out.stdout == applied_line(page, dir)
      assert out.stderr == ""
      assert File.read!(page) == expected
      assert calls(dir) == 1
    end

    @tag :tmp_dir
    test "the command receives the same bytes as --prompt prints", %{tmp_dir: dir} do
      page = setup_page(dir)
      answer(dir, 1, E.fixture("valid.json"))

      prompt = E.exec([page, "--prompt"]).stdout
      E.exec([page, "--with", fake_cmd(dir)])

      assert prompt != ""
      assert stdin_of(dir, 1) == prompt
    end

    @tag :tmp_dir
    test "standard error of the command is not captured", %{tmp_dir: dir} do
      page = setup_page(dir)
      answer(dir, 1, E.fixture("valid.json"))

      out = E.exec([page, "--with", fake_cmd(dir, @fake, [{"PD_NOISE", "chatter-from-command"}])])

      assert out.result == :ok
      assert not String.contains?(out.stderr, "chatter-from-command")
      assert not String.contains?(out.stdout, "chatter-from-command")
    end

    @tag :tmp_dir
    test "a whole-output JSON object with fence text inside a string is the answer",
         %{tmp_dir: dir} do
      page = setup_page(dir)
      data = E.explanation_fixture("valid.json")
      data = put_in(data, ["summary", Access.at(0), "text"], "Use ```json {bad} ``` inline.")
      answer(dir, 1, "\n  " <> Jason.encode!(data, pretty: true) <> "\n\n")

      out = E.exec([page, "--with", fake_cmd(dir)])

      assert out.result == :ok, out.stderr
      [tag] = E.explanation_tags(File.read!(page))
      assert Jason.decode!(tag)["explanation"]["summary"] |> hd() |> Map.get("text") =~ "inline"
    end

    @tag :tmp_dir
    test "the last fenced json block is the answer", %{tmp_dir: dir} do
      page = setup_page(dir)
      expected = page_applied_with(dir, "valid.json")

      answer(dir, 1, """
      Here is my first try:

      ```json
      #{E.fixture("bad_ids.json")}
      ```

      On reflection, this is better:

      ```json
      #{valid_pretty()}
      ```

      Hope that helps.
      """)

      out = E.exec([page, "--with", fake_cmd(dir), "--attempts", "1"])

      assert out.result == :ok, out.stderr
      assert File.read!(page) == expected
    end

    @tag :tmp_dir
    test "a fence of four backticks counts",
         %{tmp_dir: dir} do
      page = setup_page(dir)
      expected = page_applied_with(dir, "valid.json")

      answer(dir, 1, "Answer:\n\n````json\n#{valid_pretty()}\n````\n")

      out = E.exec([page, "--with", fake_cmd(dir), "--attempts", "1"])

      assert out.result == :ok, out.stderr
      assert File.read!(page) == expected
    end

    @tag :tmp_dir
    test "a block whose info string is not exactly json is ignored", %{tmp_dir: dir} do
      page = setup_page(dir)
      expected = page_applied_with(dir, "valid.json")

      answer(dir, 1, """
      ```json
      #{valid_pretty()}
      ```

      ```JSON
      #{E.fixture("bad_ids.json")}
      ```

      ```jsonc
      #{E.fixture("bad_ids.json")}
      ```
      """)

      out = E.exec([page, "--with", fake_cmd(dir), "--attempts", "1"])

      assert out.result == :ok, out.stderr
      assert File.read!(page) == expected
    end
  end

  # --- retry -----------------------------------------------------------------

  describe "an answer that fails" do
    @tag :tmp_dir
    test "the next call carries the prompt, the previous answer and the errors",
         %{tmp_dir: dir} do
      page = setup_page(dir)
      answer(dir, 1, E.fixture("bad_ids.json"))
      answer(dir, 2, E.fixture("valid.json"))
      expected = page_applied_with(dir, "valid.json")

      out = E.exec([page, "--with", fake_cmd(dir)])

      assert out.result == :ok
      assert out.stderr == "attempt 1/3: 3 errors in the explanation\n"
      assert File.read!(page) == expected
      assert calls(dir) == 2

      prompt = E.exec([page, "--prompt"]).stdout
      assert stdin_of(dir, 1) == prompt

      assert stdin_of(dir, 2) ==
               prompt <>
                 "\n\n## Your previous answer\n\n" <>
                 E.fixture("bad_ids.json") <>
                 "\n\n## Errors\n\n" <> Enum.join(@bad_ids_lines, "\n")
    end

    @tag :tmp_dir
    test "after the last attempt the error lines and a closing line are printed",
         %{tmp_dir: dir} do
      page = setup_page(dir)
      bytes = File.read!(page)
      before = E.tree(dir)
      answer(dir, 1, E.fixture("bad_ids.json"))
      answer(dir, 2, E.fixture("bad_ids.json"))

      out = E.exec([page, "--with", fake_cmd(dir), "--attempts", "2"])

      assert out.result == :error
      assert out.stdout == ""

      assert out.stderr ==
               "attempt 1/2: 3 errors in the explanation\n" <>
                 Enum.join(@bad_ids_lines, "\n") <>
                 "\nmix pd.explain: no valid explanation after 2 attempts; the page is unchanged\n"

      assert File.read!(page) == bytes
      assert Enum.filter(E.tree(dir) -- before, &(&1 =~ ~r/\.(tmp|explain)/)) == []
      assert calls(dir) == 2
    end

    @tag :tmp_dir
    test "--attempts 1 prints no retry line", %{tmp_dir: dir} do
      page = setup_page(dir)
      bytes = File.read!(page)
      answer(dir, 1, E.fixture("bad_ids.json"))

      out = E.exec([page, "--with", fake_cmd(dir), "--attempts", "1"])

      assert out.result == :error
      assert not String.contains?(out.stderr, "attempt 1/")

      assert out.stderr ==
               Enum.join(@bad_ids_lines, "\n") <>
                 "\nmix pd.explain: no valid explanation after 1 attempt; the page is unchanged\n"

      assert File.read!(page) == bytes
      assert calls(dir) == 1
    end

    @tag :tmp_dir
    test "prose without JSON fails every attempt and leaves the page", %{tmp_dir: dir} do
      page = setup_page(dir)
      bytes = File.read!(page)
      answer(dir, 1, "I am sorry, I cannot do that.\n")
      answer(dir, 2, "Still no.\n")

      out = E.exec([page, "--with", fake_cmd(dir), "--attempts", "2"])

      assert out.result == :error
      assert out.stdout == ""

      assert out.stderr ==
               "attempt 1/2: no JSON found in the command's output\n" <>
                 "mix pd.explain: no JSON found in the command's output\n" <>
                 "mix pd.explain: no valid explanation after 2 attempts; the page is unchanged\n"

      assert File.read!(page) == bytes
      assert stdin_of(dir, 2) =~ "\n\n## Your previous answer\n\nI am sorry, I cannot do that.\n"
      assert stdin_of(dir, 2) =~ "\n\n## Errors\n\nno JSON found in the command's output"
    end

    @tag :tmp_dir
    test "a non-zero exit fails the attempt even when stdout holds valid JSON",
         %{tmp_dir: dir} do
      page = setup_page(dir)
      bytes = File.read!(page)
      answer(dir, 1, E.fixture("valid.json"))
      answer(dir, 2, E.fixture("valid.json"))

      out =
        E.exec([page, "--with", fake_cmd(dir, @fake, [{"PD_STATUS", "3"}]), "--attempts", "2"])

      assert out.result == :error
      assert out.stdout == ""

      assert out.stderr ==
               "attempt 1/2: command exited with status 3\n" <>
                 "mix pd.explain: command exited with status 3\n" <>
                 "mix pd.explain: no valid explanation after 2 attempts; the page is unchanged\n"

      assert File.read!(page) == bytes
      assert stdin_of(dir, 2) =~ "\n\n## Errors\n\ncommand exited with status 3"
    end

    @tag :tmp_dir
    test "a command that outlives the timeout is killed with its children", %{tmp_dir: dir} do
      page = setup_page(dir)
      bytes = File.read!(page)

      out = E.exec([page, "--with", fake_cmd(dir, @hang), "--attempts", "2", "--timeout", "1s"])

      assert out.result == :error
      assert out.stdout == ""

      assert out.stderr ==
               "attempt 1/2: timed out after 1s\n" <>
                 "mix pd.explain: timed out after 1s\n" <>
                 "mix pd.explain: no valid explanation after 2 attempts; the page is unchanged\n"

      assert File.read!(page) == bytes
      all = pids(dir)
      assert length(all) == 4
      assert_gone(all)
    end
  end

  # --- config ----------------------------------------------------------------

  describe "the config fallback" do
    @tag :tmp_dir
    test "runs the configured command and says so first", %{tmp_dir: dir} do
      page = setup_page(dir)
      answer(dir, 1, E.fixture("valid.json"))
      expected = page_applied_with(dir, "valid.json")
      set_config(fake_cmd(dir))

      out = E.exec([page])

      assert out.result == :ok, out.stderr
      assert out.stderr == @config_line
      assert File.read!(page) == expected
    end

    @tag :tmp_dir
    test "--attempts applies to the configured command", %{tmp_dir: dir} do
      page = setup_page(dir)
      answer(dir, 1, E.fixture("bad_ids.json"))
      set_config(fake_cmd(dir))

      out = E.exec([page, "--attempts", "1"])

      assert out.result == :error
      assert String.starts_with?(out.stderr, @config_line)
      assert calls(dir) == 1
    end

    @tag :tmp_dir
    test "--prompt and --apply win over the config, and an empty value is no config",
         %{tmp_dir: dir} do
      page = setup_page(dir)
      file = E.explanation_file(dir, "valid.json")
      answer(dir, 1, E.fixture("valid.json"))
      set_config(fake_cmd(dir))

      # the config is in effect for the default mode ...
      assert E.exec([page, "--attempts", "1"]).stderr == @config_line
      assert calls(dir) == 1

      # ... and ignored for the other modes
      prompt = E.exec([page, "--prompt"])
      assert prompt.result == :ok
      assert prompt.stderr == ""
      assert prompt.stdout == E.exec([page, "--prompt"]).stdout

      applied = E.exec([page, "--apply", file])
      assert applied.result == :ok
      assert applied.stderr == ""
      assert calls(dir) == 1

      # an empty value is no config: the default mode runs
      Application.put_env(:property_damage, :explain_with, "")
      fresh = E.copy(dir, "page.html", "fresh.html")
      out = E.exec([fresh])
      assert out.result == :ok
      assert out.stderr == ""
      assert File.dir?(fresh <> ".explain")
      assert calls(dir) == 1
    end
  end

  # --- usage -----------------------------------------------------------------

  describe "usage errors" do
    defp assert_usage(args, problem) do
      out = E.exec(args)
      assert out.result == :error, inspect(args)
      assert out.stdout == "", inspect(args)
      assert out.stderr == problem <> "\n" <> E.usage_line() <> "\n", inspect(args)
    end

    @tag :tmp_dir
    test "--with together with --prompt or --apply is refused", %{tmp_dir: dir} do
      page = setup_page(dir)
      bytes = File.read!(page)
      before = E.tree(dir)

      assert_usage(
        [page, "--with", "cat", "--prompt"],
        "mix pd.explain: --with and --prompt cannot be used together"
      )

      assert_usage(
        [page, "--with", "cat", "--apply", "-"],
        "mix pd.explain: --with and --apply cannot be used together"
      )

      assert File.read!(page) == bytes
      assert E.tree(dir) == before
    end

    @tag :tmp_dir
    test "--with needs a command", %{tmp_dir: dir} do
      page = setup_page(dir)

      assert_usage([page, "--with"], "mix pd.explain: --with needs a value")
      assert_usage([page, "--with", ""], "mix pd.explain: --with needs a value")
    end

    @tag :tmp_dir
    test "--attempts and --timeout without --with are refused", %{tmp_dir: dir} do
      page = setup_page(dir)

      assert_usage([page, "--attempts", "2"], "mix pd.explain: --attempts needs --with")
      assert_usage([page, "--timeout", "5s"], "mix pd.explain: --timeout needs --with")

      assert_usage(
        [page, "--prompt", "--attempts", "2"],
        "mix pd.explain: --attempts needs --with"
      )

      assert_usage(
        [page, "--apply", "-", "--timeout", "5s"],
        "mix pd.explain: --timeout needs --with"
      )
    end

    @tag :tmp_dir
    test "--attempts must be a positive integer", %{tmp_dir: dir} do
      page = setup_page(dir)

      for bad <- ["0", "-2", "abc", "1.5", "2x"] do
        assert_usage(
          [page, "--with", "cat", "--attempts", bad],
          "mix pd.explain: --attempts must be a positive integer, got #{bad}"
        )
      end

      assert_usage(
        [page, "--with", "cat", "--attempts"],
        "mix pd.explain: --attempts needs a value"
      )
    end

    @tag :tmp_dir
    test "--timeout must be a positive number of seconds or minutes", %{tmp_dir: dir} do
      page = setup_page(dir)

      for bad <- ["0", "0s", "0m", "-3", "abc", "5h", "1.5m", "s", ""] do
        assert_usage(
          [page, "--with", "cat", "--timeout", bad],
          "mix pd.explain: --timeout must be <n>s, <n>m or a number of seconds, got #{bad}"
        )
      end

      assert_usage(
        [page, "--with", "cat", "--timeout"],
        "mix pd.explain: --timeout needs a value"
      )
    end

    @tag :tmp_dir
    test "the accepted spellings of --timeout and --attempts run the command", %{tmp_dir: dir} do
      page = setup_page(dir)
      answer(dir, 1, E.fixture("valid.json"))

      for timeout <- ["30", "30s", "1m"] do
        File.rm(Path.join(dir, "count"))
        File.write!(page, E.fixture("page.html"))

        out = E.exec([page, "--with", fake_cmd(dir), "--attempts", "2", "--timeout", timeout])

        assert out.result == :ok, "#{timeout}: #{out.stderr}"
      end
    end
  end

  # --- the runner ------------------------------------------------------------

  describe "the command runner" do
    test "a command reads the input to its end and its output comes back whole" do
      input = String.duplicate("line of the prompt\n", 20_000)

      assert E.runner().run("cat", input, 20_000) == {:ok, input}
    end

    test "the exit status reaches the caller, also on the fallback path" do
      cmd = "cat > /dev/null; echo partial; exit 3"

      assert E.runner().run(cmd, "x", 20_000) == {:exit, 3, "partial\n"}
      assert E.runner().run(cmd, "x", 20_000, force_fallback: true) == {:exit, 3, "partial\n"}
    end

    test "the command is run by sh -c, so a pipeline works" do
      assert E.runner().run("cat | tr a-z A-Z", "abc", 20_000) == {:ok, "ABC"}
    end

    @tag :tmp_dir
    test "the fallback kills the descendants of a command that outlives the timeout",
         %{tmp_dir: dir} do
      cmd = fake_cmd(dir, @hang)

      assert {:timeout, ""} = E.runner().run(cmd, "x", 1000, force_fallback: true)

      all = pids(dir)
      assert length(all) == 2
      assert_gone(all)
    end

    @tag :tmp_dir
    test "a timeout leaves no temp file and no port behind", %{tmp_dir: dir} do
      cmd = fake_cmd(dir, @hang)
      before_ports = Port.list()
      before_files = tmp_leftovers()

      for opts <- [[], [force_fallback: true]] do
        assert {:timeout, _} = E.runner().run(cmd, "x", 500, opts)
        assert_gone(pids(dir))
        assert tmp_leftovers() == before_files
        assert Port.list() -- before_ports == []
      end
    end

    @tag :tmp_dir
    test "a caller that dies takes the command and the temp files with it", %{tmp_dir: dir} do
      cmd = fake_cmd(dir, @hang)
      before_files = tmp_leftovers()
      runner = E.runner()

      caller = spawn(fn -> runner.run(cmd, "x", 60_000) end)
      wait_for_file(Path.join(dir, "pids"))
      Process.sleep(200)
      all = pids(dir)

      Process.exit(caller, :kill)

      assert_gone(all)
      assert tmp_leftovers() == before_files
    end
  end

  defp wait_for_file(path, tries \\ 100) do
    cond do
      File.exists?(path) and File.read!(path) |> String.split("\n", trim: true) |> length() >= 2 ->
        :ok

      tries == 0 ->
        flunk("#{path} was not written")

      true ->
        Process.sleep(50)
        wait_for_file(path, tries - 1)
    end
  end
end
