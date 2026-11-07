defmodule PropertyDamage.FailureReport.ContextSectionPositionTest do
  # The "What this checks" section is the second section of every failure
  # report, in the terminal text, the markdown, the HTML page's text and the
  # JSON data, and the three text renderings print the same body.
  use ExUnit.Case, async: false

  alias PropertyDamage.Failure.Explain
  alias PropertyDamage.Test.ContextSection, as: U
  alias PropertyDamage.Test.ReportLayout, as: L

  @kinds L.kinds() ++ [:idempotency, :poll_timeout]

  setup_all do
    u = U.define()
    on_exit(fn -> U.purge(u) end)
    {:ok, documented: U.check_failed(u), universe: u}
  end

  describe "position" do
    for kind <- @kinds do
      test "#{kind}: the section is second in the terminal text and in the markdown" do
        report = L.report(unquote(kind))

        for text <- [U.terminal(report), U.markdown(report)] do
          headings = U.headings(text)

          assert Enum.take(headings, 2) == ["Failure", "What this checks"],
                 "headings: #{inspect(headings)}"

          assert Enum.count(headings, &(&1 == "What this checks")) == 1
        end
      end

      test "#{kind}: the JSON data opens with the meaning of the kind" do
        report = L.report(unquote(kind))
        items = U.json_items!(report)

        assert is_list(items) and items != [], "no what_this_checks list"
        assert [%{"label" => label, "name" => nil, "missing" => false} | _] = items
        assert label == U.kind_label(U.kind(report))
      end
    end
  end

  describe "the three text renderings print one body" do
    for kind <- @kinds do
      test "#{kind}: terminal, markdown fence and page text are byte-identical" do
        report = L.report(unquote(kind))

        terminal = U.body!(report, :terminal)
        assert U.body!(report, :markdown) == terminal
        assert U.body!(report, :html) == terminal
        assert Enum.join(terminal, "\n") != ""
      end
    end

    test "a documented check failure with a fenced doc is identical in all three", %{
      documented: report
    } do
      terminal = U.body!(report, :terminal)

      assert U.body!(report, :markdown) == terminal
      assert U.body!(report, :html) == terminal
      assert Enum.any?(terminal, &(&1 == String.duplicate(" ", 16) <> "## When it fails"))
    end
  end

  describe "the JSON data" do
    test "is a list of maps with exactly label, name, text and missing", %{documented: report} do
      items = U.json_items!(report)

      assert length(items) >= 5

      for item <- items do
        assert item |> Map.keys() |> Enum.sort() == ["label", "missing", "name", "text"]
        assert is_binary(item["text"])
        assert is_boolean(item["missing"])
      end
    end

    test "lists the items in the order the section prints them", %{documented: report} do
      printed = report |> U.body!(:terminal) |> U.labels()
      json = U.json_items!(report) |> Enum.map(& &1["label"])

      assert json == printed
    end

    test "holds the meaning first, with no name, and the doc items by name", %{
      documented: report,
      universe: u
    } do
      [meaning, model, check | _] = U.json_items!(report)

      assert meaning["label"] == "Check failed"
      assert meaning["name"] == nil
      assert String.replace(meaning["text"], ~r/\s+/, " ") == Explain.meaning(:check_failed)

      assert model == %{
               "label" => "Model",
               "name" => inspect(u.model),
               "text" => U.first_paragraph(U.doc(:model)),
               "missing" => false
             }

      assert check["label"] == "Check"
      assert check["name"] == "#{inspect(u.ledger)}.assert_settled_not_negative/2"
      assert check["text"] == U.doc(:check)
    end

    test "holds the text without the printed indent", %{documented: report} do
      for item <- U.json_items!(report) do
        refute String.starts_with?(item["text"], " "), inspect(item)
        refute item["text"] =~ ~r/\n {16}/
      end
    end

    test "marks a missing doc with its gap line and nothing else as missing" do
      gap = U.define(docs: %{check: :omit, command: :omit})
      on_exit(fn -> U.purge(gap) end)

      items = gap |> U.check_failed() |> U.json_items!()
      by_label = Map.new(items, &{&1["label"], &1})

      assert by_label["Check"]["missing"] == true

      assert by_label["Check"]["text"] ==
               "(no description: add @doc to #{inspect(gap.ledger)}.assert_settled_not_negative/2)"

      assert by_label["Command"]["missing"] == true
      assert by_label["Model"]["missing"] == false
      assert by_label["Projection"]["missing"] == false
    end
  end

  test "every meaning in the section is the meaning of its kind" do
    for kind <- @kinds do
      report = L.report(kind)
      [meaning | _] = U.json_items!(report)

      assert String.replace(meaning["text"], ~r/\s+/, " ") ==
               Explain.meaning(U.kind(report)),
             "#{kind}"
    end
  end
end
