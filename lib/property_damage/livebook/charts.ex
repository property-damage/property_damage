defmodule PropertyDamage.Livebook.Charts do
  @moduledoc """
  Chart visualizations for PropertyDamage results using VegaLite.

  Provides rich data visualizations for test results, command statistics,
  timing distributions, and more.

  ## Requirements

  Add VegaLite to your dependencies:

      {:vega_lite, "~> 0.1"}
      {:kino_vega_lite, "~> 0.1"}

  ## Usage

      alias PropertyDamage.Livebook.Charts

      # Command execution bar chart
      Charts.command_bar_chart(result)

      # Timing distribution
      Charts.timing_histogram(result)

      # Success rate pie chart
      Charts.success_pie_chart(result)
  """

  # Suppress warnings for optional VegaLite/Kino dependencies (guarded at runtime)
  @compile {:no_warn_undefined, [VegaLite, Kino, Kino.Markdown]}

  @doc """
  Check if VegaLite is available.
  """
  def vega_lite_available? do
    Code.ensure_loaded?(VegaLite)
  end

  @doc """
  Create a bar chart showing command execution counts.
  """
  @spec command_bar_chart(PropertyDamage.result()) :: struct()
  def command_bar_chart(result) do
    if vega_lite_available?() do
      data = build_command_count_data(result)
      do_command_bar_chart(data)
    else
      fallback_command_chart(result)
    end
  end

  @doc """
  Create a histogram of command execution times.
  """
  @spec timing_histogram(PropertyDamage.result()) :: struct()
  def timing_histogram(result) do
    if vega_lite_available?() do
      data = build_timing_data(result)
      do_timing_histogram(data)
    else
      fallback_timing_chart(result)
    end
  end

  @doc """
  Create a pie chart showing success vs failure rates.
  """
  @spec success_pie_chart(PropertyDamage.result()) :: struct()
  def success_pie_chart(result) do
    if vega_lite_available?() do
      data = build_success_data(result)
      do_success_pie_chart(data)
    else
      fallback_success_chart(result)
    end
  end

  @doc """
  Create a timeline chart showing command execution over time.
  """
  @spec execution_timeline(PropertyDamage.result()) :: struct()
  def execution_timeline(result) do
    if vega_lite_available?() do
      data = build_timeline_data(result)
      do_execution_timeline(data)
    else
      fallback_timeline_chart(result)
    end
  end

  @doc """
  Create a heatmap showing command transitions.
  """
  @spec command_transition_heatmap(PropertyDamage.result()) :: struct()
  def command_transition_heatmap(result) do
    if vega_lite_available?() do
      data = build_transition_data(result)
      do_transition_heatmap(data)
    else
      fallback_transition_chart(result)
    end
  end

  @doc """
  Create a stacked bar chart for check results.
  """
  @spec check_results_chart(PropertyDamage.result()) :: struct()
  def check_results_chart(result) do
    if vega_lite_available?() do
      data = build_check_data(result)
      do_check_results_chart(data)
    else
      fallback_check_chart(result)
    end
  end

  # ============================================================================
  # VegaLite Chart Implementations
  # ============================================================================

  defp do_command_bar_chart(data) do
    alias VegaLite, as: Vl

    Vl.new(width: 500, height: 300, title: "Command Execution Counts")
    |> Vl.data_from_values(data)
    |> Vl.mark(:bar)
    |> Vl.encode_field(:x, "command", type: :nominal, sort: "-y", title: "Command")
    |> Vl.encode_field(:y, "count", type: :quantitative, title: "Executions")
    |> Vl.encode_field(:color, "status",
      type: :nominal,
      scale: %{domain: ["success", "failed"], range: ["#22c55e", "#ef4444"]}
    )
  end

  defp do_timing_histogram(data) do
    alias VegaLite, as: Vl

    Vl.new(width: 500, height: 300, title: "Command Timing Distribution")
    |> Vl.data_from_values(data)
    |> Vl.mark(:bar)
    |> Vl.encode_field(:x, "duration_ms",
      type: :quantitative,
      bin: %{maxbins: 20},
      title: "Duration (ms)"
    )
    |> Vl.encode(:y, aggregate: :count, title: "Count")
    |> Vl.encode_field(:color, "command", type: :nominal)
  end

  defp do_success_pie_chart(data) do
    alias VegaLite, as: Vl

    Vl.new(width: 300, height: 300, title: "Success Rate")
    |> Vl.data_from_values(data)
    |> Vl.mark(:arc, inner_radius: 50)
    |> Vl.encode_field(:theta, "count", type: :quantitative)
    |> Vl.encode_field(:color, "status",
      type: :nominal,
      scale: %{domain: ["Passed", "Failed"], range: ["#22c55e", "#ef4444"]}
    )
  end

  defp do_execution_timeline(data) do
    alias VegaLite, as: Vl

    Vl.new(width: 600, height: 200, title: "Execution Timeline")
    |> Vl.data_from_values(data)
    |> Vl.mark(:circle, size: 100)
    |> Vl.encode_field(:x, "step", type: :quantitative, title: "Step")
    |> Vl.encode_field(:y, "command", type: :nominal, title: "Command")
    |> Vl.encode_field(:color, "status",
      type: :nominal,
      scale: %{domain: ["success", "failed"], range: ["#22c55e", "#ef4444"]}
    )
    |> Vl.encode_field(:size, "duration_ms", type: :quantitative)
  end

  defp do_transition_heatmap(data) do
    alias VegaLite, as: Vl

    Vl.new(width: 400, height: 400, title: "Command Transitions")
    |> Vl.data_from_values(data)
    |> Vl.mark(:rect)
    |> Vl.encode_field(:x, "from", type: :nominal, title: "From")
    |> Vl.encode_field(:y, "to", type: :nominal, title: "To")
    |> Vl.encode_field(:color, "count",
      type: :quantitative,
      scale: %{scheme: "blues"}
    )
  end

  defp do_check_results_chart(data) do
    alias VegaLite, as: Vl

    Vl.new(width: 500, height: 300, title: "Check Results by Type")
    |> Vl.data_from_values(data)
    |> Vl.mark(:bar)
    |> Vl.encode_field(:x, "check", type: :nominal, title: "Check")
    |> Vl.encode_field(:y, "count", type: :quantitative, title: "Count")
    |> Vl.encode_field(:color, "result",
      type: :nominal,
      scale: %{domain: ["passed", "failed"], range: ["#22c55e", "#ef4444"]}
    )
  end

  # ============================================================================
  # Data Building Functions
  # ============================================================================

  defp build_command_count_data(result) do
    history = result.history || []

    history
    |> Enum.group_by(& &1.command)
    |> Enum.flat_map(fn {cmd, entries} ->
      success_count =
        Enum.count(entries, fn e ->
          match?({:ok, _}, e[:result]) or e[:success] == true
        end)

      failed_count = length(entries) - success_count

      [
        %{command: format_command(cmd), count: success_count, status: "success"},
        %{command: format_command(cmd), count: failed_count, status: "failed"}
      ]
    end)
  end

  defp build_timing_data(result) do
    history = result.history || []

    history
    |> Enum.filter(fn entry -> Map.has_key?(entry, :duration_us) end)
    |> Enum.map(fn entry ->
      %{
        command: format_command(entry.command),
        duration_ms: (entry.duration_us || 0) / 1000
      }
    end)
  end

  defp build_success_data(result) do
    history = result.history || []

    success_count =
      Enum.count(history, fn e ->
        match?({:ok, _}, e[:result]) or e[:success] == true
      end)

    failed_count = length(history) - success_count

    [
      %{status: "Passed", count: success_count},
      %{status: "Failed", count: failed_count}
    ]
  end

  defp build_timeline_data(result) do
    history = result.history || []

    history
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, idx} ->
      status =
        if match?({:ok, _}, entry[:result]) or entry[:success] == true,
          do: "success",
          else: "failed"

      %{
        step: idx,
        command: format_command(entry.command),
        status: status,
        duration_ms: (Map.get(entry, :duration_us, 0) || 0) / 1000
      }
    end)
  end

  defp build_transition_data(result) do
    history = result.history || []

    history
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] ->
      {format_command(from.command), format_command(to.command)}
    end)
    |> Enum.frequencies()
    |> Enum.map(fn {{from, to}, count} ->
      %{from: from, to: to, count: count}
    end)
  end

  defp build_check_data(result) do
    check_results = result[:check_results] || []

    check_results
    |> Enum.group_by(& &1[:check_name])
    |> Enum.flat_map(fn {check, results} ->
      passed = Enum.count(results, & &1[:passed])
      failed = length(results) - passed

      [
        %{check: format_check(check), count: passed, result: "passed"},
        %{check: format_check(check), count: failed, result: "failed"}
      ]
    end)
  end

  defp format_command(cmd) when is_atom(cmd) do
    cmd
    |> Module.split()
    |> List.last()
  end

  defp format_command(cmd), do: inspect(cmd)

  defp format_check(nil), do: "Unknown"

  defp format_check(check) when is_atom(check) do
    check
    |> to_string()
    |> String.replace("Elixir.", "")
  end

  defp format_check(check), do: inspect(check)

  # ============================================================================
  # Fallback Charts (ASCII-based when VegaLite unavailable)
  # ============================================================================

  defp fallback_command_chart(result) do
    ensure_kino!()

    history = result.history || []
    stats = Enum.frequencies_by(history, & &1.command)

    max_count = stats |> Map.values() |> Enum.max(fn -> 1 end)

    bars =
      stats
      |> Enum.sort_by(fn {_, count} -> -count end)
      |> Enum.map(fn {cmd, count} ->
        bar_width = round(count / max_count * 30)
        bar = String.duplicate("█", bar_width)
        "#{format_command(cmd) |> String.pad_trailing(20)} #{bar} #{count}"
      end)
      |> Enum.join("\n")

    md = """
    ## Command Execution Counts

    ```
    #{bars}
    ```

    *Install `vega_lite` and `kino_vega_lite` for interactive charts*
    """

    Kino.Markdown.new(md)
  end

  defp fallback_timing_chart(result) do
    ensure_kino!()

    history = result.history || []

    timings =
      history
      |> Enum.filter(&Map.has_key?(&1, :duration_us))
      |> Enum.map(& &1.duration_us)

    if Enum.empty?(timings) do
      Kino.Markdown.new("*No timing data available*")
    else
      min_t = Enum.min(timings)
      max_t = Enum.max(timings)
      avg_t = Enum.sum(timings) / length(timings)

      md = """
      ## Timing Statistics

      | Metric | Value |
      |--------|-------|
      | Min | #{format_us(min_t)} |
      | Max | #{format_us(max_t)} |
      | Avg | #{format_us(avg_t)} |
      | Count | #{length(timings)} |

      *Install `vega_lite` and `kino_vega_lite` for histograms*
      """

      Kino.Markdown.new(md)
    end
  end

  defp fallback_success_chart(result) do
    ensure_kino!()

    history = result.history || []
    total = length(history)

    success_count =
      Enum.count(history, fn e ->
        match?({:ok, _}, e[:result]) or e[:success] == true
      end)

    failed_count = total - success_count

    success_pct = if total > 0, do: round(success_count / total * 100), else: 0
    failed_pct = 100 - success_pct

    md = """
    ## Success Rate

    ```
    Passed: #{String.duplicate("█", div(success_pct, 2))} #{success_pct}% (#{success_count})
    Failed: #{String.duplicate("█", div(failed_pct, 2))} #{failed_pct}% (#{failed_count})
    ```

    *Install `vega_lite` and `kino_vega_lite` for pie charts*
    """

    Kino.Markdown.new(md)
  end

  defp fallback_timeline_chart(result) do
    ensure_kino!()

    history = result.history || []

    if Enum.empty?(history) do
      Kino.Markdown.new("*No execution data*")
    else
      timeline =
        history
        |> Enum.with_index(1)
        |> Enum.map(fn {entry, idx} ->
          status = if entry[:success] != false, do: "✅", else: "❌"
          "#{idx}. #{status} #{format_command(entry.command)}"
        end)
        |> Enum.join("\n")

      md = """
      ## Execution Timeline

      #{timeline}

      *Install `vega_lite` and `kino_vega_lite` for interactive timelines*
      """

      Kino.Markdown.new(md)
    end
  end

  defp fallback_transition_chart(result) do
    ensure_kino!()

    history = result.history || []

    transitions =
      history
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] ->
        {format_command(from.command), format_command(to.command)}
      end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_, count} -> -count end)
      |> Enum.take(10)
      |> Enum.map(fn {{from, to}, count} ->
        "#{from} → #{to}: #{count}"
      end)
      |> Enum.join("\n")

    md = """
    ## Top Command Transitions

    ```
    #{transitions}
    ```

    *Install `vega_lite` and `kino_vega_lite` for heatmaps*
    """

    Kino.Markdown.new(md)
  end

  defp fallback_check_chart(result) do
    ensure_kino!()

    check_results = result[:check_results] || []

    if Enum.empty?(check_results) do
      Kino.Markdown.new("*No check data available*")
    else
      stats =
        check_results
        |> Enum.group_by(& &1[:check_name])
        |> Enum.map(fn {check, results} ->
          passed = Enum.count(results, & &1[:passed])
          total = length(results)
          "#{format_check(check)}: #{passed}/#{total} passed"
        end)
        |> Enum.join("\n")

      md = """
      ## Check Results

      ```
      #{stats}
      ```

      *Install `vega_lite` and `kino_vega_lite` for interactive charts*
      """

      Kino.Markdown.new(md)
    end
  end

  defp format_us(us) when is_number(us) do
    cond do
      us < 1000 -> "#{round(us)}µs"
      us < 1_000_000 -> "#{Float.round(us / 1000, 1)}ms"
      true -> "#{Float.round(us / 1_000_000, 2)}s"
    end
  end

  defp ensure_kino! do
    unless Code.ensure_loaded?(Kino) do
      raise "Kino is required for Livebook integration"
    end
  end
end
