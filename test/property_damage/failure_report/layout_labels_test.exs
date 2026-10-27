defmodule PropertyDamage.FailureReport.LayoutLabelsTest do
  # One label per step in every section of the report (DR-055 decision 5):
  # roots [i], leaves [i.j] under their root, [setup i], [teardown i] and
  # [branch b.i]. The Failure section's At, every line marked ► and the
  # Projections heading carry the failing step's label.
  use ExUnit.Case, async: true

  alias PropertyDamage.FailureReport
  alias PropertyDamage.Test.ReportLayout, as: L

  @kinds L.kinds()

  defp listing_labels(text) do
    for {_header, lines} <- text |> L.section("Minimal Reproduction") |> L.listings(),
        do: lines |> L.steps() |> Enum.map(& &1.label)
  end

  describe "every failure kind" do
    for kind <- @kinds do
      test "#{kind}: At, the ► lines and the Projections heading carry one label" do
        # The failing step's label agrees across sections; ► ends with ◄── and the outcome.
        report = L.report(unquote(kind))
        facts = L.facts(report)

        for text <- [L.plain(report), L.strip_ansi(L.colored(report)), L.markdown(report)],
            do: L.assert_labels(text, facts)
      end
    end

    test "a failure not localized to a step marks none" do
      # An adapter setup failure and a latency budget print no ► and no At step.
      for kind <- [:setup_failed_adapter, :latency_exceeded] do
        facts = kind |> L.report() |> L.facts()
        assert facts.label == nil, "control: #{kind} is not localized"
        L.assert_labels(L.plain(L.report(kind)), facts)
      end
    end
  end

  describe "an expanded root" do
    test "is [i] in both listings, with the variant's leaves [i.j] under it, never the generated root id" do
      # The shrunk root index labels the root and its leaves; the root line names its entry.
      report = L.report(:diverged_expanded)
      root = report.failed_at_index
      generated = L.generated_root(report)
      assert generated != root, "control: the root's generated id differs from its shrunk index"

      %{entry: entry, leaves: leaves} =
        report.expansions |> Map.fetch!(report.variant.name) |> Enum.find(&(&1.root == root))

      assert is_binary(entry) and length(leaves) == 2,
             "control: the variant ran the root as two leaves"

      L.assert_expanded_root(L.plain(report), root, length(leaves), entry, generated)
    end

    test "a one-target failure inside a leaf is labeled [i.j]" do
      # A check that fails on the second leaf of a Refund marks that leaf.
      report = L.report(:leaf_check)
      root = report.failed_at_index
      assert %{position: %{section: {:leaf, _}, offset: 1}} = FailureReport.failure_step(report)

      text = L.plain(report)
      label = "[#{root}.1]"
      assert L.facts(report).label == label
      L.assert_labels(text, L.facts(report))

      assert [%{label: ^label}] =
               text |> L.section("Minimal Reproduction") |> L.steps() |> Enum.filter(& &1.marked?)
    end
  end

  describe "a branching run" do
    test "lists the prefix as [i], branch commands as [branch b.i] and the suffix as distinct [n]" do
      # Every label is unique; the failing branch command carries ► and At names it.
      report = L.report(:branching)
      text = L.plain(report)
      assert [labels] = listing_labels(text)

      assert ["[0]", "[branch 0.0]", "[branch 0.1]", "[branch 1.0]", suffix] = labels
      assert suffix =~ ~r/^\[\d+\]$/
      assert Enum.uniq(labels) == labels, "labels repeat: #{inspect(labels)}"

      assert [%{label: "[branch 0.1]"}] =
               text |> L.section("Minimal Reproduction") |> L.steps() |> Enum.filter(& &1.marked?)

      assert L.field_value(text, "At") =~ ~r/^\[branch 0\.1\] /
    end
  end

  describe "setup and teardown commands" do
    test "are listed as [setup i] before the roots and [teardown i] after them" do
      # The check failure's listing runs setup, roots, teardown, in that order.
      report = L.report(:setup_check)
      roots = L.facts(report).roots
      assert {length(report.setup_commands), length(report.teardown_commands)} == {2, 1}

      assert [labels] = listing_labels(L.plain(report))

      assert labels ==
               ["[setup 0]", "[setup 1]"] ++
                 Enum.map(0..(roots - 1), &"[#{&1}]") ++ ["[teardown 0]"]

      L.assert_labels(L.plain(report), L.facts(report))
    end

    test "a failure at a setup command is At [setup i], and that line carries ►" do
      # The Login setup command failed: [setup 1].
      report = L.report(:setup_failed_command)
      text = L.plain(report)
      assert L.field_value(text, "At") =~ ~r/^\[setup 1\] /

      assert [%{label: "[setup 1]"}] =
               text |> L.section("Minimal Reproduction") |> L.steps() |> Enum.filter(& &1.marked?)
    end
  end
end
