defmodule PropertyDamage.SuggestionsTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Suggestions
  alias PropertyDamage.Suggestions.{Patterns, Analyzer, Formatter}

  # ============================================================================
  # Test Fixtures
  # ============================================================================

  defmodule TestEvents.AccountCreated do
    defstruct [:account_ref, :balance, :currency, :inserted_at]
  end

  defmodule TestEvents.AccountCredited do
    defstruct [:account_ref, :amount, :currency, :new_balance]
  end

  defmodule TestEvents.AccountDebited do
    defstruct [:account_ref, :amount, :currency, :new_balance]
  end

  defmodule TestEvents.OrderCreated do
    defstruct [:order_ref, :user_id, :total_amount, :status, :created_at]
  end

  defmodule TestEvents.OrderUpdated do
    defstruct [:order_ref, :status, :updated_at]
  end

  defmodule TestEvents.PaymentProcessed do
    defstruct [:payment_id, :order_ref, :amount, :currency]
  end

  # Test projection with existing checks
  defmodule TestProjection do
    use PropertyDamage.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state

    @trigger every: 1
    def assert_balance_non_negative(_state, _cmd_or_event) do
      # No-op assertion that always passes
      :ok
    end
  end

  # Test projection without checks
  defmodule EmptyProjection do
    @behaviour PropertyDamage.Projection

    @impl true
    def init, do: %{}

    @impl true
    def apply(state, _), do: state
  end

  # Test model
  defmodule TestModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: []

    @impl true
    def state_projection, do: EmptyProjection

    @impl true
    def extra_projections, do: [TestProjection]
  end

  # Model with no projections
  defmodule MinimalModel do
    @behaviour PropertyDamage.Model

    @impl true
    def commands, do: []

    @impl true
    def state_projection, do: EmptyProjection

    @impl true
    def extra_projections, do: []
  end

  # ============================================================================
  # Patterns Tests
  # ============================================================================

  describe "Patterns.detect_patterns/1" do
    test "detects numeric patterns in event fields" do
      patterns = Patterns.detect_patterns(TestEvents.AccountCreated)

      balance_pattern = Enum.find(patterns, &(&1.field == :balance))
      assert balance_pattern != nil
      assert balance_pattern.type == :numeric
      assert balance_pattern.confidence >= 0.9
    end

    test "detects currency patterns" do
      patterns = Patterns.detect_patterns(TestEvents.AccountCreated)

      currency_pattern = Enum.find(patterns, &(&1.field == :currency))
      assert currency_pattern != nil
      assert currency_pattern.type == :currency
    end

    test "detects reference patterns" do
      patterns = Patterns.detect_patterns(TestEvents.AccountCreated)

      ref_pattern = Enum.find(patterns, &(&1.field == :account_ref))
      assert ref_pattern != nil
      assert ref_pattern.type == :reference
    end

    test "detects status patterns" do
      patterns = Patterns.detect_patterns(TestEvents.OrderCreated)

      status_pattern = Enum.find(patterns, &(&1.field == :status))
      assert status_pattern != nil
      assert status_pattern.type == :status
    end

    test "detects timestamp patterns" do
      patterns = Patterns.detect_patterns(TestEvents.OrderCreated)

      timestamp_pattern = Enum.find(patterns, &(&1.field == :created_at))
      assert timestamp_pattern != nil
      assert timestamp_pattern.type == :timestamp
    end

    test "returns empty for non-struct module" do
      patterns = Patterns.detect_patterns(String)
      assert patterns == []
    end
  end

  describe "Patterns.detect_patterns_multi/1" do
    test "detects patterns across multiple events" do
      events = [
        TestEvents.AccountCreated,
        TestEvents.AccountCredited,
        TestEvents.AccountDebited
      ]

      patterns = Patterns.detect_patterns_multi(events)

      # Should find currency in multiple events
      currency_patterns = Enum.filter(patterns, &(&1.type == :currency))
      assert length(currency_patterns) >= 1

      # Should have higher confidence for fields in multiple events
      currency_pattern = hd(currency_patterns)
      assert currency_pattern.confidence >= 0.95
    end

    test "groups patterns by field and type" do
      events = [
        TestEvents.AccountCreated,
        TestEvents.AccountCredited
      ]

      patterns = Patterns.detect_patterns_multi(events)

      # Each field/type combo should appear once
      unique_keys =
        patterns
        |> Enum.map(fn p -> {p.type, p.field} end)
        |> Enum.uniq()

      assert length(unique_keys) == length(patterns)
    end
  end

  describe "Patterns.find_cross_event_fields/1" do
    test "finds fields appearing in multiple events" do
      events = [
        TestEvents.AccountCreated,
        TestEvents.AccountCredited,
        TestEvents.AccountDebited
      ]

      cross_fields = Patterns.find_cross_event_fields(events)

      # currency appears in all three
      currency_entry = Enum.find(cross_fields, fn {field, _} -> field == :currency end)
      assert currency_entry != nil
      {_field, events_with_currency} = currency_entry
      assert length(events_with_currency) == 3

      # account_ref appears in all three
      ref_entry = Enum.find(cross_fields, fn {field, _} -> field == :account_ref end)
      assert ref_entry != nil
    end

    test "sorts by number of occurrences descending" do
      events = [
        TestEvents.AccountCreated,
        TestEvents.AccountCredited,
        TestEvents.OrderCreated
      ]

      cross_fields = Patterns.find_cross_event_fields(events)

      if length(cross_fields) >= 2 do
        [{_f1, e1}, {_f2, e2} | _] = cross_fields
        assert length(e1) >= length(e2)
      end
    end
  end

  describe "Patterns.suggest_checks_for_field/2" do
    test "suggests non-negative for balance field" do
      checks = Patterns.suggest_checks_for_field(:balance)

      assert :non_negative in checks
      assert :reasonable_bounds in checks
    end

    test "suggests currency checks for currency field" do
      checks = Patterns.suggest_checks_for_field(:currency)

      assert :currency_consistency in checks
      assert :valid_currency_code in checks
    end

    test "suggests reference checks for ref fields" do
      checks = Patterns.suggest_checks_for_field(:account_ref)

      assert :reference_exists in checks
      assert :reference_valid in checks
    end

    test "suggests status checks for status field" do
      checks = Patterns.suggest_checks_for_field(:status)

      assert :valid_status in checks
      assert :valid_transition in checks
    end

    test "filters by focus option" do
      all_checks = Patterns.suggest_checks_for_field(:balance)
      numeric_checks = Patterns.suggest_checks_for_field(:balance, focus: :numeric)

      assert :non_negative in numeric_checks
      # Should not include non-numeric checks
      assert length(numeric_checks) <= length(all_checks)
    end
  end

  describe "Patterns.field_pattern_type/1" do
    test "returns :numeric for balance" do
      assert Patterns.field_pattern_type(:balance) == :numeric
    end

    test "returns :currency for currency" do
      assert Patterns.field_pattern_type(:currency) == :currency
    end

    test "returns :reference for account_ref" do
      assert Patterns.field_pattern_type(:account_ref) == :reference
    end

    test "returns :status for status" do
      assert Patterns.field_pattern_type(:status) == :status
    end

    test "returns nil for unknown field" do
      assert Patterns.field_pattern_type(:random_field) == nil
    end
  end

  # ============================================================================
  # Analyzer Tests
  # ============================================================================

  describe "Analyzer.analyze/2" do
    test "returns analysis structure" do
      analysis = Analyzer.analyze(TestModel)

      assert Map.has_key?(analysis, :model)
      assert Map.has_key?(analysis, :suggestions)
      assert Map.has_key?(analysis, :detected_patterns)
      assert Map.has_key?(analysis, :existing_checks)
      assert Map.has_key?(analysis, :field_coverage)
      assert Map.has_key?(analysis, :summary)
    end

    test "finds existing checks" do
      analysis = Analyzer.analyze(TestModel)

      assert length(analysis.existing_checks) >= 1

      check_names = Enum.map(analysis.existing_checks, & &1.name)
      assert :balance_non_negative in check_names
    end

    test "respects max_suggestions option" do
      analysis = Analyzer.analyze(MinimalModel, max_suggestions: 3)

      assert length(analysis.suggestions) <= 3
    end

    test "respects include_low_priority option" do
      analysis_with_low = Analyzer.analyze(MinimalModel, include_low_priority: true)
      analysis_without_low = Analyzer.analyze(MinimalModel, include_low_priority: false)

      low_count_with = Enum.count(analysis_with_low.suggestions, &(&1.priority == :low))
      low_count_without = Enum.count(analysis_without_low.suggestions, &(&1.priority == :low))

      assert low_count_without == 0
      # May or may not have low priority depending on patterns detected
    end

    test "calculates field coverage" do
      analysis = Analyzer.analyze(TestModel)

      coverage = analysis.field_coverage
      assert Map.has_key?(coverage, :total_fields)
      assert Map.has_key?(coverage, :covered_fields)
      assert Map.has_key?(coverage, :uncovered_fields)
      assert Map.has_key?(coverage, :coverage_percentage)
      assert is_float(coverage.coverage_percentage)
    end

    test "generates summary" do
      analysis = Analyzer.analyze(TestModel)

      assert is_binary(analysis.summary)
      assert String.length(analysis.summary) > 0
    end
  end

  # ============================================================================
  # Suggestions API Tests
  # ============================================================================

  describe "Suggestions.analyze/2" do
    test "returns analysis for a model" do
      analysis = Suggestions.analyze(TestModel)

      assert analysis.model == TestModel
      assert is_list(analysis.suggestions)
    end
  end

  describe "Suggestions.format/2" do
    test "formats for terminal" do
      analysis = Suggestions.analyze(TestModel)
      output = Suggestions.format(analysis, :terminal)

      assert is_binary(output)
      assert output =~ "PROPERTY & INVARIANT SUGGESTIONS"
    end

    test "formats for markdown" do
      analysis = Suggestions.analyze(TestModel)
      output = Suggestions.format(analysis, :markdown)

      assert is_binary(output)
      assert output =~ "# Property & Invariant Suggestions"
      assert output =~ "## Summary"
    end

    test "formats for json" do
      analysis = Suggestions.analyze(TestModel)
      output = Suggestions.format(analysis, :json)

      assert is_binary(output)
      decoded = Jason.decode!(output)
      assert Map.has_key?(decoded, "suggestions")
      assert Map.has_key?(decoded, "field_coverage")
    end
  end

  describe "Suggestions.high_priority/1" do
    test "filters to only high priority suggestions" do
      analysis = %{
        suggestions: [
          %{priority: :high, type: :test1},
          %{priority: :medium, type: :test2},
          %{priority: :low, type: :test3},
          %{priority: :high, type: :test4}
        ]
      }

      high = Suggestions.high_priority(analysis)

      assert length(high) == 2

      for suggestion <- high do
        assert suggestion.priority == :high,
               "expected high priority, got: #{inspect(suggestion)}"
      end
    end
  end

  describe "Suggestions.for_field/2" do
    test "filters suggestions by field" do
      analysis = %{
        suggestions: [
          %{field: :balance, type: :test1},
          %{field: :currency, type: :test2},
          %{field: :balance, type: :test3},
          %{field: nil, type: :test4}
        ]
      }

      balance_suggestions = Suggestions.for_field(analysis, :balance)

      assert length(balance_suggestions) == 2

      for suggestion <- balance_suggestions do
        assert suggestion.field == :balance,
               "expected field :balance, got: #{inspect(suggestion)}"
      end
    end
  end

  describe "Suggestions.for_event/2" do
    test "filters suggestions by event" do
      analysis = %{
        suggestions: [
          %{event: TestEvents.AccountCreated, type: :test1},
          %{event: TestEvents.OrderCreated, type: :test2},
          %{event: TestEvents.AccountCreated, type: :test3}
        ]
      }

      account_suggestions = Suggestions.for_event(analysis, TestEvents.AccountCreated)

      assert length(account_suggestions) == 2

      for suggestion <- account_suggestions do
        assert suggestion.event == TestEvents.AccountCreated,
               "expected event TestEvents.AccountCreated, got: #{inspect(suggestion)}"
      end
    end
  end

  describe "Suggestions.summary/1" do
    test "returns summary string" do
      analysis = %{
        suggestions: [
          %{priority: :high},
          %{priority: :high},
          %{priority: :medium},
          %{priority: :low}
        ]
      }

      summary = Suggestions.summary(analysis)

      assert summary =~ "4 suggestions"
      assert summary =~ "2 high"
      assert summary =~ "1 medium"
      assert summary =~ "1 low"
    end
  end

  # ============================================================================
  # Formatter Tests
  # ============================================================================

  describe "Formatter.format/2" do
    setup do
      analysis = %{
        model: TestModel,
        suggestions: [
          %{
            type: :non_negative_check,
            priority: :high,
            field: :balance,
            event: TestEvents.AccountCreated,
            command: nil,
            description: "Add non-negative check for balance",
            rationale: "Balance should never be negative",
            example_code: "check code here",
            confidence: 0.95
          },
          %{
            type: :currency_consistency,
            priority: :medium,
            field: :currency,
            event: TestEvents.AccountCredited,
            command: nil,
            description: "Add currency consistency check",
            rationale: "Currencies should match",
            example_code: nil,
            confidence: 0.9
          }
        ],
        detected_patterns: [],
        existing_checks: [],
        cross_event_fields: [],
        events_analyzed: 3,
        field_coverage: %{
          total_fields: 10,
          covered_fields: 3,
          uncovered_fields: [:amount, :status],
          coverage_percentage: 30.0
        },
        summary: "Test summary"
      }

      {:ok, analysis: analysis}
    end

    test "terminal format includes header", %{analysis: analysis} do
      output = Formatter.format(analysis, :terminal)

      assert output =~ "PROPERTY & INVARIANT SUGGESTIONS"
    end

    test "terminal format shows suggestions by priority", %{analysis: analysis} do
      output = Formatter.format(analysis, :terminal)

      assert output =~ "HIGH PRIORITY"
      assert output =~ "MEDIUM PRIORITY"
      assert output =~ "balance"
    end

    test "terminal format shows unchecked fields", %{analysis: analysis} do
      output = Formatter.format(analysis, :terminal)

      assert output =~ "Unchecked Fields" or output =~ ":amount"
    end

    test "markdown format includes header", %{analysis: analysis} do
      output = Formatter.format(analysis, :markdown)

      assert output =~ "# Property & Invariant Suggestions"
    end

    test "markdown format includes summary table", %{analysis: analysis} do
      output = Formatter.format(analysis, :markdown)

      assert output =~ "| Metric | Value |"
      assert output =~ "Events Analyzed"
    end

    test "markdown format groups by priority", %{analysis: analysis} do
      output = Formatter.format(analysis, :markdown)

      assert output =~ "High Priority"
      assert output =~ "Medium Priority"
    end

    test "json format is valid JSON", %{analysis: analysis} do
      output = Formatter.format(analysis, :json)

      decoded = Jason.decode!(output)
      assert is_map(decoded)
      assert decoded["field_coverage"]["coverage_percentage"] == 30.0
    end
  end

  describe "Formatter.generate_example_code/1" do
    test "generates code for non_negative_check" do
      suggestion = %{type: :non_negative_check, field: :balance}
      code = Formatter.generate_example_code(suggestion)

      assert code =~ "@trigger every: 1"
      assert code =~ "def assert_balance_non_negative"
      assert code =~ "PropertyDamage.fail!"
    end

    test "generates code for currency_consistency" do
      suggestion = %{type: :currency_consistency, field: :currency}
      code = Formatter.generate_example_code(suggestion)

      assert code =~ "currency"
    end

    test "generates code for reference_exists" do
      suggestion = %{type: :reference_exists, field: :account_ref}
      code = Formatter.generate_example_code(suggestion)

      assert code =~ "account"
      assert code =~ "exists"
    end

    test "generates fallback for unknown type" do
      suggestion = %{type: :unknown_type, description: "Test suggestion"}
      code = Formatter.generate_example_code(suggestion)

      assert code =~ "Test suggestion"
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "integration" do
    test "full workflow with test model" do
      # Analyze
      analysis = Suggestions.analyze(TestModel)

      # Check structure
      assert analysis.model == TestModel
      assert is_list(analysis.suggestions)

      # Format in different formats
      terminal = Suggestions.format(analysis, :terminal)
      markdown = Suggestions.format(analysis, :markdown)
      json = Suggestions.format(analysis, :json)

      assert is_binary(terminal)
      assert is_binary(markdown)
      assert is_binary(json)

      # Filter suggestions
      high = Suggestions.high_priority(analysis)
      assert is_list(high)

      # Get summary
      summary = Suggestions.summary(analysis)
      assert is_binary(summary)
    end

    test "handles model with no assertion projections" do
      analysis = Suggestions.analyze(MinimalModel)

      assert analysis.model == MinimalModel
      assert analysis.existing_checks == []
    end
  end
end
