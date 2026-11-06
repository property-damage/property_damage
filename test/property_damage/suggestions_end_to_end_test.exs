defmodule PropertyDamage.SuggestionsEndToEndTest do
  # Runs a real failing campaign on the ledger model, then analyzes that same
  # model module. The control is the same system with no check projections.
  use ExUnit.Case, async: true

  alias PropertyDamage.Suggestions
  alias PropertyDamage.Suggestions.Patterns
  alias PropertyDamage.Test.Gauntlet, as: G

  @bug {:double_debit_from, 5}
  @patterns_source Path.expand("../../lib/property_damage/suggestions/patterns.ex", __DIR__)

  setup_all do
    # The campaign finds the seeded defect; the analysis then reads the model
    # the campaign ran.
    assert {:error, %PropertyDamage.FailureReport{}} = G.run(G.Model, @bug)
    %{checked: Suggestions.analyze(G.Model), unchecked: Suggestions.analyze(G.UncheckedModel)}
  end

  defp find(analysis, type, field),
    do: Enum.find(analysis.suggestions, &(&1.type == type and &1.field == field))

  describe "analyze/2 on the model a campaign ran" do
    test "analyzes the events the commands declare", %{checked: checked} do
      assert checked.model == G.Model
      assert checked.events_analyzed == 3
      assert Enum.map(checked.existing_checks, & &1.name) == [:balance_matches_ledger]
    end

    test "suggests a non-negative check for the amount", %{checked: checked} do
      assert %{priority: :high, event: G.Events.Deposited, confidence: confidence} =
               find(checked, :non_negative_check, :amount)

      assert confidence == 1.0
    end

    test "suggests a currency check for the opened account", %{checked: checked} do
      assert %{priority: :high, event: G.Events.AccountOpened} =
               find(checked, :currency_consistency, :currency)
    end

    test "suggests an existence check for the account id", %{checked: checked} do
      assert %{priority: :medium, event: G.Events.Deposited} =
               find(checked, :reference_exists, :account_id)
    end

    test "suggests a consistency check for a field shared by events", %{checked: checked} do
      assert %{priority: :medium} = find(checked, :cross_event_consistency, :amount)
      assert %{priority: :low} = find(checked, :cross_event_consistency, :account_id)
    end

    test "sorts suggestions from high to low priority", %{checked: checked} do
      order = %{high: 0, medium: 1, low: 2}
      ranks = Enum.map(checked.suggestions, &order[&1.priority])

      assert ranks == Enum.sort(ranks)

      assert Suggestions.summary(checked) ==
               "Found 8 suggestions: 2 high, 2 medium, 4 low priority"
    end

    test "selects by priority, field and event", %{checked: checked} do
      assert checked |> Suggestions.high_priority() |> Enum.map(& &1.field) == [
               :amount,
               :currency
             ]

      assert [%{type: :non_negative_check}] =
               Suggestions.for_field(checked, :amount)
               |> Enum.filter(&(&1.type == :non_negative_check))

      assert Suggestions.for_event(checked, G.Events.AccountOpened) != []
    end

    test "honors the priority and count options" do
      no_low = Suggestions.analyze(G.Model, include_low_priority: false)
      capped = Suggestions.analyze(G.Model, max_suggestions: 3)

      refute Enum.any?(no_low.suggestions, &(&1.priority == :low))
      assert length(capped.suggestions) == 3
    end
  end

  describe "analyze/2 against checks that exist" do
    test "drops the suggestion for the field a check covers", %{
      checked: checked,
      unchecked: unchecked
    } do
      assert find(unchecked, :non_negative_check, :balance)
      refute find(checked, :non_negative_check, :balance)
    end

    test "keeps the suggestion for a field no check covers", %{checked: checked} do
      assert find(checked, :non_negative_check, :amount)
    end

    test "yields fewer suggestions and more coverage than the unchecked model",
         %{checked: checked, unchecked: unchecked} do
      assert length(checked.suggestions) < length(unchecked.suggestions)
      assert unchecked.existing_checks == []
      assert unchecked.field_coverage.coverage_percentage == 0.0
      assert checked.field_coverage.coverage_percentage == 25.0
      assert :balance in unchecked.field_coverage.uncovered_fields
      refute :balance in checked.field_coverage.uncovered_fields
    end
  end

  describe "format/2" do
    test "renders the terminal report", %{checked: checked} do
      text = Suggestions.format(checked)

      assert text =~ "PROPERTY & INVARIANT SUGGESTIONS"
      assert text =~ "Model: PropertyDamage.Test.Gauntlet.Model"
      assert text =~ "Existing checks: 1"
      assert text =~ "Add non-negative check for amount (amount)"
      assert text =~ "Add currency consistency check (currency)"
    end

    test "renders the markdown report with example code", %{unchecked: unchecked} do
      text = Suggestions.format(unchecked, :markdown)

      assert text =~ "# Property & Invariant Suggestions"
      assert text =~ "| Total Suggestions | 10 |"
      assert text =~ "Add non-negative check for balance `balance` (Deposited)"
      assert text =~ "<summary>Example Code</summary>"
    end

    test "renders the json report", %{checked: checked} do
      json = checked |> Suggestions.format(:json) |> Jason.decode!()

      assert is_map(json)
      assert Jason.encode!(json) =~ "non_negative_check"
    end

    test "generates check code for a suggestion", %{checked: checked} do
      code = checked |> find(:non_negative_check, :amount) |> Suggestions.generate_check_code()

      assert code =~ "amount_non_negative"
    end
  end

end
