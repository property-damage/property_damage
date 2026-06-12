defmodule PropertyDamage.Mutation.Analysis do
  @moduledoc """
  Analyzes mutation testing results to identify weaknesses and generate suggestions.

  Provides insights into:
  - Which checks are weak (never caught mutations)
  - Which fields aren't being validated
  - Actionable suggestions for improvement
  """

  alias PropertyDamage.Mutation.Report

  @type analysis :: %{
          weak_commands: [{module(), float()}],
          weak_operators: [{atom(), float()}],
          unchecked_fields: [atom()],
          suggestions: [String.t()],
          summary: String.t()
        }

  @doc """
  Analyzes a mutation report and returns insights.
  """
  @spec analyze(Report.t()) :: analysis()
  def analyze(report) do
    %{
      weak_commands: find_weak_commands(report),
      weak_operators: find_weak_operators(report),
      unchecked_fields: find_unchecked_fields(report),
      suggestions: generate_suggestions(report),
      summary: generate_summary(report)
    }
  end

  @doc """
  Formats an analysis for display.
  """
  @spec format(analysis(), atom()) :: String.t()
  def format(analysis, format \\ :terminal)

  def format(analysis, :terminal) do
    [
      format_summary_terminal(analysis),
      format_weak_commands_terminal(analysis),
      format_weak_operators_terminal(analysis),
      format_unchecked_fields_terminal(analysis),
      format_suggestions_terminal(analysis)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def format(analysis, :markdown) do
    [
      "# Mutation Testing Analysis\n",
      format_summary_markdown(analysis),
      format_weak_commands_markdown(analysis),
      format_unchecked_fields_markdown(analysis),
      format_suggestions_markdown(analysis)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # ============================================================================
  # Analysis Functions
  # ============================================================================

  defp find_weak_commands(report) do
    report.by_command
    |> Enum.filter(fn {_cmd, stats} -> stats.score < 0.8 end)
    |> Enum.sort_by(fn {_cmd, stats} -> stats.score end, :asc)
    |> Enum.map(fn {cmd, stats} -> {cmd, stats.score} end)
  end

  defp find_weak_operators(report) do
    report.by_operator
    |> Enum.filter(fn {_op, stats} -> stats.score < 0.8 end)
    |> Enum.sort_by(fn {_op, stats} -> stats.score end, :asc)
    |> Enum.map(fn {op, stats} -> {op, stats.score} end)
  end

  defp find_unchecked_fields(report) do
    # Find fields that were mutated but never caused failures
    report.survived_mutations
    # Enum.member? instead of `in`: the `in` expansion here trips an
    # "unsafe variable" error in Erlang's cover compiler (mix test --cover)
    |> Enum.filter(fn result ->
      Enum.member?([:value, :omission, :boundary], result.operator)
    end)
    |> Enum.map(fn result ->
      case result.mutation do
        %{target: target} when is_atom(target) -> target
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp generate_suggestions(report) do
    suggestions = []

    # Suggestion for low overall score
    suggestions =
      if report.mutation_score < 0.5 do
        suggestions ++
          [
            "Your mutation score is below 50%. Consider adding more comprehensive checks for your invariants."
          ]
      else
        suggestions
      end

    # Suggestions based on survived mutations
    suggestions = suggestions ++ analyze_survived_mutations(report.survived_mutations)

    # Suggestions based on weak operators
    suggestions = suggestions ++ analyze_weak_operators(report)

    Enum.uniq(suggestions)
  end

  defp analyze_survived_mutations(survived) do
    suggestions = []

    # Check for value mutations that survived
    value_survivors =
      Enum.filter(survived, fn r -> r.operator == :value end)

    suggestions =
      if length(value_survivors) > 0 do
        fields =
          value_survivors
          |> Enum.map(fn r -> r.mutation[:target] end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.take(3)

        if length(fields) > 0 do
          suggestions ++
            ["Add checks that verify exact values for: #{Enum.join(fields, ", ")}"]
        else
          suggestions
        end
      else
        suggestions
      end

    # Check for omission mutations that survived
    omission_survivors =
      Enum.filter(survived, fn r -> r.operator == :omission end)

    suggestions =
      if length(omission_survivors) > 0 do
        fields =
          omission_survivors
          |> Enum.map(fn r -> r.mutation[:target] end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.take(3)

        if length(fields) > 0 do
          suggestions ++
            ["Add presence validation for fields: #{Enum.join(fields, ", ")}"]
        else
          suggestions
        end
      else
        suggestions
      end

    # Check for boundary mutations that survived
    boundary_survivors =
      Enum.filter(survived, fn r -> r.operator == :boundary end)

    suggestions =
      if length(boundary_survivors) > 0 do
        suggestions ++
          ["Add boundary checks for numeric fields (zero, negative, max values)"]
      else
        suggestions
      end

    suggestions
  end

  defp analyze_weak_operators(report) do
    suggestions = []

    weak_ops =
      report.by_operator
      |> Enum.filter(fn {_op, stats} -> stats.score < 0.5 end)
      |> Enum.map(fn {op, _stats} -> op end)

    suggestions =
      if :status in weak_ops do
        suggestions ++
          ["Your checks may not properly handle error cases. Add validation for error responses."]
      else
        suggestions
      end

    suggestions =
      if :event in weak_ops do
        suggestions ++
          [
            "Event structure mutations often survive. Consider validating event relationships and IDs."
          ]
      else
        suggestions
      end

    suggestions
  end

  defp generate_summary(report) do
    cond do
      report.mutation_score >= 0.9 ->
        "Excellent! Your tests are highly effective at catching mutations."

      report.mutation_score >= 0.8 ->
        "Good mutation coverage. Your tests catch most simulated bugs."

      report.mutation_score >= 0.6 ->
        "Moderate coverage. Consider strengthening checks for better bug detection."

      report.mutation_score >= 0.4 ->
        "Low coverage. Many mutations survive - your tests may miss real bugs."

      true ->
        "Very low coverage. Your tests are not catching most simulated bugs."
    end
  end

  # ============================================================================
  # Terminal Formatting
  # ============================================================================

  defp format_summary_terminal(analysis) do
    """
    ╔══════════════════════════════════════════════════════════════════════╗
    ║                       MUTATION ANALYSIS                              ║
    ╚══════════════════════════════════════════════════════════════════════╝

    #{analysis.summary}
    """
  end

  defp format_weak_commands_terminal(analysis) do
    if length(analysis.weak_commands) == 0 do
      nil
    else
      header = "┌─ Weak Commands (< 80% kill rate) ──────────────────────────────────┐"
      footer = "└─────────────────────────────────────────────────────────────────────┘"

      rows =
        analysis.weak_commands
        |> Enum.map(fn {cmd, score} ->
          cmd_name = format_module_name(cmd)
          pct = Float.round(score * 100, 1)
          "│ #{String.pad_trailing(cmd_name, 40)} #{String.pad_leading("#{pct}%", 6)} │"
        end)
        |> Enum.join("\n")

      "\n#{header}\n#{rows}\n#{footer}"
    end
  end

  defp format_weak_operators_terminal(analysis) do
    if length(analysis.weak_operators) == 0 do
      nil
    else
      header = "┌─ Weak Operators (< 80% kill rate) ─────────────────────────────────┐"
      footer = "└─────────────────────────────────────────────────────────────────────┘"

      rows =
        analysis.weak_operators
        |> Enum.map(fn {op, score} ->
          pct = Float.round(score * 100, 1)
          "│ :#{String.pad_trailing(to_string(op), 39)} #{String.pad_leading("#{pct}%", 6)} │"
        end)
        |> Enum.join("\n")

      "\n#{header}\n#{rows}\n#{footer}"
    end
  end

  defp format_unchecked_fields_terminal(analysis) do
    if length(analysis.unchecked_fields) == 0 do
      nil
    else
      header = "┌─ Unchecked Fields ──────────────────────────────────────────────────┐"
      footer = "└─────────────────────────────────────────────────────────────────────┘"

      fields = Enum.join(analysis.unchecked_fields, ", ")
      "│ #{String.pad_trailing(fields, 68)} │"

      "\n#{header}\n│ #{String.pad_trailing(fields, 68)} │\n#{footer}"
    end
  end

  defp format_suggestions_terminal(analysis) do
    if length(analysis.suggestions) == 0 do
      nil
    else
      header = "┌─ Suggestions ───────────────────────────────────────────────────────┐"
      footer = "└─────────────────────────────────────────────────────────────────────┘"

      rows =
        analysis.suggestions
        |> Enum.with_index(1)
        |> Enum.map(fn {suggestion, idx} ->
          # Wrap long suggestions
          wrapped = wrap_text(suggestion, 64)

          wrapped
          |> Enum.with_index()
          |> Enum.map(fn {line, line_idx} ->
            prefix = if line_idx == 0, do: "#{idx}. ", else: "   "
            "│ #{String.pad_trailing(prefix <> line, 68)} │"
          end)
          |> Enum.join("\n")
        end)
        |> Enum.join("\n")

      "\n#{header}\n#{rows}\n#{footer}"
    end
  end

  # ============================================================================
  # Markdown Formatting
  # ============================================================================

  defp format_summary_markdown(analysis) do
    "## Summary\n\n#{analysis.summary}\n"
  end

  defp format_weak_commands_markdown(analysis) do
    if length(analysis.weak_commands) == 0 do
      nil
    else
      header = """
      ## Weak Commands

      | Command | Kill Rate |
      |---------|-----------|
      """

      rows =
        analysis.weak_commands
        |> Enum.map(fn {cmd, score} ->
          cmd_name = format_module_name(cmd)
          pct = Float.round(score * 100, 1)
          "| #{cmd_name} | #{pct}% |"
        end)
        |> Enum.join("\n")

      header <> rows <> "\n"
    end
  end

  defp format_unchecked_fields_markdown(analysis) do
    if length(analysis.unchecked_fields) == 0 do
      nil
    else
      fields =
        analysis.unchecked_fields
        |> Enum.map(&"`#{&1}`")
        |> Enum.join(", ")

      "## Unchecked Fields\n\n#{fields}\n"
    end
  end

  defp format_suggestions_markdown(analysis) do
    if length(analysis.suggestions) == 0 do
      nil
    else
      suggestions =
        analysis.suggestions
        |> Enum.map(&"- #{&1}")
        |> Enum.join("\n")

      "## Suggestions\n\n#{suggestions}\n"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp format_module_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
  end

  defp wrap_text(text, width) do
    text
    |> String.split(" ")
    |> Enum.reduce({[], ""}, fn word, {lines, current} ->
      if String.length(current) + String.length(word) + 1 <= width do
        new_current =
          if current == "" do
            word
          else
            current <> " " <> word
          end

        {lines, new_current}
      else
        {lines ++ [current], word}
      end
    end)
    |> then(fn {lines, current} ->
      if current == "", do: lines, else: lines ++ [current]
    end)
  end
end
