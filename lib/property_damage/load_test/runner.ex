defmodule PropertyDamage.LoadTest.Runner do
  @moduledoc """
  Orchestrates a load test run.

  The Runner manages:
  - Starting/stopping sessions according to the ramp strategy
  - Metrics collection and periodic reporting
  - Duration-based termination
  - Graceful shutdown

  ## Architecture

  ```
  Runner (GenServer)
    ├── Metrics (GenServer) - Collects metrics from all sessions
    ├── Session 1 (GenServer) - Individual user session
    ├── Session 2 (GenServer)
    └── Session N (GenServer)
  ```

  ## Usage

      {:ok, runner} = Runner.start_link(
        model: MyModel,
        adapter: HTTPAdapter,
        adapter_config: %{base_url: "http://localhost:4000"},
        concurrent_users: 100,
        duration: {5, :minutes},
        ramp_up: {:linear, {30, :seconds}}
      )

      # Wait for completion
      {:ok, report} = Runner.await(runner)

      # Or stop early
      {:ok, report} = Runner.stop(runner)
  """

  use GenServer

  require Logger

  alias PropertyDamage.LoadTest.{Metrics, Session, RampStrategy}

  defstruct [
    :model,
    :adapter,
    :adapter_config,
    :target_users,
    :duration_ms,
    :ramp_up_plan,
    :ramp_down_plan,
    :commands_range,
    :think_time_range,
    :metrics_interval_ms,
    :on_metrics,
    :on_complete,
    :metrics,
    :sessions,
    :start_time,
    :phase,
    :ramp_step_index,
    :awaiting
  ]

  @type t :: %__MODULE__{}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a new load test run.

  ## Options

  - `:model` - Model module (required)
  - `:adapter` - Adapter module (required)
  - `:adapter_config` - Adapter configuration (default: %{})
  - `:concurrent_users` - Target number of concurrent users (required)
  - `:duration` - Test duration as `{value, unit}` (required)
  - `:ramp_up` - Ramp-up strategy (default: :immediate)
  - `:ramp_down` - Ramp-down strategy (default: :immediate)
  - `:commands_per_session` - {min, max} commands per sequence (default: {10, 50})
  - `:think_time` - {min, max} ms between commands (default: {0, 0})
  - `:metrics_interval` - Metrics callback interval (default: {1, :second})
  - `:on_metrics` - Callback function for periodic metrics
  - `:on_complete` - Callback function when test completes
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Wait for the load test to complete.

  Returns the final report when the test finishes.
  """
  @spec await(pid(), timeout()) :: {:ok, map()} | {:error, term()}
  def await(pid, timeout \\ :infinity) do
    GenServer.call(pid, :await, timeout)
  end

  @doc """
  Stop a load test early and get the report.
  """
  @spec stop(pid()) :: {:ok, map()}
  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  @doc """
  Get current metrics snapshot.
  """
  @spec get_metrics(pid()) :: map()
  def get_metrics(pid) do
    GenServer.call(pid, :get_metrics)
  end

  @doc """
  Get current status.
  """
  @spec status(pid()) :: map()
  def status(pid) do
    GenServer.call(pid, :status)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    target_users = Keyword.fetch!(opts, :concurrent_users)
    duration = Keyword.fetch!(opts, :duration)
    ramp_up = Keyword.get(opts, :ramp_up, :immediate)
    ramp_down = Keyword.get(opts, :ramp_down, :immediate)
    commands_range = Keyword.get(opts, :commands_per_session, {10, 50})
    think_time_range = Keyword.get(opts, :think_time, {0, 0})
    metrics_interval = Keyword.get(opts, :metrics_interval, {1, :seconds})
    on_metrics = Keyword.get(opts, :on_metrics)
    on_complete = Keyword.get(opts, :on_complete)

    # Start metrics collector
    {:ok, metrics} = Metrics.start_link()

    # Build ramp plans
    ramp_up_plan = RampStrategy.plan(ramp_up, target_users)
    ramp_down_plan = RampStrategy.plan_down(ramp_down, target_users)

    duration_ms = duration_to_ms(duration)
    metrics_interval_ms = duration_to_ms(metrics_interval)

    state = %__MODULE__{
      model: model,
      adapter: adapter,
      adapter_config: adapter_config,
      target_users: target_users,
      duration_ms: duration_ms,
      ramp_up_plan: ramp_up_plan,
      ramp_down_plan: ramp_down_plan,
      commands_range: commands_range,
      think_time_range: think_time_range,
      metrics_interval_ms: metrics_interval_ms,
      on_metrics: on_metrics,
      on_complete: on_complete,
      metrics: metrics,
      sessions: %{},
      start_time: System.monotonic_time(:millisecond),
      phase: :ramp_up,
      ramp_step_index: 0,
      awaiting: nil
    }

    # Schedule first ramp step
    send(self(), :execute_ramp_step)

    # Schedule metrics reporting
    if on_metrics do
      schedule_metrics_report(metrics_interval_ms)
    end

    # Schedule duration check
    schedule_duration_check(1000)

    {:ok, state}
  end

  @impl true
  def handle_call(:await, from, state) do
    {:noreply, %{state | awaiting: from}}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    report = finish_test(state)
    {:stop, :normal, {:ok, report}, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    snapshot = Metrics.snapshot(state.metrics)
    {:reply, snapshot, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.start_time

    status = %{
      phase: state.phase,
      active_sessions: map_size(state.sessions),
      target_users: state.target_users,
      elapsed_ms: elapsed_ms,
      duration_ms: state.duration_ms,
      progress_percent: min(100.0, elapsed_ms / state.duration_ms * 100.0)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:execute_ramp_step, %{phase: :ramp_up} = state) do
    plan = state.ramp_up_plan

    if state.ramp_step_index >= length(plan) do
      # Ramp-up complete, enter steady state
      {:noreply, %{state | phase: :steady}}
    else
      {time_ms, target} = Enum.at(plan, state.ramp_step_index)
      current = map_size(state.sessions)
      delta = target - current

      new_sessions =
        if delta > 0 do
          add_sessions(state, delta)
        else
          state.sessions
        end

      # Schedule next step
      next_index = state.ramp_step_index + 1

      if next_index < length(plan) do
        {next_time_ms, _} = Enum.at(plan, next_index)
        delay = next_time_ms - time_ms
        Process.send_after(self(), :execute_ramp_step, delay)
      end

      {:noreply, %{state | sessions: new_sessions, ramp_step_index: next_index}}
    end
  end

  @impl true
  def handle_info(:execute_ramp_step, %{phase: :ramp_down} = state) do
    plan = state.ramp_down_plan

    if state.ramp_step_index >= length(plan) do
      # Ramp-down complete
      _report = finish_test(state)
      {:stop, :normal, state}
    else
      {time_ms, target} = Enum.at(plan, state.ramp_step_index)
      current = map_size(state.sessions)
      delta = current - target

      new_sessions =
        if delta > 0 do
          remove_sessions(state, delta)
        else
          state.sessions
        end

      # Schedule next step
      next_index = state.ramp_step_index + 1

      if next_index < length(plan) do
        {next_time_ms, _} = Enum.at(plan, next_index)
        delay = next_time_ms - time_ms
        Process.send_after(self(), :execute_ramp_step, delay)
        {:noreply, %{state | sessions: new_sessions, ramp_step_index: next_index}}
      else
        # Last step - finish test
        report = finish_test(%{state | sessions: new_sessions})

        if state.awaiting do
          GenServer.reply(state.awaiting, {:ok, report})
        end

        {:stop, :normal, %{state | sessions: new_sessions, ramp_step_index: next_index, phase: :finished}}
      end
    end
  end

  @impl true
  def handle_info(:execute_ramp_step, state) do
    # In steady phase, no ramping needed
    {:noreply, state}
  end

  @impl true
  def handle_info(:report_metrics, state) do
    if state.on_metrics != nil and state.phase != :finished do
      snapshot = Metrics.snapshot(state.metrics)
      state.on_metrics.(snapshot)
      schedule_metrics_report(state.metrics_interval_ms)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:check_duration, state) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.start_time

    cond do
      state.phase == :finished ->
        {:noreply, state}

      elapsed_ms >= state.duration_ms and state.phase != :ramp_down ->
        # Duration reached, start ramp-down
        Logger.info("Load test duration reached, starting ramp-down")
        new_state = %{state | phase: :ramp_down, ramp_step_index: 0}
        send(self(), :execute_ramp_step)
        {:noreply, new_state}

      true ->
        schedule_duration_check(1000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # A session died - remove it from tracking
    session_id = find_session_id(state.sessions, pid)

    if session_id do
      new_sessions = Map.delete(state.sessions, session_id)
      {:noreply, %{state | sessions: new_sessions}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Stop all sessions
    for {_id, pid} <- state.sessions do
      try do
        Session.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    # Stop metrics
    Metrics.stop(state.metrics)

    :ok
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp add_sessions(state, count) do
    next_id = (Map.keys(state.sessions) |> Enum.max(fn -> 0 end)) + 1

    Enum.reduce(1..count, state.sessions, fn i, sessions ->
      session_id = next_id + i - 1

      {:ok, pid} =
        Session.start_link(
          model: state.model,
          adapter: state.adapter,
          adapter_config: state.adapter_config,
          metrics: state.metrics,
          session_id: session_id,
          commands_range: state.commands_range,
          think_time_range: state.think_time_range
        )

      # Monitor the session
      Process.monitor(pid)

      Map.put(sessions, session_id, pid)
    end)
  end

  defp remove_sessions(state, count) do
    # Remove oldest sessions first
    session_ids =
      state.sessions
      |> Map.keys()
      |> Enum.sort()
      |> Enum.take(count)

    Enum.reduce(session_ids, state.sessions, fn id, sessions ->
      pid = Map.get(sessions, id)

      if pid do
        try do
          Session.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      Map.delete(sessions, id)
    end)
  end

  defp find_session_id(sessions, pid) do
    sessions
    |> Enum.find(fn {_id, session_pid} -> session_pid == pid end)
    |> case do
      {id, _} -> id
      nil -> nil
    end
  end

  defp finish_test(state) do
    # Stop all sessions
    for {_id, pid} <- state.sessions do
      try do
        Session.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    # Get final metrics
    snapshot = Metrics.snapshot(state.metrics)

    report = %{
      metrics: snapshot,
      config: %{
        model: state.model,
        adapter: state.adapter,
        concurrent_users: state.target_users,
        duration_ms: state.duration_ms
      }
    }

    if state.on_complete do
      state.on_complete.(report)
    end

    report
  end

  defp schedule_metrics_report(interval_ms) do
    Process.send_after(self(), :report_metrics, interval_ms)
  end

  defp schedule_duration_check(interval_ms) do
    Process.send_after(self(), :check_duration, interval_ms)
  end

  defp duration_to_ms({value, :milliseconds}), do: value
  defp duration_to_ms({value, :seconds}), do: value * 1000
  defp duration_to_ms({value, :minutes}), do: value * 60 * 1000
end
