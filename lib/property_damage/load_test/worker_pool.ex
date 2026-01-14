defmodule PropertyDamage.LoadTest.WorkerPool do
  @moduledoc """
  Pool of workers with persistent adapter contexts for load testing.

  The WorkerPool manages a fixed number of Worker processes, each holding
  a persistent adapter context. Arrivals check out workers, execute sequences,
  and check workers back in for reuse.

  ## Features

  - **Persistent contexts**: Workers call `adapter.setup/1` once at pool init
  - **Bounded queue**: When pool exhausted, arrivals queue up to `max_queue_size`
  - **Load shedding**: Excess arrivals beyond queue capacity are dropped
  - **Stats tracking**: Pool utilization, queue depth, checkout latency

  ## Usage

      {:ok, pool} = WorkerPool.start_link(
        size: 50,
        max_queue_size: 100,
        model: MyModel,
        adapter: HTTPAdapter,
        adapter_config: %{base_url: "http://localhost:4000"},
        metrics: metrics_pid,
        think_time_range: {50, 200},
        assertion_mode: :disabled
      )

      # Check out a worker (blocks if pool empty, queue has room)
      case WorkerPool.checkout(pool) do
        {:ok, worker} ->
          Worker.execute_sequence(worker)
          WorkerPool.checkin(pool, worker)

        {:error, :pool_exhausted} ->
          # Queue full, arrival was dropped
          :dropped
      end

      WorkerPool.stop(pool)
  """

  use GenServer

  require Logger

  alias PropertyDamage.LoadTest.Worker

  defstruct [
    # Configuration
    :size,
    :max_queue_size,
    :model,
    :adapter,
    :adapter_config,
    :metrics,
    :think_time_range,
    :assertion_mode,
    # Pool state
    :available,
    :in_use,
    :waiting,
    # Stats
    :total_checkouts,
    :total_checkins,
    :total_dropped,
    :total_queue_time_ms,
    # Utilization tracking
    :peak_in_use,
    :utilization_samples,
    :utilization_sum
  ]

  @type t :: %__MODULE__{}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a new worker pool.

  ## Options

  - `:size` - Number of workers in the pool (required)
  - `:max_queue_size` - Maximum pending arrivals to queue (default: size * 2)
  - `:model` - Model module (required)
  - `:adapter` - Adapter module (required)
  - `:adapter_config` - Adapter configuration (default: %{})
  - `:metrics` - Metrics collector pid (required)
  - `:think_time_range` - {min, max} ms between commands (default: {0, 0})
  - `:assertion_mode` - How to handle assertions (default: :disabled)

  Returns `{:ok, pid}` or `{:error, reason}` if worker setup fails.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Check out a worker from the pool.

  - If a worker is available, returns `{:ok, worker_pid}` immediately
  - If pool is exhausted but queue has room, blocks until a worker is available
  - If pool is exhausted and queue is full, returns `{:error, :pool_exhausted}`

  ## Options

  - `:timeout` - Maximum time to wait in queue (default: 5000ms)
  """
  @spec checkout(pid(), keyword()) :: {:ok, pid()} | {:error, :pool_exhausted | :timeout}
  def checkout(pool, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    GenServer.call(pool, {:checkout, timeout}, timeout + 1000)
  end

  @doc """
  Return a worker to the pool.
  """
  @spec checkin(pid(), pid()) :: :ok
  def checkin(pool, worker) do
    GenServer.cast(pool, {:checkin, worker})
  end

  @doc """
  Get pool statistics.
  """
  @spec stats(pid()) :: map()
  def stats(pool) do
    GenServer.call(pool, :stats)
  end

  @doc """
  Stop the pool and all workers.
  """
  @spec stop(pid()) :: :ok
  def stop(pool) do
    GenServer.stop(pool, :normal)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    size = Keyword.fetch!(opts, :size)
    max_queue_size = Keyword.get(opts, :max_queue_size, size * 2)
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    metrics = Keyword.fetch!(opts, :metrics)
    think_time_range = Keyword.get(opts, :think_time_range, {0, 0})
    assertion_mode = Keyword.get(opts, :assertion_mode, :disabled)

    state = %__MODULE__{
      size: size,
      max_queue_size: max_queue_size,
      model: model,
      adapter: adapter,
      adapter_config: adapter_config,
      metrics: metrics,
      think_time_range: think_time_range,
      assertion_mode: assertion_mode,
      available: :queue.new(),
      in_use: MapSet.new(),
      waiting: :queue.new(),
      total_checkouts: 0,
      total_checkins: 0,
      total_dropped: 0,
      total_queue_time_ms: 0,
      peak_in_use: 0,
      utilization_samples: 0,
      utilization_sum: 0.0
    }

    # Start workers
    case start_workers(state) do
      {:ok, workers} ->
        available = Enum.reduce(workers, :queue.new(), &:queue.in/2)
        {:ok, %{state | available: available}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:checkout, timeout}, from, state) do
    checkout_start = System.monotonic_time(:millisecond)

    case :queue.out(state.available) do
      {{:value, worker}, rest} ->
        # Worker available immediately
        new_in_use = MapSet.put(state.in_use, worker)
        in_use_count = MapSet.size(new_in_use)
        utilization = in_use_count / max(state.size, 1)

        new_state = %{
          state
          | available: rest,
            in_use: new_in_use,
            total_checkouts: state.total_checkouts + 1,
            peak_in_use: max(state.peak_in_use, in_use_count),
            utilization_samples: state.utilization_samples + 1,
            utilization_sum: state.utilization_sum + utilization
        }

        {:reply, {:ok, worker}, new_state}

      {:empty, _} ->
        # Pool exhausted - check if we can queue
        queue_size = :queue.len(state.waiting)

        if queue_size < state.max_queue_size do
          # Add to waiting queue
          waiter = {from, checkout_start, timeout}
          new_waiting = :queue.in(waiter, state.waiting)

          # Schedule timeout check
          Process.send_after(self(), {:checkout_timeout, from}, timeout)

          # Pool is at 100% utilization when queueing
          new_state = %{
            state
            | waiting: new_waiting,
              peak_in_use: max(state.peak_in_use, state.size),
              utilization_samples: state.utilization_samples + 1,
              utilization_sum: state.utilization_sum + 1.0
          }

          {:noreply, new_state}
        else
          # Queue full - drop the arrival (also 100% utilization)
          new_state = %{
            state
            | total_dropped: state.total_dropped + 1,
              peak_in_use: max(state.peak_in_use, state.size),
              utilization_samples: state.utilization_samples + 1,
              utilization_sum: state.utilization_sum + 1.0
          }

          {:reply, {:error, :pool_exhausted}, new_state}
        end
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    available_count = :queue.len(state.available)
    in_use_count = MapSet.size(state.in_use)
    queue_depth = :queue.len(state.waiting)

    avg_utilization =
      if state.utilization_samples > 0 do
        state.utilization_sum / state.utilization_samples
      else
        0.0
      end

    peak_utilization = state.peak_in_use / max(state.size, 1)

    stats = %{
      size: state.size,
      available: available_count,
      in_use: in_use_count,
      queue_depth: queue_depth,
      max_queue_size: state.max_queue_size,
      utilization: in_use_count / max(state.size, 1),
      peak_utilization: peak_utilization,
      avg_utilization: avg_utilization,
      total_checkouts: state.total_checkouts,
      total_checkins: state.total_checkins,
      total_dropped: state.total_dropped,
      avg_queue_time_ms:
        if state.total_checkouts > 0 do
          state.total_queue_time_ms / state.total_checkouts
        else
          0.0
        end
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:checkin, worker}, state) do
    # Only checkin if worker is in our in_use set
    if MapSet.member?(state.in_use, worker) do
      new_in_use = MapSet.delete(state.in_use, worker)

      case :queue.out(state.waiting) do
        {{:value, {from, checkout_start, _timeout}}, rest_waiting} ->
          # Give worker to waiting arrival
          queue_time = System.monotonic_time(:millisecond) - checkout_start
          GenServer.reply(from, {:ok, worker})

          new_state = %{
            state
            | in_use: MapSet.put(new_in_use, worker),
              waiting: rest_waiting,
              total_checkins: state.total_checkins + 1,
              total_checkouts: state.total_checkouts + 1,
              total_queue_time_ms: state.total_queue_time_ms + queue_time
          }

          {:noreply, new_state}

        {:empty, _} ->
          # No waiters - return worker to available pool
          new_available = :queue.in(worker, state.available)

          new_state = %{
            state
            | available: new_available,
              in_use: new_in_use,
              total_checkins: state.total_checkins + 1
          }

          {:noreply, new_state}
      end
    else
      # Worker not from our pool - ignore
      Logger.warning("WorkerPool received checkin for unknown worker: #{inspect(worker)}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:checkout_timeout, from}, state) do
    # Remove timed-out waiter from queue
    new_waiting =
      :queue.filter(
        fn {waiter_from, _start, _timeout} -> waiter_from != from end,
        state.waiting
      )

    # If waiter was removed, they timed out
    if :queue.len(new_waiting) < :queue.len(state.waiting) do
      GenServer.reply(from, {:error, :timeout})
    end

    {:noreply, %{state | waiting: new_waiting}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Worker died - remove from tracking
    new_in_use = MapSet.delete(state.in_use, pid)

    # Filter from available queue
    new_available =
      :queue.filter(fn worker -> worker != pid end, state.available)

    # TODO: Consider restarting failed workers

    {:noreply, %{state | in_use: new_in_use, available: new_available}}
  end

  @impl true
  def terminate(_reason, state) do
    # Stop all workers
    all_workers =
      MapSet.to_list(state.in_use) ++ :queue.to_list(state.available)

    for worker <- all_workers do
      try do
        Worker.stop(worker)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp start_workers(state) do
    results =
      Enum.map(1..state.size, fn id ->
        Worker.start_link(
          worker_id: id,
          model: state.model,
          adapter: state.adapter,
          adapter_config: state.adapter_config,
          metrics: state.metrics,
          think_time_range: state.think_time_range,
          assertion_mode: state.assertion_mode
        )
      end)

    # Check for failures
    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} ->
        # Stop any successfully started workers
        for {:ok, pid} <- results do
          Worker.stop(pid)
        end

        {:error, {:worker_start_failed, reason}}

      nil ->
        workers = Enum.map(results, fn {:ok, pid} -> pid end)

        # Monitor all workers
        for worker <- workers do
          Process.monitor(worker)
        end

        {:ok, workers}
    end
  end
end
