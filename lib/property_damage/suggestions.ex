defmodule PropertyDamage.Suggestions do
  @moduledoc """
  Property and invariant suggestions for PropertyDamage models.

  Analyzes a model's commands, events, and projections to suggest missing
  checks and invariants that would improve test coverage.

  ## Overview

  This module helps answer the question: "What invariants should my model check?"

  It examines:
  - **Event fields**: Numeric fields that should be non-negative, currency fields
    that should be consistent, reference fields that should exist, etc.
  - **Command patterns**: Operations that commonly need specific checks
  - **Existing checks**: What's already covered vs what's missing

  ## Usage

      # Analyze a model and get suggestions
      suggestions = PropertyDamage.Suggestions.analyze(MyModel)

      # Print suggestions
      IO.puts(PropertyDamage.Suggestions.format(suggestions))

      # Get suggestions as structured data
      suggestions.missing_checks      # List of suggested checks
      suggestions.unchecked_fields    # Fields with no apparent validation
      suggestions.coverage_gaps       # Areas lacking coverage

  ## How It Works

  1. **Event Analysis**: Extracts all events produced by commands and analyzes
     their field types to suggest appropriate checks.

  2. **Pattern Detection**: Identifies common patterns that warrant invariants:
     - Numeric fields (balance, amount, count) → non-negative checks
     - Currency/type fields → consistency checks across operations
     - Reference fields (account_ref, user_id) → existence checks
     - Status fields → valid state transition checks
     - Timestamp fields → ordering checks

  3. **Check Coverage**: Compares detected patterns against existing checks
     to find gaps in test coverage.

  4. **Suggestion Generation**: Produces actionable suggestions with example
     code for implementing missing checks.
  """

  alias PropertyDamage.Suggestions.{Analyzer, Formatter, Patterns}

  @type suggestion :: %{
          type: atom(),
          priority: :high | :medium | :low,
          field: atom() | nil,
          event: module() | nil,
          command: module() | nil,
          description: String.t(),
          rationale: String.t(),
          example_code: String.t() | nil
        }

  @type analysis :: %{
          model: module(),
          suggestions: [suggestion()],
          detected_patterns: [Patterns.pattern()],
          existing_checks: [map()],
          field_coverage: map(),
          summary: String.t()
        }

  @doc """
  Analyzes a model and returns suggestions for missing checks.

  ## Options

  - `:include_low_priority` - Include low priority suggestions (default: true)
  - `:max_suggestions` - Maximum suggestions to return (default: 20)
  - `:focus` - Focus on specific areas: `:all`, `:numeric`, `:references`, `:consistency` (default: `:all`)

  ## Example

      suggestions = PropertyDamage.Suggestions.analyze(MyModel)
      IO.puts(PropertyDamage.Suggestions.format(suggestions))
  """
  @spec analyze(module(), keyword()) :: analysis()
  def analyze(model, opts \\ []) do
    Analyzer.analyze(model, opts)
  end

  @doc """
  Formats suggestions for display.

  ## Formats

  - `:terminal` - ASCII box output for console (default)
  - `:markdown` - Markdown tables for documentation
  - `:json` - JSON for programmatic analysis

  ## Example

      suggestions = PropertyDamage.Suggestions.analyze(MyModel)
      IO.puts(PropertyDamage.Suggestions.format(suggestions, :terminal))
  """
  @spec format(analysis(), atom()) :: String.t()
  def format(analysis, format \\ :terminal) do
    Formatter.format(analysis, format)
  end

  @doc """
  Returns only high-priority suggestions.
  """
  @spec high_priority(analysis()) :: [suggestion()]
  def high_priority(analysis) do
    Enum.filter(analysis.suggestions, &(&1.priority == :high))
  end

  @doc """
  Returns suggestions for a specific field.
  """
  @spec for_field(analysis(), atom()) :: [suggestion()]
  def for_field(analysis, field) do
    Enum.filter(analysis.suggestions, &(&1.field == field))
  end

  @doc """
  Returns suggestions for a specific event type.
  """
  @spec for_event(analysis(), module()) :: [suggestion()]
  def for_event(analysis, event_module) do
    Enum.filter(analysis.suggestions, &(&1.event == event_module))
  end

  @doc """
  Generates example check code for a suggestion.
  """
  @spec generate_check_code(suggestion()) :: String.t()
  def generate_check_code(suggestion) do
    suggestion.example_code || Formatter.generate_example_code(suggestion)
  end

  @doc """
  Returns a quick summary of the analysis.
  """
  @spec summary(analysis()) :: String.t()
  def summary(analysis) do
    high = length(high_priority(analysis))
    medium = length(Enum.filter(analysis.suggestions, &(&1.priority == :medium)))
    low = length(Enum.filter(analysis.suggestions, &(&1.priority == :low)))
    total = length(analysis.suggestions)

    "Found #{total} suggestions: #{high} high, #{medium} medium, #{low} low priority"
  end
end
