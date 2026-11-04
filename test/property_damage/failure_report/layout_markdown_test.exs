defmodule PropertyDamage.FailureReport.LayoutMarkdownTest do
  # The markdown failure report is the plain terminal layout in markdown
  # dress (DR-055 decision 11): the banner as a heading, the seed, the same
  # sections in the same order, each body fenced and equal to the terminal's,
  # and no color.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.ReportLayout, as: L

  @kinds L.kinds()

  describe "every failure kind" do
    for kind <- @kinds do
      test "#{kind}: markdown mirrors the plain terminal report" do
        # Banner heading, Seed, the same headings, each fenced body equal to the terminal's, no ANSI.
        report = L.report(unquote(kind))
        L.assert_markdown_mirrors(L.markdown(report), L.plain(report), L.facts(report))
      end
    end
  end
end
