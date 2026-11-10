defmodule PropertyDamage.LoadTest.Report do
  @moduledoc false

  @type report :: %{metrics: map(), pool_stats: map(), config: map()}
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
    #{format_check_summary_line(m)}
    #{format_phases_line(m)}
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
      terminal_checks(m),
      terminal_phases(m),
      terminal_commands(m),
      terminal_chart(m),
      terminal_footer()
    ]
    |> Enum.join("\n")
  end

  # Every terminal box line is this many characters wide, edges included.
  @box_width 72

  defp terminal_header do
    inner = @box_width - 2

    """
    ╔#{String.duplicate("═", inner)}╗
    ║#{center("PROPERTY DAMAGE LOAD TEST REPORT", inner)}║
    ╚#{String.duplicate("═", inner)}╝
    """
  end

  defp center(text, width) do
    left = div(width - String.length(text), 2)
    text |> String.pad_leading(left + String.length(text)) |> String.pad_trailing(width)
  end

  # A box with a title in its top edge and one row per line, each padded (or
  # cut) to the box width.
  defp box(title, rows) do
    inner = @box_width - 2
    top = "─ #{title} "

    lines =
      ["┌" <> String.pad_trailing(top, inner, "─") <> "┐"] ++
        Enum.map(rows, &box_row/1) ++
        ["└" <> String.duplicate("─", inner) <> "┘"]

    Enum.join(lines, "\n") <> "\n"
  end

  defp box_row(text) do
    content = @box_width - 4
    "│ " <> (text |> String.slice(0, content) |> String.pad_trailing(content)) <> " │"
  end

  defp terminal_config(config) do
    model_name = config.model |> to_string() |> String.replace("Elixir.", "")
    adapter_name = config.adapter |> to_string() |> String.replace("Elixir.", "")

    box("Configuration", [
      "Model:         #{model_name}",
      "Adapter:       #{adapter_name}",
      "Arrival Rate:  #{format_arrival_rate(config.arrival_rate)}",
      "Duration:      #{format_duration(config.duration_ms)}",
      "Seed:          #{format_seed(config)}"
    ])
  end

  defp format_seed(config), do: config |> Map.get(:seed, "unknown") |> to_string()

  defp terminal_throughput(metrics) do
    arrivals_spawned = Map.get(metrics, :arrivals_spawned, 0)
    arrivals_completed = Map.get(metrics, :arrivals_completed, 0)
    arrivals_per_second = Map.get(metrics, :arrivals_per_second, 0.0)

    box("Throughput", [
      "Total Commands:     #{format_number(metrics.total_requests)}",
      "Commands/Second:    #{format_float(metrics.requests_per_second)}",
      "Arrivals Spawned:   #{format_number(arrivals_spawned)}",
      "Arrivals Completed: #{format_number(arrivals_completed)}",
      "Arrivals/Second:    #{format_float(arrivals_per_second)}"
    ])
  end

  defp terminal_latency(metrics) do
    cell = &String.pad_trailing(format_float(&1), 10)

    box("Latency (ms)", [
      "Min:  #{cell.(metrics.latency_min)} │ p50:  #{cell.(metrics.latency_p50)} │ Mean: #{cell.(metrics.latency_mean)}",
      "Max:  #{cell.(metrics.latency_max)} │ p95:  #{cell.(metrics.latency_p95)} │ p99:  #{cell.(metrics.latency_p99)}"
    ])
  end

  defp terminal_errors(metrics) do
    error_details =
      if map_size(metrics.errors_by_type) > 0 do
        metrics.errors_by_type
        |> Enum.map_join(", ", fn {type, count} -> "#{type}: #{count}" end)
      else
        "none"
      end

    box("Execution Errors", [
      "Total:       #{metrics.total_errors}",
      "Error Rate:  #{format_float(metrics.error_rate)}%",
      "By Type:     #{error_details}"
    ])
  end

  defp terminal_checks(metrics) do
    failures = Map.get(metrics, :check_failures, 0)
    failures_by_exception = Map.get(metrics, :failures_by_exception, %{})

    if failures == 0 and map_size(failures_by_exception) == 0 do
      ""
    else
      failure_details =
        if map_size(failures_by_exception) > 0 do
          failures_by_exception
          |> Enum.sort_by(fn {_, count} -> -count end)
          |> Enum.take(5)
          |> Enum.map_join(", ", fn {module, count} ->
            name = module |> to_string() |> String.replace("Elixir.", "")
            "#{name}: #{count}"
          end)
        else
          "none"
        end

      failure_rate = Map.get(metrics, :check_failure_rate, 0.0)

      box("Check Failures", [
        "Total Failures:  #{failures}",
        "Failure Rate:    #{format_float(failure_rate)}%",
        "By Exception:    #{failure_details}"
      ])
    end
  end

  # Shown when the run executed any phase besides the roots.
  defp terminal_phases(metrics) do
    case phase_counts(metrics) do
      nil ->
        ""

      counts ->
        box("Phases", [
          "Setup Commands:    #{format_number(counts.setup_commands)}",
          "Teardown Commands: #{format_number(counts.teardown_commands)}",
          "Eventual Checks:   #{format_number(counts.eventual_checks)}",
          "Stutter Retries:   #{format_number(counts.stutter_retries)}"
        ])
    end
  end

  defp terminal_commands(metrics) do
    if map_size(metrics.by_command) == 0 do
      ""
    else
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

          "#{name}#{count}#{p50}#{p95}#{errors}"
        end)

      box(
        "Per-Command Breakdown",
        [
          "Command                          Count     p50      p95    Errors",
          String.duplicate("─", @box_width - 4)
        ] ++ rows
      )
    end
  end

  defp terminal_chart(metrics) do
    if length(metrics.history) < 2 do
      ""
    else
      box("Throughput Over Time", ascii_chart(metrics.history, :rps, 60, 8))
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

        box("Worker Pool", [
          "Workers Created:  #{total_created}",
          "Peak Workers:     #{peak_in_use}",
          "Peak Utilization: #{format_float(peak_util * 100)}%",
          "Avg Utilization:  #{format_float(avg_util * 100)}%",
          "Total Checkouts:  #{format_number(stats.total_checkouts)}"
        ])
    end
  end

  defp terminal_footer do
    """
    #{String.duplicate("═", @box_width)}
    Generated by PropertyDamage Load Test
    """
  end

  # The chart's rows, one string each, for `box/2` to frame.
  defp ascii_chart(history, field, width, height) do
    values = Enum.map(history, &Map.get(&1, field, 0))

    if Enum.empty?(values) or Enum.all?(values, &(&1 == 0)) do
      List.duplicate(String.duplicate(" ", width), height)
    else
      max_val = Enum.max(values)
      min_val = Enum.min(values)
      range = max(max_val - min_val, 1)

      # Sample values to fit width
      samples =
        if length(values) > width do
          step = length(values) / width
          Enum.map(0..(width - 1)//1, fn i -> Enum.at(values, trunc(i * step)) end)
        else
          values
        end

      for row <- (height - 1)..0//-1 do
        threshold = min_val + range * (row / (height - 1))

        samples
        |> Enum.map_join("", fn val -> if val >= threshold, do: "█", else: " " end)
        |> String.pad_trailing(width)
      end
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
    | Seed | #{format_seed(c)} |

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

    #{format_checks_markdown(m)}

    #{format_phases_markdown(m)}

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
    |> Enum.map_join("\n", fn {type, count} -> "- `#{type}`: #{count}" end)
  end

  defp format_commands_markdown(commands) when map_size(commands) == 0,
    do: "| - | - | - | - | - |"

  defp format_commands_markdown(commands) do
    commands
    |> Enum.sort_by(fn {_, data} -> -data.count end)
    |> Enum.map_join("\n", fn {module, data} ->
      name = module |> to_string() |> String.replace("Elixir.", "")

      "| `#{name}` | #{data.count} | #{format_float(data.latency_p50)} | #{format_float(data.latency_p95)} | #{data.error_count} |"
    end)
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
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)

  defp format_float(f) when is_float(f), do: :erlang.float_to_binary(f, decimals: 2)
  defp format_float(n) when is_integer(n), do: to_string(n) <> ".00"
  defp format_float(n), do: to_string(n)

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  defp format_check_summary_line(metrics) do
    case Map.get(metrics, :check_failures, 0) do
      0 ->
        ""

      failures ->
        "Checks: #{failures} failures (#{format_float(metrics.check_failure_rate)}%)"
    end
  end

  defp format_phases_line(metrics) do
    case phase_counts(metrics) do
      nil ->
        ""

      counts ->
        "Phases: #{counts.setup_commands} setup commands, " <>
          "#{counts.teardown_commands} teardown commands, " <>
          "#{counts.eventual_checks} eventual checks, " <>
          "#{counts.stutter_retries} stutter retries"
    end
  end

  defp format_phases_markdown(metrics) do
    case phase_counts(metrics) do
      nil ->
        ""

      counts ->
        """
        ## Phases

        - **Setup Commands:** #{counts.setup_commands}
        - **Teardown Commands:** #{counts.teardown_commands}
        - **Eventual Checks:** #{counts.eventual_checks}
        - **Stutter Retries:** #{counts.stutter_retries}
        """
    end
  end

  # The run's phase counts, or nil when it ran no phase besides the roots (or
  # the report predates the counts).
  defp phase_counts(metrics) do
    counts = Map.get(metrics, :phase_counts)

    if is_map(counts) and Enum.any?(Map.values(counts), &(&1 > 0)), do: counts
  end

  defp format_checks_markdown(metrics) do
    failures = Map.get(metrics, :check_failures, 0)
    failures_by_exception = Map.get(metrics, :failures_by_exception, %{})

    if failures == 0 and map_size(failures_by_exception) == 0 do
      ""
    else
      failure_rate = Map.get(metrics, :check_failure_rate, 0.0)

      breakdown =
        if map_size(failures_by_exception) > 0 do
          failures_by_exception
          |> Enum.sort_by(fn {_, count} -> -count end)
          |> Enum.map_join("\n", fn {module, count} ->
            name = module |> to_string() |> String.replace("Elixir.", "")
            "| `#{name}` | #{count} |"
          end)
        else
          "| - | - |"
        end

      """
      ## Check Failures

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
