# Resource Polling

This guide explains how to use the `ResourcePoller` mechanism for commands that need to poll external resources for status changes.

## When to Use Resource Polling

Use `ctx.start_poller.(opts)` when your adapter needs to:

1. **Poll external resources asynchronously** - Start a background poller that monitors a resource while the command returns immediately
2. **Inject events as status changes** - Push events to the event queue as the resource transitions through states
3. **Handle eventual consistency** - Test systems where resources don't settle immediately

### vs. Blocking Settle

**Use blocking settle** (via `@probe` or `@bridge` semantics) when:
- You want to wait until the resource settles before returning
- The entire command should be considered atomic
- Events should only be emitted once the final state is reached

**Use resource polling** when:
- You want the command to return immediately with an initial event
- Intermediate state changes should emit separate events
- Multiple commands may be in-flight while resources settle
- You need fine-grained control over timeout behavior

## Usage Example

```elixir
defmodule MyAdapter do
  use PropertyDamage.Adapter

  @impl true
  def execute(%CreateAuthorization{user_id: user_id, amount: amount} = cmd, ctx) do
    # Step 1: Create the authorization (returns immediately)
    {:ok, %{body: %{"id" => id, "status" => "processing"}}} =
      Req.post(ctx.client, url: "/authorizations", json: %{
        user_id: user_id,
        amount: amount
      })

    # Step 2: Start background poller for status changes
    _poller = ctx.start_poller.(
      poll_fn: fn ->
        Req.get(ctx.client, url: "/authorizations/#{id}")
      end,
      interval_ms: 500,
      timeout_ms: 30_000,
      handler: fn response ->
        case response.body["status"] do
          "processing" ->
            :continue

          "pending_review" ->
            {:inject, %AuthorizationPendingReview{id: id}}

          "approved" ->
            {:done, %AuthorizationApproved{id: id, approved_at: DateTime.utc_now()}}

          "declined" ->
            {:done, %AuthorizationDeclined{id: id, reason: response.body["decline_reason"]}}
        end
      end
    )

    # Step 3: Return initial event immediately
    {:ok, [%AuthorizationCreated{id: id, status: :processing}]}
  end
end
```

## Handler Return Values

The handler function receives the response from `poll_fn` and must return one of:

| Return | Behavior |
|--------|----------|
| `:continue` | Keep polling, no event injected |
| `{:inject, event}` | Push event to queue, keep polling |
| `{:inject, [events]}` | Push multiple events, keep polling |
| `{:done, event}` | Push event, stop polling |
| `{:done, [events]}` | Push multiple events, stop |
| `{:done, []}` | Stop without injecting events |
| `{:error, reason}` | Stop polling with error |

The `reason` in `{:error, reason}` can be any term. For structured error reporting,
you can use an exception struct:

```elixir
{:error, %PaymentError{code: :gateway_timeout, details: response}}
```

When an exception is used, the framework will use `Exception.message/1` for
cleaner log output in `:log` assertion mode.

### Handler Patterns

**Track intermediate states:**
```elixir
handler: fn response ->
  case response.body["status"] do
    "queued" -> :continue
    "processing" -> {:inject, %ProcessingStarted{id: id}}
    "completed" -> {:done, %ProcessingCompleted{id: id}}
  end
end
```

**Emit batch of final events:**
```elixir
handler: fn response ->
  case response.body["status"] do
    "pending" -> :continue
    "completed" ->
      items = response.body["items"]
      events = Enum.map(items, &%ItemProcessed{id: &1["id"]})
      {:done, events ++ [%BatchCompleted{count: length(items)}]}
  end
end
```

**Handle errors gracefully:**
```elixir
handler: fn response ->
  case response do
    {:ok, %{status: 200, body: body}} ->
      if body["completed"], do: {:done, %Completed{}}, else: :continue

    {:ok, %{status: 404}} ->
      {:error, :resource_not_found}

    {:error, reason} ->
      {:error, {:http_error, reason}}
  end
end
```

## Start Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `poll_fn` | Yes | - | Zero-arity function that polls the resource |
| `handler` | Yes | - | Function that receives poll result, returns action |
| `interval_ms` | Yes | - | Milliseconds between poll attempts |
| `timeout_ms` | Yes | - | Maximum time to poll before timing out |
| `on_timeout` | No | `:fail` | Timeout behavior (see below) |

## Timeout Handling

The `on_timeout` option controls what happens when polling exceeds `timeout_ms`:

```elixir
# Silent timeout - poller stops, no failure reported
on_timeout: :ignore

# Generic timeout error (default behavior)
on_timeout: :fail

# Custom error message
on_timeout: {:error, "Payment never confirmed"}

# Dynamic based on timeout info
on_timeout: fn info ->
  {:error, "Resource never settled after #{info.poll_count} polls (#{info.elapsed_ms}ms)"}
end

# Conditional handling
on_timeout: fn info ->
  if info.poll_count > 10 do
    :ignore  # We tried hard enough
  else
    {:error, "Gave up too early"}
  end
end
```

### Timeout Info

