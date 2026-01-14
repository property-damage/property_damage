defmodule PropertyDamage.Mutation.Formatter do
  @moduledoc """
  Formats mutation testing reports for various outputs.

  Supports:
  - `:terminal` - ASCII boxes for console output
  - `:markdown` - Markdown tables for documentation
  - `:json` - JSON for programmatic analysis
  """

  alias PropertyDamage.Mutation.Report

  @bar_width 20

  @doc """
  Formats a mutation report for the specified output format.
  """
  @spec format(Report.t(), atom()) :: String.t()
  def format(report, format \\ :terminal)

  def format(report, :terminal) do
    [
      format_header_terminal(report),
      format_summary_terminal(report),
      format_by_command_terminal(report),
      format_by_operator_terminal(report),
      format_survived_terminal(report),
      format_footer_terminal(report)
    ]
    |> Enum.join("\n")
  end

  def format(report, :markdown) do
    [
      format_header_markdown(report),
      format_summary_markdown(report),
      format_by_command_markdown(report),
      format_by_operator_markdown(report),
      format_survived_markdown(report),
      format_footer_markdown(report)
    ]
    |> Enum.join("\n")
  end

  def format(report, :json) do
    %{
      mutation_score: report.mutation_score,
      killed: report.killed,
      survived: report.survived,
      timeout: report.timeout,
      total: report.total,
      passes_target: Report.passes?(report),
      target_score: report.target_score,
      by_command:
        Enum.into(report.by_command, %{}, fn {cmd, stats} ->
          {inspect(cmd), stats}
        end),
      by_operator: report.by_operator,
      survived_mutations:
        Enum.map(report.survived_mutations, fn m ->
          %{
            command: inspect(m.command),
            operator: m.operator,
            mutation: format_mutation_json(m.mutation),
            duration_ms: Map.get(m, :duration_ms, 0)
          }
        end),
      duration_ms: report.duration_ms
    }
    |> Jason.encode!(pretty: true)
  end

  # ============================================================================
  # Terminal Format
  # ============================================================================

  defp format_header_terminal(_report) do
    """
    ╔══════════════════════════════════════════════════════════════════════╗
    ║                       MUTATION TESTING REPORT                        ║
    ╚══════════════════════════════════════════════════════════════════════╝
    """
  end

  defp format_summary_terminal(report) do
    score_pct = Float.round(report.mutation_score * 100, 1)
    target_pct = Float.round(report.target_score * 100, 0)
    status = if Report.passes?(report), do: "✓ PASS", else: "✗ FAIL"

    """
    Mutation Score: #{score_pct}% (#{report.killed}/#{report.total} killed)  #{status} (target: #{target_pct}%)
    """
  end

  defp format_by_command_terminal(report) do
    if map_size(report.by_command) == 0 do
      ""
    else
      header = "┌─ By Command ────────────────────────────────────────────────────────┐"
      footer = "└─────────────────────────────────────────────────────────────────────┘"

      rows =
        report.by_command
        |> Enum.sort_by(fn {_cmd, stats} -> -stats.score end)
        |> Enum.map(fn {cmd, stats} ->
          cmd_name = format_command_name(cmd)
          bar = progress_bar(stats.score)
          pct = Float.round(stats.score * 100, 0)

          "│ #{String.pad_trailing(cmd_name, 16)} #{bar} #{String.pad_leading("#{pct}%", 4)} (#{stats.killed}/#{stats.total}) │"
        end)
        |> Enum.join("\n")

      "\n#{header}\n#{rows}\n#{footer}"
    end
  end

  defp format_by_operator_terminal(report) do
    if map_size(report.by_operator) == 0 do
      ""
    else
      header = "┌─ By Operator ───────────────────────────────────────────────────────┐"
      footer = "└─────────────────────────────────────────────────────────────────────┘"

      rows =
        report.by_operator
        |> Enum.sort_by(fn {_op, stats} -> -stats.score end)
        |> Enum.map(fn {op, stats} ->
          op_name = ":#{op}"
          bar = progress_bar(stats.score)
          pct = Float.round(stats.score * 100, 0)

          "│ #{String.pad_trailing(op_name, 16)} #{bar} #{String.pad_leading("#{pct}%", 4)} (#{stats.killed}/#{stats.total}) │"
        end)
        |> Enum.join("\n")

      "\n#{header}\n#{rows}\n#{footer}"
    end
  end

  defp format_survived_terminal(report) do
    if length(report.survived_mutations) == 0 do
      "\n┌─ All Mutations Killed ──────────────────────────────────────────────┐\n│ Great! All mutations were detected by your tests.                    │\n└─────────────────────────────────────────────────────────────────────┘"
    else
      header = "┌─ Survived Mutations (Weaknesses) ──────────────────────────────────┐"
      footer = "└─────────────────────────────────────────────────────────────────────┘"

      rows =
        report.survived_mutations
        |> Enum.take(10)
        |> Enum.with_index(1)
        |> Enum.map(fn {result, idx} ->
          cmd_name = format_command_name(result.command)
          mutation_desc = format_mutation_short(result.mutation)
          "│ #{idx}. #{cmd_name}: #{String.pad_trailing(mutation_desc, 50)} │"
        end)
        |> Enum.join("\n")

      more =
        if length(report.survived_mutations) > 10 do
          "\n│ ... and #{length(report.survived_mutations) - 10} more                                              │"
        else
          ""
        end

      "\n#{header}\n#{rows}#{more}\n#{footer}"
    end
  end

  defp format_footer_terminal(report) do
    duration_sec = Float.round(report.duration_ms / 1000, 1)
    "\nDuration: #{duration_sec}s"
  end

  # ============================================================================
  # Markdown Format
  # ============================================================================

  defp format_header_markdown(_report) do
    "# Mutation Testing Report\n"
  end

  defp format_summary_markdown(report) do
    score_pct = Float.round(report.mutation_score * 100, 1)
    target_pct = Float.round(report.target_score * 100, 0)
    status = if Report.passes?(report), do: "PASS", else: "FAIL"

    """
    ## Summary

    | Metric | Value |
    |--------|-------|
    | Mutation Score | #{score_pct}% |
    | Killed | #{report.killed} |
    | Survived | #{report.survived} |
    | Total | #{report.total} |
    | Status | **#{status}** (target: #{target_pct}%) |
    """
  end

  defp format_by_command_markdown(report) do
    if map_size(report.by_command) == 0 do
      ""
    else
      header = """
      ## By Command

      | Command | Score | Killed | Survived | Total |
      |---------|-------|--------|----------|-------|
      """

      rows =
        report.by_command
        |> Enum.sort_by(fn {_cmd, stats} -> -stats.score end)
        |> Enum.map(fn {cmd, stats} ->
          cmd_name = format_command_name(cmd)
          pct = Float.round(stats.score * 100, 1)
          "| #{cmd_name} | #{pct}% | #{stats.killed} | #{stats.survived} | #{stats.total} |"
        end)
        |> Enum.join("\n")

      header <> rows <> "\n"
    end
  end

  defp format_by_operator_markdown(report) do
    if map_size(report.by_operator) == 0 do
      ""
    else
      header = """
      ## By Operator

      | Operator | Score | Killed | Survived | Total |
      |----------|-------|--------|----------|-------|
      """

      rows =
        report.by_operator
        |> Enum.sort_by(fn {_op, stats} -> -stats.score end)
        |> Enum.map(fn {op, stats} ->
          pct = Float.round(stats.score * 100, 1)
          "| `:#{op}` | #{pct}% | #{stats.killed} | #{stats.survived} | #{stats.total} |"
        end)
        |> Enum.join("\n")

      header <> rows <> "\n"
    end
  end

  defp format_survived_markdown(report) do
    if length(report.survived_mutations) == 0 do
      "\n## Survived Mutations\n\nAll mutations were killed! Your tests are effective.\n"
    else
      header = """
      ## Survived Mutations (Weaknesses)

      | # | Command | Operator | Mutation |
      |---|---------|----------|----------|
      """

      rows =
        report.survived_mutations
        |> Enum.with_index(1)
        |> Enum.map(fn {result, idx} ->
          cmd_name = format_command_name(result.command)
          mutation_desc = format_mutation_short(result.mutation)
          "| #{idx} | #{cmd_name} | `:#{result.operator}` | #{mutation_desc} |"
        end)
        |> Enum.join("\n")

      header <> rows <> "\n"
    end
  end

  defp format_footer_markdown(report) do
    duration_sec = Float.round(report.duration_ms / 1000, 1)
    "\n---\n\n*Duration: #{duration_sec}s*\n"
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp format_command_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
  end

  defp format_mutation_short(mutation) do
    case mutation do
      %{target: target, original: original, mutated: mutated} when is_atom(target) ->
        "#{target}: #{inspect(original)} → #{inspect(mutated)}"

      %{type: type, description: desc} when is_binary(desc) ->
        "#{type}: #{desc}"

      %{type: type} ->
        to_string(type)

      _ ->
        inspect(mutation, limit: 3)
    end
  end

  defp format_mutation_json(mutation) do
    mutation
    |> Map.take([:type, :target, :original, :mutated, :description])
    |> Enum.into(%{}, fn {k, v} -> {k, inspect_safe(v)} end)
  end

  defp inspect_safe(value) when is_atom(value), do: to_string(value)
  defp inspect_safe(value) when is_binary(value), do: value
  defp inspect_safe(value) when is_number(value), do: value
  defp inspect_safe(value), do: inspect(value)

  defp progress_bar(score) when is_float(score) do
    filled = round(score * @bar_width)
    empty = @bar_width - filled

    filled_str = String.duplicate("█", filled)
    empty_str = String.duplicate("░", empty)

    filled_str <> empty_str
  end
end
