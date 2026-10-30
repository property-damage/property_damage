defmodule Mix.Tasks.Pd.ExplainUsageTest do
  # async: false because the task prints to stdout and stderr, which the tests
  # capture, and capturing stderr is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PropertyDamage.Test.ExplainSupport, as: E

  # `exec/1` is the halt-free seam: `run/1` only turns an `:error` into a
  # halt, so the decision logic runs in-process.

  defp assert_only_problem(args, problem) do
    out = E.exec(args)

    assert out.result == :error
    assert out.stdout == ""
    assert out.stderr == problem <> "\n" <> E.usage_line() <> "\n"
  end

  describe "usage errors" do
    setup %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      %{dir: dir, page: page, before: E.tree(dir), bytes: File.read!(page)}
    end

    @tag :tmp_dir
    test "no PAGE prints the problem and the usage line", %{dir: dir, before: before} do
      for args <- [[], ["--prompt"]] do
        out = E.exec(args)

        assert out.result == :error
        assert out.stdout == ""
        assert out.stderr == "mix pd.explain: no PAGE given\n" <> E.usage_line() <> "\n"
      end

      assert E.tree(dir) == before
    end

    @tag :tmp_dir
    test "two PAGEs print the problem and the usage line", %{page: page} do
      out = E.exec([page, page <> ".other"])

      assert out.result == :error
      assert out.stdout == ""
      assert out.stderr == "mix pd.explain: more than one PAGE given\n" <> E.usage_line() <> "\n"
    end

    @tag :tmp_dir
    test "an unknown option is named as given", %{page: page, dir: dir, before: before} do
      out = E.exec([page, "--frob"])

      assert out.result == :error
      assert out.stdout == ""
      assert out.stderr == "mix pd.explain: unknown option --frob\n" <> E.usage_line() <> "\n"
      assert E.tree(dir) == before
    end

    @tag :tmp_dir
    test "--apply as the last argument needs a value", %{page: page, dir: dir, before: before} do
      out = E.exec([page, "--apply"])

      assert out.result == :error
      assert out.stdout == ""
      assert out.stderr == "mix pd.explain: --apply needs a value\n" <> E.usage_line() <> "\n"
      assert E.tree(dir) == before
    end

    @tag :tmp_dir
    test "--prompt and --apply together are refused", %{page: page, dir: dir, before: before} do
      file = E.explanation_file(dir, "valid.json")
      before = Enum.sort([Path.basename(file) | before])

      out = E.exec([page, "--prompt", "--apply", file])

      assert out.result == :error
      assert out.stdout == ""

      assert out.stderr ==
               "mix pd.explain: --prompt and --apply cannot be used together\n" <>
                 E.usage_line() <> "\n"

      assert E.tree(dir) == before
    end

    @tag :tmp_dir
    test "a PAGE that does not exist is named as given", %{dir: dir} do
      missing = Path.join(dir, "absent.html")

      out = E.exec([missing])

      assert out.result == :error
      assert out.stdout == ""

      assert out.stderr ==
               "mix pd.explain: #{missing} does not exist\n" <> E.usage_line() <> "\n"

      refute File.exists?(missing <> ".explain")
    end

    @tag :tmp_dir
    test "the first failing check is the only one printed", %{page: page, dir: dir} do
      missing = Path.join(dir, "absent.html")
      file = E.explanation_file(dir, "valid.json")

      # options come before the PAGE count, the count before the mode clash,
      # and the mode clash before the PAGE's existence
      assert_only_problem([page, page, "--frob"], "mix pd.explain: unknown option --frob")

      assert_only_problem(
        [page, page, "--prompt", "--apply", file],
        "mix pd.explain: more than one PAGE given"
      )

      assert_only_problem(
        [missing, "--prompt", "--apply", file],
        "mix pd.explain: --prompt and --apply cannot be used together"
      )

      assert_only_problem([missing, "--apply", file], "mix pd.explain: #{missing} does not exist")
    end
  end

  describe "--with" do
    @tag :tmp_dir
    test "is parsed and refused with one line and no usage line", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      bytes = File.read!(page)
      before = E.tree(dir)
      line = "mix pd.explain: --with is not available in this version\n"

      for args <- [
            [page, "--with", "cat"],
            ["--with", "cat"],
            [page, page, "--with", "cat"],
            [Path.join(dir, "absent.html"), "--with", "cat", "--prompt"],
            [page, "--with", "cat", "--apply", "-"]
          ] do
        out = E.exec(args, input: "")

        assert out.result == :error
        assert out.stdout == ""
        assert out.stderr == line
      end

      assert File.read!(page) == bytes
      assert E.tree(dir) == before
    end

    @tag :tmp_dir
    test "an unknown option is reported before it", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")

      out = E.exec([page, "--frob", "--with", "cat"])

      assert out.result == :error
      assert out.stderr == "mix pd.explain: unknown option --frob\n" <> E.usage_line() <> "\n"
    end
  end

  describe "--apply FILE" do
    @tag :tmp_dir
    test "a FILE that does not exist is named as given, without the usage line", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      bytes = File.read!(page)
      before = E.tree(dir)
      file = Path.join(dir, "absent.json")

      out = E.exec([page, "--apply", file])

      assert out.result == :error
      assert out.stdout == ""
      assert out.stderr == "mix pd.explain: #{file} does not exist\n"
      assert File.read!(page) == bytes
      assert E.tree(dir) == before
    end
  end

  describe "documentation and entry point" do
    test "the task has a shortdoc and a moduledoc naming the modes and the files" do
      mod = E.task()

      assert is_binary(Mix.Task.shortdoc(mod)) and Mix.Task.shortdoc(mod) != ""

      assert {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(mod)
      assert moduledoc =~ "--prompt"
      assert moduledoc =~ "--apply"
      assert moduledoc =~ ".explain"
    end

    @tag :tmp_dir
    test "run/1 on a valid page returns without halting", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      mod = E.task()
      assert function_exported?(mod, :run, 1)

      stdout = capture_io(fn -> mod.run([page, "--prompt"]) end)

      assert stdout ==
               E.instructions() <> "\n" <> E.bundle_bytes(File.read!(page)) <> "\n"
    end
  end
end
