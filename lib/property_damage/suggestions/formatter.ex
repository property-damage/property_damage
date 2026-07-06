defmodule PropertyDamage.Suggestions.Formatter do
  @moduledoc false

  @box_width 72

  @doc """
  Formats analysis results for the specified output format.
  """
  @spec format(map(), atom()) :: String.t()
  def format(analysis, format \\ :terminal)

  def format(analysis, :terminal) do
    [
      format_header_terminal(),
      format_summary_terminal(analysis),
      format_suggestions_terminal(analysis),
      format_field_coverage_terminal(analysis),
      format_footer_terminal()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def format(analysis, :markdown) do
    [
      format_header_markdown(),
      format_summary_markdown(analysis),
      format_suggestions_markdown(analysis),
      format_field_coverage_markdown(analysis)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def format(analysis, :json) do
    %{
      model: inspect(analysis.model),
      summary: analysis.summary,
      suggestions:
        Enum.map(analysis.suggestions, fn s ->
          %{
            type: s.type,
            priority: s.priority,
            field: s.field,
            event: if(s.event, do: inspect(s.event), else: nil),
            description: s.description,
            rationale: s.rationale
          }
        end),
      field_coverage: analysis.field_coverage,
      existing_checks_count: length(analysis.existing_checks),
      patterns_detected: length(analysis.detected_patterns)
    }
    |> Jason.encode!(pretty: true)
  end

  @doc """
  Generates example check code for a suggestion.
  """
  @spec generate_example_code(map()) :: String.t()
  def generate_example_code(suggestion) do
    case suggestion.type do
      :non_negative_check ->
        generate_non_negative_code(suggestion.field)

      :currency_consistency ->
        generate_currency_code()

      :reference_exists ->
        generate_reference_code(suggestion.field)

      :valid_status_transition ->
        generate_status_code(suggestion.field)

      _ ->
        "# Add a check for #{suggestion.description}"
    end
  end

  # ============================================================================
  # Terminal Format
  # ============================================================================

  defp format_header_terminal do
    """
    ╔#{String.duplicate("═", @box_width)}╗
    ║#{String.pad_leading("PROPERTY & INVARIANT SUGGESTIONS", div(@box_width, 2) + 16)}#{String.duplicate(" ", div(@box_width, 2) - 16)}║
    ╚#{String.duplicate("═", @box_width)}╝
    """
  end

  defp format_summary_terminal(analysis) do
    high = Enum.count(analysis.suggestions, &(&1.priority == :high))
    medium = Enum.count(analysis.suggestions, &(&1.priority == :medium))
    low = Enum.count(analysis.suggestions, &(&1.priority == :low))

    model_name = analysis.model |> Module.split() |> Enum.join(".")

    coverage = analysis.field_coverage.coverage_percentage

    """

    Model: #{model_name}
    Events analyzed: #{analysis.events_analyzed}
    Existing checks: #{length(analysis.existing_checks)}
    Field coverage: #{coverage}%

    Suggestions: #{length(analysis.suggestions)} total
      ▸ #{high} high priority (should address)
      ▸ #{medium} medium priority (consider adding)
      ▸ #{low} low priority (nice to have)
    """
  end

  defp format_suggestions_terminal(analysis) do
    if analysis.suggestions == [] do
      """

      ┌─ No Suggestions ────────────────────────────────────────────────────┐
      │ Great! Your model appears to have good check coverage.              │
      └─────────────────────────────────────────────────────────────────────┘
      """
    else
      header = "\n┌─ Suggestions #{String.duplicate("─", @box_width - 15)}┐"
      footer = "└#{String.duplicate("─", @box_width)}┘"

      # Group by priority
      by_priority = Enum.group_by(analysis.suggestions, & &1.priority)

      sections =
        [:high, :medium, :low]
        |> Enum.map(fn priority ->
          suggestions = Map.get(by_priority, priority, [])

          if suggestions != [] do
            format_priority_section(priority, suggestions)
          else
            nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n│#{String.duplicate(" ", @box_width)}│\n")

      "#{header}\n#{sections}\n#{footer}"
    end
  end

  defp format_priority_section(priority, suggestions) do
    label =
      case priority do
        :high -> "HIGH PRIORITY"
        :medium -> "MEDIUM PRIORITY"
        :low -> "LOW PRIORITY"
      end

    header = "│ ▶ #{label} #{String.duplicate("─", @box_width - String.length(label) - 5)}│"

    rows =
      suggestions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, idx} ->
        desc = truncate(s.description, @box_width - 8)
        field_info = if s.field, do: " (#{s.field})", else: ""
        line = "#{idx}. #{desc}#{field_info}"
        "│   #{String.pad_trailing(line, @box_width - 4)}│"
      end)

    "#{header}\n#{rows}"
  end

  defp format_field_coverage_terminal(analysis) do
    coverage = analysis.field_coverage

    if coverage.uncovered_fields == [] do
      nil
    else
      header = "\n┌─ Unchecked Fields #{String.duplicate("─", @box_width - 20)}┐"
      footer = "└#{String.duplicate("─", @box_width)}┘"

      fields =
        coverage.uncovered_fields
        |> Enum.take(10)
        |> Enum.map_join(", ", &inspect/1)

      content = "│ #{String.pad_trailing(fields, @box_width - 2)}│"

      more =
        if length(coverage.uncovered_fields) > 10 do
          remaining = length(coverage.uncovered_fields) - 10
          "\n│ #{String.pad_trailing("... and #{remaining} more", @box_width - 2)}│"
        else
          ""
        end

      "#{header}\n#{content}#{more}\n#{footer}"
    end
  end

  defp format_footer_terminal do
    """

    Run with :markdown format for detailed suggestions with example code.
    """
  end

  # ============================================================================
  # Markdown Format
  # ============================================================================

  defp format_header_markdown do
    "# Property & Invariant Suggestions\n"
  end

  defp format_summary_markdown(analysis) do
    high = Enum.count(analysis.suggestions, &(&1.priority == :high))
    medium = Enum.count(analysis.suggestions, &(&1.priority == :medium))
    low = Enum.count(analysis.suggestions, &(&1.priority == :low))
    coverage = analysis.field_coverage.coverage_percentage

    """
    ## Summary

    | Metric | Value |
    |--------|-------|
    | Model | `#{inspect(analysis.model)}` |
    | Events Analyzed | #{analysis.events_analyzed} |
    | Existing Checks | #{length(analysis.existing_checks)} |
    | Field Coverage | #{coverage}% |
    | Total Suggestions | #{length(analysis.suggestions)} |
    | High Priority | #{high} |
    | Medium Priority | #{medium} |
    | Low Priority | #{low} |
    """
  end

  defp format_suggestions_markdown(analysis) do
    if analysis.suggestions == [] do
      """
      ## Suggestions

      No suggestions - your model has good check coverage!
      """
    else
      by_priority = Enum.group_by(analysis.suggestions, & &1.priority)

      sections =
        [:high, :medium, :low]
        |> Enum.map(fn priority ->
          suggestions = Map.get(by_priority, priority, [])

          if suggestions != [] do
            format_priority_section_markdown(priority, suggestions)
          else
            nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      """
      ## Suggestions

      #{sections}
      """
    end
  end

  defp format_priority_section_markdown(priority, suggestions) do
    label =
      case priority do
        :high -> "High Priority"
        :medium -> "Medium Priority"
        :low -> "Low Priority"
      end

    emoji =
      case priority do
        :high -> "🔴"
        :medium -> "🟡"
        :low -> "🟢"
      end

    header = "### #{emoji} #{label}\n"

    rows =
      suggestions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, idx} ->
        field_badge = if s.field, do: " `#{s.field}`", else: ""
        event_badge = if s.event, do: " (#{s.event |> Module.split() |> List.last()})", else: ""

        example =
          if s.example_code do
            """

            <details>
            <summary>Example Code</summary>

            ```elixir
            #{String.trim(s.example_code)}
            ```
            </details>
            """
          else
            ""
          end

        """
        #### #{idx}. #{s.description}#{field_badge}#{event_badge}

        #{s.rationale}
        #{example}
        """
      end)

    "#{header}#{rows}"
  end

  defp format_field_coverage_markdown(analysis) do
    coverage = analysis.field_coverage

    if coverage.uncovered_fields == [] do
      nil
    else
      fields =
        coverage.uncovered_fields
        |> Enum.map_join(", ", &"`#{&1}`")

      """
      ## Unchecked Fields

      The following fields were detected but don't appear to be validated:

      #{fields}
      """
    end
  end

  # ============================================================================
  # Code Generation Helpers
  # ============================================================================

  defp generate_non_negative_code(field) do
    """
    @trigger every: 1
    def assert_#{field}_non_negative(state, _cmd_or_event) do
      violations =
        state.entities
        |> Enum.filter(fn {_id, entity} ->
          Map.get(entity, :#{field}, 0) < 0
        end)

      unless Enum.empty?(violations) do
        PropertyDamage.fail!("Negative #{field} detected", violations: violations)
      end
    end
    """
  end

  defp generate_currency_code do
    """
    @trigger every: 1
    def assert_currency_consistency(state, _cmd_or_event) do
      violations =
        state.operations
        |> Enum.filter(fn op ->
          entity = Map.get(state.entities, op.entity_ref)
          entity && entity.currency != op.currency
        end)

      unless Enum.empty?(violations) do
        PropertyDamage.fail!("Currency mismatch detected", violations: violations)
      end
    end
    """
  end

  defp generate_reference_code(field) do
    entity = field |> Atom.to_string() |> String.replace(~r/_ref|_id/, "")

    """
    @trigger every: 1
    def assert_#{field}_exists(state, _cmd_or_event) do
      refs_in_use = # collect all #{field} values from state
      known_refs = Map.keys(state.#{entity}s)
      missing = refs_in_use -- known_refs

      unless Enum.empty?(missing) do
        PropertyDamage.fail!("Invalid #{field} references", missing: missing)
      end
    end
    """
  end

  defp generate_status_code(field) do
    """
    @trigger every: 1
    def assert_valid_#{field}(state, _cmd_or_event) do
      valid_statuses = [:pending, :active, :completed, :cancelled]

      invalid =
        state.entities
        |> Enum.filter(fn {_id, e} ->
          Map.get(e, :#{field}) not in valid_statuses
        end)

      unless Enum.empty?(invalid) do
        PropertyDamage.fail!("Invalid #{field} values", invalid: invalid)
      end
    end
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp truncate(str, max_len) do
    if String.length(str) <= max_len do
      str
    else
      String.slice(str, 0, max_len - 3) <> "..."
    end
  end
end
