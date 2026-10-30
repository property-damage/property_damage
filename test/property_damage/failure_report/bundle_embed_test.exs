defmodule PropertyDamage.FailureReport.BundleEmbedTest do
  # How the page carries the bundle: in a second script tag of its own, safe
  # against text that would close the tag, written with every page and with
  # no index page, read by the viewer's script only to show a page's
  # explanation, and intact for text outside ASCII.
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport.HTML
  alias PropertyDamage.Test.BundleSupport, as: B
  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.ReportLayout, as: RL

  @viewer Path.expand("../../../priv/failure_report/viewer.html", __DIR__)

  @tag_open ~s(<script type="application/json" id="pd-bundle">)

  setup do
    previous = System.get_env("PD_LOG")
    System.delete_env("PD_LOG")
    dir = B.tmp_dir("pd_bundle_pages")

    on_exit(fn ->
      if previous, do: System.put_env("PD_LOG", previous), else: System.delete_env("PD_LOG")
    end)

    {:ok, dir: dir}
  end

  describe "render/1" do
    for kind <- [
          :check_failed,
          :diverged,
          :diverged_expanded,
          :setup_failed_command,
          :test_code_error
        ] do
      test "holds exactly one bundle tag, whose content is the bundle, for the #{kind} report" do
        report = RL.report(unquote(kind))
        html = HTML.render(report)

        assert B.bundle_id_count(html) == 1
        assert [_content] = B.bundle_tags(html)
        assert B.page_bundle(html) == B.build(report)
      end
    end

    test "puts the bundle tag on the line after the report tag" do
      lines = RL.report(:check_failed) |> HTML.render() |> String.split("\n")

      index = Enum.find_index(lines, &String.contains?(&1, ~s(id="pd-report")))
      assert index
      assert lines |> Enum.at(index + 1) |> String.starts_with?(@tag_open)
    end

    test "leaves no placeholder in the page" do
      html = HTML.render(RL.report(:check_failed))

      assert B.bundle_id_count(html) == 1
      refute html =~ "__PD_"
    end

    test "holds a bundle that matches the page's own text" do
      report = RL.report(:diverged)
      html = HTML.render(report)
      bundle = B.page_bundle(html)

      parsed = B.parse(B.page_text(report), B.default_name(report))
      assert Enum.map(bundle["sections"], & &1["title"]) == parsed.headings
    end

    test "keeps the bundle of a report whose log filter hides lines the same as the build" do
      F.compile!()
      report = F.filter_report!(log: [only: [:http], except: [:body]])

      assert B.page_bundle(HTML.render(report)) == B.build(report)
    end
  end

  describe "text that would close the tag" do
    @marker_extra ~S'''
    def marker, do: "</script>"
    def opener, do: "<!--<script>"
    '''

    test "leaves the page with the same number of script tags as a page without it" do
      plain = B.define()
      marked = B.define(adapter_extra: @marker_extra)

      plain_html = plain |> B.run() |> HTML.render()
      marked_html = marked |> B.run() |> HTML.render()

      assert B.bundle_id_count(marked_html) == 1
      assert B.script_counts(marked_html) == B.script_counts(plain_html)
      assert {opened, closed} = B.script_counts(marked_html)
      assert opened == closed
    end

    test "still parses the bundle, with the source as it was" do
      system = B.define(adapter_extra: @marker_extra)
      html = system |> B.run() |> HTML.render()

      bundle = B.page_bundle(html)
      source = B.module_entry(bundle, system.adapter)["source"]

      assert source =~ ~S(def marker, do: "</script>")
      assert source =~ ~S(def opener, do: "<!--<script>")
    end

    test "leaves the closing text only in escaped form inside the bundle tag" do
      system = B.define(adapter_extra: @marker_extra)
      html = system |> B.run() |> HTML.render()

      assert [content] = B.bundle_tags(html)
      refute content =~ "</script>"
      refute content =~ "<script"
      refute content =~ "<!--"
    end
  end

  describe "write/2" do
    test "writes a page with the bundle tag", %{dir: dir} do
      report = RL.report(:check_failed)
      assert {:ok, path} = HTML.write(report, dir)

      page = File.read!(path)
      assert B.bundle_id_count(page) == 1
      assert B.page_bundle(page) == B.build(report)
    end

    test "writes an index page without one", %{dir: dir} do
      assert {:ok, first} = HTML.write(RL.report(:check_failed), dir)
      assert {:ok, second} = HTML.write(RL.report(:diverged), dir)

      for page <- [first, second], do: assert(B.bundle_id_count(File.read!(page)) == 1)

      index = File.read!(Path.join(dir, "index.html"))
      refute index =~ "pd-bundle"
      assert B.bundle_id_count(index) == 0
    end

    test "writes an index without one for a directory the index alone is written into", %{
      dir: dir
    } do
      File.mkdir_p!(dir)
      assert {:ok, path} = HTML.write_index(dir)

      refute File.read!(path) =~ "pd-bundle"
    end
  end

  describe "the viewer" do
    test "holds the bundle tag on exactly one line, the tag line" do
      viewer = File.read!(@viewer)
      lines = String.split(viewer, "\n")

      named = Enum.filter(lines, &String.contains?(&1, ~s(id="pd-bundle")))
      assert [tag_line] = named
      assert String.starts_with?(tag_line, @tag_open)
      assert String.contains?(tag_line, "</script>")
    end

    # The script names the bundle only inside explain/1, and calls explain/1
    # only when the page has an explanation tag, so a page without one never
    # reads its bundle.
    test "reads the bundle only on the explanation path" do
      [_markup, script] = @viewer |> File.read!() |> String.split("<script>\n", parts: 2)
      [before, rest] = String.split(script, "\n  function explain(", parts: 2)
      [body, after_body] = String.split(rest, "\n  }\n", parts: 2)
      outside = before <> after_body

      assert body =~ ~s{document.getElementById("pd-bundle")}
      assert not String.contains?(outside, "pd-bundle")
      assert outside =~ ~s{var XTAG = document.getElementById("pd-explanation");}
      assert Regex.scan(~r/\bexplain\(/, outside) == [["explain("]]
      assert outside =~ "if (XTAG) explain(XTAG);"
    end

    test "carries the tag on the line after the report tag" do
      lines = @viewer |> File.read!() |> String.split("\n")

      index = Enum.find_index(lines, &String.contains?(&1, ~s(id="pd-report")))
      assert index
      assert lines |> Enum.at(index + 1) |> String.contains?(~s(id="pd-bundle"))
    end
  end

  describe "text outside ASCII" do
    # The characters are written as escapes, so this file holds only ASCII.
    @doc_text "Zöe pays 5 € to Bob, 日本語"
    @comment_text "Zoë checks 5 €"
    @function_doc "Prüft the ß amount of Åsa"

    setup do
      extra = ~s(@doc "#{@function_doc}"\n  def checked, do: :ok\n)
      system = B.define(model_doc: @doc_text, model_line: @comment_text, model_extra: extra)
      html = system |> B.run() |> HTML.render()
      {:ok, system: system, html: html}
    end

    test "round-trips a moduledoc through the page", %{system: system, html: html} do
      assert String.valid?(html)
      entry = html |> B.page_bundle() |> B.module_entry(system.model)

      assert entry["moduledoc"] == @doc_text
    end

    test "round-trips the doc of a function", %{system: system, html: html} do
      entry = html |> B.page_bundle() |> B.module_entry(system.model)

      assert B.function_entry(entry, :checked, 0)["doc"] == @function_doc
    end

    test "round-trips a line of source", %{system: system, html: html} do
      entry = html |> B.page_bundle() |> B.module_entry(system.model)

      assert entry["source"] =~ "# " <> @comment_text
      assert entry["source"] == File.read!(system.file)
      assert entry["lines"] == B.line_count(system.file)
    end
  end
end
