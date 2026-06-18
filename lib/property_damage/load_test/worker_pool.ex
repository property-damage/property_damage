defmodule PropertyDamage.LoadTest.WorkerPool do
  @moduledoc false

  use GenServer

  require Logger

  alias PropertyDamage.LoadTest.Worker

  defstruct [
    # Configuration
    :model,
    :adapter,
    :adapter_config,
    :metrics,
    :think_time_range,
    :assertion_mode,
    # Pool state
    :available,
    :in_use,
    # Stats
    :total_created,
    :total_checkouts,
    :total_checkins,
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

  - `:model` - Model module (required)
  - `:adapter` - Adapter module (required)
  - `:adapter_config` - Adapter configuration (default: %{})
  - `:metrics` - Metrics collector pid (required)
  - `:think_time_range` - {min, max} ms between commands (default: {0, 0})
  - `:assertion_mode` - How to handle assertions (default: :disabled)

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Check out a worker from the pool.

  If a worker is available, returns it immediately. Otherwise, creates a new
  worker on demand. This operation always succeeds unless worker creation fails.

  Returns `{:ok, worker_pid}` or `{:error, reason}` if worker creation fails.
  """
  @spec checkout(pid()) :: {:ok, pid()} | {:error, term()}
  def checkout(pool) do
    GenServer.call(pool, :checkout, :infinity)
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
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    metrics = Keyword.fetch!(opts, :metrics)
    think_time_range = Keyword.get(opts, :think_time_range, {0, 0})
    assertion_mode = Keyword.get(opts, :assertion_mode, :disabled)

    state = %__MODULE__{
      model: model,
      adapter: adapter,
      adapter_config: adapter_config,
      metrics: metrics,
      think_time_range: think_time_range,
      assertion_mode: assertion_mode,
      available: :queue.new(),
      in_use: MapSet.new(),
      total_created: 0,
      total_checkouts: 0,
      total_checkins: 0,
      peak_in_use: 0,
      utilization_samples: 0,
      utilization_sum: 0.0
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:checkout, _from, state) do
    case :queue.out(state.available) do
      {{:value, worker}, rest} ->
        # Use existing idle worker
        new_in_use = MapSet.put(state.in_use, worker)
        in_use_count = MapSet.size(new_in_use)

        new_state = %{
          state
          | available: rest,
            in_use: new_in_use,
            total_checkouts: state.total_checkouts + 1,
            peak_in_use: max(state.peak_in_use, in_use_count)
        }

        # Sample utilization
        new_state = sample_utilization(new_state)

        {:reply, {:ok, worker}, new_state}

      {:empty, _} ->
        # No idle workers - create a new one
        case create_worker(state) do
          {:ok, worker, new_state} ->
            new_in_use = MapSet.put(new_state.in_use, worker)
            in_use_count = MapSet.size(new_in_use)

            new_state = %{
              new_state
              | in_use: new_in_use,
                total_checkouts: new_state.total_checkouts + 1,
                peak_in_use: max(new_state.peak_in_use, in_use_count)
            }

            # Sample utilization
            new_state = sample_utilization(new_state)

            {:reply, {:ok, worker}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    available_count = :queue.len(state.available)
    in_use_count = MapSet.size(state.in_use)
    total_workers = available_count + in_use_count

    utilization =
      if total_workers > 0 do
        in_use_count / total_workers
      else
        0.0
      end

    avg_utilization =
      if state.utilization_samples > 0 do
        state.utilization_sum / state.utilization_samples
      else
        0.0
      end

    peak_utilization =
      if state.total_created > 0 do
        state.peak_in_use / state.total_created
      else
        0.0
      end

    stats = %{
      total_created: state.total_created,
      available: available_count,
      in_use: in_use_count,
      utilization: utilization,
      peak_utilization: peak_utilization,
      avg_utilization: avg_utilization,
      peak_in_use: state.peak_in_use,
      total_checkouts: state.total_checkouts,
      total_checkins: state.total_checkins
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:checkin, worker}, state) do
    # Only checkin if worker is in our in_use set
    if MapSet.member?(state.in_use, worker) do
      new_in_use = MapSet.delete(state.in_use, worker)
      new_available = :queue.in(worker, state.available)

      new_state = %{
        state
        | available: new_available,
          in_use: new_in_use,
          total_checkins: state.total_checkins + 1
      }

      {:noreply, new_state}
    else
      # Worker not from our pool - ignore
      Logger.warning("WorkerPool received checkin for unknown worker: #{inspect(worker)}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Worker died - remove from tracking
    new_in_use = MapSet.delete(state.in_use, pid)

    # Filter from available queue
    new_available =
      :queue.filter(fn worker -> worker != pid end, state.available)

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

  defp create_worker(state) do
    worker_id = state.total_created + 1

    case Worker.start_link(
           worker_id: worker_id,
           model: state.model,
           adapter: state.adapter,
           adapter_config: state.adapter_config,
           metrics: state.metrics,
           think_time_range: state.think_time_range,
           assertion_mode: state.assertion_mode
         ) do
      {:ok, worker} ->
        Process.monitor(worker)
        {:ok, worker, %{state | total_created: state.total_created + 1}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sample_utilization(state) do
    available_count = :queue.len(state.available)
    in_use_count = MapSet.size(state.in_use)
    total_workers = available_count + in_use_count

    utilization =
      if total_workers > 0 do
        in_use_count / total_workers
      else
        0.0
      end

    %{
      state
      | utilization_samples: state.utilization_samples + 1,
        utilization_sum: state.utilization_sum + utilization
    }
  end
end
