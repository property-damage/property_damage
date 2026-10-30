defmodule PropertyDamage.FailureReport.ContextSectionGapsTest do
  # A doc that is missing prints a gap line under the item's label line: what
  # is missing and the line that fixes it, byte for byte.
  use ExUnit.Case, async: false

  alias PropertyDamage.Docs
  alias PropertyDamage.Test.ContextSection, as: U

  @pad String.duplicate(" ", 16)

  defp gap_of(report, label) do
    item = report |> U.body!(:terminal) |> U.item!(label)
    assert [line] = item.rest, "#{label}: expected one gap line, got #{inspect(item.rest)}"
    assert String.starts_with?(line, @pad)
    refute String.starts_with?(line, @pad <> " ")
    String.replace_prefix(line, @pad, "")
  end

  defp assert_gap_in_all_renderings(report, label, line) do
    for rendering <- [:terminal, :markdown, :html] do
      item = report |> U.body!(rendering) |> U.item!(label)
      assert item.rest == [@pad <> line], "#{rendering} #{label}"
    end
  end

  describe "a function with no doc or a hidden doc" do
    setup do
      u = U.define(docs: %{check: :omit, model: :omit, projection: :omit, command: :omit})
      on_exit(fn -> U.purge(u) end)
      {:ok, u: u, report: U.check_failed(u)}
    end

    test "a function with no @doc names the function", %{u: u, report: report} do
      assert gap_of(report, "Check") ==
               "(no description: add @doc to #{inspect(u.ledger)}.assert_settled_not_negative/2)"

      assert_gap_in_all_renderings(
        report,
        "Check",
        "(no description: add @doc to #{inspect(u.ledger)}.assert_settled_not_negative/2)"
      )
    end

    test "the name stays on the label line", %{u: u, report: report} do
      item = report |> U.body!(:terminal) |> U.item!("Check")
      assert item.head == "#{inspect(u.ledger)}.assert_settled_not_negative/2"
    end

    test "a module with no @moduledoc names the module, for the model, projection and command",
         %{u: u, report: report} do
      assert gap_of(report, "Model") == "(no description: add @moduledoc to #{inspect(u.model)})"

      assert gap_of(report, "Projection") ==
               "(no description: add @moduledoc to #{inspect(u.ledger)})"

      assert gap_of(report, "Command") == "(no description: add @moduledoc to #{inspect(u.pay)})"
    end
  end

  describe "a hidden doc" do
    setup do
      u = U.define(docs: %{check: false, model: false, projection: false, command: false})
      on_exit(fn -> U.purge(u) end)
      {:ok, u: u, report: U.check_failed(u)}
    end

    test "@doc false on a function asks for a @doc", %{u: u, report: report} do
      assert gap_of(report, "Check") ==
               "(no description: #{inspect(u.ledger)}.assert_settled_not_negative/2 has @doc false; replace it with a @doc)"
    end

    test "@moduledoc false asks for a @moduledoc, for the model, projection and command", %{
      u: u,
      report: report
    } do
      assert gap_of(report, "Model") ==
               "(no description: #{inspect(u.model)} has @moduledoc false; replace it with a @moduledoc)"

      assert gap_of(report, "Projection") ==
               "(no description: #{inspect(u.ledger)} has @moduledoc false; replace it with a @moduledoc)"

      assert gap_of(report, "Command") ==
               "(no description: #{inspect(u.pay)} has @moduledoc false; replace it with a @moduledoc)"
    end
  end

  describe "the observations of a comparison" do
    setup do
      u =
        U.define(
          docs: %{compare_total: :omit, compare_fees: :omit, relation: :omit, projection: :omit}
        )

      on_exit(fn -> U.purge(u) end)
      {:ok, u: u, report: U.diverged(u)}
    end

    test "the observation, the relation and the other observation name their functions", %{
      u: u,
      report: report
    } do
      assert gap_of(report, "Observation") ==
               "(no description: add @doc to #{inspect(u.ledger)}.a_total/2)"

      assert gap_of(report, "Relation") ==
               "(no description: add @doc to #{inspect(u.relations)}.same_total/2)"

      assert gap_of(report, "Also differed") ==
               "(no description: add @doc to #{inspect(u.ledger)}.b_fees/2)"

      assert gap_of(report, "Projection") ==
               "(no description: add @moduledoc to #{inspect(u.ledger)})"
    end
  end

  describe "docs that cannot be read" do
    test "a model, projection and command declared with the behaviour alone" do
      u = U.define(bare: true)
      on_exit(fn -> U.purge(u) end)

      for module <- [u.model, u.ledger, u.pay] do
        assert Docs.fetch(module) == :unavailable, "#{inspect(module)} must have no docs"
      end

      report = U.projection_violation(u)

      assert gap_of(report, "Model") ==
               "(no description: PropertyDamage cannot read the docs of #{inspect(u.model)}; declare it with use PropertyDamage.Model)"

      assert gap_of(report, "Projection") ==
               "(no description: PropertyDamage cannot read the docs of #{inspect(u.ledger)}; declare it with use PropertyDamage.Model.Projection)"

      assert gap_of(report, "Command") ==
               "(no description: PropertyDamage cannot read the docs of #{inspect(u.pay)}; declare it with use PropertyDamage.Command)"
    end

    test "a relation in a module whose docs cannot be read names the projection's use line" do
      u = U.define(relation: :plain)
      on_exit(fn -> U.purge(u) end)
      assert Docs.fetch(u.relations) == :unavailable

      report = U.diverged(u)

      assert gap_of(report, "Relation") ==
               "(no description: PropertyDamage cannot read the docs of #{inspect(u.relations)}; declare it with use PropertyDamage.Model.Projection)"
    end

    test "the gap prints in the markdown and in the page text as it does in the terminal" do
      u = U.define(bare: true)
      on_exit(fn -> U.purge(u) end)

      report = U.projection_violation(u)

      assert_gap_in_all_renderings(
        report,
        "Model",
        "(no description: PropertyDamage cannot read the docs of #{inspect(u.model)}; declare it with use PropertyDamage.Model)"
      )
    end
  end

  describe "an expansion entry with no doc" do
    test "a single entry is the first, and the gap names the model function and the root" do
      u = U.define(commands: :refund, entries: "[credits(n, amount)]")
      on_exit(fn -> U.purge(u) end)

      report = U.refund_diverged(u, [], [], max_commands: 1)

      line =
        "(no description: add doc: \"...\" to the first entry that #{inspect(u.model)}.refund_paths/2 returns for Refund)"

      paths = report |> U.body!(:terminal) |> U.items() |> Enum.filter(&(&1.label == "Path"))
      assert length(paths) == 2

      for path <- paths do
        assert path.rest == [@pad <> line]
      end

      assert_gap_in_all_renderings(report, "Path", line)
    end

    test "the entry that ran counts from one: the second when the first cannot run" do
      entries = "[[{__P__.Blocked, overrides: %{n: n}}], credits(n, amount)]"
      u = U.define(commands: :refund, entries: entries)
      on_exit(fn -> U.purge(u) end)

      report = U.refund_diverged(u, [], [], max_commands: 1)

      for path <- report |> U.body!(:terminal) |> U.items() |> Enum.filter(&(&1.label == "Path")) do
        assert path.rest == [
                 @pad <>
                   "(no description: add doc: \"...\" to the second entry that #{inspect(u.model)}.refund_paths/2 returns for Refund)"
               ]
      end
    end
  end
end