The function form receives a `timeout_info` map with the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `elapsed_ms` | `non_neg_integer()` | Total wall-clock time since poller started (>= `timeout_ms`) |
| `poll_count` | `non_neg_integer()` | Number of times `poll_fn` was called |
| `last_poll_result` | `term() \| nil` | Return value from most recent `poll_fn`, or `nil` if none completed |

Example:

```elixir
%{
  elapsed_ms: 30050,           # Just over 30 seconds
  poll_count: 60,              # Polled 60 times at 500ms intervals
  last_poll_result: %{         # Last response from poll_fn
    status: 200,
    body: %{"status" => "processing"}
  }
}
```

### Exception Support in Timeout Handlers

Like handler errors, `on_timeout` can return `{:error, exception}` for structured
error reporting:

```elixir
defmodule ResourceTimeout do
  defexception [:resource, :elapsed_ms, :poll_count, :last_status]

  def message(%{resource: r, elapsed_ms: ms, poll_count: n}) do
    "#{r} did not settle after #{ms}ms (#{n} polls)"
  end
end

# Usage
on_timeout: fn info ->
  {:error, %ResourceTimeout{
    resource: "authorization",
    elapsed_ms: info.elapsed_ms,
    poll_count: info.poll_count,
    last_status: info.last_poll_result[:status]
  }}
end
```

If the `on_timeout` function itself raises an exception, it will be captured with
its stacktrace and reported as `{:on_timeout_error, exception, stacktrace}`.

## Lifecycle

1. **During command execution**: Adapter calls `ctx.start_poller.(opts)`
2. **Poller spawns**: Starts polling immediately in background process
3. **Command returns**: Initial events returned, executor continues to next command
4. **Between commands**: EventQueue drained, poller-injected events processed
5. **Poller completes**: Via `{:done, _}`, timeout, or error
6. **At sequence end**: Executor awaits all active pollers, collects results

## Error Handling

Errors from pollers are handled based on `assertion_mode`:

| Mode | Behavior |
|------|----------|
| `:halt` | First error stops execution, reported as failure |
| `:record` | Errors recorded, sequence continues, all failures reported at end |
| `:log` | Errors logged as warnings, sequence continues |
| `:disabled` | Errors ignored |

### Error Types

Errors are captured with stacktraces when code raises, or without when errors
are explicitly returned:

| Error | Has Stacktrace? | Cause |
|-------|-----------------|-------|
| `{:poll_fn_error, exception, stacktrace}` | Yes | `poll_fn` raised an exception |
| `{:handler_error, exception, stacktrace}` | Yes | `handler` raised an exception |
| `{:on_timeout_error, exception, stacktrace}` | Yes | `on_timeout` function raised |
| `{:timeout, timeout_info}` | No | Polling timed out with `on_timeout: :fail` |
| Custom `reason` | No | Handler or `on_timeout` returned `{:error, reason}` |

### Log Mode Formatting

In `:log` mode, errors are formatted for clean log output:

- **Raised exceptions**: Shows exception type and message
  ```
  [warning] Resource poller #Ref<...> error: handler raised: invalid response format
  ```

- **Returned exceptions**: Uses `Exception.message/1`
  ```
  [warning] Resource poller #Ref<...> error: Payment failed with code gateway_error
  ```

- **Other terms**: Uses `inspect/1`
  ```
  [warning] Resource poller #Ref<...> error: :resource_not_found
  ```

## Testing Adapters with Resource Polling

When testing adapters that use resource polling, you can use the returned poller handle for manual control:

```elixir
test "authorization polling" do
  {:ok, queue} = EventQueue.start_link()

  # Create mock context with start_poller
  ctx = %{
    client: mock_client,
    start_poller: fn opts ->
      ResourcePoller.start(Keyword.merge(opts, [
        event_queue: queue,
        command_index: 0
      ]))
    end
  }

  # Execute the command
  {:ok, events} = MyAdapter.execute(%CreateAuthorization{...}, ctx)

  # Initial event returned immediately
  assert [%AuthorizationCreated{}] = events

  # Wait for poller to complete
  # (In real tests, the executor does this automatically)
  Process.sleep(100)

  # Check injected events
  entries = EventQueue.drain(queue)
  assert Enum.any?(entries, &match?(%{event: %AuthorizationApproved{}}, &1))
end
```

## Best Practices

1. **Return initial event immediately** - Don't block in `execute/2`, let the poller handle status changes

2. **Use appropriate intervals** - Balance responsiveness with API rate limits

3. **Set reasonable timeouts** - Consider typical settlement times plus safety margin

4. **Handle transient errors** - Use `:continue` for retryable errors, `{:error, _}` for permanent failures

5. **Consider `on_timeout: :ignore`** - For resources where timeout is acceptable (e.g., optional webhooks)

6. **Track poller in model state** - If your model needs to know about pending operations, emit an event

## See Also

- `PropertyDamage.ResourcePoller` - Module documentation
- `PropertyDamage.Adapter` - Adapter behaviour and context
- [Async and Eventual Consistency](async_and_eventual_consistency.md) - Related guide
