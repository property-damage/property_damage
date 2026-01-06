defmodule PropertyDamage.Livebook do
  @moduledoc """
  Livebook integration for PropertyDamage with rich visualizations.

  Provides interactive widgets and visualizations for exploring PropertyDamage
  test runs in Livebook notebooks.

  ## Requirements

  Add `kino` to your dependencies:

      {:kino, "~> 0.12"}

  ## Quick Start

  In a Livebook cell:

      alias PropertyDamage.Livebook

      # Run tests and visualize results
      result = PropertyDamage.run(
        model: MyModel,
        adapter: MyAdapter,
        max_runs: 100
      )

      Livebook.visualize(result)

  ## Available Widgets

  - `visualize/1` - Main dashboard with all visualizations
  - `results_table/1` - DataTable of run results
  - `command_stats/1` - Command execution statistics
  - `state_timeline/1` - Visual state progression
  - `failure_details/1` - Detailed failure analysis
  - `live_monitor/0` - Real-time telemetry streaming

  ## Interactive Exploration

      # Explore a specific failure
      Livebook.explore_failure(result)

      # Step through commands
      Livebook.command_stepper(result)

      # Compare model vs actual state
      Livebook.state_diff(result)
  """

  # Suppress warnings for optional Kino dependency (guarded by ensure_kino!/0 at runtime)
  @compile {:no_warn_undefined,
            [
              Kino,
              Kino.Markdown,
              Kino.DataTable,
              Kino.Frame,
              Kino.Control,
              Kino.Input,
              Kino.Layout
            ]}

  @doc """
  Check if Kino is available.
  """
  def kino_available? do
    Code.ensure_loaded?(Kino)
  end

  @doc """
  Create the main visualization dashboard for a test result.

  Returns a Kino.Layout with tabs for different views:
  - Overview: Summary statistics
  - Commands: Command execution details
  - State: State progression timeline
  - Failures: Failure analysis (if any)
  """
  @spec visualize(PropertyDamage.result()) :: struct()
  def visualize(result) do
    ensure_kino!()

    tabs =
      [
        {"📊 Overview", overview_tab(result)},
        {"⚡ Commands", commands_tab(result)},
        {"📈 State Timeline", state_timeline_tab(result)}
      ]
      |> maybe_add_failure_tab(result)

    Kino.Layout.tabs(tabs)
  end

  @doc """
  Create a DataTable showing run results.
  """
  @spec results_table(PropertyDamage.result()) :: struct()
  def results_table(result) do
    ensure_kino!()

    data =
      result.history
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, idx} ->
        %{
          "#" => idx,
          "Command" => format_command_name(entry.command),
          "Args" => inspect(entry.args, pretty: true, limit: 3),
          "Result" => format_result_status(entry),
          "Events" => length(Map.get(entry, :events, [])),
          "Duration" => format_duration(entry)
        }
      end)

    Kino.DataTable.new(data,
      name: "Command History",
      keys: ["#", "Command", "Args", "Result", "Events", "Duration"]
    )
  end

  @doc """
  Create command execution statistics visualization.
  """
  @spec command_stats(PropertyDamage.result()) :: struct()
  def command_stats(result) do
    ensure_kino!()

    stats = calculate_command_stats(result.history)

    data =
      stats
      |> Enum.map(fn {cmd, stats} ->
        %{
          "Command" => format_command_name(cmd),
          "Count" => stats.count,
          "Success" => stats.success,
          "Failed" => stats.failed,
          "Success Rate" => format_percentage(stats.success, stats.count),
          "Avg Duration" => format_avg_duration(stats)
        }
      end)
      |> Enum.sort_by(& &1["Count"], :desc)

    Kino.DataTable.new(data,
      name: "Command Statistics",
      keys: ["Command", "Count", "Success", "Failed", "Success Rate", "Avg Duration"]
    )
  end

  @doc """
  Create a state timeline visualization showing state progression.
  """
  @spec state_timeline(PropertyDamage.result()) :: struct()
  def state_timeline(result) do
    ensure_kino!()

    timeline_md = build_state_timeline_markdown(result)
    Kino.Markdown.new(timeline_md)
  end

  @doc """
  Create detailed failure analysis visualization.
  """
  @spec failure_details(PropertyDamage.result()) :: struct()
  def failure_details(result) do
    ensure_kino!()

    if result.success do
      Kino.Markdown.new("✅ **No failures** - All checks passed!")
    else
      build_failure_visualization(result)
    end
  end

  @doc """
  Create a live telemetry monitor that streams updates.

  Returns a Kino.Frame that updates in real-time as tests run.
  """
  @spec live_monitor() :: struct()
  def live_monitor do
    ensure_kino!()

    frame = Kino.Frame.new()

    # Subscribe to telemetry updates
    {:ok, _pid} =
      Task.start(fn ->
        PropertyDamage.Telemetry.Collector.subscribe()
        monitor_loop(frame, initial_monitor_state())
      end)

    Kino.Layout.grid([
      Kino.Markdown.new("## 📡 Live Test Monitor\n\n*Waiting for test runs...*"),
      frame
    ])
  end

  @doc """
  Create an interactive command stepper for exploring execution.
  """
  @spec command_stepper(PropertyDamage.result()) :: struct()
  def command_stepper(result) do
    ensure_kino!()

    history = result.history
    total = length(history)

    if total == 0 do
      Kino.Markdown.new("*No commands executed*")
    else
      # Create a form for step navigation
      form =
        Kino.Control.form(
          [
            step: Kino.Input.number("Step", default: 1, min: 1, max: total)
          ],
          submit: "Go to Step"
        )

      frame = Kino.Frame.new()

      # Render initial step
      render_step(frame, history, 1)

      # Handle form submissions
      Kino.listen(form, fn %{data: %{step: step}} ->
        step = max(1, min(step || 1, total))
        render_step(frame, history, step)
      end)

      Kino.Layout.grid([
        Kino.Markdown.new("## 🔍 Command Stepper\n\nNavigate through command execution:"),
        form,
        frame
      ])
    end
  end

  @doc """
  Create a state diff visualization comparing model vs actual state.
  """
  @spec state_diff(PropertyDamage.result()) :: struct()
  def state_diff(result) do
    ensure_kino!()

    if result.success do
      Kino.Markdown.new(
        "✅ **States match** - Model state equals actual state throughout execution."
      )
    else
      build_state_diff_visualization(result)
    end
  end

  @doc """
  Create an interactive failure explorer.
  """
  @spec explore_failure(PropertyDamage.result()) :: struct()
  def explore_failure(result) do
    ensure_kino!()

    if result.success do
      Kino.Markdown.new("✅ **No failures to explore**")
    else
      build_failure_explorer(result)
    end
  end

  @doc """
  Run PropertyDamage with live visualization.

  Starts a test run and displays live progress in a Kino.Frame.
  """
  @spec run_with_visualization(keyword()) :: PropertyDamage.result()
  def run_with_visualization(opts) do
    ensure_kino!()

    frame = Kino.Frame.new()

    # Start collector if not running
    ensure_collector_started()

    # Subscribe to updates
    PropertyDamage.Telemetry.Collector.subscribe()

    # Render initial state
    Kino.Frame.render(frame, Kino.Markdown.new("🚀 **Starting test run...**"))

    # Run in a task so we can update the frame
    task =
      Task.async(fn ->
        PropertyDamage.run(opts)
      end)

    # Update loop
    update_visualization_loop(frame)

    # Wait for result
    result = Task.await(task, :infinity)

    # Render final result
    Kino.Frame.render(frame, visualize(result))

    result
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp ensure_kino! do
    unless kino_available?() do
      raise """
      Kino is required for Livebook integration.

      Add to your dependencies:

          {:kino, "~> 0.12"}

      Or install in Livebook:

          Mix.install([{:kino, "~> 0.12"}])
      """
    end
  end

  defp ensure_collector_started do
    case Process.whereis(PropertyDamage.Telemetry.Collector) do
      nil ->
        {:ok, _pid} = PropertyDamage.Telemetry.Collector.start_link()
        :ok

      _pid ->
        :ok
    end
  end

  # Overview Tab
  defp overview_tab(result) do
    stats = calculate_overview_stats(result)

    md = """
    ## Test Run Summary

    | Metric | Value |
    |--------|-------|
    | **Status** | #{if result.success, do: "✅ Passed", else: "❌ Failed"} |
    | **Commands Executed** | #{stats.total_commands} |
    | **Successful** | #{stats.successful_commands} |
    | **Failed** | #{stats.failed_commands} |
    | **Events Generated** | #{stats.total_events} |
    | **Checks Run** | #{stats.checks_run} |
    #{if result.shrunk_sequence, do: "| **Shrunk From** | #{stats.original_length} → #{stats.shrunk_length} commands |", else: ""}

    #{failure_summary_section(result)}
    """

    Kino.Markdown.new(md)
  end

  defp failure_summary_section(%{success: true}), do: ""

  defp failure_summary_section(result) do
    """

    ### Failure Details

    #{format_failure_message(result)}
    """
  end

  # Commands Tab
  defp commands_tab(result) do
    Kino.Layout.grid([
      command_stats(result),
      results_table(result)
    ])
  end

  # State Timeline Tab
  defp state_timeline_tab(result) do
    state_timeline(result)
  end

  defp maybe_add_failure_tab(tabs, %{success: true}), do: tabs

  defp maybe_add_failure_tab(tabs, result) do
    tabs ++ [{"❌ Failure Analysis", failure_details(result)}]
  end

  # Stats Calculation
  defp calculate_overview_stats(result) do
    history = result.history || []

    successful =
      Enum.count(history, fn entry ->
        match?({:ok, _}, entry[:result]) or entry[:success] == true
      end)

    total_events =
      history
      |> Enum.map(fn entry -> length(Map.get(entry, :events, [])) end)
      |> Enum.sum()

    %{
      total_commands: length(history),
      successful_commands: successful,
      failed_commands: length(history) - successful,
      total_events: total_events,
      checks_run: count_checks(result),
      original_length: get_in(result, [:shrink_info, :original_length]) || length(history),
      shrunk_length: length(result.shrunk_sequence || history)
    }
  end

  defp calculate_command_stats(history) do
    history
    |> Enum.group_by(& &1.command)
    |> Enum.map(fn {cmd, entries} ->
      success_count =
        Enum.count(entries, fn entry ->
          match?({:ok, _}, entry[:result]) or entry[:success] == true
        end)

      total_duration =
        entries
        |> Enum.map(fn entry -> Map.get(entry, :duration_us, 0) end)
        |> Enum.sum()

      {cmd,
       %{
         count: length(entries),
         success: success_count,
         failed: length(entries) - success_count,
         total_duration: total_duration
       }}
    end)
    |> Map.new()
  end

  defp count_checks(%{check_results: results}) when is_list(results), do: length(results)
  defp count_checks(_), do: 0

  # Formatting
  defp format_command_name(cmd) when is_atom(cmd) do
    cmd
    |> Module.split()
    |> List.last()
  end

  defp format_command_name(cmd), do: inspect(cmd)

  defp format_result_status(%{result: {:ok, _}}), do: "✅"
  defp format_result_status(%{result: {:error, _}}), do: "❌"
  defp format_result_status(%{success: true}), do: "✅"
  defp format_result_status(%{success: false}), do: "❌"
  defp format_result_status(_), do: "—"

  defp format_duration(%{duration_us: us}) when is_integer(us) do
    cond do
      us < 1000 -> "#{us}µs"
      us < 1_000_000 -> "#{Float.round(us / 1000, 1)}ms"
      true -> "#{Float.round(us / 1_000_000, 2)}s"
    end
  end

  defp format_duration(_), do: "—"

  defp format_percentage(part, total) when total > 0 do
    pct = Float.round(part / total * 100, 1)
    "#{pct}%"
  end

  defp format_percentage(_, _), do: "—"

  defp format_avg_duration(%{total_duration: total, count: count}) when count > 0 do
    avg = div(total, count)
    format_duration(%{duration_us: avg})
  end

  defp format_avg_duration(_), do: "—"

  defp format_failure_message(%{failure_message: msg}) when is_binary(msg), do: msg

  defp format_failure_message(%{error: error}) do
    """
    ```
    #{inspect(error, pretty: true)}
    ```
    """
  end

  defp format_failure_message(_), do: "*No failure details available*"

  # State Timeline Building
  defp build_state_timeline_markdown(result) do
    history = result.history || []

    if Enum.empty?(history) do
      "*No commands executed*"
    else
      entries =
        history
        |> Enum.with_index(1)
        |> Enum.map(fn {entry, idx} ->
          status = if entry[:success] != false, do: "✅", else: "❌"
          cmd = format_command_name(entry.command)
          events = length(Map.get(entry, :events, []))

          """
          ### Step #{idx}: #{cmd} #{status}

          **Events:** #{events}

          #{format_state_change(entry)}
          """
        end)
        |> Enum.join("\n---\n\n")

      """
      ## State Timeline

      #{entries}
      """
    end
  end

  defp format_state_change(%{model_state_before: before, model_state_after: after_state})
       when not is_nil(before) and not is_nil(after_state) do
    """
    <details>
    <summary>State Change</summary>

    **Before:**
    ```elixir
    #{inspect(before, pretty: true, limit: 10)}
    ```

    **After:**
    ```elixir
    #{inspect(after_state, pretty: true, limit: 10)}
    ```

    </details>
    """
  end

  defp format_state_change(_), do: ""

  # Failure Visualization
  defp build_failure_visualization(result) do
    md = """
    ## ❌ Failure Analysis

    #{format_failure_message(result)}

    ### Failed Command

    #{format_failed_command(result)}

    ### Sequence Leading to Failure

    #{format_failure_sequence(result)}

    #{shrinking_info_section(result)}
    """

    Kino.Markdown.new(md)
  end

  defp format_failed_command(%{failed_command: cmd}) when not is_nil(cmd) do
    """
    ```elixir
    #{inspect(cmd, pretty: true)}
    ```
    """
  end

  defp format_failed_command(_), do: "*Not available*"

  defp format_failure_sequence(%{shrunk_sequence: seq}) when is_list(seq) and length(seq) > 0 do
    seq
    |> Enum.with_index(1)
    |> Enum.map(fn {cmd, idx} ->
      "#{idx}. `#{format_command_name(cmd.command)}` - #{inspect(cmd.args, limit: 3)}"
    end)
    |> Enum.join("\n")
  end

  defp format_failure_sequence(%{history: history}) when is_list(history) do
    history
    |> Enum.take(-5)
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, idx} ->
      "#{idx}. `#{format_command_name(entry.command)}`"
    end)
    |> Enum.join("\n")
  end

  defp format_failure_sequence(_), do: "*Not available*"

  defp shrinking_info_section(%{shrunk_sequence: seq, shrink_info: info})
       when not is_nil(seq) and not is_nil(info) do
    """
    ### Shrinking

    | Metric | Value |
    |--------|-------|
    | Original Length | #{info[:original_length] || "?"} |
    | Shrunk Length | #{length(seq)} |
    | Iterations | #{info[:iterations] || "?"} |
    """
  end

  defp shrinking_info_section(_), do: ""

  # Failure Explorer
  defp build_failure_explorer(result) do
    tabs = [
      {"Summary", failure_details(result)},
      {"Commands", results_table(result)},
      {"State Diff", state_diff(result)}
    ]

    Kino.Layout.tabs(tabs)
  end

  # State Diff Visualization
  defp build_state_diff_visualization(result) do
    md = """
    ## State Comparison

    ### Model State (Expected)

    ```elixir
    #{inspect(result[:model_state], pretty: true, limit: 20)}
    ```

    ### Actual State (Observed)

    ```elixir
    #{inspect(result[:actual_state], pretty: true, limit: 20)}
    ```

    #{format_diff_details(result)}
    """

    Kino.Markdown.new(md)
  end

  defp format_diff_details(%{diff: diff}) when not is_nil(diff) do
    """
    ### Differences

    ```diff
    #{diff}
    ```
    """
  end

  defp format_diff_details(_), do: ""

  # Command Stepper
  defp render_step(frame, history, step_num) do
    entry = Enum.at(history, step_num - 1)
    total = length(history)

    md = """
    ### Step #{step_num} of #{total}

    **Command:** `#{format_command_name(entry.command)}`

    **Arguments:**
    ```elixir
    #{inspect(entry.args, pretty: true)}
    ```

    **Result:** #{format_result_status(entry)}

    #{format_step_events(entry)}

    #{format_step_state(entry)}
    """

    Kino.Frame.render(frame, Kino.Markdown.new(md))
  end

  defp format_step_events(%{events: events}) when is_list(events) and length(events) > 0 do
    event_list =
      events
      |> Enum.map(fn event ->
        "- `#{inspect(event, limit: 5)}`"
      end)
      |> Enum.join("\n")

    """
    **Events Generated:**
    #{event_list}
    """
  end

  defp format_step_events(_), do: ""

  defp format_step_state(%{model_state_after: state}) when not is_nil(state) do
    """
    **State After:**
    ```elixir
    #{inspect(state, pretty: true, limit: 10)}
    ```
    """
  end

  defp format_step_state(_), do: ""

  # Live Monitor
  defp initial_monitor_state do
    %{
      runs: 0,
      commands: 0,
      checks_passed: 0,
      checks_failed: 0,
      current_command: nil,
      last_update: nil
    }
  end

  defp monitor_loop(frame, state) do
    receive do
      {:telemetry_update, event_type, data, collector_state} ->
        new_state = update_monitor_state(state, event_type, data, collector_state)
        render_monitor(frame, new_state)
        monitor_loop(frame, new_state)
    after
      5000 ->
        # Periodic refresh
        monitor_loop(frame, state)
    end
  end

  defp update_monitor_state(state, event_type, _data, collector_state) do
    %{
      state
      | runs: collector_state.runs,
        commands: collector_state.commands_executed,
        checks_passed: collector_state.checks_passed,
        checks_failed: collector_state.checks_failed,
        current_command: get_current_command(event_type, collector_state),
        last_update: DateTime.utc_now()
    }
  end

  defp get_current_command(:command_start, %{current_run: %{current_command: cmd}}), do: cmd
  defp get_current_command(_, _), do: nil

  defp render_monitor(frame, state) do
    md = """
    | Metric | Value |
    |--------|-------|
    | **Runs** | #{state.runs} |
    | **Commands** | #{state.commands} |
    | **Checks Passed** | #{state.checks_passed} |
    | **Checks Failed** | #{state.checks_failed} |
    | **Last Update** | #{format_timestamp(state.last_update)} |

    #{if state.current_command, do: "**Current:** `#{state.current_command}`", else: ""}
    """

    Kino.Frame.render(frame, Kino.Markdown.new(md))
  end

  defp format_timestamp(nil), do: "—"
  defp format_timestamp(dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp update_visualization_loop(frame) do
    receive do
      {:telemetry_update, _event_type, _data, state} ->
        render_live_progress(frame, state)
        update_visualization_loop(frame)
    after
      100 ->
        :ok
    end
  end

  defp render_live_progress(frame, state) do
    md = """
    ### 🔄 Running...

    | Metric | Value |
    |--------|-------|
    | Runs | #{state.runs} |
    | Commands | #{state.commands_executed} |
    | Checks | #{state.checks_passed + state.checks_failed} |
    """

    Kino.Frame.render(frame, Kino.Markdown.new(md))
  end
end
