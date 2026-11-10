defmodule PropertyDamage.FailureReport.Formatter do
  @moduledoc false

  alias PropertyDamage.{FailureReport, Sequence}
  alias PropertyDamage.FailureReport.{Document, Layout, Render}

  @type format :: :terminal | :markdown | :json | :compact

  @doc """
  Format a failure report as `:terminal` text, `:markdown`, `:json` or a
  `:compact` one-line summary.

  The terminal and markdown formats print one layout (DR-055, DR-056): the
  banner and the seed, then the Failure, Minimal Reproduction, Projections and
  Reproduction sections, with every step and every event in full. The
  markdown format is the terminal text without color, each section's body in
  a fenced block. The JSON format is the one document of
  `PropertyDamage.FailureReport.Document`, which lists its keys.

  ## Options

  - `:color` - Use ANSI colors in the terminal format (default: true)
  - `:indent` - Indentation for JSON (default: 2)
  - `:sources` - `true` adds the source members to the JSON document
    (default: false)
  - `:log` - `[only: tags, except: tags]`, a tag filter for the log lines
    (`PropertyDamage.Log.Filter`) that replaces the report's own, for
    `:terminal`, `:markdown` and `:json`. The environment variable `PD_LOG`,
    when set and non-blank, replaces both. `:compact` ignores filters.
  """
  @spec format(FailureReport.t(), format(), keyword()) :: String.t()
  def format(report, format \\ :terminal, opts \\ [])

  def format(report, :terminal, opts),
    do: report |> Layout.build(opts) |> Render.terminal(Keyword.get(opts, :color, true))

  def format(report, :markdown, opts), do: report |> Layout.build(opts) |> Render.markdown()
  def format(report, :json, opts), do: format_json(report, opts)
  def format(report, :compact, _opts), do: format_compact(report)

  # ============================================================================
  # JSON Format
  # ============================================================================

  defp format_json(report, opts) do
    indent = Keyword.get(opts, :indent, 2)
    Jason.encode!(Document.build(report, opts), pretty: indent > 0)
  end

  # ============================================================================
  # Compact Format
  # ============================================================================

  defp format_compact(report) do
    type = FailureReport.kind_summary(report)
    cmd_count = Sequence.command_count(FailureReport.shrunk_sequence(report))

    origin_tag =
      case report.error_origin do
        :test_code_error -> "[TEST CODE ERROR]"
        :sut_error -> "[SUT BUG]"
        _ -> "[FAIL]"
      end

    "#{origin_tag} #{type} | run=#{FailureReport.run_number(report)} cmd=#{FailureReport.failure_index(report)} " <>
      "shrunk=#{cmd_count} seed=#{FailureReport.seed(report)}"
  end
end
