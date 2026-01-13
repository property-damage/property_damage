defmodule PropertyDamage.LoadTest.Report do
  @moduledoc """
  Generates load test reports in various formats.

  ## Supported Formats

  - `:terminal` - Colored terminal output with ASCII charts
  - `:markdown` - Markdown formatted report
  - `:json` - JSON format for programmatic processing

  ## Usage

      {:ok, report} = Runner.await(runner)
      formatted = Report.format(report, :terminal)
      IO.puts(formatted)

      # Or save to file
      Report.save(report, "load_test_report.md", :markdown)
  """

  @type report :: %{metrics: map(), config: map()}
  @type format :: :terminal | :markdown | :json

  @doc """
  Format a report for display.

  ## Parameters

  - `report` - Report from Runner.await/1
  - `format` - Output format (`:terminal`, `:markdown`, `:json`)

  ## Returns

  Formatted string.
  """
  @spec format(report(), format()) :: String.t()
  def format(report, :terminal) do
    format_terminal(report)
  end

  def format(report, :markdown) do
    format_markdown(report)
  end

  def format(report, :json) do
    Jason.encode!(report, pretty: true)
  end

  @doc """
  Save a report to a file.
  """
  @spec save(report(), Path.t(), format()) :: :ok | {:error, term()}
  def save(report, path, format \\ :markdown) do
    content = format(report, format)
    File.write(path, content)
  end

  @doc """
  Generate a summary string for quick display.
  """
  @spec summary(report()) :: String.t()
  def summary(report) do
    m = report.metrics

    """
    Load Test Summary: #{format_number(m.total_requests)} requests in #{format_duration(m.duration_ms)}
    Throughput: #{format_float(m.requests_per_second)} RPS
    Latency: p50=#{format_float(m.latency_p50)}ms, p95=#{format_float(m.latency_p95)}ms, p99=#{format_float(m.latency_p99)}ms
    Errors: #{m.total_errors} (#{format_float(m.error_rate)}%)
    #{format_assertion_summary_line(m)}
    """
  end

  # ============================================================================
  # Terminal Formatting
  # ============================================================================

  defp format_terminal(report) do
    m = report.metrics
    c = report.config

    [
      terminal_header(),
      terminal_config(c),
      terminal_throughput(m),
      terminal_latency(m),
      terminal_errors(m),
      terminal_assertions(m),
      terminal_commands(m),
      terminal_chart(m),
      terminal_footer()
    ]
    |> Enum.join("\n")
  end

  defp terminal_header do
    """
    ╔══════════════════════════════════════════════════════════════════════╗
    ║                     PROPERTY DAMAGE LOAD TEST REPORT                  ║
    ╚══════════════════════════════════════════════════════════════════════╝
    """
  end

  defp terminal_config(config) do
    model_name = config.model |> to_string() |> String.replace("Elixir.", "")
    adapter_name = config.adapter |> to_string() |> String.replace("Elixir.", "")

    """
    ┌─ Configuration ──────────────────────────────────────────────────────┐
    │ Model:       #{String.pad_trailing(model_name, 55)}│
    │ Adapter:     #{String.pad_trailing(adapter_name, 55)}│
    │ Users:       #{String.pad_trailing(to_string(config.concurrent_users), 55)}│
    │ Duration:    #{String.pad_trailing(format_duration(config.duration_ms), 55)}│
    └──────────────────────────────────────────────────────────────────────┘
    """
  end

  defp terminal_throughput(metrics) do
    """
    ┌─ Throughput ─────────────────────────────────────────────────────────┐
    │ Total Requests:    #{String.pad_trailing(format_number(metrics.total_requests), 48)}│
    │ Requests/Second:   #{String.pad_trailing(format_float(metrics.requests_per_second), 48)}│
    │ Active Sessions:   #{String.pad_trailing(to_string(metrics.active_sessions), 48)}│
    │ Completed:         #{String.pad_trailing(to_string(metrics.completed_sessions), 48)}│
    └──────────────────────────────────────────────────────────────────────┘
    """
  end

  defp terminal_latency(metrics) do
    """
    ┌─ Latency (ms) ───────────────────────────────────────────────────────┐
    │ Min:     #{String.pad_trailing(format_float(metrics.latency_min), 10)} │ p50:   #{String.pad_trailing(format_float(metrics.latency_p50), 10)} │ Mean:  #{String.pad_trailing(format_float(metrics.latency_mean), 10)}│
    │ Max:     #{String.pad_trailing(format_float(metrics.latency_max), 10)} │ p95:   #{String.pad_trailing(format_float(metrics.latency_p95), 10)} │ p99:   #{String.pad_trailing(format_float(metrics.latency_p99), 10)}│
    └──────────────────────────────────────────────────────────────────────┘
    """
  end

  defp terminal_errors(metrics) do
    error_details =
      if map_size(metrics.errors_by_type) > 0 do
        metrics.errors_by_type
        |> Enum.map(fn {type, count} -> "#{type}: #{count}" end)
        |> Enum.join(", ")
      else
        "none"
      end

    """
    ┌─ Errors ─────────────────────────────────────────────────────────────┐
    │ Total:       #{String.pad_trailing(to_string(metrics.total_errors), 55)}│
    │ Error Rate:  #{String.pad_trailing(format_float(metrics.error_rate) <> "%", 55)}│
    │ By Type:     #{String.pad_trailing(error_details, 55)}│
    └──────────────────────────────────────────────────────────────────────┘
    """
  end


  defp terminal_assertions(metrics) do
    failures = Map.get(metrics, :assertion_failures, 0)
    failures_by_exception = Map.get(metrics, :failures_by_exception, %{})

    if failures == 0 and map_size(failures_by_exception) == 0 do
      ""
    else
      failure_details =
        if map_size(failures_by_exception) > 0 do
          failures_by_exception
          |> Enum.sort_by(fn {_, count} -> -count end)
          |> Enum.take(5)
          |> Enum.map(fn {module, count} ->
            name = module |> to_string() |> String.replace("Elixir.", "")
            "#{name}: #{count}"
          end)
          |> Enum.join(", ")
        else
          "none"
        end

      failure_rate = Map.get(metrics, :assertion_failure_rate, 0.0)

      """
      ┌─ Assertions ─────────────────────────────────────────────────────────┐
      │ Total Failures:  #{String.pad_trailing(to_string(failures), 51)}│
      │ Failure Rate:    #{String.pad_trailing(format_float(failure_rate) <> "%", 51)}│
      │ By Exception:    #{String.pad_trailing(failure_details, 51)}│
      └──────────────────────────────────────────────────────────────────────┘
      """
    end
  end
  defp terminal_commands(metrics) do
    if map_size(metrics.by_command) == 0 do
      ""
    else
      header = """
      ┌─ Per-Command Breakdown ────────────────────────────────────────────┐
      │ Command                          Count     p50      p95    Errors  │
      │ ─────────────────────────────────────────────────────────────────  │
      """

      rows =
        metrics.by_command
        |> Enum.sort_by(fn {_, data} -> -data.count end)
        |> Enum.take(10)
        |> Enum.map(fn {module, data} ->
          name =
            module
            |> to_string()
            |> String.replace("Elixir.", "")
            |> String.split(".")
            |> List.last()
            |> String.slice(0, 30)
            |> String.pad_trailing(32)

          count = data.count |> to_string() |> String.pad_leading(8)
          p50 = format_float(data.latency_p50) |> String.pad_leading(8)
          p95 = format_float(data.latency_p95) |> String.pad_leading(8)
          errors = data.error_count |> to_string() |> String.pad_leading(8)

          "│ #{name}#{count}#{p50}#{p95}#{errors}  │"
        end)
        |> Enum.join("\n")

      footer = """
      └──────────────────────────────────────────────────────────────────────┘
      """

      header <> rows <> "\n" <> footer
    end
  end

  defp terminal_chart(metrics) do
    if length(metrics.history) < 2 do
      ""
    else
      """
      ┌─ Throughput Over Time ──────────────────────────────────────────────┐
      #{ascii_chart(metrics.history, :rps, 60, 8)}
      └──────────────────────────────────────────────────────────────────────┘
      """
    end
  end

  defp terminal_footer do
    """
    ════════════════════════════════════════════════════════════════════════
    Generated by PropertyDamage Load Test
    """
  end

  defp ascii_chart(history, field, width, height) do
    values = Enum.map(history, &Map.get(&1, field, 0))

    if Enum.empty?(values) or Enum.all?(values, &(&1 == 0)) do
      String.duplicate("│ " <> String.duplicate(" ", width) <> " │\n", height)
    else
      max_val = Enum.max(values)
      min_val = Enum.min(values)
      range = max(max_val - min_val, 1)

      # Sample values to fit width
      samples =
        if length(values) > width do
          step = length(values) / width
          Enum.map(0..(width - 1), fn i -> Enum.at(values, trunc(i * step)) end)
        else
          values
        end

      # Build chart rows
      rows =
        for row <- (height - 1)..0 do
          threshold = min_val + range * (row / (height - 1))

          chars =
            Enum.map(samples, fn val ->
              if val >= threshold, do: "█", else: " "
            end)
            |> Enum.join("")
            |> String.pad_trailing(width)

          "│ #{chars} │"
        end

      Enum.join(rows, "\n")
    end
  end

  # ============================================================================
  # Markdown Formatting
  # ============================================================================

  defp format_markdown(report) do
    m = report.metrics
    c = report.config

    model_name = c.model |> to_string() |> String.replace("Elixir.", "")
    adapter_name = c.adapter |> to_string() |> String.replace("Elixir.", "")

    """
    # PropertyDamage Load Test Report

    ## Configuration

    | Parameter | Value |
    |-----------|-------|
    | Model | `#{model_name}` |
    | Adapter | `#{adapter_name}` |
    | Concurrent Users | #{c.concurrent_users} |
    | Duration | #{format_duration(c.duration_ms)} |

    ## Summary

    - **Total Requests:** #{format_number(m.total_requests)}
    - **Throughput:** #{format_float(m.requests_per_second)} requests/second
    - **Error Rate:** #{format_float(m.error_rate)}%

    ## Latency Distribution

    | Metric | Value (ms) |
    |--------|------------|
    | Minimum | #{format_float(m.latency_min)} |
    | p50 (Median) | #{format_float(m.latency_p50)} |
    | p95 | #{format_float(m.latency_p95)} |
    | p99 | #{format_float(m.latency_p99)} |
    | Maximum | #{format_float(m.latency_max)} |
    | Mean | #{format_float(m.latency_mean)} |

    ## Errors

    - **Total Errors:** #{m.total_errors}
    #{format_errors_markdown(m.errors_by_type)}

    #{format_assertions_markdown(m)}

    ## Per-Command Breakdown

    | Command | Count | p50 (ms) | p95 (ms) | Errors |
    |---------|-------|----------|----------|--------|
    #{format_commands_markdown(m.by_command)}

    ---
    *Generated by PropertyDamage Load Test*
    """
  end

  defp format_errors_markdown(errors) when map_size(errors) == 0, do: "- No errors recorded"

  defp format_errors_markdown(errors) do
    errors
    |> Enum.map(fn {type, count} -> "- `#{type}`: #{count}" end)
    |> Enum.join("\n")
  end

  defp format_commands_markdown(commands) when map_size(commands) == 0,
    do: "| - | - | - | - | - |"

  defp format_commands_markdown(commands) do
    commands
    |> Enum.sort_by(fn {_, data} -> -data.count end)
    |> Enum.map(fn {module, data} ->
      name = module |> to_string() |> String.replace("Elixir.", "")

      "| `#{name}` | #{data.count} | #{format_float(data.latency_p50)} | #{format_float(data.latency_p95)} | #{data.error_count} |"
    end)
    |> Enum.join("\n")
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)

  defp format_float(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 2)
  defp format_float(n) when is_integer(n), do: to_string(n) <> ".00"
  defp format_float(n), do: to_string(n)

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp format_assertion_summary_line(metrics) do
    case Map.get(metrics, :assertion_failures, 0) do
      0 -> ""
      failures -> "Assertions: #{failures} failures (#{format_float(metrics.assertion_failure_rate)}%)"
    end
  end

  defp format_assertions_markdown(metrics) do
    failures = Map.get(metrics, :assertion_failures, 0)
    failures_by_exception = Map.get(metrics, :failures_by_exception, %{})

    if failures == 0 and map_size(failures_by_exception) == 0 do
      ""
    else
      failure_rate = Map.get(metrics, :assertion_failure_rate, 0.0)

      breakdown =
        if map_size(failures_by_exception) > 0 do
          failures_by_exception
          |> Enum.sort_by(fn {_, count} -> -count end)
          |> Enum.map(fn {module, count} ->
            name = module |> to_string() |> String.replace("Elixir.", "")
            "| `#{name}` | #{count} |"
          end)
          |> Enum.join("\n")
        else
          "| - | - |"
        end

      """
      ## Assertions

      - **Total Failures:** #{failures}
      - **Failure Rate:** #{format_float(failure_rate)}%

      | Exception | Failures |
      |-----------|----------|
      #{breakdown}
      """
    end
  end
end
