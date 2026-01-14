defmodule PropertyDamage.LoadTest.Metrics do
  @moduledoc """
  Collects and aggregates load test metrics.

  Uses ETS for lock-free, concurrent updates from multiple sessions.
  Provides real-time throughput, latency percentiles, and error tracking.

  ## What Gets Measured

  Metrics are **command-centric**, not HTTP-centric:

  - **Request** = one command execution (e.g., `CreateAuthorization`)
  - **Latency** = wall-clock time for the entire command execution

  This means:
  - If `CreateAuthorization` internally does 1 POST + 15 polling GETs,
    that counts as **1 request**, not 16
  - The latency includes the full polling duration, not just the initial call

  Example for an async command with 3-second polling:
  - POST `/authorizations` takes 50ms
  - 15 polling GETs take 3000ms total
  - **Reported**: 1 request with ~3050ms latency

  To measure actual HTTP throughput, use external monitoring (server metrics,
  proxy logs) or add telemetry instrumentation inside your adapter.

  ## Architecture

  - Uses ETS tables for atomic counters and latency samples
  - Reservoir sampling for memory-bounded percentile calculation
  - Per-command breakdown for detailed analysis
  - Time series history for graphing and trend analysis

  ## Usage

      {:ok, metrics} = Metrics.start_link()
      Metrics.record_request(metrics, CreateAccount, 45, :ok)
      Metrics.record_request(metrics, GetBalance, 12, :ok)
      snapshot = Metrics.snapshot(metrics)
  """

  use GenServer

  @reservoir_size 1000
  @history_interval_ms 1000

  defstruct [
    :counters_table,
    :latencies_table,
    :errors_table,
    :command_metrics_table,
    :assertion_failures_table,
    :recent_failures,
    :history,
    :start_time,
    :last_snapshot_time,
    :last_total_requests
  ]

  @type t :: %__MODULE__{}

  @type snapshot :: %{
          total_requests: non_neg_integer(),
          requests_per_second: float(),
          latency_p50: float(),
          latency_p95: float(),
          latency_p99: float(),
          latency_max: float(),
          latency_mean: float(),
          latency_min: float(),
          total_errors: non_neg_integer(),
          error_rate: float(),
          errors_by_type: %{atom() => non_neg_integer()},
          active_sessions: non_neg_integer(),
          completed_sessions: non_neg_integer(),
          by_command: %{module() => command_metrics()},
          duration_ms: non_neg_integer(),
          history: [history_point()],
          assertion_failures: non_neg_integer(),
          assertion_failure_rate: float(),
          failures_by_exception: %{module() => non_neg_integer()},
          recent_assertion_failures: [map()],
          # Arrival metrics
          arrivals_spawned: non_neg_integer(),
          arrivals_completed: non_neg_integer(),
          arrivals_dropped: non_neg_integer(),
          arrivals_per_second: float(),
          drop_rate: float()
        }

  @type command_metrics :: %{
          count: non_neg_integer(),
          latency_p50: float(),
          latency_p95: float(),
          latency_mean: float(),
          error_count: non_neg_integer()
        }

  @type history_point :: %{
          timestamp: integer(),
          rps: float(),
          latency_p95: float(),
          active_sessions: non_neg_integer(),
          error_rate: float()
        }

  # Counter indices
  @total_requests 1
  @total_errors 2
  @active_sessions 3
  @completed_sessions 4
  @assertion_failures 5
  @arrivals_spawned 6
  @arrivals_completed 7
  @arrivals_dropped 8

  # Total counter indices
  @counter_count 8

  # Max recent failures to keep
  @max_recent_failures 100

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a new metrics collector.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stop the metrics collector.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid)
  end

  @doc """
  Record a completed request.

  ## Parameters

  - `pid` - Metrics collector pid
  - `command_module` - The command module that was executed
  - `latency_ms` - Request latency in milliseconds
  - `result` - `:ok` for success, `{:error, type}` for errors
  """
  @spec record_request(pid(), module(), number(), :ok | {:error, atom()}) :: :ok
  def record_request(pid, command_module, latency_ms, result) do
    GenServer.cast(pid, {:record_request, command_module, latency_ms, result})
  end

  @doc """
  Record a session starting.
  """
  @spec session_started(pid()) :: :ok
  def session_started(pid) do
    GenServer.cast(pid, :session_started)
  end

  @doc """
  Record a session completing.
  """
  @spec session_completed(pid()) :: :ok
  def session_completed(pid) do
    GenServer.cast(pid, :session_completed)
  end

  @doc """
  Record an assertion failure.

  ## Parameters

  - `pid` - Metrics collector pid
  - `exception_module` - Module of the exception that was raised
  - `command_module` - The command that was being executed
  - `failure` - Map with failure details (reason, command_index, etc.)
  """
  @spec record_assertion_failure(pid(), module(), module(), map()) :: :ok
  def record_assertion_failure(pid, exception_module, command_module, failure) do
    GenServer.cast(pid, {:record_assertion_failure, exception_module, command_module, failure})
  end

  @doc """
  Record an arrival being spawned.
  """
  @spec arrival_spawned(pid()) :: :ok
  def arrival_spawned(pid) do
    GenServer.cast(pid, :arrival_spawned)
  end

  @doc """
  Record an arrival completing its sequence.
  """
  @spec arrival_completed(pid()) :: :ok
  def arrival_completed(pid) do
    GenServer.cast(pid, :arrival_completed)
  end

  @doc """
  Record an arrival being dropped due to pool exhaustion.
  """
  @spec arrival_dropped(pid()) :: :ok
  def arrival_dropped(pid) do
    GenServer.cast(pid, :arrival_dropped)
  end

  @doc """
  Get a snapshot of current metrics.
  """
  @spec snapshot(pid()) :: snapshot()
  def snapshot(pid) do
    GenServer.call(pid, :snapshot)
  end

  @doc """
  Reset all metrics.
  """
  @spec reset(pid()) :: :ok
  def reset(pid) do
    GenServer.call(pid, :reset)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS tables for concurrent access
    counters_table = :ets.new(:load_test_counters, [:set, :public])
    latencies_table = :ets.new(:load_test_latencies, [:set, :public])
    errors_table = :ets.new(:load_test_errors, [:set, :public])
    command_metrics_table = :ets.new(:load_test_command_metrics, [:set, :public])
    assertion_failures_table = :ets.new(:load_test_assertion_failures, [:set, :public])

    # Initialize counters
    :ets.insert(counters_table, {:counters, :atomics.new(@counter_count, signed: false)})

    now = System.monotonic_time(:millisecond)

    state = %__MODULE__{
      counters_table: counters_table,
      latencies_table: latencies_table,
      errors_table: errors_table,
      command_metrics_table: command_metrics_table,
      assertion_failures_table: assertion_failures_table,
      recent_failures: [],
      history: [],
      start_time: now,
      last_snapshot_time: now,
      last_total_requests: 0
    }

    # Schedule periodic history sampling
    schedule_history_sample()

    {:ok, state}
  end

  @impl true
  def handle_cast({:record_request, command_module, latency_ms, result}, state) do
    counters = get_counters(state.counters_table)

    # Increment request count
    :atomics.add(counters, @total_requests, 1)

    # Record latency using reservoir sampling
    record_latency(state.latencies_table, latency_ms)

    # Record per-command metrics
    record_command_metrics(state.command_metrics_table, command_module, latency_ms, result)

    # Handle errors
    case result do
      {:error, error_type} ->
        :atomics.add(counters, @total_errors, 1)
        increment_error_type(state.errors_table, error_type)

      :ok ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:session_started, state) do
    counters = get_counters(state.counters_table)
    :atomics.add(counters, @active_sessions, 1)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:session_completed, state) do
    counters = get_counters(state.counters_table)
    :atomics.sub(counters, @active_sessions, 1)
    :atomics.add(counters, @completed_sessions, 1)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_assertion_failure, exception_module, command_module, failure}, state) do
    counters = get_counters(state.counters_table)

    # Increment assertion failure count
    :atomics.add(counters, @assertion_failures, 1)

    # Track by exception module
    increment_assertion_failure(state.assertion_failures_table, exception_module)

    # Add to recent failures (bounded)
    failure_record =
      Map.merge(failure, %{
        exception_module: exception_module,
        command_module: command_module,
        recorded_at: System.monotonic_time(:millisecond)
      })

    recent = [failure_record | state.recent_failures]
    recent = Enum.take(recent, @max_recent_failures)

    {:noreply, %{state | recent_failures: recent}}
  end

  @impl true
  def handle_cast(:arrival_spawned, state) do
    counters = get_counters(state.counters_table)
    :atomics.add(counters, @arrivals_spawned, 1)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:arrival_completed, state) do
    counters = get_counters(state.counters_table)
    :atomics.add(counters, @arrivals_completed, 1)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:arrival_dropped, state) do
    counters = get_counters(state.counters_table)
    :atomics.add(counters, @arrivals_dropped, 1)
    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snapshot = build_snapshot(state)
    {:reply, snapshot, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # Clear all tables
    :ets.delete_all_objects(state.latencies_table)
    :ets.delete_all_objects(state.errors_table)
    :ets.delete_all_objects(state.command_metrics_table)
    :ets.delete_all_objects(state.assertion_failures_table)

    # Reset counters
    counters = get_counters(state.counters_table)

    for i <- 1..@counter_count do
      :atomics.put(counters, i, 0)
    end

    now = System.monotonic_time(:millisecond)

    new_state = %{
      state
      | history: [],
        recent_failures: [],
        start_time: now,
        last_snapshot_time: now,
        last_total_requests: 0
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:sample_history, state) do
    new_state = sample_history_point(state)
    schedule_history_sample()
    {:noreply, new_state}
  end

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.counters_table)
    :ets.delete(state.latencies_table)
    :ets.delete(state.errors_table)
    :ets.delete(state.command_metrics_table)
    :ets.delete(state.assertion_failures_table)
    :ok
  end

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  defp get_counters(table) do
    [{:counters, counters}] = :ets.lookup(table, :counters)
    counters
  end

  defp record_latency(table, latency_ms) do
    # Use reservoir sampling for bounded memory
    key = :rand.uniform(@reservoir_size)
    :ets.insert(table, {key, latency_ms})
  end

  defp record_command_metrics(table, command_module, latency_ms, result) do
    # Get or create command entry
    key = command_module

    case :ets.lookup(table, key) do
      [] ->
        # Initialize new command metrics
        is_error = match?({:error, _}, result)

        entry = %{
          count: 1,
          latencies: [latency_ms],
          error_count: if(is_error, do: 1, else: 0)
        }

        :ets.insert(table, {key, entry})

      [{^key, existing}] ->
        # Update existing - keep bounded latency samples
        is_error = match?({:error, _}, result)

        latencies =
          if length(existing.latencies) >= 100 do
            # Use reservoir sampling
            idx = :rand.uniform(100)
            List.replace_at(existing.latencies, idx - 1, latency_ms)
          else
            [latency_ms | existing.latencies]
          end

        updated = %{
          existing
          | count: existing.count + 1,
            latencies: latencies,
            error_count: existing.error_count + if(is_error, do: 1, else: 0)
        }

        :ets.insert(table, {key, updated})
    end
  end

  defp increment_error_type(table, error_type) do
    case :ets.lookup(table, error_type) do
      [] ->
        :ets.insert(table, {error_type, 1})

      [{^error_type, count}] ->
        :ets.insert(table, {error_type, count + 1})
    end
  end

  defp increment_assertion_failure(table, exception_module) do
    case :ets.lookup(table, exception_module) do
      [] ->
        :ets.insert(table, {exception_module, 1})

      [{^exception_module, count}] ->
        :ets.insert(table, {exception_module, count + 1})
    end
  end

  defp schedule_history_sample do
    Process.send_after(self(), :sample_history, @history_interval_ms)
  end

  defp sample_history_point(state) do
    counters = get_counters(state.counters_table)
    now = System.monotonic_time(:millisecond)

    total_requests = :atomics.get(counters, @total_requests)
    total_errors = :atomics.get(counters, @total_errors)
    active_sessions = :atomics.get(counters, @active_sessions)

    # Calculate RPS since last sample
    elapsed_ms = now - state.last_snapshot_time
    requests_since_last = total_requests - state.last_total_requests

    rps =
      if elapsed_ms > 0 do
        requests_since_last / (elapsed_ms / 1000.0)
      else
        0.0
      end

    # Get current p95
    latencies = get_all_latencies(state.latencies_table)
    latency_p95 = percentile(latencies, 95)

    # Error rate
    error_rate =
      if total_requests > 0 do
        total_errors / total_requests * 100.0
      else
        0.0
      end

    point = %{
      timestamp: now,
      rps: rps,
      latency_p95: latency_p95,
      active_sessions: active_sessions,
      error_rate: error_rate
    }

    # Keep last 300 points (5 minutes at 1s intervals)
    history = Enum.take([point | state.history], 300)

    %{state | history: history, last_snapshot_time: now, last_total_requests: total_requests}
  end

  defp build_snapshot(state) do
    counters = get_counters(state.counters_table)
    now = System.monotonic_time(:millisecond)

    total_requests = :atomics.get(counters, @total_requests)
    total_errors = :atomics.get(counters, @total_errors)
    active_sessions = :atomics.get(counters, @active_sessions)
    completed_sessions = :atomics.get(counters, @completed_sessions)

    duration_ms = now - state.start_time

    # Calculate RPS
    rps =
      if duration_ms > 0 do
        total_requests / (duration_ms / 1000.0)
      else
        0.0
      end

    # Get latency stats
    latencies = get_all_latencies(state.latencies_table)

    latency_stats =
      if Enum.empty?(latencies) do
        %{p50: 0.0, p95: 0.0, p99: 0.0, max: 0.0, min: 0.0, mean: 0.0}
      else
        %{
          p50: percentile(latencies, 50),
          p95: percentile(latencies, 95),
          p99: percentile(latencies, 99),
          max: Enum.max(latencies),
          min: Enum.min(latencies),
          mean: Enum.sum(latencies) / length(latencies)
        }
      end

    # Error rate
    error_rate =
      if total_requests > 0 do
        total_errors / total_requests * 100.0
      else
        0.0
      end

    # Errors by type
    errors_by_type =
      :ets.tab2list(state.errors_table)
      |> Map.new()

    # Per-command metrics
    by_command =
      :ets.tab2list(state.command_metrics_table)
      |> Enum.map(fn {module, data} ->
        cmd_latencies = data.latencies

        cmd_stats =
          if Enum.empty?(cmd_latencies) do
            %{p50: 0.0, p95: 0.0, mean: 0.0}
          else
            %{
              p50: percentile(cmd_latencies, 50),
              p95: percentile(cmd_latencies, 95),
              mean: Enum.sum(cmd_latencies) / length(cmd_latencies)
            }
          end

        {module,
         %{
           count: data.count,
           latency_p50: cmd_stats.p50,
           latency_p95: cmd_stats.p95,
           latency_mean: cmd_stats.mean,
           error_count: data.error_count
         }}
      end)
      |> Map.new()

    # Assertion failure stats
    assertion_failures = :atomics.get(counters, @assertion_failures)

    assertion_failure_rate =
      if total_requests > 0 do
        assertion_failures / total_requests * 100.0
      else
        0.0
      end

    failures_by_exception =
      :ets.tab2list(state.assertion_failures_table)
      |> Map.new()

    # Arrival stats
    arrivals_spawned = :atomics.get(counters, @arrivals_spawned)
    arrivals_completed = :atomics.get(counters, @arrivals_completed)
    arrivals_dropped = :atomics.get(counters, @arrivals_dropped)

    arrivals_per_second =
      if duration_ms > 0 do
        arrivals_spawned / (duration_ms / 1000.0)
      else
        0.0
      end

    drop_rate =
      if arrivals_spawned > 0 do
        arrivals_dropped / arrivals_spawned * 100.0
      else
        0.0
      end

    %{
      total_requests: total_requests,
      requests_per_second: rps,
      latency_p50: latency_stats.p50,
      latency_p95: latency_stats.p95,
      latency_p99: latency_stats.p99,
      latency_max: latency_stats.max,
      latency_min: latency_stats.min,
      latency_mean: latency_stats.mean,
      total_errors: total_errors,
      error_rate: error_rate,
      errors_by_type: errors_by_type,
      active_sessions: active_sessions,
      completed_sessions: completed_sessions,
      by_command: by_command,
      duration_ms: duration_ms,
      history: Enum.reverse(state.history),
      assertion_failures: assertion_failures,
      assertion_failure_rate: assertion_failure_rate,
      failures_by_exception: failures_by_exception,
      recent_assertion_failures: Enum.reverse(state.recent_failures),
      # Arrival metrics
      arrivals_spawned: arrivals_spawned,
      arrivals_completed: arrivals_completed,
      arrivals_dropped: arrivals_dropped,
      arrivals_per_second: arrivals_per_second,
      drop_rate: drop_rate
    }
  end

  defp get_all_latencies(table) do
    :ets.tab2list(table)
    |> Enum.map(fn {_key, latency} -> latency end)
  end

  defp percentile([], _p), do: 0.0

  defp percentile(list, p) when p >= 0 and p <= 100 do
    sorted = Enum.sort(list)
    n = length(sorted)
    rank = p / 100.0 * (n - 1)
    lower_index = trunc(rank)
    upper_index = min(lower_index + 1, n - 1)
    fraction = rank - lower_index

    lower_value = Enum.at(sorted, lower_index)
    upper_value = Enum.at(sorted, upper_index)

    lower_value + fraction * (upper_value - lower_value)
  end
end
