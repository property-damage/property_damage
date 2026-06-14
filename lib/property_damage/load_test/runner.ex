defmodule PropertyDamage.LoadTest.Runner do
  @moduledoc """
  Orchestrates a load test run using arrival rate scheduling.

  The Runner manages:
  - Worker pool with persistent adapter contexts
  - Arrival scheduling at the configured rate
  - Rate ramping up and down
  - Metrics collection and periodic reporting
  - Duration-based termination

  ## Architecture

  ```
  Runner (GenServer)
    ├── Metrics (GenServer) - Collects metrics from all workers
    ├── WorkerPool (GenServer) - Manages workers with persistent contexts
    │   ├── Worker 1 - Holds adapter context
    │   ├── Worker 2
    │   └── Worker N
    └── Arrivals (Tasks) - Spawned at configured rate
  ```

  ## Usage

      {:ok, runner} = Runner.start_link(
        model: MyModel,
        adapter: HTTPAdapter,
        adapter_config: %{base_url: "http://localhost:4000"},
        arrival_rate: 100,  # 100 arrivals per second
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

  alias PropertyDamage.LoadTest.{Metrics, RampStrategy, Worker, WorkerPool}
  alias PropertyDamage.Options

  defstruct [
    :model,
    :adapter,
    :adapter_config,
    :arrival_rate,
    :arrival_jitter,
    :current_rate,
    :duration_ms,
    :ramp_up_plan,
    :ramp_down_plan,
    :think_time_range,
    :metrics_interval_ms,
    :on_metrics,
    :on_complete,
    :metrics,
    :pool,
    :start_time,
    :phase,
    :ramp_step_index,
    :awaiting,
    :assertion_mode,
    :in_flight
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
  - `:arrival_rate` - Target arrival rate (required)
    - Integer: arrivals per second (e.g., `100`)
    - Tuple: `{count, {time, unit}}` (e.g., `{2, {15, :milliseconds}}`)
  - `:duration` - Test duration as `{value, unit}` (required)
  - `:arrival_jitter` - {min, max} ms jitter per arrival (default: {0, 0})
  - `:ramp_up` - Ramp-up strategy (default: :immediate)
  - `:ramp_down` - Ramp-down strategy (default: :immediate)
  - `:think_time` - {min, max} ms between commands in sequence (default: {0, 0})
  - `:metrics_interval` - Metrics callback interval (default: {1, :second})
  - `:on_metrics` - Callback function for periodic metrics
  - `:on_complete` - Callback function when test completes
  - `:assertion_mode` - How to handle assertions (default: :disabled)
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
    # Validate options with NimbleOptions
    opts = Options.validate_load_test!(opts)

    model = opts[:model]
    adapter = opts[:adapter]
    adapter_config = opts[:adapter_config]
    arrival_rate = opts[:arrival_rate]
    arrival_jitter = opts[:arrival_jitter]
    duration = opts[:duration]
    ramp_up = opts[:ramp_up]
    ramp_down = opts[:ramp_down]
    think_time_range = opts[:think_time]
    metrics_interval = opts[:metrics_interval]
    on_metrics = opts[:on_metrics]
    on_complete = opts[:on_complete]
    assertion_mode = opts[:assertion_mode]

    # Start metrics collector
    {:ok, metrics} = Metrics.start_link()

    # Start dynamic worker pool (no size configuration needed)
    case WorkerPool.start_link(
           model: model,
           adapter: adapter,
           adapter_config: adapter_config,
           metrics: metrics,
           think_time_range: think_time_range,
           assertion_mode: assertion_mode
         ) do
      {:ok, pool} ->
        # Build ramp plans
        ramp_up_plan = RampStrategy.plan(ramp_up, arrival_rate)
        ramp_down_plan = RampStrategy.plan_down(ramp_down, arrival_rate)

        duration_ms = duration_to_ms(duration)
        metrics_interval_ms = duration_to_ms(metrics_interval)

        state = %__MODULE__{
          model: model,
          adapter: adapter,
          adapter_config: adapter_config,
          arrival_rate: arrival_rate,
          arrival_jitter: arrival_jitter,
          current_rate: {1, {1, :seconds}},
          duration_ms: duration_ms,
          ramp_up_plan: ramp_up_plan,
          ramp_down_plan: ramp_down_plan,
          think_time_range: think_time_range,
          metrics_interval_ms: metrics_interval_ms,
          on_metrics: on_metrics,
          on_complete: on_complete,
          metrics: metrics,
          pool: pool,
          start_time: System.monotonic_time(:millisecond),
          phase: :ramp_up,
          ramp_step_index: 0,
          awaiting: nil,
          assertion_mode: assertion_mode,
          in_flight: MapSet.new()
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

      {:error, reason} ->
        Metrics.stop(metrics)
        {:stop, {:pool_start_failed, reason}}
    end
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
    pool_stats = WorkerPool.stats(state.pool)

    status = %{
      phase: state.phase,
      current_rate: state.current_rate,
      target_rate: state.arrival_rate,
      pool_utilization: pool_stats.utilization,
      workers_created: pool_stats.total_created,
      peak_workers: pool_stats.peak_in_use,
      in_flight: MapSet.size(state.in_flight),
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
      {time_ms, rate} = Enum.at(plan, state.ramp_step_index)
      new_state = %{state | current_rate: rate}

      # Only start arrival chain on FIRST step - subsequent steps just update the rate
      # The chain self-perpetuates via schedule_next_arrival in :schedule_arrival handler
      if state.ramp_step_index == 0 do
        schedule_next_arrival(new_state)
      end

      # Schedule next step
      next_index = state.ramp_step_index + 1

      if next_index < length(plan) do
        {next_time_ms, _} = Enum.at(plan, next_index)
        delay = next_time_ms - time_ms
        Process.send_after(self(), :execute_ramp_step, delay)
      end

      {:noreply, %{new_state | ramp_step_index: next_index}}
    end
  end

  @impl true
  def handle_info(:execute_ramp_step, %{phase: :ramp_down} = state) do
    plan = state.ramp_down_plan

    if state.ramp_step_index >= length(plan) do
      # Ramp-down complete - wait for in-flight to drain
      if MapSet.size(state.in_flight) == 0 do
        report = finish_test(state)

        if state.awaiting do
          GenServer.reply(state.awaiting, {:ok, report})
        end

        {:stop, :normal, %{state | phase: :finished}}
      else
        # Wait for in-flight to complete
        Process.send_after(self(), :check_drain, 100)
        {:noreply, %{state | phase: :draining}}
      end
    else
      {time_ms, rate} = Enum.at(plan, state.ramp_step_index)
      new_state = %{state | current_rate: rate}

      # Schedule next step
      next_index = state.ramp_step_index + 1

      if next_index < length(plan) do
        {next_time_ms, _} = Enum.at(plan, next_index)
        delay = next_time_ms - time_ms
        Process.send_after(self(), :execute_ramp_step, delay)
      else
        # Schedule one more to trigger completion check
        Process.send_after(self(), :execute_ramp_step, 0)
      end

      {:noreply, %{new_state | ramp_step_index: next_index}}
    end
  end

  @impl true
  def handle_info(:execute_ramp_step, state) do
    # In steady phase, no ramping needed
    {:noreply, state}
  end

  @impl true
  def handle_info(:schedule_arrival, state) when state.phase in [:ramp_up, :steady] do
    # Spawn an arrival
    new_state = spawn_arrival(state)

    # Schedule next arrival
    schedule_next_arrival(new_state)

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:schedule_arrival, %{phase: :ramp_down} = state) do
    # Still spawn arrivals during ramp-down but at reduced rate
    new_state = spawn_arrival(state)
    schedule_next_arrival(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:schedule_arrival, state) do
    # In draining or finished phase, don't spawn new arrivals
    {:noreply, state}
  end

  @impl true
  def handle_info({:arrival_completed, ref, _result}, state) do
    new_in_flight = MapSet.delete(state.in_flight, ref)
    Metrics.arrival_completed(state.metrics)
    {:noreply, %{state | in_flight: new_in_flight}}
  end

  @impl true
  def handle_info(:check_drain, %{phase: :draining} = state) do
    if MapSet.size(state.in_flight) == 0 do
      report = finish_test(state)

      if state.awaiting do
        GenServer.reply(state.awaiting, {:ok, report})
      end

      {:stop, :normal, %{state | phase: :finished}}
    else
      # Still waiting for in-flight
      Process.send_after(self(), :check_drain, 100)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:check_drain, state) do
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

      state.phase == :draining ->
        {:noreply, state}

      elapsed_ms >= state.duration_ms and state.phase not in [:ramp_down, :draining] ->
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
  def terminate(_reason, state) do
    # Stop worker pool
    if state.pool do
      WorkerPool.stop(state.pool)
    end

    # Stop metrics
    if state.metrics do
      Metrics.stop(state.metrics)
    end

    :ok
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp spawn_arrival(state) do
    runner_pid = self()
    ref = make_ref()

    # Checkout a worker (dynamic pool - always succeeds or creates new worker)
    case WorkerPool.checkout(state.pool) do
      {:ok, worker} ->
        Metrics.arrival_spawned(state.metrics)

        # Execute sequence in a task
        Task.start(fn ->
          result = Worker.execute_sequence(worker)
          WorkerPool.checkin(state.pool, worker)
          send(runner_pid, {:arrival_completed, ref, result})
        end)

        %{state | in_flight: MapSet.put(state.in_flight, ref)}

      {:error, reason} ->
        # Worker creation failed (rare - e.g., adapter.setup failed)
        Logger.warning("Failed to create worker for arrival: #{inspect(reason)}")
        state
    end
  end

  defp schedule_next_arrival(state) do
    interval_ms = RampStrategy.rate_to_interval_ms(state.current_rate)

    # Apply jitter
    {min_jitter, max_jitter} = state.arrival_jitter

    jitter =
      if max_jitter > min_jitter do
        :rand.uniform(max_jitter - min_jitter + 1) + min_jitter - 1
      else
        0
      end

    delay = round(interval_ms) + jitter
    delay = max(delay, 1)

    Process.send_after(self(), :schedule_arrival, delay)
  end

  defp finish_test(state) do
    # Get final metrics
    snapshot = Metrics.snapshot(state.metrics)
    pool_stats = WorkerPool.stats(state.pool)

    report = %{
      metrics: snapshot,
      pool_stats: pool_stats,
      config: %{
        model: state.model,
        adapter: state.adapter,
        arrival_rate: state.arrival_rate,
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
  defp duration_to_ms({value, :hours}), do: value * 60 * 60 * 1000
end
