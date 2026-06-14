defmodule PropertyDamage.Telemetry.Dashboard do
  @moduledoc """
  LiveView dashboard for monitoring PropertyDamage test runs.

  This module provides a real-time dashboard that displays:
  - Run progress and statistics
  - Command execution metrics
  - Check pass/fail rates
  - Shrinking progress
  - Recent events timeline

  ## Setup

  ### 1. Create a LiveView in your application

      defmodule MyAppWeb.PropertyDamageDashboardLive do
        use MyAppWeb, :live_view

        alias PropertyDamage.Telemetry.{Collector, Dashboard}

        def mount(_params, _session, socket) do
          if connected?(socket) do
            Collector.subscribe()
          end

          state = Collector.get_state()

          {:ok,
           assign(socket,
             page_title: "PropertyDamage Dashboard",
             state: state,
             view_mode: :overview
           )}
        end

        def handle_info({:telemetry_update, _event_type, _data, state}, socket) do
          {:noreply, assign(socket, :state, state)}
        end

        def handle_event("reset", _params, socket) do
          Collector.reset()
          {:noreply, socket}
        end

        def handle_event("set_view_mode", %{"mode" => mode}, socket) do
          {:noreply, assign(socket, :view_mode, String.to_existing_atom(mode))}
        end

        def render(assigns) do
          Dashboard.render(assigns)
        end
      end

  ### 2. Add route in your router

      live "/property-damage", PropertyDamageDashboardLive

  ### 3. Start the collector in your application

      # In your application.ex
      children = [
        # ...
        PropertyDamage.Telemetry.Collector
      ]

  ## Requirements

  - Phoenix LiveView must be installed in your application
  - The Collector must be running to receive events
  """

  alias PropertyDamage.Telemetry.Collector

  @doc """
  Returns the initial assigns for the dashboard.
  """
  @spec initial_assigns() :: keyword()
  def initial_assigns do
    state = Collector.get_state()

    [
      page_title: "PropertyDamage Dashboard",
      state: state,
      view_mode: :overview
    ]
  end

  @doc """
  Render the dashboard HTML.

  Returns a Phoenix.LiveView.Rendered struct if Phoenix is available,
  otherwise returns an HTML string.
  """
  def render(assigns) do
    if Code.ensure_loaded?(Phoenix.LiveView.Engine) do
      render_heex(assigns)
    else
      render_html(assigns)
    end
  end

  # Render using HEEx if Phoenix is available
  defp render_heex(assigns) do
    # This will only be called if Phoenix is available
    # We use EEx to avoid compile-time dependency
    template = dashboard_template()

    EEx.eval_string(template, assigns: assigns, engine: EEx.SmartEngine)
  end

  # Render as plain HTML string
  defp render_html(assigns) do
    state = assigns[:state] || %{}
    view_mode = assigns[:view_mode] || :overview

    """
    <div class="pd-dashboard">
      <style>#{css()}</style>

      <header class="pd-header">
        <h1>PropertyDamage Dashboard</h1>
        <div class="pd-header-actions">
          <button onclick="location.reload()" class="pd-btn">Refresh</button>
        </div>
      </header>

      <nav class="pd-nav">
        #{render_nav_buttons(view_mode)}
      </nav>

      <main class="pd-main">
        #{render_view(view_mode, state)}
      </main>
    </div>
    """
  end

  defp render_nav_buttons(current) do
    modes = [:overview, :commands, :checks, :events]

    modes
    |> Enum.map_join("\n", fn mode ->
      active = if mode == current, do: "active", else: ""
      "<button class=\"pd-nav-btn #{active}\">#{mode}</button>"
    end)
  end

  defp render_view(:overview, state), do: render_overview_html(state)
  defp render_view(:commands, state), do: render_commands_html(state)
  defp render_view(:checks, state), do: render_checks_html(state)
  defp render_view(:events, state), do: render_events_html(state)

  defp render_overview_html(state) do
    runs = state[:runs] || 0
    completed = state[:runs_completed] || 0
    failed = state[:runs_failed] || 0
    commands = state[:commands_executed] || 0
    checks_passed = state[:checks_passed] || 0
    checks_failed = state[:checks_failed] || 0
    shrink_iters = state[:shrink_iterations] || 0
    total_time = state[:total_command_time_ms] || 0

    pass_rate =
      if completed + failed > 0 do
        Float.round(completed / (completed + failed) * 100, 1)
      else
        100.0
      end

    current_run = state[:current_run]

    current_run_html =
      if current_run do
        progress =
          if current_run[:max_runs] && current_run[:max_runs] > 0 do
            Float.round((current_run[:current_sequence] || 0) / current_run[:max_runs] * 100, 1)
          else
            0
          end

        """
        <div class="pd-current-run">
          <h3>Current Run</h3>
          <div class="pd-run-info">
            <div class="pd-run-row">
              <span class="pd-label">Model:</span>
              <span class="pd-value">#{inspect(current_run[:model])}</span>
            </div>
            <div class="pd-run-row">
              <span class="pd-label">Progress:</span>
              <span class="pd-value">#{current_run[:current_sequence] || 0} / #{current_run[:max_runs] || 0}</span>
            </div>
            <div class="pd-run-row">
              <span class="pd-label">Commands:</span>
              <span class="pd-value">#{current_run[:commands_in_run] || 0}</span>
            </div>
            <div class="pd-run-row">
              <span class="pd-label">Seed:</span>
              <span class="pd-value">#{current_run[:seed] || "N/A"}</span>
            </div>
          </div>
          <div class="pd-progress-bar">
            <div class="pd-progress-fill" style="width: #{progress}%"></div>
          </div>
        </div>
        """
      else
        "<div class=\"pd-no-run\"><p>No test run in progress</p></div>"
      end

    """
    <div class="pd-overview">
      <div class="pd-cards">
        <div class="pd-card">
          <div class="pd-card-label">Runs</div>
          <div class="pd-card-value">#{runs}</div>
          <div class="pd-card-sub">
            <span class="pd-success">#{completed} passed</span>
            <span class="pd-error">#{failed} failed</span>
          </div>
        </div>

        <div class="pd-card">
          <div class="pd-card-label">Commands</div>
          <div class="pd-card-value">#{commands}</div>
          <div class="pd-card-sub">#{format_duration(total_time)} total</div>
        </div>

        <div class="pd-card">
          <div class="pd-card-label">Checks</div>
          <div class="pd-card-value">#{checks_passed + checks_failed}</div>
          <div class="pd-card-sub">
            <span class="pd-success">#{checks_passed} passed</span>
            <span class="pd-error">#{checks_failed} failed</span>
          </div>
        </div>

        <div class="pd-card">
          <div class="pd-card-label">Shrinking</div>
          <div class="pd-card-value">#{shrink_iters}</div>
          <div class="pd-card-sub">iterations</div>
        </div>
      </div>

      #{current_run_html}

      <div class="pd-pass-rate">
        <h3>Pass Rate</h3>
        <div class="pd-rate-bar">
          <div class="pd-rate-passed" style="width: #{pass_rate}%"></div>
        </div>
        <div class="pd-rate-label">#{pass_rate}%</div>
      </div>
    </div>
    """
  end

  defp render_commands_html(state) do
    command_stats = state[:command_stats] || %{}

    if map_size(command_stats) > 0 do
      rows =
        command_stats
        |> Enum.sort_by(fn {_, s} -> -(s[:count] || 0) end)
        |> Enum.map_join("\n", fn {cmd, stats} ->
          """
          <tr>
            <td>#{short_module_name(cmd)}</td>
            <td>#{stats[:count] || 0}</td>
            <td>#{format_microseconds(stats[:avg_time_us] || 0)}</td>
            <td>#{format_microseconds(stats[:total_time] || 0)}</td>
          </tr>
          """
        end)

      """
      <div class="pd-commands">
        <h3>Command Statistics</h3>
        <table class="pd-table">
          <thead>
            <tr>
              <th>Command</th>
              <th>Count</th>
              <th>Avg Time</th>
              <th>Total Time</th>
            </tr>
          </thead>
          <tbody>
            #{rows}
          </tbody>
        </table>
      </div>
      """
    else
      "<div class=\"pd-commands\"><h3>Command Statistics</h3><p class=\"pd-empty\">No commands executed yet</p></div>"
    end
  end

  defp render_checks_html(state) do
    check_stats = state[:check_stats] || %{}

    if map_size(check_stats) > 0 do
      rows =
        check_stats
        |> Enum.sort_by(fn {name, _} -> name end)
        |> Enum.map_join("\n", fn {check, stats} ->
          passed = stats[:passed] || 0
          failed = stats[:failed] || 0
          total = passed + failed

          pass_rate =
            if total > 0 do
              Float.round(passed / total * 100, 1)
            else
              100.0
            end

          row_class = if failed > 0, do: "pd-row-warning", else: ""

          """
          <tr class="#{row_class}">
            <td>#{check}</td>
            <td class="pd-success">#{passed}</td>
            <td class="pd-error">#{failed}</td>
            <td>#{pass_rate}%</td>
          </tr>
          """
        end)

      """
      <div class="pd-checks">
        <h3>Check Statistics</h3>
        <table class="pd-table">
          <thead>
            <tr>
              <th>Check</th>
              <th>Passed</th>
              <th>Failed</th>
              <th>Pass Rate</th>
            </tr>
          </thead>
          <tbody>
            #{rows}
          </tbody>
        </table>
      </div>
      """
    else
      "<div class=\"pd-checks\"><h3>Check Statistics</h3><p class=\"pd-empty\">No checks executed yet</p></div>"
    end
  end

  defp render_events_html(state) do
    events = state[:recent_events] || []

    if events != [] do
      event_rows =
        events
        |> Enum.map_join("\n", fn event ->
          event_type = event[:type] || :unknown
          timestamp = event[:timestamp] || 0

          """
          <div class="pd-event pd-event-#{event_type}">
            <span class="pd-event-time">#{format_timestamp(timestamp)}</span>
            <span class="pd-event-type">#{event_type}</span>
            <span class="pd-event-detail">#{event_detail(event)}</span>
          </div>
          """
        end)

      """
      <div class="pd-events">
        <h3>Recent Events</h3>
        <div class="pd-event-list">
          #{event_rows}
        </div>
      </div>
      """
    else
      "<div class=\"pd-events\"><h3>Recent Events</h3><p class=\"pd-empty\">No events yet</p></div>"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{div(ms, 60_000)}m #{rem(ms, 60_000) |> div(1000)}s"

  defp format_microseconds(us) when us < 1000, do: "#{us}us"
  defp format_microseconds(us) when us < 1_000_000, do: "#{Float.round(us / 1000, 1)}ms"
  defp format_microseconds(us), do: "#{Float.round(us / 1_000_000, 2)}s"

  defp format_timestamp(ts) when is_integer(ts) and ts > 0 do
    datetime = DateTime.from_unix!(div(ts, 1000), :second)
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  defp format_timestamp(_), do: "--:--:--"

  defp short_module_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
  end

  defp short_module_name(other), do: inspect(other)

  defp event_detail(%{type: :run_start, metadata: meta}) do
    "#{short_module_name(meta[:model])} - #{meta[:max_runs]} runs"
  end

  defp event_detail(%{type: :run_stop, result: result, duration_ms: dur}) do
    "#{result} in #{format_duration(dur)}"
  end

  defp event_detail(%{type: :run_exception, kind: kind, reason: reason}) do
    "#{kind}: #{String.slice(to_string(reason), 0, 50)}"
  end

  defp event_detail(%{type: :check_failed, check_name: name, message: msg}) do
    "#{name}: #{msg || "failed"}"
  end

  defp event_detail(%{type: :shrink_complete, original_length: orig, shrunk_length: shrunk}) do
    "#{orig} -> #{shrunk} commands"
  end

  defp event_detail(_), do: ""

  # Placeholder for HEEx template - not used in library mode
  defp dashboard_template do
    # This would be the HEEx template if we had Phoenix
    ""
  end

  # ============================================================================
  # CSS
  # ============================================================================

  @doc """
  Returns the CSS styles for the dashboard.
  """
  def css do
    """
    .pd-dashboard {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      max-width: 1200px;
      margin: 0 auto;
      padding: 20px;
      color: #333;
    }

    .pd-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 20px;
      padding-bottom: 20px;
      border-bottom: 2px solid #e0e0e0;
    }

    .pd-header h1 {
      margin: 0;
      font-size: 24px;
      color: #2c3e50;
    }

    .pd-header-actions {
      display: flex;
      gap: 10px;
    }

    .pd-btn {
      padding: 8px 16px;
      border: 1px solid #ccc;
      border-radius: 4px;
      background: #fff;
      cursor: pointer;
      font-size: 14px;
    }

    .pd-btn:hover { background: #f5f5f5; }
    .pd-btn-active { background: #e3f2fd; border-color: #2196f3; color: #1976d2; }
    .pd-btn-danger { color: #d32f2f; border-color: #d32f2f; }
    .pd-btn-danger:hover { background: #ffebee; }

    .pd-nav {
      display: flex;
      gap: 5px;
      margin-bottom: 20px;
    }

    .pd-nav-btn {
      padding: 10px 20px;
      border: none;
      background: #f5f5f5;
      cursor: pointer;
      border-radius: 4px 4px 0 0;
      font-size: 14px;
    }

    .pd-nav-btn:hover { background: #e0e0e0; }
    .pd-nav-btn.active { background: #2196f3; color: white; }

    .pd-main {
      background: #fff;
      border-radius: 8px;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
      padding: 20px;
    }

    .pd-cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 20px;
      margin-bottom: 30px;
    }

    .pd-card {
      background: #f8f9fa;
      border-radius: 8px;
      padding: 20px;
      text-align: center;
    }

    .pd-card-label {
      font-size: 12px;
      text-transform: uppercase;
      color: #666;
      margin-bottom: 5px;
    }

    .pd-card-value {
      font-size: 36px;
      font-weight: bold;
      color: #2c3e50;
    }

    .pd-card-sub {
      font-size: 12px;
      color: #666;
      margin-top: 5px;
    }

    .pd-success { color: #27ae60; }
    .pd-error { color: #e74c3c; }

    .pd-current-run {
      background: #e3f2fd;
      border-radius: 8px;
      padding: 20px;
      margin-bottom: 20px;
    }

    .pd-current-run h3 {
      margin: 0 0 15px 0;
      color: #1976d2;
    }

    .pd-run-info {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 10px;
      margin-bottom: 15px;
    }

    .pd-run-row {
      display: flex;
      justify-content: space-between;
    }

    .pd-label { color: #666; }
    .pd-value { font-weight: 500; }

    .pd-progress-bar {
      height: 8px;
      background: #bbdefb;
      border-radius: 4px;
      overflow: hidden;
    }

    .pd-progress-fill {
      height: 100%;
      background: #2196f3;
      transition: width 0.3s ease;
    }

    .pd-no-run {
      text-align: center;
      padding: 40px;
      color: #666;
    }

    .pd-pass-rate {
      margin-top: 20px;
    }

    .pd-pass-rate h3 {
      margin: 0 0 10px 0;
    }

    .pd-rate-bar {
      height: 24px;
      background: #ffcdd2;
      border-radius: 4px;
      overflow: hidden;
    }

    .pd-rate-passed {
      height: 100%;
      background: #a5d6a7;
      transition: width 0.3s ease;
    }

    .pd-rate-label {
      text-align: center;
      margin-top: 5px;
      font-weight: bold;
    }

    .pd-table {
      width: 100%;
      border-collapse: collapse;
    }

    .pd-table th, .pd-table td {
      padding: 12px;
      text-align: left;
      border-bottom: 1px solid #e0e0e0;
    }

    .pd-table th {
      background: #f5f5f5;
      font-weight: 600;
    }

    .pd-row-warning { background: #fff8e1; }

    .pd-empty {
      text-align: center;
      padding: 40px;
      color: #666;
    }

    .pd-event-list {
      max-height: 400px;
      overflow-y: auto;
    }

    .pd-event {
      display: flex;
      gap: 15px;
      padding: 10px;
      border-bottom: 1px solid #e0e0e0;
      font-size: 13px;
    }

    .pd-event-time {
      color: #666;
      font-family: monospace;
    }

    .pd-event-type {
      font-weight: 500;
      min-width: 120px;
    }

    .pd-event-run_start .pd-event-type { color: #2196f3; }
    .pd-event-run_stop .pd-event-type { color: #4caf50; }
    .pd-event-run_exception .pd-event-type { color: #f44336; }
    .pd-event-check_failed .pd-event-type { color: #ff9800; }
    .pd-event-shrink_complete .pd-event-type { color: #9c27b0; }

    .pd-event-detail {
      color: #666;
      flex: 1;
    }
    """
  end
end
