defmodule PropertyDamage.FailureReport.LayoutMarkdownTest do
  # The markdown failure report is the plain terminal layout in markdown
  # dress (DR-055 decision 11): the banner as a heading, the seed, the same
  # sections in the same order, each body fenced and equal to the terminal's,
  # and no color. A report saved before the reference and wait fields renders
  # in both formats.
  #
  # Not async: the saved report's projection is compiled here under the name
  # the persistence tests also compile it under.
  use ExUnit.Case, async: false

  alias PropertyDamage.Persistence
  alias PropertyDamage.Test.Compare
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

  describe "a report saved before the reference and wait fields" do
    # The file was saved by format-15 code from a run of two PayAdapter
    # targets "a" and "b" compared on this projection.
    @fixture Path.expand(
               "../../support/fixtures/persistence/v15_without_reference_fields.pd",
               __DIR__
             )

    @saved_projection_source """
    defmodule PropertyDamage.Test.SavedV15.Ledger do
      use PropertyDamage.Model.Projection
      alias PropertyDamage.Test.Compare.{Paid, Settled}

      @impl true
      def init, do: %{unsettled: %{}, settled: 0, by: nil}

      @impl true
      def apply(s, %Paid{n: n, amount: a, by: by}), do: %{s | unsettled: Map.put(s.unsettled, n, a), by: by}
      def apply(s, %Settled{n: n, amount: a}), do: %{s | unsettled: Map.delete(s.unsettled, n), settled: s.settled + a}
      def apply(s, _), do: s

      @compare every: 1
      def totals(s, _root) do
        if s.unsettled == %{}, do: %{settled: s.settled}, else: {:pending, :unsettled}
      end
    end
    """

    # Loading decodes only atoms that exist, so the saved run's projection
    # and model are defined, and every module loaded, before the file is read.
    setup do
      projection = PropertyDamage.Test.SavedV15.Ledger

      unless Code.ensure_loaded?(projection) do
        {:ok, [^projection | _]} = Compare.compile(@saved_projection_source)
      end

      model = PropertyDamage.Test.SavedV15.Model
      unless Code.ensure_loaded?(model), do: Compare.define_model!(model, [projection])
      Enum.each(Application.spec(:property_damage, :modules), &Code.ensure_loaded!/1)
      :ok
    end

    test "is refused as format version 15, so it never reaches the layout" do
      # Version 16 refuses every older file (DR-061).
      assert Persistence.load(@fixture) == {:error, {:unsupported_format_version, 15, 16}}
    end
  end
end
