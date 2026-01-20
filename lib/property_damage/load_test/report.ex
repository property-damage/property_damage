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
    report
    |> make_json_encodable()
    |> Jason.encode!(pretty: true)
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
    Load Test Summary: #{format_number(m.total_requests)} commands in #{format_duration(m.duration_ms)}
    Throughput: #{format_float(m.requests_per_second)} cmd/sec
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
      terminal_pool_stats(report),
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
    arrival_rate_str = format_arrival_rate(config.arrival_rate)

    """
    ┌─ Configuration ──────────────────────────────────────────────────────┐
    │ Model:         #{String.pad_trailing(model_name, 53)}│
    │ Adapter:       #{String.pad_trailing(adapter_name, 53)}│
    │ Arrival Rate:  #{String.pad_trailing(arrival_rate_str, 53)}│
    │ Duration:      #{String.pad_trailing(format_duration(config.duration_ms), 53)}│
    └──────────────────────────────────────────────────────────────────────┘
    """
  end

  defp terminal_throughput(metrics) do
    arrivals_spawned = Map.get(metrics, :arrivals_spawned, 0)
    arrivals_completed = Map.get(metrics, :arrivals_completed, 0)
    arrivals_per_second = Map.get(metrics, :arrivals_per_second, 0.0)

    """
    ┌─ Throughput ─────────────────────────────────────────────────────────┐
    │ Total Commands:    #{String.pad_trailing(format_number(metrics.total_requests), 48)}│
    │ Commands/Second:   #{String.pad_trailing(format_float(metrics.requests_per_second), 48)}│
    │ Arrivals Spawned:  #{String.pad_trailing(format_number(arrivals_spawned), 48)}│
    │ Arrivals Completed: #{String.pad_trailing(format_number(arrivals_completed), 47)}│
    │ Arrivals/Second:   #{String.pad_trailing(format_float(arrivals_per_second), 48)}│
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
    ┌─ Execution Errors ───────────────────────────────────────────────────┐
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
      ┌─ Assertion Failures ─────────────────────────────────────────────────┐
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

  defp terminal_pool_stats(report) do
    case Map.get(report, :pool_stats) do
      nil ->
        ""

      stats ->
        peak_util = Map.get(stats, :peak_utilization, stats.utilization)
        avg_util = Map.get(stats, :avg_utilization, stats.utilization)
        total_created = Map.get(stats, :total_created, 0)
        peak_in_use = Map.get(stats, :peak_in_use, 0)

        """
        ┌─ Worker Pool ────────────────────────────────────────────────────────┐
        │ Workers Created: #{String.pad_trailing(to_string(total_created), 51)}│
        │ Peak Workers:    #{String.pad_trailing(to_string(peak_in_use), 51)}│
        │ Peak Utilization: #{String.pad_trailing(format_float(peak_util * 100) <> "%", 50)}│
        │ Avg Utilization: #{String.pad_trailing(format_float(avg_util * 100) <> "%", 51)}│
        │ Total Checkouts: #{String.pad_trailing(format_number(stats.total_checkouts), 51)}│
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
    arrival_rate_str = format_arrival_rate(c.arrival_rate)

    arrivals_spawned = Map.get(m, :arrivals_spawned, 0)
    arrivals_completed = Map.get(m, :arrivals_completed, 0)

    """
    # PropertyDamage Load Test Report

    ## Configuration

    | Parameter | Value |
    |-----------|-------|
    | Model | `#{model_name}` |
    | Adapter | `#{adapter_name}` |
    | Arrival Rate | #{arrival_rate_str} |
    | Duration | #{format_duration(c.duration_ms)} |

    ## Summary

    - **Total Commands:** #{format_number(m.total_requests)}
    - **Throughput:** #{format_float(m.requests_per_second)} commands/second
    - **Arrivals Spawned:** #{format_number(arrivals_spawned)}
    - **Arrivals Completed:** #{format_number(arrivals_completed)}
    - **Error Rate:** #{format_float(m.error_rate)}%

    #{format_pool_stats_markdown(report)}

    ## Latency Distribution

    | Metric | Value (ms) |
    |--------|------------|
    | Minimum | #{format_float(m.latency_min)} |
    | p50 (Median) | #{format_float(m.latency_p50)} |
    | p95 | #{format_float(m.latency_p95)} |
    | p99 | #{format_float(m.latency_p99)} |
    | Maximum | #{format_float(m.latency_max)} |
    | Mean | #{format_float(m.latency_mean)} |

    ## Execution Errors

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
      0 ->
        ""

      failures ->
        "Assertions: #{failures} failures (#{format_float(metrics.assertion_failure_rate)}%)"
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
      ## Assertion Failures

      - **Total Failures:** #{failures}
      - **Failure Rate:** #{format_float(failure_rate)}%

      | Exception | Failures |
      |-----------|----------|
      #{breakdown}
      """
    end
  end

  defp format_pool_stats_markdown(report) do
    case Map.get(report, :pool_stats) do
      nil ->
        ""

      stats ->
        peak_util = Map.get(stats, :peak_utilization, stats.utilization)
        avg_util = Map.get(stats, :avg_utilization, stats.utilization)
        total_created = Map.get(stats, :total_created, 0)
        peak_in_use = Map.get(stats, :peak_in_use, 0)

        """
        ## Worker Pool

        | Metric | Value |
        |--------|-------|
        | Workers Created | #{total_created} |
        | Peak Workers | #{peak_in_use} |
        | Peak Utilization | #{format_float(peak_util * 100)}% |
        | Avg Utilization | #{format_float(avg_util * 100)}% |
        | Total Checkouts | #{format_number(stats.total_checkouts)} |
        """
    end
  end

  defp format_arrival_rate({count, {time, unit}}) do
    "#{count} per #{time} #{unit}"
  end

  defp format_arrival_rate(rate) when is_integer(rate) do
    "#{rate}/sec"
  end

  defp format_arrival_rate(rate), do: inspect(rate)

  # ============================================================================
  # JSON Encoding Helpers
  # ============================================================================

  defp make_json_encodable(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {k, make_json_encodable(v)} end)
  end

  defp make_json_encodable(data) when is_list(data) do
    Enum.map(data, &make_json_encodable/1)
  end

  defp make_json_encodable({count, {time, unit}})
       when is_integer(count) and is_integer(time) and is_atom(unit) do
    [count, [time, Atom.to_string(unit)]]
  end

  defp make_json_encodable(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> make_json_encodable()
  end

  defp make_json_encodable(atom)
       when is_atom(atom) and not is_boolean(atom) and not is_nil(atom) do
    Atom.to_string(atom)
  end

  defp make_json_encodable(data), do: data
end
