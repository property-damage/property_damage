defmodule Mix.Tasks.Pd.ExplainDefaultTest do
  # async: false because the task prints to stdout and stderr, which the tests
  # capture, and capturing stderr is global.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.ExplainSupport, as: E

  # The bundle hash of the committed fixture page, so that a change to the
  # page or to the way the tests cut the bundle out shows up here.
  @page_hash "2a79640f06d21f6c1c8da9df035e4f3f6f326bdf7d65440b13dcb2dfa7357656"

  defp instructions_bytes do
    path = Path.join(:code.priv_dir(:property_damage), "explain/instructions.md")
    assert File.exists?(path), "the instructions file #{path} does not exist"
    File.read!(path)
  end

  defp four_lines(page, hash) do
    [
      Path.expand(page <> ".explain/bundle.json"),
      Path.expand(page <> ".explain/instructions.md"),
      "prompt version: 1",
      "bundle hash: #{hash}"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp explained_json(hash, version),
    do: Jason.encode!(%{"bundle_hash" => hash, "prompt_version" => version})

  defp broken_pages(dir) do
    html = E.fixture("page.html")
    open = ~s(<script type="application/json" id="pd-bundle">)
    bytes = E.bundle_bytes(html)

    [
      {E.copy(dir, "page_no_bundle.html"),
       "no bundle in this page (it was written by a version that did not embed one)"},
      {E.write(
         dir,
         "reordered.html",
         String.replace(html, open, ~s(<script id="pd-bundle" type="application/json">))
       ), "no bundle in this page (it was written by a version that did not embed one)"},
      {E.write(dir, "two.html", E.with_text_before_body_end(html, open <> bytes <> "</script>")),
       "more than one bundle in this page"},
      {E.write(dir, "not_json.html", String.replace(html, bytes, ~s({"format":1,))),
       "the bundle in this page is not valid JSON"},
      {E.copy(dir, "page_format_999.html"),
       "bundle format 999 is not supported; this version reads formats: 1"}
    ]
  end

  describe "the fixture page" do
    @tag :tmp_dir
    test "carries the bundle the other tests rely on", %{tmp_dir: dir} do
      html = File.read!(E.copy(dir, "page.html"))
      bundle = E.bundle(html)

      assert E.bundle_hash(html) == @page_hash
      assert bundle["format"] == 1
      assert E.tag_count(html, "pd-bundle") == 1
      assert E.tag_count(html, "pd-explanation") == 0
      assert Enum.any?(bundle["ids"], &String.starts_with?(&1, "entry:"))
      assert Enum.any?(bundle["ids"], &String.starts_with?(&1, "source:"))
      assert Enum.any?(bundle["context"], &(&1["missing"] == true))
      assert Enum.any?(bundle["modules"], &is_binary(&1["source"]))
    end
  end

  describe "default mode" do
    @tag :tmp_dir
    test "writes the two files and prints their paths, the version and the hash", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      bytes = File.read!(page)

      out = E.exec([page])

      assert out.result == :ok
      assert out.stderr == ""
      assert out.stdout == four_lines(page, @page_hash)

      assert E.tree(dir) == [
               "page.html",
               "page.html.explain/bundle.json",
               "page.html.explain/instructions.md"
             ]

      assert File.read!(page) == bytes
      assert File.read!(page <> ".explain/bundle.json") == E.bundle_bytes(bytes)
      assert E.sha256(File.read!(page <> ".explain/bundle.json")) == @page_hash
      assert File.read!(page <> ".explain/instructions.md") == instructions_bytes()
      assert instructions_bytes() == E.instructions()
    end

    @tag :tmp_dir
    test "prints absolute paths for a page given by a relative path", %{tmp_dir: dir} do
      page = Path.relative_to_cwd(E.copy(dir, "page.html"))
      refute Path.type(page) == :absolute

      out = E.exec([page])

      assert out.result == :ok
      assert out.stdout == four_lines(page, @page_hash)
      assert File.exists?(Path.expand(page <> ".explain/bundle.json"))
    end

    @tag :tmp_dir
    test "keeps a stray file in the directory and overwrites the two files", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      explain = page <> ".explain"
      File.mkdir_p!(explain)
      File.write!(Path.join(explain, "notes.txt"), "keep me")
      File.write!(Path.join(explain, "bundle.json"), "old")
      File.write!(Path.join(explain, "instructions.md"), "old")

      out = E.exec([page])

      assert out.result == :ok
      assert out.stdout == four_lines(page, @page_hash)
      assert File.read!(Path.join(explain, "notes.txt")) == "keep me"
      assert File.read!(Path.join(explain, "bundle.json")) == E.bundle_bytes(File.read!(page))
      assert File.read!(Path.join(explain, "instructions.md")) == instructions_bytes()
    end

    @tag :tmp_dir
    test "a second run writes the same files again", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      first = E.exec([page])
      File.write!(page <> ".explain/bundle.json", "changed")

      second = E.exec([page])

      assert first.result == :ok and second.result == :ok
      assert second.stdout == first.stdout
      assert File.read!(page <> ".explain/bundle.json") == E.bundle_bytes(File.read!(page))
    end
  end

  describe "already explained" do
    @tag :tmp_dir
    test "a tag for this hash and version prints one line and writes nothing", %{tmp_dir: dir} do
      html = E.fixture("page.html")

      for {name, page_html} <- [
            {"after_bundle", E.with_tag_after_bundle(html, explained_json(@page_hash, 1))},
            {"elsewhere", E.with_text_before_body_end(html, E.tag(explained_json(@page_hash, 1)))}
          ] do
        page = E.write(dir, name <> ".html", page_html)
        before = E.tree(dir)

        out = E.exec([page])

        assert out.result == :ok
        assert out.stderr == ""

        assert out.stdout ==
                 "#{page} is already explained (bundle #{@page_hash}, prompt version 1)\n"

        assert E.tree(dir) == before
        assert File.read!(page) == page_html
      end
    end

    @tag :tmp_dir
    test "a tag for another hash, another version or no object does not count", %{tmp_dir: dir} do
      html = E.fixture("page.html")
      other_hash = String.duplicate("ab", 32)

      for {name, json} <- [
            {"other_hash", explained_json(other_hash, 1)},
            {"other_version", explained_json(@page_hash, 2)},
            {"string_version", explained_json(@page_hash, "1")},
            {"no_version", Jason.encode!(%{"bundle_hash" => @page_hash})},
            {"no_hash", Jason.encode!(%{"prompt_version" => 1})},
            {"an_array", Jason.encode!([@page_hash, 1])},
            {"not_json", "{not json"}
          ] do
        page = E.write(dir, name <> ".html", E.with_tag_after_bundle(html, json))
        bytes = File.read!(page)

        out = E.exec([page])

        assert out.result == :ok, "#{name}: the page must not count as explained"
        assert out.stderr == ""
        assert out.stdout == four_lines(page, @page_hash), name
        assert File.read!(page <> ".explain/bundle.json") == E.bundle_bytes(html), name
        assert File.read!(page) == bytes
      end
    end
  end

  describe "--prompt" do
    @tag :tmp_dir
    test "prints the instructions, a newline, the bundle bytes and a newline", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      bytes = File.read!(page)
      before = E.tree(dir)

      out = E.exec([page, "--prompt"])

      assert out.result == :ok
      assert out.stderr == ""
      assert out.stdout == instructions_bytes() <> "\n" <> E.bundle_bytes(bytes) <> "\n"
      assert E.tree(dir) == before
      assert File.read!(page) == bytes
    end

    @tag :tmp_dir
    test "prints only the prompt for a page that already holds an explanation", %{tmp_dir: dir} do
      html = E.with_tag_after_bundle(E.fixture("page.html"), explained_json(@page_hash, 1))
      page = E.write(dir, "explained.html", html)
      before = E.tree(dir)

      out = E.exec([page, "--prompt"])

      assert out.result == :ok
      assert out.stderr == ""
      assert out.stdout == instructions_bytes() <> "\n" <> E.bundle_bytes(html) <> "\n"
      assert E.tree(dir) == before
    end
  end

  describe "a page the task cannot read" do
    @tag :tmp_dir
    test "every mode names the page and the problem on one line and changes nothing", %{
      tmp_dir: dir
    } do
      pages = broken_pages(dir)
      file = E.explanation_file(dir, "valid.json")
      before = E.tree(dir)

      for {page, problem} <- pages,
          args <- [[page], [page, "--prompt"], [page, "--apply", file]] do
        bytes = File.read!(page)

        out = E.exec(args)

        label = "#{Path.basename(page)} #{Enum.join(tl(args), " ")}"
        assert out.result == :error, label
        assert out.stdout == "", label
        assert out.stderr == "#{page}: #{problem}\n", label
        assert File.read!(page) == bytes, label
        assert E.tree(dir) == before, label
      end
    end
  end
end
