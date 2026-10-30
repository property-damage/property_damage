defmodule Mix.Tasks.Pd.ExplainHardeningTest do
  # async: false because the task prints to stdout and stderr, which the tests
  # capture, and capturing stderr is global.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.ExplainSupport, as: E

  @open ~s(<script type="application/json" id="pd-explanation">)
  @bundle_open ~s(<script type="application/json" id="pd-bundle">)
  @malformed "an earlier explanation in this page is malformed; " <>
               "remove its pd-explanation tag by hand"

  defp valid, do: E.explanation_fixture("valid.json")

  # Builds a page from the fixture with `fun` applied to its bytes, and
  # asserts `--apply` rejects it with the one malformed-tag line, the page
  # byte for byte as before and no new file in the directory.
  defp assert_malformed(dir, fun) do
    page = E.write(dir, "page.html", fun.(E.fixture("page.html")))
    file = E.explanation_file(dir, valid())
    bytes = File.read!(page)
    before = E.tree(dir)

    out = E.exec([page, "--apply", file])

    assert out.result == :error
    assert out.stdout == ""
    assert out.stderr == "#{page}: #{@malformed}\n"
    assert File.read!(page) == bytes
    assert E.tree(dir) == before
  end

  defp after_bundle(html, extra) do
    [head, rest] = String.split(html, @bundle_open, parts: 2)
    [bytes, tail] = String.split(rest, "</script>", parts: 2)
    head <> @bundle_open <> bytes <> "</script>" <> extra <> tail
  end

  defp before_bundle(html, extra), do: String.replace(html, @bundle_open, extra <> @bundle_open)

  describe "a malformed earlier explanation tag" do
    @tag :tmp_dir
    test "an opener nested in another opener is refused", %{tmp_dir: dir} do
      assert_malformed(dir, &after_bundle(&1, @open <> "{}" <> @open <> "{}</script>"))
    end

    @tag :tmp_dir
    test "an opener left unclosed before the bundle is refused", %{tmp_dir: dir} do
      assert_malformed(dir, &before_bundle(&1, @open <> "{"))
    end

    @tag :tmp_dir
    test "an opener left unclosed at the end of the page is refused", %{tmp_dir: dir} do
      assert_malformed(dir, &(&1 <> @open <> "{"))
    end

    @tag :tmp_dir
    test "an opener without a close in the head is refused", %{tmp_dir: dir} do
      assert_malformed(
        dir,
        &String.replace(&1, "<head>", "<head>" <> @open <> "{", global: false)
      )
    end

    @tag :tmp_dir
    test "the default mode treats it as not explained and writes the two files",
         %{tmp_dir: dir} do
      page = E.write(dir, "page.html", before_bundle(E.fixture("page.html"), @open <> "{"))
      bytes = File.read!(page)

      out = E.exec([page])

      assert out.result == :ok
      assert out.stderr == ""
      assert [bundle_path, instructions_path | _] = E.lines(out.stdout)
      assert File.exists?(bundle_path)
      assert File.read!(instructions_path) == E.instructions()
      assert File.read!(page) == bytes
    end
  end

  describe "one line per error" do
    @tag :tmp_dir
    test "an unknown key holding a newline prints one line", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      file = E.explanation_file(dir, Map.put(valid(), "a\nschema: forged", 1))

      out = E.exec([page, "--apply", file])

      assert out.result == :error
      assert E.lines(out.stderr) == [~s(schema: unknown key "a\\nschema: forged")]
    end

    @tag :tmp_dir
    test "a cited id holding a newline prints one line", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      id = "a\nforged: line"

      file =
        E.explanation_file(
          dir,
          update_in(valid(), ["summary", Access.at(0), "cites"], &[id | &1])
        )

      out = E.exec([page, "--apply", file])

      assert out.result == :error
      assert E.lines(out.stderr) == [inspect(id) <> ": not in this page"]
    end

    @tag :tmp_dir
    test "a bundle format holding a newline prints one line", %{tmp_dir: dir} do
      html = E.fixture("page.html")
      bundle = Map.put(E.bundle(html), "format", "9\nfake")
      bytes = E.bundle_bytes(html)
      page = E.write(dir, "page.html", String.replace(html, bytes, Jason.encode!(bundle)))

      out = E.exec([page, "--prompt"])

      assert out.result == :error

      assert E.lines(out.stderr) == [
               "#{page}: bundle format \"9\\nfake\" (a string) is not supported; " <>
                 "this version reads formats: 1"
             ]
    end
  end
end
