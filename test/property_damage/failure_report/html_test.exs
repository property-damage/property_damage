defmodule PropertyDamage.FailureReport.HTMLTest do
  # The report as one HTML page: the page embeds the terminal text without
  # color, a directory of pages gets an index, and a failing run writes its page
  # when `report_html:` or `PD_REPORT_HTML` names a directory.
  use ExUnit.Case, async: false

  alias PropertyDamage.FailureReport.HTML
  alias PropertyDamage.Test.LogFixtures, as: F
  alias PropertyDamage.Test.TmpPath

  setup do
    F.compile!()
    dir = TmpPath.unique("pd_report_html")
    previous = System.get_env("PD_REPORT_HTML")
    System.delete_env("PD_REPORT_HTML")

    on_exit(fn ->
      File.rm_rf(dir)

      if previous,
        do: System.put_env("PD_REPORT_HTML", previous),
        else: System.delete_env("PD_REPORT_HTML")
    end)

    {:ok, dir: dir}
  end

  defp check_report(extra \\ []),
    do: F.report!(F.Model, [F.target("alice", %{quiet: true, fail_at: 1})], extra)

  defp embedded_text(html) do
    [_, json] =
      Regex.run(~r{<script type="application/json" id="pd-report">(.*?)</script>}s, html)

    Jason.decode!(json)
  end

  defp index_entries(dir) do
    html = File.read!(Path.join(dir, "index.html"))

    [_, json] =
      Regex.run(~r{<script type="application/json" id="pd-reports">(.*?)</script>}s, html)

    Jason.decode!(json)
  end

  describe "render/1" do
    test "embeds the terminal text, without color, as the page's report" do
      report = check_report()
      html = HTML.render(report)

      assert embedded_text(html) == F.plain(report)
      refute embedded_text(html) =~ "\e["
    end

    test "names the model, the failing target and its adapter, the kind and the seed in the title" do
      report = check_report()
      [_, title] = Regex.run(~r{<title>(.*?)</title>}, HTML.render(report))

      assert title =~ inspect(report.model)
      {adapter, _entry} = hd(report.targets)
      assert title =~ "#{adapter |> Module.split() |> List.last()}.alice"
      assert title =~ to_string(report.kind)
      assert title =~ "seed #{report.seed}"
    end

    test "no text in the report can close the script that holds it" do
      report = check_report()
      text = F.plain(report) <> "</script><script>alert(1)</script>"
      json = Jason.encode!(text, escape: :html_safe)

      refute json =~ "</script>"
      assert Jason.decode!(json) == text
      refute HTML.render(report) =~ "__PD_"
    end

    test "the viewer opens an explanation with a fixed line, and a page without one shows none" do
      html = HTML.render(check_report())
      [markup, viewer] = String.split(html, "<script>\n", parts: 2)

      assert viewer =~
               "Hypotheses ranked by a language model from this run; each claim links to its evidence."

      assert viewer =~ ~s{if (XTAG) explain(XTAG);}
      assert not String.contains?(markup, ~s(id="pd-explanation"))
      assert not String.contains?(markup, "Hypotheses ranked")
    end
  end

  describe "write/2" do
    test "writes the page and an index that lists it", %{dir: dir} do
      report = check_report()
      assert {:ok, path} = HTML.write(report, dir)

      assert Path.dirname(path) == dir
      assert File.read!(path) == HTML.render(report)
      assert [%{"file" => file, "title" => title}] = index_entries(dir)
      assert file == Path.basename(path)
      assert title =~ "alice"
    end

    test "the index skips files that are not report pages", %{dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "notes.html"), "<p>no title here</p>")
      File.write!(Path.join(dir, "report.txt"), "text")

      {:ok, path} = HTML.write(check_report(), dir)

      assert Enum.map(index_entries(dir), & &1["file"]) == [Path.basename(path)]
    end

    test "an index with no pages says so", %{dir: dir} do
      File.mkdir_p!(dir)
      assert {:ok, _path} = HTML.write_index(dir)
      assert index_entries(dir) == []
    end
  end

  describe "the run" do
    test "writes no page by default", %{dir: dir} do
      check_report()
      refute File.exists?(dir)
    end

    test "writes the page into report_html:", %{dir: dir} do
      report = check_report(report_html: dir)

      assert [entry] = index_entries(dir)
      assert dir |> Path.join(entry["file"]) |> File.read!() |> embedded_text() == F.plain(report)
    end

    test "PD_REPORT_HTML replaces report_html:", %{dir: dir} do
      System.put_env("PD_REPORT_HTML", dir)
      check_report(report_html: Path.join(dir, "ignored"))

      assert [_entry] = index_entries(dir)
      refute File.exists?(Path.join(dir, "ignored"))
    end

    test "a directory that cannot be written costs a warning, not the report", %{dir: dir} do
      File.mkdir_p!(Path.dirname(dir))
      File.write!(dir, "a file where the directory should be")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %PropertyDamage.FailureReport{} = check_report(report_html: dir)
        end)

      assert log =~ "could not write the failure report's HTML page"
    end

    test "an invalid PD_LOG costs a warning, not the report", %{dir: dir} do
      previous = System.get_env("PD_LOG")
      System.put_env("PD_LOG", "only")

      on_exit(fn ->
        if previous,
          do: System.put_env("PD_LOG", previous),
          else: System.delete_env("PD_LOG")
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %PropertyDamage.FailureReport{} = check_report(report_html: dir)
        end)

      assert log =~ "could not write the failure report's HTML page into #{dir}"
      assert length(String.split(log, "could not write the failure report's HTML page")) == 2
    end

    test "anything but a path or false is an option error" do
      assert_raise NimbleOptions.ValidationError, ~r/report_html/, fn ->
        F.run(F.Model, [F.target("alice")], report_html: :yes)
      end
    end
  end
end
