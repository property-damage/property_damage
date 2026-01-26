defmodule PropertyDamage.ResourcePoller do
  @moduledoc """
  GenServer-based poller for external resources during command execution.

  ResourcePoller enables adapters to start background polling of external resources
  during `execute/2`, injecting events as the resource status changes. This allows
  commands to return immediately with an initial event while a poller monitors the
  resource for subsequent state changes.

  ## Usage Pattern

  In an adapter's `execute/2`, use `ctx.start_poller.(opts)` to spawn a poller:

      def execute(%CreateAuthorization{} = cmd, ctx) do
        {:ok, %{body: %{"id" => id}}} = Req.post(ctx.client, ...)

        _poller = ctx.start_poller.(
          poll_fn: fn -> Req.get(ctx.client, url: "/authorizations/\#{id}") end,
          interval_ms: 500,
          timeout_ms: 30_000,
          handler: fn response ->
            case response.body["status"] do
              "processing" -> :continue
              "pending_review" -> {:inject, %AuthorizationPendingReview{id: id}}
              "approved" -> {:done, %AuthorizationApproved{id: id}}
              "declined" -> {:done, %AuthorizationDeclined{id: id}}
            end
          end
        )

        {:ok, [%AuthorizationCreated{id: id, status: :processing}]}
      end

  ## Handler Return Values

  | Return | Behavior |
  |--------|----------|
  | `:continue` | Keep polling, no event |
  | `{:inject, event}` | Push event to EventQueue, keep polling |
  | `{:inject, [events]}` | Push multiple events, keep polling |
  | `{:done, event}` | Push event, stop polling |
  | `{:done, [events]}` | Push multiple events, stop (use `{:done, []}` for no event) |
  | `{:error, reason}` | Stop polling with error |

  The `reason` in `{:error, reason}` can be any term, including an exception struct
  for structured error reporting:

      # Simple string error
      {:error, "Payment gateway timeout"}

      # Exception for structured errors
      {:error, %PaymentError{code: :gateway_timeout, details: response}}

  When an exception is used, the framework will use `Exception.message/1` for
  cleaner log output in `:log` assertion mode.

  ## Timeout Handling

  The `on_timeout` option controls behavior when polling exceeds `timeout_ms`:

  | Value | Behavior |
  |-------|----------|
  | `:ignore` | Silent timeout, poller stops, no failure |
  | `:fail` (default) | Generic timeout error reported |
  | `{:error, reason}` | Custom error reason reported |
  | `fn info -> result` | Function called with timeout info |

  The timeout info passed to the function:

      %{
        elapsed_ms: non_neg_integer(),     # Total time elapsed
        poll_count: non_neg_integer(),     # Number of poll attempts
        last_poll_result: term() | nil     # Result of last poll_fn call
      }

  Like handler errors, `on_timeout` can return `{:error, exception}` for structured
  error reporting:

      on_timeout: fn info ->
        {:error, %ResourceTimeout{
          resource: "authorization",
          elapsed_ms: info.elapsed_ms,
          poll_count: info.poll_count
        }}
      end

  ## Lifecycle

  1. Adapter calls `ctx.start_poller.(opts)` during `execute/2`
  2. Poller spawns, begins polling immediately
  3. Handler processes each poll result, may inject events
  4. At sequence end, executor awaits all active pollers
  5. Errors handled based on `assertion_mode`

  ## Error Handling

  Errors are captured with stacktraces where applicable:

  - `poll_fn` raises → `{:error, {:poll_fn_error, exception, stacktrace}}`
  - `handler` raises → `{:error, {:handler_error, exception, stacktrace}}`
  - `on_timeout` fn raises → `{:error, {:on_timeout_error, exception, stacktrace}}`
  - `handler` returns `{:error, reason}` → `{:error, reason}` (no stacktrace)
  - `on_timeout` returns `{:error, reason}` → `{:error, reason}` (no stacktrace)
  - Timeout with `:fail` → `{:error, {:timeout, timeout_info}}`

  In `:log` assertion mode, exceptions are formatted using `Exception.message/1`
  for cleaner output. In `:halt` and `:record` modes, full error details including
  stacktraces (when available) are preserved in the failure report.
  """

  use GenServer

  alias PropertyDamage.EventQueue

  @typedoc """
  Options for starting a resource poller.

  Required:
  - `:poll_fn` - Function `(() -> response)` to poll the resource
  - `:handler` - Function `(response -> result)` to process poll results
  - `:interval_ms` - Milliseconds between polls
  - `:timeout_ms` - Maximum polling duration
  - `:event_queue` - EventQueue pid for injecting events
  - `:command_index` - Index of the command that started this poller

  Optional:
  - `:on_timeout` - Timeout handling: `:ignore`, `:fail`, `{:error, reason}`, or function
  - `:branch_id` - Branch identifier for parallel execution
  """
  @type start_opts :: [
          poll_fn: (-> term()),
          handler: (term() -> handler_result()),
          interval_ms: pos_integer(),
          timeout_ms: pos_integer(),
          event_queue: pid(),
          command_index: non_neg_integer(),
          on_timeout: on_timeout_option(),
          branch_id: non_neg_integer() | nil
        ]

  @typedoc """
  Handler return values.

  The `{:error, reason}` variant accepts any term, including exception structs
  for structured error reporting. Exceptions will be formatted using
  `Exception.message/1` in `:log` mode.
  """
  @type handler_result ::
          :continue
          | {:inject, struct() | [struct()]}
          | {:done, struct() | [struct()]}
          | {:error, term() | Exception.t()}

  @typedoc """
  Timeout handling options.

  The `{:error, reason}` variant accepts any term, including exception structs.
  The function variant receives `timeout_info()` and should return `:ignore`
  or `{:error, reason}`. If the function raises, the exception is captured
  with its stacktrace.
  """
  @type on_timeout_option ::
          :ignore
          | :fail
          | {:error, term() | Exception.t()}
          | (timeout_info() -> :ignore | {:error, term() | Exception.t()})

  @typedoc """
  Information passed to `on_timeout` functions when polling exceeds `timeout_ms`.

  This map provides context about what happened during polling, allowing the
  timeout handler to make informed decisions about how to respond.

  ## Fields

  - `:elapsed_ms` - Total wall-clock time in milliseconds since the poller started.
    This will be >= `timeout_ms` from the start options.

  - `:poll_count` - Number of times `poll_fn` was called. A count of 0 means the
    poller timed out before the first poll could complete (unlikely but possible
    if `timeout_ms` < `interval_ms`).

  - `:last_poll_result` - The return value from the most recent `poll_fn` call,
    or `nil` if no polls completed. Useful for logging or including in error
    messages to show what state the resource was in when it timed out.

  ## Example Usage

      on_timeout: fn info ->
        if info.poll_count > 10 do
          # We tried hard enough, treat as success
          :ignore
        else
          {:error, %ResourceTimeout{
            elapsed_ms: info.elapsed_ms,
            poll_count: info.poll_count,
            last_status: info.last_poll_result[:status]
          }}
        end
      end
  """
  @type timeout_info :: %{
          elapsed_ms: non_neg_integer(),
          poll_count: non_neg_integer(),
          last_poll_result: term() | nil
        }

  @typedoc """
  Result from a completed poller.

  Error reasons can be:
  - `{:poll_fn_error, exception, stacktrace}` - poll_fn raised
  - `{:handler_error, exception, stacktrace}` - handler raised
  - `{:on_timeout_error, exception, stacktrace}` - on_timeout function raised
  - `{:timeout, timeout_info}` - timeout with `on_timeout: :fail`
  - Any term from `{:error, reason}` returned by handler or on_timeout
  """
  @type result ::
          {:success, reference()}
          | {:timeout_ignored, reference()}
          | {:error, reference(), term()}

  @typedoc """
  Poller handle returned by start/1.
  """
  @type t :: %__MODULE__{
          id: reference(),
          pid: pid(),
          caller: pid(),
          started_at: integer(),
          timeout_ms: pos_integer(),
          command_index: non_neg_integer()
        }

  defstruct [
    :id,
    :pid,
    :caller,
    :started_at,
    :timeout_ms,
    :command_index
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start polling a resource.

  Spawns a polling process that periodically calls `poll_fn`, passes the result
  to `handler`, and injects events to the EventQueue based on handler return.

  Returns a handle that can be used with `await/2` to wait for completion.

  ## Options

  See `t:start_opts/0` for the full list of options.

  ## Example

      poller = ResourcePoller.start(
        poll_fn: fn -> Req.get(client, url: "/resource/\#{id}") end,
        handler: fn resp -> ... end,
        interval_ms: 500,
        timeout_ms: 30_000,
        event_queue: queue,
        command_index: 5
      )
  """
  @spec start(start_opts()) :: t()
  def start(opts) do
    id = make_ref()
    poll_fn = Keyword.fetch!(opts, :poll_fn)
    handler = Keyword.fetch!(opts, :handler)
    interval_ms = Keyword.fetch!(opts, :interval_ms)
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    event_queue = Keyword.fetch!(opts, :event_queue)
    command_index = Keyword.fetch!(opts, :command_index)
    on_timeout = Keyword.get(opts, :on_timeout, :fail)
    branch_id = Keyword.get(opts, :branch_id)

    caller = self()
    started_at = System.monotonic_time(:millisecond)

    init_state = %{
      id: id,
      poll_fn: poll_fn,
      handler: handler,
      interval_ms: interval_ms,
      timeout_ms: timeout_ms,
      started_at: started_at,
      caller: caller,
      event_queue: event_queue,
      command_index: command_index,
      on_timeout: on_timeout,
      branch_id: branch_id,
      poll_count: 0,
      last_poll_result: nil
    }

    {:ok, pid} = GenServer.start_link(__MODULE__, init_state)

    %__MODULE__{
      id: id,
      pid: pid,
      caller: caller,
      started_at: started_at,
      timeout_ms: timeout_ms,
      command_index: command_index
    }
  end

  @doc """
  Wait for a poller to complete.

  Blocks until the poller finishes via `{:done, _}`, times out, or errors.

  ## Options

  - `:timeout` - Maximum time to wait in milliseconds (default: poller's timeout_ms + 1000)

  ## Returns

  - `{:success, id}` - Poller completed via `{:done, _}`
  - `{:timeout_ignored, id}` - Timeout occurred, on_timeout returned `:ignore`
  - `{:error, id, reason}` - Error from handler, poll_fn, or timeout
  - `{:error, :await_timeout}` - Await itself timed out
  """
  @spec await(t(), keyword()) :: result() | {:error, :await_timeout}
  def await(%__MODULE__{id: id} = poller, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, poller.timeout_ms + 1000)

    receive do
      {:resource_poller_result, ^id, result} ->
        result
    after
      timeout ->
        stop(poller)
        {:error, :await_timeout}
    end
  end

  @doc """
  Wait for multiple pollers to complete.

  Returns when all pollers have completed.

  ## Options

  - `:timeout` - Maximum time to wait for all pollers (default: max of all poller timeouts + 1000)

  ## Returns

  List of `{poller_id, result}` tuples.
  """
  @spec await_all([t()], keyword()) :: [{reference(), result()}]
  def await_all(pollers, opts \\ []) do
    if Enum.empty?(pollers) do
      []
    else
      max_timeout =
        pollers
        |> Enum.map(& &1.timeout_ms)
        |> Enum.max(fn -> 5000 end)

      timeout = Keyword.get(opts, :timeout, max_timeout + 1000)
      deadline = System.monotonic_time(:millisecond) + timeout

      await_all_loop(pollers, [], deadline)
    end
  end

  defp await_all_loop([], results, _deadline), do: results

  defp await_all_loop(pollers, results, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      # Timeout - stop all remaining pollers
      Enum.each(pollers, &stop/1)

      timeout_results =
        Enum.map(pollers, fn p ->
          {p.id, {:error, p.id, :await_timeout}}
        end)

      results ++ timeout_results
    else
      receive do
        {:resource_poller_result, id, result} ->
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
      {:resource_poller_result, ^id, result} ->
        {:ok, result}
    after
      0 ->
        :pending
    end
  end

  @doc """
  Stop a poller early.

  The poller process will be terminated and no result message will be sent.
  Safe to call multiple times or on already-stopped pollers.
  """
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{pid: pid}) do
    # Use try/catch to handle race condition where process terminates
    # between alive? check and stop call
    try do
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    catch
      :exit, {:noproc, _} -> :ok
      :exit, {:normal, _} -> :ok
    end

    :ok
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
      handle_timeout(state, elapsed)
    else
      execute_poll(state)
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp execute_poll(state) do
    poll_count = state.poll_count + 1

    # Execute poll_fn with error handling
    poll_result =
      try do
        {:ok, state.poll_fn.()}
      rescue
        e ->
          {:poll_fn_error, e, __STACKTRACE__}
      end

    case poll_result do
      {:ok, response} ->
        # Execute handler with error handling
        handler_result =
          try do
            {:ok, state.handler.(response)}
          rescue
            e ->
              {:handler_error, e, __STACKTRACE__}
          end

        case handler_result do
          {:ok, result} ->
            handle_handler_result(result, response, poll_count, state)

          {:handler_error, exception, stacktrace} ->
            send_result(state, {:error, state.id, {:handler_error, exception, stacktrace}})
            {:stop, :normal, state}
        end

      {:poll_fn_error, exception, stacktrace} ->
        send_result(state, {:error, state.id, {:poll_fn_error, exception, stacktrace}})
        {:stop, :normal, state}
    end
  end

  defp handle_handler_result(:continue, response, poll_count, state) do
    # Keep polling
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, %{state | poll_count: poll_count, last_poll_result: response}}
  end

  defp handle_handler_result({:inject, events}, response, poll_count, state) do
    # Inject events and keep polling
    inject_events(events, state)
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, %{state | poll_count: poll_count, last_poll_result: response}}
  end

  defp handle_handler_result({:done, events}, _response, _poll_count, state) do
    # Inject final events and stop
    inject_events(events, state)
    send_result(state, {:success, state.id})
    {:stop, :normal, state}
  end

  defp handle_handler_result({:error, reason}, _response, _poll_count, state) do
    send_result(state, {:error, state.id, reason})
    {:stop, :normal, state}
  end

  defp inject_events(event_or_events, state) do
    events = List.wrap(event_or_events)

    for event <- events do
      EventQueue.push_from_poller(
        state.event_queue,
        state.id,
        state.command_index,
        event,
        state.branch_id
      )
    end
  end

  defp handle_timeout(state, elapsed) do
    timeout_info = %{
      elapsed_ms: elapsed,
      poll_count: state.poll_count,
      last_poll_result: state.last_poll_result
    }

    result =
      case state.on_timeout do
        :ignore ->
          {:timeout_ignored, state.id}

        :fail ->
          {:error, state.id, {:timeout, timeout_info}}

        {:error, reason} ->
          {:error, state.id, reason}

        fun when is_function(fun, 1) ->
          try do
            case fun.(timeout_info) do
              :ignore -> {:timeout_ignored, state.id}
              {:error, reason} -> {:error, state.id, reason}
            end
          rescue
            e ->
              {:error, state.id, {:on_timeout_error, e, __STACKTRACE__}}
          end
      end

    send_result(state, result)
    {:stop, :normal, state}
  end

  defp send_result(state, result) do
    send(state.caller, {:resource_poller_result, state.id, result})
  end
end
