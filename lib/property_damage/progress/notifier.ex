defmodule PropertyDamage.Progress.Notifier do
  @moduledoc """
  Isolated, non-blocking progress dispatch for load tests (DR-022).

  A load test runs in a `Runner` GenServer that also schedules arrivals, so a
  slow consumer must never run in that process. The runner `emit/2`s progress to
  this dedicated GenServer instead (a fire-and-forget cast); consumers are
  invoked here, so a slow consumer cannot stall load generation.

  Under backpressure (a consumer slower than the snapshot cadence) the internal
  buffer is bounded. On overflow it is **deterministically decimated** — every
  other intermediate update is dropped (`decimate/1`), halving the buffered
  updates while preserving temporal spread across the whole run — rather than
  tail-dropping (which would keep only the early updates) or randomly sampling.
  Terminal `:result` updates are **never** decimated.

  At completion the runner calls `flush/1` (and `stop/1`): there is no more load
  to protect, so the remaining buffer is drained synchronously, guaranteeing the
  terminal `*Result` is delivered.

  Consumers are invoked via `PropertyDamage.Progress.Reporter.dispatch/2`, so a
  raising consumer is caught and logged here too.
  """

  use GenServer

  alias PropertyDamage.Progress
  alias PropertyDamage.Progress.Reporter

  @default_capacity 256

  @type consumer :: (Progress.t() -> any())

  @doc """
  Start a notifier for a list of consumer functions.

  Options: `:capacity` (max buffered updates before decimation, default 256),
  plus any standard `GenServer` options (e.g. `:name`).
  """
  @spec start_link([consumer()], keyword()) :: GenServer.on_start()
  def start_link(consumers, opts \\ []) do
    {capacity, gen_opts} = Keyword.pop(opts, :capacity, @default_capacity)
    GenServer.start_link(__MODULE__, {consumers, capacity}, gen_opts)
  end

  @doc "Fire-and-forget: hand a progress value to the notifier. Never blocks the caller."
  @spec emit(GenServer.server(), Progress.t()) :: :ok
  def emit(notifier, %Progress{} = progress), do: GenServer.cast(notifier, {:emit, progress})

  @doc "Drain all buffered updates synchronously. Blocks until delivered (use at completion)."
  @spec flush(GenServer.server()) :: :ok
  def flush(notifier), do: GenServer.call(notifier, :flush, :infinity)

  @doc "Flush then stop the notifier."
  @spec stop(GenServer.server()) :: :ok
  def stop(notifier) do
    flush(notifier)
    GenServer.stop(notifier)
  end

  # Halve the buffered updates while preserving temporal spread: keep every other
  # `:progress`-kind update (the even-indexed ones) and all `:result`-kind
  # updates, in order. Public only so it can be unit-tested directly.
  @doc false
  @spec decimate([Progress.t()]) :: [Progress.t()]
  def decimate(buffer) do
    {kept, _} =
      Enum.reduce(buffer, {[], 0}, fn progress, {acc, progress_index} ->
        cond do
          Progress.kind(progress) == :result -> {[progress | acc], progress_index}
          rem(progress_index, 2) == 0 -> {[progress | acc], progress_index + 1}
          true -> {acc, progress_index + 1}
        end
      end)

    Enum.reverse(kept)
  end

  @impl true
  def init({consumers, capacity}) do
    {:ok, %{consumers: consumers, buffer: [], count: 0, capacity: capacity, draining?: false}}
  end

  @impl true
  def handle_cast({:emit, progress}, state) do
    buffer = state.buffer ++ [progress]
    count = state.count + 1

    {buffer, count} =
      if count > state.capacity do
        decimated = decimate(buffer)
        {decimated, length(decimated)}
      else
        {buffer, count}
      end

    state = %{state | buffer: buffer, count: count}

    if state.draining? do
      {:noreply, state}
    else
      send(self(), :drain)
      {:noreply, %{state | draining?: true}}
    end
  end

  @impl true
  def handle_info(:drain, %{buffer: []} = state) do
    {:noreply, %{state | draining?: false}}
  end

  def handle_info(:drain, %{buffer: [progress | rest]} = state) do
    Reporter.dispatch(state.consumers, progress)
    send(self(), :drain)
    {:noreply, %{state | buffer: rest, count: state.count - 1}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    Enum.each(state.buffer, &Reporter.dispatch(state.consumers, &1))
    {:reply, :ok, %{state | buffer: [], count: 0, draining?: false}}
  end
end
