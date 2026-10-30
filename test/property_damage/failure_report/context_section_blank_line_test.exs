defmodule PropertyDamage.FailureReport.ContextSectionBlankLineTest do
  # A doc line that holds only spaces prints as an empty line, like a blank doc
  # line, so the section carries no trailing whitespace.
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.ContextSection, as: U

  setup_all do
    u = U.define(docs: %{projection: "Keeps totals.\n   \nSecond line."})
    on_exit(fn -> U.purge(u) end)
    {:ok, report: U.projection_violation(u)}
  end

  for rendering <- [:terminal, :markdown, :html] do
    test "a whitespace-only doc line prints empty in the #{rendering} text", %{report: report} do
      body = U.body(report, unquote(rendering))

      assert Enum.all?(body, fn line -> line == "" or String.trim(line) != "" end),
             "a line of only spaces in the section: #{inspect(body)}"

      first = Enum.find_index(body, &String.contains?(&1, "Keeps totals."))
      assert first, "the subject doc is missing: #{inspect(body)}"
      assert Enum.at(body, first + 1) == ""
      assert String.contains?(Enum.at(body, first + 2), "Second line.")
    end
  end
end
