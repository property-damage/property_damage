defmodule PropertyDamage.Telemetry.Collector do
  @moduledoc """
  Collects and aggregates telemetry events for the dashboard.

  The Collector is a GenServer that:
  1. Attaches to PropertyDamage telemetry events
  2. Aggregates metrics (counts, timings, pass/fail rates)
  3. Maintains a sliding window of recent events
  4. Broadcasts updates to subscribers (LiveView processes)

  ## Usage

      # Start the collector (typically in your application supervisor)
      {:ok, pid} = PropertyDamage.Telemetry.Collector.start_link()

      # Subscribe to updates (from a LiveView)
      PropertyDamage.Telemetry.Collector.subscribe()

      # Get current state
      state = PropertyDamage.Telemetry.Collector.get_state()

  ## State Structure

  The collector maintains:
  - `runs` - Total runs started
  - `runs_completed` - Successful runs
  - `runs_failed` - Failed runs
  - `commands_executed` - Total commands executed
  - `checks_passed` - Total checks passed
  - `checks_failed` - Total checks failed
  - `current_run` - Current run info (if running)
  - `recent_events` - Last N events (sliding window)
  - `command_stats` - Per-command timing stats
  - `check_stats` - Per-check pass/fail stats
  """

  use GenServer

  @max_recent_events 100
  @pubsub_topic "property_damage:telemetry"

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the collector.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get the current aggregated state.
  """
  @spec get_state(GenServer.server()) :: map()
  def get_state(server \\ __MODULE__) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Subscribe to telemetry updates.

  The calling process will receive messages of the form:
  `{:telemetry_update, event_type, data}`
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc """
  Unsubscribe from telemetry updates.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__) do
    GenServer.call(server, {:unsubscribe, self()})
  end

  @doc """
  Reset all collected metrics.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @doc """
  Get the PubSub topic for broadcasts.
  """
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    attach_handlers()

    state = %{
      # Counters
      runs: 0,
      runs_completed: 0,
      runs_failed: 0,
      commands_executed: 0,
      checks_passed: 0,
      checks_failed: 0,
      shrink_iterations: 0,

      # Timing aggregates (in microseconds)
      total_run_time: 0,
      total_command_time: 0,
      total_check_time: 0,
      total_shrink_time: 0,

      # Current run info
      current_run: nil,

      # Recent events (sliding window)
      recent_events: [],

      # Per-command stats
      command_stats: %{},

      # Per-check stats
      check_stats: %{},

      # Subscribers
      subscribers: MapSet.new(),

      # Start time for uptime
      started_at: System.system_time(:millisecond)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, sanitize_state(state), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_call(:reset, _from, state) do
    new_state = %{
      state
      | runs: 0,
        runs_completed: 0,
        runs_failed: 0,
        commands_executed: 0,
        checks_passed: 0,
        checks_failed: 0,
        shrink_iterations: 0,
        total_run_time: 0,
        total_command_time: 0,
        total_check_time: 0,
        total_shrink_time: 0,
        current_run: nil,
        recent_events: [],
        command_stats: %{},
        check_stats: %{}
    }

    broadcast(new_state, :reset, %{})
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_info({:telemetry_event, event_name, measurements, metadata}, state) do
    new_state = handle_telemetry_event(event_name, measurements, metadata, state)
    {:noreply, new_state}
  end

  # ============================================================================
  # Telemetry Event Handlers
  # ============================================================================

  defp handle_telemetry_event([:property_damage, :run, :start], _measurements, metadata, state) do
    current_run = %{
      model: metadata[:model],
      adapter: metadata[:adapter],
      max_runs: metadata[:max_runs],
      max_commands: metadata[:max_commands],
      seed: metadata[:seed],
      started_at: System.system_time(:millisecond),
      current_sequence: 0,
      commands_in_run: 0
    }

    new_state = %{
      state
      | runs: state.runs + 1,
        current_run: current_run
    }

    event = %{type: :run_start, metadata: metadata, timestamp: now()}
    new_state = add_recent_event(new_state, event)
    broadcast(new_state, :run_start, current_run)
    new_state
  end

  defp handle_telemetry_event([:property_damage, :run, :stop], measurements, metadata, state) do
    duration_us = div(measurements[:duration] || 0, 1000)

    new_state =
      if metadata[:result] == :ok do
        %{state | runs_completed: state.runs_completed + 1}
      else
        %{state | runs_failed: state.runs_failed + 1}
      end

    new_state = %{
      new_state
      | total_run_time: state.total_run_time + duration_us,
        current_run: nil
    }

    event = %{
      type: :run_stop,
      result: metadata[:result],
      duration_ms: div(duration_us, 1000),
      timestamp: now()
    }

    new_state = add_recent_event(new_state, event)
    broadcast(new_state, :run_stop, event)
    new_state
  end

  defp handle_telemetry_event(
         [:property_damage, :run, :exception],
         _measurements,
         metadata,
         state
       ) do
    new_state = %{
      state
      | runs_failed: state.runs_failed + 1,
        current_run: nil
    }

    event = %{
      type: :run_exception,
      kind: metadata[:kind],
      reason: inspect(metadata[:reason]),
      timestamp: now()
    }

    new_state = add_recent_event(new_state, event)
    broadcast(new_state, :run_exception, event)
    new_state
  end

  defp handle_telemetry_event(
         [:property_damage, :sequence, :start],
         _measurements,
         metadata,
         state
       ) do
    current_run =
      if state.current_run do
        %{state.current_run | current_sequence: metadata[:run_number]}
      else
        nil
      end

    new_state = %{state | current_run: current_run}
    broadcast(new_state, :sequence_start, metadata)
    new_state
  end

  defp handle_telemetry_event(
         [:property_damage, :sequence, :stop],
         _measurements,
         metadata,
         state
       ) do
    broadcast(state, :sequence_stop, metadata)
    state
  end

  defp handle_telemetry_event(
         [:property_damage, :command, :start],
         _measurements,
         metadata,
         state
       ) do
    current_run =
      if state.current_run do
        %{state.current_run | commands_in_run: state.current_run.commands_in_run + 1}
      else
        nil
      end

    new_state = %{state | current_run: current_run}
    broadcast(new_state, :command_start, metadata)
    new_state
  end

  defp handle_telemetry_event([:property_damage, :command, :stop], measurements, metadata, state) do
    duration_us = div(measurements[:duration] || 0, 1000)
    command = metadata[:command]

    # Update per-command stats
    command_stats =
      Map.update(state.command_stats, command, %{count: 1, total_time: duration_us}, fn stats ->
        %{stats | count: stats.count + 1, total_time: stats.total_time + duration_us}
      end)

    new_state = %{
      state
      | commands_executed: state.commands_executed + 1,
        total_command_time: state.total_command_time + duration_us,
        command_stats: command_stats
    }

    broadcast(new_state, :command_stop, Map.put(metadata, :duration_us, duration_us))
    new_state
  end

  defp handle_telemetry_event([:property_damage, :check, :stop], measurements, metadata, state) do
    duration_us = div(measurements[:duration] || 0, 1000)
    check_name = metadata[:check_name]
    passed = metadata[:passed]

    # Update per-check stats
    check_stats =
      Map.update(state.check_stats, check_name, %{passed: 0, failed: 0}, fn stats ->
        if passed do
          %{stats | passed: stats.passed + 1}
        else
          %{stats | failed: stats.failed + 1}
        end
      end)

    new_state =
      if passed do
        %{state | checks_passed: state.checks_passed + 1}
      else
        %{state | checks_failed: state.checks_failed + 1}
      end

    new_state = %{
      new_state
      | total_check_time: state.total_check_time + duration_us,
        check_stats: check_stats
    }

    if passed do
      broadcast(new_state, :check_passed, metadata)
      new_state
    else
      event = %{
        type: :check_failed,
        check_name: check_name,
        message: metadata[:message],
        timestamp: now()
      }

      new_state = add_recent_event(new_state, event)
      broadcast(new_state, :check_failed, event)
      new_state
    end
  end

  defp handle_telemetry_event(
         [:property_damage, :shrink, :iteration],
         measurements,
         metadata,
         state
       ) do
    new_state = %{state | shrink_iterations: state.shrink_iterations + 1}

    broadcast(
      new_state,
      :shrink_iteration,
      Map.put(metadata, :iteration, measurements[:iteration])
    )

    new_state
  end

  defp handle_telemetry_event([:property_damage, :shrink, :stop], measurements, metadata, state) do
    duration_us = div(measurements[:duration] || 0, 1000)

    new_state = %{state | total_shrink_time: state.total_shrink_time + duration_us}

    event = %{
      type: :shrink_complete,
      original_length: metadata[:original_length],
      shrunk_length: metadata[:shrunk_length],
      iterations: measurements[:iterations],
      duration_ms: div(duration_us, 1000),
      timestamp: now()
    }

    new_state = add_recent_event(new_state, event)
    broadcast(new_state, :shrink_complete, event)
    new_state
  end

  defp handle_telemetry_event(_event_name, _measurements, _metadata, state) do
    state
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp attach_handlers do
    events = [
      [:property_damage, :run, :start],
      [:property_damage, :run, :stop],
      [:property_damage, :run, :exception],
      [:property_damage, :sequence, :start],
      [:property_damage, :sequence, :stop],
      [:property_damage, :command, :start],
      [:property_damage, :command, :stop],
      [:property_damage, :check, :start],
      [:property_damage, :check, :stop],
      [:property_damage, :shrink, :start],
      [:property_damage, :shrink, :iteration],
      [:property_damage, :shrink, :stop]
    ]

    handler_id = "property_damage_collector_#{inspect(self())}"

    :telemetry.attach_many(
      handler_id,
      events,
      &__MODULE__.dispatch_telemetry_event/4,
      %{pid: self()}
    )
  end

  @doc false
  def dispatch_telemetry_event(event_name, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  defp add_recent_event(state, event) do
    recent =
      [event | state.recent_events]
      |> Enum.take(@max_recent_events)

    %{state | recent_events: recent}
  end

  defp broadcast(state, event_type, data) do
    message = {:telemetry_update, event_type, data, sanitize_state(state)}

    for pid <- state.subscribers do
      send(pid, message)
    end

    :ok
  end

  defp sanitize_state(state) do
    %{
      runs: state.runs,
      runs_completed: state.runs_completed,
      runs_failed: state.runs_failed,
      commands_executed: state.commands_executed,
      checks_passed: state.checks_passed,
      checks_failed: state.checks_failed,
      shrink_iterations: state.shrink_iterations,
      total_run_time_ms: div(state.total_run_time, 1000),
      total_command_time_ms: div(state.total_command_time, 1000),
      total_check_time_ms: div(state.total_check_time, 1000),
      total_shrink_time_ms: div(state.total_shrink_time, 1000),
      current_run: state.current_run,
      recent_events: state.recent_events,
      command_stats: sanitize_command_stats(state.command_stats),
      check_stats: state.check_stats,
      uptime_ms: System.system_time(:millisecond) - state.started_at
    }
  end

  defp sanitize_command_stats(stats) do
    Map.new(stats, fn {cmd, data} ->
      avg_time = if data.count > 0, do: div(data.total_time, data.count), else: 0
      {cmd, Map.put(data, :avg_time_us, avg_time)}
    end)
  end

  defp now do
    System.system_time(:millisecond)
  end
end
