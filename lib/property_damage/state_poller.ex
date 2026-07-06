defmodule PropertyDamage.StatePoller do
  @moduledoc false

  use GenServer

  @typedoc """
  Options for starting a state poller.

  Required:
  - `:predicate` - Function `(state -> boolean)` to evaluate
  - `:projection` - The projection module whose state is checked
  - `:interval_ms` - Polling interval in milliseconds
  - `:timeout_ms` - Maximum time to poll before timing out
  - `:triggered_by` - Map with `:event` and `:assertion_name`

  Optional:
  - `:predicate_source` - String representation of the predicate for debugging
  - `:get_state_fn` - Function to get current projection state (for testing)
  """
  @type start_opts :: [
          predicate: (any() -> boolean()),
          predicate_source: String.t() | nil,
          projection: module(),
          interval_ms: pos_integer(),
          timeout_ms: pos_integer(),
          triggered_by: %{event: struct(), assertion_name: atom()},
          get_state_fn: (module() -> any()) | nil
        ]

  @typedoc """
  Result from a completed poller.
  """
  @type result ::
          {:success, reference()}
          | {:timeout, reference(), timeout_info()}

  @typedoc """
  Information about a poll timeout for debugging.
  """
  @type timeout_info :: %{
          predicate_source: String.t() | nil,
          projection: module(),
          triggered_by: map(),
          final_state: any(),
          elapsed_ms: non_neg_integer(),
          poll_count: non_neg_integer()
        }

  @typedoc """
  Poller handle returned by start/1.
  """
  @type t :: %__MODULE__{
          id: reference(),
          predicate: (any() -> boolean()),
          predicate_source: String.t() | nil,
          projection: module(),
          interval_ms: pos_integer(),
          timeout_ms: pos_integer(),
          started_at: integer(),
          triggered_by: map(),
          pid: pid(),
          caller: pid()
        }

  defstruct [
    :id,
    :predicate,
    :predicate_source,
    :projection,
    :interval_ms,
    :timeout_ms,
    :started_at,
    :triggered_by,
    :pid,
    :caller
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start polling for a predicate.

  Spawns a polling process that periodically evaluates the predicate against
  the projection state until it returns `true` or the timeout expires.

  Returns a handle that can be used with `await/2` to wait for completion.

  ## Options

  See `t:start_opts/0` for the full list of options.

  ## Example

      poller = StatePoller.start(
        predicate: fn s -> s.payments["pay_123"] == :confirmed end,
        projection: PaymentProjection,
        interval_ms: 100,
        timeout_ms: 5000,
        triggered_by: %{event: event, assertion_name: :payment_confirmed}
      )
  """
  @spec start(start_opts()) :: t()
  def start(opts) do
    id = make_ref()
    predicate = Keyword.fetch!(opts, :predicate)
    predicate_source = Keyword.get(opts, :predicate_source)
    projection = Keyword.fetch!(opts, :projection)
    interval_ms = Keyword.fetch!(opts, :interval_ms)
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    triggered_by = Keyword.fetch!(opts, :triggered_by)
    get_state_fn = Keyword.get(opts, :get_state_fn)

    caller = self()
    started_at = System.monotonic_time(:millisecond)

    init_state = %{
      id: id,
      predicate: predicate,
      predicate_source: predicate_source,
      projection: projection,
      interval_ms: interval_ms,
      timeout_ms: timeout_ms,
      started_at: started_at,
      triggered_by: triggered_by,
      caller: caller,
      get_state_fn: get_state_fn,
      poll_count: 0,
      last_state: nil,
      last_predicate_error: nil
    }

    {:ok, pid} = GenServer.start_link(__MODULE__, init_state)

    %__MODULE__{
      id: id,
      predicate: predicate,
      predicate_source: predicate_source,
      projection: projection,
      interval_ms: interval_ms,
      timeout_ms: timeout_ms,
      started_at: started_at,
      triggered_by: triggered_by,
      pid: pid,
      caller: caller
    }
  end

  @doc """
  Wait for a poller to complete.

  Blocks until the poller succeeds, times out, or the wait timeout expires.

  ## Options

  - `:timeout` - Maximum time to wait in milliseconds (default: poller's timeout_ms + 1000)

  ## Returns

  - `{:success, id}` - Predicate became true
  - `{:timeout, id, timeout_info}` - Poller timed out
  - `{:error, :await_timeout}` - Await itself timed out (shouldn't happen normally)
  """
  @spec await(t(), keyword()) :: result() | {:error, :await_timeout}
  def await(%__MODULE__{id: id} = poller, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, poller.timeout_ms + 1000)

    receive do
      {:poller_result, ^id, result} ->
        result
    after
      timeout ->
        # Force stop the poller if it's still running
        stop(poller)
        {:error, :await_timeout}
    end
  end

  @doc """
  Wait for multiple pollers to complete.

  Returns when all pollers have completed (success or timeout).

  ## Options

  - `:timeout` - Maximum time to wait for all pollers (default: max of all poller timeouts + 1000)

  ## Returns

  List of `{poller_id, result}` tuples.
  """
  @spec await_all([t()], keyword()) :: [{reference(), result()}]
  def await_all(pollers, opts \\ []) do
    max_timeout =
      pollers
      |> Enum.map(& &1.timeout_ms)
      |> Enum.max(fn -> 5000 end)

    timeout = Keyword.get(opts, :timeout, max_timeout + 1000)
    deadline = System.monotonic_time(:millisecond) + timeout

    await_all_loop(pollers, [], deadline)
  end

  defp await_all_loop([], results, _deadline), do: results

  defp await_all_loop(pollers, results, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      # Timeout - stop all remaining pollers and return timeout errors
      Enum.each(pollers, &stop/1)

      timeout_results =
        Enum.map(pollers, fn p ->
          {p.id, {:error, :await_timeout}}
        end)

      results ++ timeout_results
    else
      receive do
        {:poller_result, id, result} ->
          # Find and remove the completed poller
          case Enum.find(pollers, &(&1.id == id)) do
            nil ->
              # Not one of ours, keep waiting
              await_all_loop(pollers, results, deadline)

            _poller ->
              remaining_pollers = Enum.reject(pollers, &(&1.id == id))
              await_all_loop(remaining_pollers, [{id, result} | results], deadline)
          end
      after
        remaining ->
          # Overall timeout
          await_all_loop([], results, 0)
      end
    end
  end

  @doc """
  Check if a poller has completed without blocking.

  ## Returns

  - `{:ok, result}` - Poller has completed
  - `:pending` - Poller is still running
  """
  @spec check(t()) :: {:ok, result()} | :pending
  def check(%__MODULE__{id: id}) do
    receive do
      {:poller_result, ^id, result} ->
        {:ok, result}
    after
      0 ->
        :pending
    end
  end

  @doc """
  Stop a poller early.

  The poller process will be terminated and no result message will be sent.
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{pid: pid}) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end

    :ok
  end

  @doc """
  Update the state getter function for a poller.

  This is used by the executor to provide access to the current projection state.
  """
  @spec update_state_getter(t(), (module() -> any())) :: :ok
  def update_state_getter(%__MODULE__{pid: pid}, get_state_fn) do
    GenServer.cast(pid, {:update_state_getter, get_state_fn})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(state) do
    # Start polling immediately
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.started_at

    if elapsed >= state.timeout_ms do
      # Timeout - send failure result
      timeout_info = %{
        predicate_source: state.predicate_source,
        projection: state.projection,
        triggered_by: state.triggered_by,
        final_state: state.last_state,
        elapsed_ms: elapsed,
        poll_count: state.poll_count,
        last_predicate_error: state.last_predicate_error
      }

      send(state.caller, {:poller_result, state.id, {:timeout, state.id, timeout_info}})
      {:stop, :normal, state}
    else
      # Get current state and evaluate predicate
      current_state = get_projection_state(state)
      poll_count = state.poll_count + 1

      try do
        if state.predicate.(current_state) do
          # Success!
          send(state.caller, {:poller_result, state.id, {:success, state.id}})
          {:stop, :normal, state}
        else
          # Continue polling
          Process.send_after(self(), :poll, state.interval_ms)
          {:noreply, %{state | poll_count: poll_count, last_state: current_state}}
        end
      rescue
        e ->
          # Predicate raised - treat as not satisfied but log. A predicate that
          # always raises (e.g. non-exhaustive heads) would otherwise time out
          # looking like "condition never became true"; we keep the last error
          # so the timeout report can name the real cause.
          require Logger

          Logger.warning(
            "StatePoller predicate raised: #{inspect(e)} in #{state.triggered_by.assertion_name}"
          )

          Process.send_after(self(), :poll, state.interval_ms)

          {:noreply,
           %{state | poll_count: poll_count, last_state: current_state, last_predicate_error: e}}
      catch
        # A BEAM exit/throw (e.g. a GenServer.call to a dead process) bypasses
        # `rescue`; without this it kills the poller and, through its start_link,
        # the run. Treat it exactly like a raising predicate (A3).
        kind, reason ->
          require Logger

          Logger.warning(
            "StatePoller predicate escaped via #{kind}: #{inspect(reason)} " <>
              "in #{state.triggered_by.assertion_name}"
          )

          Process.send_after(self(), :poll, state.interval_ms)

          {:noreply,
           %{
             state
             | poll_count: poll_count,
               last_state: current_state,
               last_predicate_error: {kind, reason}
           }}
      end
    end
  end

  @impl true
  def handle_cast({:update_state_getter, get_state_fn}, state) do
    {:noreply, %{state | get_state_fn: get_state_fn}}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_projection_state(%{get_state_fn: nil, projection: projection}) do
    # Default: try to get state from projection's init
    # In real use, the executor will provide a get_state_fn
    projection.init()
  end

  defp get_projection_state(%{get_state_fn: get_state_fn, projection: projection}) do
    get_state_fn.(projection)
  end
end
