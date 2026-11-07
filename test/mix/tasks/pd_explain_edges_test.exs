defmodule Mix.Tasks.Pd.ExplainEdgesTest do
  # async: false because the task prints to stdout and stderr, which the tests
  # capture, and capturing stderr is global.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.ExplainSupport, as: E

  @bundle_open ~s(<script type="application/json" id="pd-bundle">)
  @explanation_open ~s(<script type="application/json" id="pd-explanation">)

  defp valid, do: E.explanation_fixture("valid.json")

  defp ledger, do: E.mod("Ledger")

  defp with_cites(cites), do: put_in(valid(), ["summary", Access.at(0), "cites"], cites)

  # The fixture page with its bundle replaced by `fun` applied to the decoded bundle.
  defp page_with_bundle(dir, fun) do
    html = E.fixture("page.html")
    bytes = E.bundle_bytes(html)
    E.write(dir, "page.html", String.replace(html, bytes, Jason.encode!(fun.(E.bundle(html)))))
  end

  defp assert_refused(out, lines) do
    assert out.result == :error
    assert out.stdout == ""
    assert E.lines(out.stderr) == lines
  end

  describe "standard input as bytes" do
    @tag :tmp_dir
    test "invalid UTF-8 on stdin is refused as a file with the same bytes is", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      bytes = File.read!(page)
      text = Jason.encode!(valid())
      broken = String.replace(text, "bob", <<"bo", 0xE9>>)
      refute String.valid?(broken)

      from_file = E.apply_to(page, {:raw, broken})
      from_stdin = E.exec([page, "--apply", "-"], binary_input: broken)

      assert from_file.result == :error
      assert [line] = E.lines(from_file.stderr)
      assert String.starts_with?(line, "schema: not a JSON object (")
      assert from_stdin == from_file
      assert File.read!(page) == bytes
    end

    @tag :tmp_dir
    test "valid UTF-8 on stdin is read as the bytes it holds", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      spec = update_in(valid(), ["summary", Access.at(0), "text"], &(&1 <> " café"))

      out = E.exec([page, "--apply", "-"], binary_input: Jason.encode!(spec))

      assert out.result == :ok
      assert [json] = E.explanation_tags(File.read!(page))
      assert Jason.decode!(json)["explanation"] == spec
    end
  end

  describe "the files the task writes" do
    @tag :tmp_dir
    test "--apply on a symlinked page refuses and leaves the link and its target", %{tmp_dir: dir} do
      target = E.copy(dir, "page.html", "real.html")
      page = Path.join(dir, "link.html")
      File.ln_s!(target, page)
      bytes = File.read!(target)

      out = E.apply_to(page, "valid.json")

      assert_refused(out, ["mix pd.explain: #{page} is a symbolic link; refusing to replace it"])
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(page)
      assert File.read!(target) == bytes
      assert E.tree(dir) == ["input_explanation.json", "link.html", "real.html"]
    end

    @tag :tmp_dir
    test "--apply on a read-only page refuses and leaves the file", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      File.chmod!(page, 0o444)
      bytes = File.read!(page)

      out = E.apply_to(page, "valid.json")

      assert_refused(out, ["mix pd.explain: #{page} is read-only; refusing to replace it"])
      assert File.read!(page) == bytes
      assert File.stat!(page).mode |> Bitwise.band(0o777) == 0o444
      assert E.tree(dir) == ["input_explanation.json", "page.html"]
    end

    @tag :tmp_dir
    test "--apply keeps the file mode of the page", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      File.chmod!(page, 0o640)

      out = E.apply_to(page, "valid.json")

      assert out.result == :ok
      assert File.stat!(page).mode |> Bitwise.band(0o777) == 0o640
    end

    @tag :tmp_dir
    test "a failed write names the page and not its temp file", %{tmp_dir: dir} do
      sub = Path.join(dir, "locked")
      File.mkdir!(sub)
      page = E.copy(sub, "page.html")
      file = E.explanation_file(dir, valid())
      bytes = File.read!(page)
      File.chmod!(sub, 0o555)

      out =
        try do
          E.exec([page, "--apply", file])
        after
          File.chmod!(sub, 0o755)
        end

      assert_refused(out, ["mix pd.explain: cannot write #{page} (permission denied)"])
      assert File.read!(page) == bytes
      assert E.tree(sub) == ["page.html"]
    end

    @tag :tmp_dir
    test "default mode refuses a symlinked bundle.json and leaves its target", %{tmp_dir: dir} do
      assert_symlink_refused(dir, "bundle.json")
    end

    @tag :tmp_dir
    test "default mode refuses a symlinked instructions.md and leaves its target", %{
      tmp_dir: dir
    } do
      assert_symlink_refused(dir, "instructions.md")
    end

    defp assert_symlink_refused(dir, name) do
      page = E.copy(dir, "page.html")
      explain = Path.expand(page <> ".explain")
      File.mkdir_p!(explain)
      target = E.write(dir, "precious.txt", "keep me")
      link = Path.join(explain, name)
      File.ln_s!(target, link)

      out = E.exec([page])

      assert_refused(out, [
        "mix pd.explain: #{link} is a symbolic link; refusing to write through it"
      ])

      assert File.read!(target) == "keep me"
      assert E.tree(explain) == [name]
    end
  end

  describe "format and bundle messages" do
    @tag :tmp_dir
    test "a string format shows its JSON type", %{tmp_dir: dir} do
      page = page_with_bundle(dir, &Map.put(&1, "format", "1"))

      assert_refused(E.exec([page, "--prompt"]), [
        "#{page}: bundle format \"1\" (a string) is not supported; " <>
          "this version reads formats: 1"
      ])
    end

    @tag :tmp_dir
    test "a missing format says the bundle has no format field", %{tmp_dir: dir} do
      page = page_with_bundle(dir, &Map.delete(&1, "format"))

      assert_refused(E.exec([page, "--prompt"]), [
        "#{page}: the bundle has no format field; this version reads formats: 1"
      ])
    end

    @tag :tmp_dir
    test "a null format and a list format show their JSON type", %{tmp_dir: dir} do
      page = page_with_bundle(dir, &Map.put(&1, "format", nil))

      assert_refused(E.exec([page, "--prompt"]), [
        "#{page}: bundle format null is not supported; this version reads formats: 1"
      ])

      page = page_with_bundle(dir, &Map.put(&1, "format", [1]))

      assert_refused(E.exec([page, "--prompt"]), [
        "#{page}: bundle format [1] (a list) is not supported; this version reads formats: 1"
      ])
    end

    @tag :tmp_dir
    test "a page with no bundle script gives a reason that holds for every cause", %{
      tmp_dir: dir
    } do
      page = E.copy(dir, "page_no_bundle.html")

      assert_refused(E.exec([page, "--prompt"]), [
        "#{page}: no bundle in this page (it holds no pd-bundle script)"
      ])
    end
  end

  describe "explanation input edge cases" do
    @tag :tmp_dir
    test "a range id with leading zeros is refused", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      id = "source:#{ledger()}:01-03"
      bytes = File.read!(page)

      out = E.apply_to(page, with_cites([id]))

      assert_refused(out, ["#{id}: not in this page"])
      assert File.read!(page) == bytes

      for bad <- ["source:#{ledger()}:1-03", "source:#{ledger()}:00-3"] do
        out = E.apply_to(page, with_cites([bad]))
        assert_refused(out, ["#{bad}: not in this page"])
      end
    end

    @tag :tmp_dir
    test "a range id in canonical digits is still accepted", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")

      out = E.apply_to(page, with_cites(["source:#{ledger()}:3-30"]))

      assert out.result == :ok
    end

    @tag :tmp_dir
    test "a duplicated object key is refused and named", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      bytes = File.read!(page)
      text = Jason.encode!(valid())

      top = String.replace_prefix(text, "{", ~s({"summary":[],))
      nested = String.replace(text, ~s("rank":1), ~s("rank":1,"rank":2), global: false)

      out = E.apply_to(page, {:raw, top})
      assert_refused(out, [~s(schema: duplicate key summary)])

      out = E.apply_to(page, {:raw, nested})
      assert_refused(out, [~s(schema: duplicate key rank)])

      out = E.exec([page, "--apply", "-"], input: top)
      assert_refused(out, [~s(schema: duplicate key summary)])
      assert File.read!(page) == bytes
    end

    @tag :tmp_dir
    test "a byte-order mark before the JSON is stripped", %{tmp_dir: dir} do
      bom = <<0xEF, 0xBB, 0xBF>>
      text = bom <> Jason.encode!(valid())

      page = E.copy(dir, "page.html")
      out = E.apply_to(page, {:raw, text})
      assert out.result == :ok, out.stderr
      assert [json] = E.explanation_tags(File.read!(page))
      assert Jason.decode!(json)["explanation"] == valid()

      page = E.copy(dir, "page.html", "second.html")
      out = E.exec([page, "--apply", "-"], binary_input: text)
      assert out.result == :ok, out.stderr
      assert [json] = E.explanation_tags(File.read!(page))
      assert Jason.decode!(json)["explanation"] == valid()
    end
  end

  describe "usage edge forms" do
    defp assert_usage(args, problem) do
      out = E.exec(args)
      assert out.result == :error, inspect(args)
      assert out.stdout == "", inspect(args)
      assert out.stderr == problem <> "\n" <> E.usage_line() <> "\n", inspect(args)
    end

    @tag :tmp_dir
    test "--with with no value names the problem", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      assert_usage([page, "--with"], "mix pd.explain: --with needs a value")
    end

    @tag :tmp_dir
    test "--prompt with a value says it takes none", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      assert_usage([page, "--prompt=yes"], "mix pd.explain: --prompt takes no value, got yes")
    end

    @tag :tmp_dir
    test "--apply with an empty value names the problem", %{tmp_dir: dir} do
      page = E.copy(dir, "page.html")
      before = E.tree(dir)

      assert_usage([page, "--apply", ""], "mix pd.explain: --apply needs a value")
      assert E.tree(dir) == before
    end
  end

  describe "small checks" do
    @tag :tmp_dir
    test "a malformed earlier tag is found whatever the case of the nested opener", %{
      tmp_dir: dir
    } do
      html = E.fixture("page.html")
      [head, rest] = String.split(html, @bundle_open, parts: 2)
      [bytes, tail] = String.split(rest, "</script>", parts: 2)

      page =
        E.write(
          dir,
          "page.html",
          head <>
            @bundle_open <>
            bytes <> "</script>" <> @explanation_open <> "{}<SCRIPT>{}</script>" <> tail
        )

      before = File.read!(page)
      out = E.apply_to(page, "valid.json")

      assert_refused(out, [
        "#{page}: an earlier explanation in this page is malformed; " <>
          "remove its pd-explanation tag by hand"
      ])

      assert File.read!(page) == before
    end

    @tag :tmp_dir
    test "an out-of-range line with a control character prints the whole id quoted", %{
      tmp_dir: dir
    } do
      name = "Zed\nfake"

      page =
        page_with_bundle(dir, fn bundle ->
          module = %{"module" => name, "source" => "a\nb\nc\n", "lines" => 3}
          Map.update!(bundle, "modules", &(&1 ++ [module]))
        end)

      id = "source:#{name}:1-9"
      out = E.apply_to(page, with_cites([id]))

      assert_refused(out, [inspect(id) <> ": lines 1-9 outside 1-3"])
    end
  end
end
