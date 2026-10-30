defmodule PropertyDamage.FailureReport.ContextSectionLayoutTest do
  # The columns of the "What this checks" section and the way it prints docs:
  # labels at column 2, text at column 16, long labels alone on their line,
  # a subject's doc whole and a supporting doc up to its first blank line,
  # and no doc line that could pass for a heading.
  use ExUnit.Case, async: false

  alias PropertyDamage.{Failure, FailureReport}
  alias PropertyDamage.Failure.Explain
  alias PropertyDamage.Test.ContextSection, as: U

  @label_width 14

  setup_all do
    u = U.define()
    setup = U.define(setup: true)
    on_exit(fn -> Enum.each([u, setup], &U.purge/1) end)

    reports = %{
      check_failed: U.check_failed(u),
      projection_violation: U.projection_violation(u),
      diverged: U.diverged(u),
      did_not_converge: U.did_not_converge(u),
      adapter_error: U.adapter_error(u),
      latency_exceeded: U.latency_exceeded(u),
      setup_failed: U.setup_failed_command(setup)
    }

    {:ok, u: u, reports: reports}
  end

  defp with_failure(report, failure),
    do: %{report | failure_reason: failure, kind: FailureReport.kind_of(failure)}

  describe "columns" do
    test "every line starts at column 2 or column 16, and items sit one blank line apart", %{
      reports: reports
    } do
      for {kind, report} <- reports, rendering <- [:terminal, :markdown] do
        body = U.body!(report, rendering)
        assert length(body) > 3, "#{kind} #{rendering}: a section of one line is no section"

        U.assert_columns(body)
        U.assert_item_separation(body)
      end
    end

    test "the label of a short item is padded to column 16, where its name starts", %{
      reports: reports,
      u: u
    } do
      body = U.body!(reports.check_failed, :terminal)

      assert Enum.any?(
               body,
               &(&1 == "  " <> String.pad_trailing("Model", @label_width) <> inspect(u.model))
             )

      assert Enum.any?(
               body,
               &(&1 ==
                   "  " <>
                     String.pad_trailing("Check", @label_width) <>
                     "#{inspect(u.ledger)}.assert_settled_not_negative/2")
             )
    end

    test "a label of 13 characters keeps one space before the text", %{reports: reports} do
      # "Adapter error" has 13 characters and a short label fits column 16.
      [meaning | _] = U.body!(reports.adapter_error, :terminal) |> U.items()

      assert meaning.label == "Adapter error"
      assert meaning.head != nil
      line = hd(U.body!(reports.adapter_error, :terminal))
      assert String.starts_with?(line, "  Adapter error ")
      assert String.at(line, 16) != " "
      assert String.length("Adapter error") == 13
    end

    test "the meaning of a short label starts on the label line", %{reports: reports} do
      line = hd(U.body!(reports.check_failed, :terminal))

      assert String.starts_with?(
               line,
               "  " <> String.pad_trailing("Check failed", 14) <> "A property"
             )
    end

    for {kind, label} <- [
          projection_violation: "Projection violation",
          did_not_converge: "Did not converge",
          latency_exceeded: "Latency exceeded"
        ] do
      test "#{label} stands alone on its line, its text on the next line at column 16", %{
        reports: reports
      } do
        body = U.body!(reports[unquote(kind)], :terminal)

        assert [first, second | _] = body
        assert first == "  " <> unquote(label)
        assert String.starts_with?(second, String.duplicate(" ", 16))
        refute String.starts_with?(second, String.duplicate(" ", 17))
      end
    end

    test "a label of exactly 14 characters stands alone", %{reports: reports} do
      report = with_failure(reports.check_failed, Failure.settle_timeout(:no_check_saw_it))
      [first, second | _] = U.body!(report, :terminal)

      assert String.length("Settle timeout") == 14
      assert first == "  Settle timeout"
      assert String.starts_with?(second, String.duplicate(" ", 16) <> "The system")
    end
  end

  describe "the meaning" do
    test "wraps at word boundaries within 80 columns and reads as the meaning of the kind", %{
      reports: reports
    } do
      for {kind, report} <- reports do
        [meaning | _] = report |> U.body!(:terminal) |> U.items()
        lines = U.text_lines(meaning)

        assert Enum.all?(lines, &(String.length(&1) <= 80 - 16)),
               "#{kind}: a meaning line is longer than the room after column 16"

        joined = lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join(" ")
        assert joined == Explain.meaning(U.kind(report)), "#{kind}"
      end
    end

    test "a meaning longer than one line breaks into more than one", %{reports: reports} do
      [meaning | _] = reports.diverged |> U.body!(:terminal) |> U.items()
      assert length(U.text_lines(meaning)) >= 3
    end
  end

  describe "a subject prints its whole doc" do
    test "line by line at column 16, a blank line as an empty line", %{reports: reports, u: u} do
      item = reports.check_failed |> U.body!(:terminal) |> U.item!("Check")

      assert item.head == "#{inspect(u.ledger)}.assert_settled_not_negative/2"
      assert item.rest == U.indent(U.doc(:check))
      assert "" in item.rest
    end

    test "a heading and a fenced block inside the doc stay at column 16, in markdown too", %{
      reports: reports
    } do
      for rendering <- [:terminal, :markdown] do
        body = U.body!(reports.check_failed, rendering)
        pad = String.duplicate(" ", 16)

        assert (pad <> "## When it fails") in body
        assert (pad <> "```elixir") in body
        assert (pad <> "```") in body

        refute Enum.any?(body, &String.starts_with?(&1, "#")),
               "#{rendering}: a line starts with #"

        refute Enum.any?(body, &String.starts_with?(&1, "`")),
               "#{rendering}: a line starts with a fence"
      end
    end

    test "the heading inside a doc starts no section of the report", %{reports: reports} do
      for text <- [U.terminal(reports.check_failed), U.markdown(reports.check_failed)] do
        refute "When it fails" in U.headings(text)
        assert Enum.take(U.headings(text), 2) == ["Failure", "What this checks"]
      end
    end

    test "the command of an execution failure prints whole, second paragraph included", %{
      reports: reports
    } do
      item = reports.adapter_error |> U.body!(:terminal) |> U.item!("Command")

      assert item.rest == U.indent(U.doc(:command))
      assert Enum.join(item.rest, "\n") =~ "Second command paragraph."
    end

    test "the projection of a violation prints whole", %{reports: reports} do
      item = reports.projection_violation |> U.body!(:terminal) |> U.item!("Projection")

      assert item.rest == U.indent(U.doc(:projection))
    end

    test "the observation of a divergence prints whole", %{reports: reports} do
      item = reports.diverged |> U.body!(:terminal) |> U.item!("Observation")

      assert item.rest == U.indent(U.doc(:compare_total))
    end

    test "the command of a setup failure prints whole", %{reports: reports} do
      item = reports.setup_failed |> U.body!(:terminal) |> U.item!("Command")

      assert item.rest == U.indent(U.doc(:login))
    end
  end

  describe "a supporting item prints up to the first blank line" do
    test "the model, the projection and the command of a check failure", %{reports: reports} do
      body = U.body!(reports.check_failed, :terminal)

      for {label, key} <- [{"Model", :model}, {"Projection", :projection}, {"Command", :command}] do
        item = U.item!(body, label)
        paragraph = U.first_paragraph(U.doc(key))

        assert item.rest == U.indent(paragraph), label
        assert length(item.rest) >= 2, "#{label}: the first paragraph has several lines"
        refute Enum.join(item.rest, "\n") =~ "Second", label
      end
    end

    test "the relation and the other observation of a divergence", %{reports: reports} do
      body = U.body!(reports.diverged, :terminal)

      assert U.item!(body, "Relation").rest == U.indent(U.first_paragraph(U.doc(:relation)))

      assert U.item!(body, "Also differed").rest ==
               U.indent(U.first_paragraph(U.doc(:compare_fees)))
    end

    test "the projection of a divergence prints its first paragraph", %{reports: reports} do
      item = reports.diverged |> U.body!(:terminal) |> U.item!("Projection")

      assert item.rest == U.indent(U.first_paragraph(U.doc(:projection)))
    end

    test "the command of a comparison prints its first paragraph", %{reports: reports} do
      item = reports.did_not_converge |> U.body!(:terminal) |> U.item!("Command")

      assert item.rest == U.indent(U.first_paragraph(U.doc(:command)))
    end
  end

  test "markdown prints the body the terminal prints", %{reports: reports} do
    for {_kind, report} <- reports do
      assert U.body!(report, :markdown) == U.body!(report, :terminal)
    end
  end
end
