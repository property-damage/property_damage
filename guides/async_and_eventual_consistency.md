# Async and Eventual Consistency

This guide covers patterns for testing systems with asynchronous operations and
eventual consistency, including:

- **Probe commands** - Query until data appears
- **Async commands** - Create resource and poll until settled
- **Mid-execution injection** - Emit events as they happen during polling
- **Adapter.Injector** - Handle webhook/callback events

## Overview

Many real-world APIs involve asynchronous operations:

```
Client                          API                         Backend
  │                              │                              │
  │── POST /authorizations ─────>│                              │
  │<── 201 {status: processing} ─│── Queue for processing ─────>│
  │                              │                              │
  │── GET /authorizations/123 ──>│                              │
  │<── 200 {status: processing} ─│                              │
  │                              │<── Processing complete ──────│
  │── GET /authorizations/123 ──>│                              │
  │<── 200 {status: approved} ───│                              │
```

PropertyDamage provides several mechanisms to handle these patterns.

## Command Semantics

Commands declare their behavior via the `semantics/0` callback:

| Semantics | Purpose | Mutates State? | Settle Behavior |
|-----------|---------|----------------|-----------------|
| `:sync` | Standard operations (default) | Yes | Execute once |
| `:probe` | Query and wait for consistency | No | Retry until success |
| `:async` | Create and wait for completion | Yes | Retry until complete |

## Probe Commands

Use probes for **read-only queries** that may need to wait for eventual consistency.

### When to Use

- Checking if a resource exists after creation
- Waiting for a computed value to update
- Polling for state changes caused by other commands

### Implementation

```elixir
defmodule MyTest.Commands.GetOrder do
  @behaviour PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:order_id]

  @impl true
  def generator(overrides \\ %{}) do
    # Default to nil - Model provides actual order_id via with:
    %{order_id: nil}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  # Probe semantics enables settle/retry logic
  def semantics, do: :probe

  # Read-only commands are prioritized for removal during shrinking
  def read_only?, do: true

  # Configure retry behavior
  def settle_config do
    %{
      timeout_ms: 5_000,     # Max time to wait
      interval_ms: 200,      # Time between retries
      backoff: :exponential  # :linear or :exponential
    }
  end
end
```

The Model wires this probe with state-dependent order selection:

```elixir
def commands do
  [
    {GetOrder,
      when: fn state -> map_size(state.orders) > 0 end,
      with: fn state -> %{order_id: StreamData.member_of(Map.keys(state.orders))} end}
  ]
end
```

### Adapter Implementation

Return `{:retry, reason}` when the data isn't ready yet:

```elixir
def execute(%GetOrder{order_id: id}, ctx, _runtime) do
  case Req.get(ctx.client, url: "/orders/#{id}") do
    {:ok, %{status: 200, body: body}} ->
      {:ok, [%OrderRetrieved{order_id: id, data: body}]}

    {:ok, %{status: 404}} ->
      # Not found yet - Settle module will retry
      {:retry, :not_found}

    {:error, %{reason: :timeout}} ->
      # Transient error - retry
      {:retry, :timeout}

    {:error, reason} ->
      # Hard failure - stop immediately
      {:error, reason}
  end
end
```

The executor wraps probe execution with `Settle.settle/2`, which:
1. Calls `adapter.execute/3`
2. If `{:retry, reason}` is returned, sleeps and retries
3. Continues until `{:ok, events}`, `{:error, reason}`, or timeout

## Async Commands

Use async commands for **operations that create resources and must wait for them to settle**.

### When to Use

- Creating authorizations that process asynchronously
- Submitting jobs that complete in the background
- Any operation returning "processing" status that requires polling

### The Retry Limitation

**Important**: The Settle module calls the adapter with identical arguments each retry:

```elixir
# Inside executor - same command every time
Settle.settle(
  fn -> adapter.execute(command, user_context, runtime) end,
  ...
)
```

This means `{:retry, reason}` **does not work** for create-then-poll scenarios:

```elixir
# BROKEN: First call creates, retry creates AGAIN!
def execute(%CreateAuthorization{} = cmd, ctx, _runtime) do
  case Req.post(ctx.client, url: "/authorizations", json: payload(cmd)) do
    {:ok, %{body: %{"status" => "processing"}}} ->
      {:retry, :processing}  # Next retry will POST again!
    ...
  end
end
```

### Recommended Pattern: Internal Polling

Handle the entire create-and-poll flow inside `execute/3`:

```elixir
defmodule MyTest.Commands.CreateAuthorization do
  @behaviour PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:account_id, :amount, :currency]

  @impl true
  def generator(overrides \\ %{}) do
    # account_id provided via Model's with: option
    %{
      account_id: nil,
      amount: StreamData.integer(100..10000),
      currency: StreamData.member_of(["USD", "EUR", "GBP"])
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  # Async semantics protects this command during shrinking
  # if downstream commands use its authorization_id
  def semantics, do: :async
end

# The event marks server-generated fields with external()
defmodule MyTest.Events.AuthorizationCreated do
  import PropertyDamage, only: [external: 0]

  # authorization_id is server-generated
  defstruct [:account_id, :amount, :currency, :status, authorization_id: external()]
end
```

The Model wires this command with account selection:

```elixir
def commands do
  [
    {CreateAuthorization,
      when: fn state -> map_size(state.accounts) > 0 end,
      with: fn state -> %{account_id: StreamData.member_of(Map.keys(state.accounts))} end}
  ]
end
```

```elixir
defmodule MyTest.HTTPAdapter do
  @behaviour PropertyDamage.Adapter

  @poll_timeout_ms 10_000
  @poll_interval_ms 200

  def execute(%CreateAuthorization{} = cmd, ctx, _runtime) do
    payload = %{
      account_id: cmd.account_id,
      amount: cmd.amount,
      currency: cmd.currency
    }

    case Req.post(ctx.client, url: "/authorizations", json: payload) do
      {:ok, %{status: 201, body: %{"id" => id, "status" => status}}} ->
        case status do
          "approved" ->
            {:ok, approved_events(id, cmd)}

          "declined" ->
            {:ok, declined_events(id, cmd, "immediate")}

          "processing" ->
            # Poll until settled - all inside this single execute call
            poll_until_settled(ctx.client, id, cmd)
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_response, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp poll_until_settled(client, id, cmd) do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms
    do_poll(client, id, cmd, deadline)
  end

  defp do_poll(client, id, cmd, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, {:timeout, :authorization_not_settled}}
    else
      case Req.get(client, url: "/authorizations/#{id}") do
        {:ok, %{status: 200, body: %{"status" => "approved"}}} ->
          {:ok, approved_events(id, cmd)}

        {:ok, %{status: 200, body: %{"status" => "declined", "reason" => reason}}} ->
          {:ok, declined_events(id, cmd, reason)}

        {:ok, %{status: 200, body: %{"status" => "processing"}}} ->
          Process.sleep(@poll_interval_ms)
          do_poll(client, id, cmd, deadline)

        {:error, _reason} ->
          # Transient error - keep polling
          Process.sleep(@poll_interval_ms)
          do_poll(client, id, cmd, deadline)
      end
    end
  end

  defp approved_events(id, cmd) do
    [
      %AuthorizationCreated{
        authorization_id: id,
        account_id: cmd.account_id,
        amount: cmd.amount,
        currency: cmd.currency,
        status: :approved
      },
      %AuthorizationApproved{
        authorization_id: id,
        amount: cmd.amount
      }
    ]
  end

  defp declined_events(id, cmd, reason) do
    [
      %AuthorizationCreated{
        authorization_id: id,
        account_id: cmd.account_id,
        amount: cmd.amount,
        currency: cmd.currency,
        status: :declined
      },
      %AuthorizationDeclined{
        authorization_id: id,
        reason: reason
      }
    ]
  end
end
```

### Alternative: Mid-Execution Event Injection

The internal polling pattern above has a limitation: **all events are returned together
at the end**, compressing the timeline. If your model needs to see intermediate states
(e.g., verify the authorization exists before it's approved), use `runtime.inject`:

```elixir
def execute(%CreateAuthorization{} = cmd, ctx, runtime) do
  payload = %{
    account_id: cmd.account_id,
    amount: cmd.amount,
    currency: cmd.currency
  }

  case Req.post(ctx.client, url: "/authorizations", json: payload) do
    {:ok, %{status: 201, body: %{"id" => id, "status" => status}}} ->
      # Inject AuthorizationCreated NOW - projections update immediately
      runtime.inject.(%AuthorizationCreated{
        authorization_id: id,
        account_id: cmd.account_id,
        amount: cmd.amount,
        currency: cmd.currency,
        status: status_to_atom(status)
      })

      case status do
        "approved" ->
          {:ok, [%AuthorizationApproved{authorization_id: id, amount: cmd.amount}]}

        "declined" ->
          {:ok, [%AuthorizationDeclined{authorization_id: id, reason: "immediate"}]}

        "processing" ->
          # Poll until settled - AuthorizationCreated already visible to projections
          poll_until_settled(ctx.client, id, cmd)
      end

    {:error, reason} ->
      {:error, reason}
  end
end

defp poll_until_settled(client, id, cmd) do
  # ... polling logic ...
  case final_status do
    "approved" ->
      {:ok, [%AuthorizationApproved{authorization_id: id, amount: cmd.amount}]}

    "declined" ->
      {:ok, [%AuthorizationDeclined{authorization_id: id, reason: reason}]}
  end
end
```

**Key behaviors of `runtime.inject`:**

- Injected events update projections **immediately** when injected
- Injected events are recorded with source `:injected` in the event log
- For events with `external()` fields, values are captured from the **first** injected event
- Events returned from `execute/3` are processed **after** injected events
- Adapters that ignore the `runtime` handle continue to work unchanged

**When to use `runtime.inject`:**

- Model assertions depend on intermediate states
- Projections need to track resources before they settle
- Event timeline accuracy matters for debugging/visualization
- You want to emit `Created` event immediately, then `Settled` event after polling

### Alternative: Process Dictionary for Retry State

If you prefer using `{:retry, reason}` with the Settle module, track in-flight
operations using the process dictionary:

```elixir
def execute(%CreateAuthorization{} = cmd, ctx, _runtime) do
  # Use command hash as key to track this specific operation
  cmd_key = :erlang.phash2({cmd.account_id, cmd.amount, cmd.currency})

  case Process.get({:pending_auth, cmd_key}) do
    nil ->
      # First call - create the authorization
      create_authorization(cmd, cmd_key, ctx)

    authorization_id ->
      # Retry call - just poll
      poll_authorization(authorization_id, cmd, cmd_key, ctx)
  end
end

defp create_authorization(cmd, cmd_key, ctx) do
  case Req.post(ctx.client, url: "/authorizations", json: payload(cmd)) do
    {:ok, %{body: %{"id" => id, "status" => "processing"}}} ->
      # Store ID for subsequent retries
      Process.put({:pending_auth, cmd_key}, id)
      {:retry, :processing}

    {:ok, %{body: %{"id" => id, "status" => "approved"}}} ->
      {:ok, approved_events(id, cmd)}

    {:ok, %{body: %{"id" => id, "status" => "declined", "reason" => r}}} ->
      {:ok, declined_events(id, cmd, r)}
  end
end

defp poll_authorization(authorization_id, cmd, cmd_key, ctx) do
  case Req.get(ctx.client, url: "/authorizations/#{authorization_id}") do
    {:ok, %{body: %{"status" => "approved"}}} ->
      Process.delete({:pending_auth, cmd_key})
      {:ok, approved_events(authorization_id, cmd)}

    {:ok, %{body: %{"status" => "declined", "reason" => r}}} ->
      Process.delete({:pending_auth, cmd_key})
      {:ok, declined_events(authorization_id, cmd, r)}

    {:ok, %{body: %{"status" => "processing"}}} ->
      {:retry, :still_processing}
  end
end
```

### Async Shrinking Protection

The `:async` semantics provides **shrinking protection**. When a test fails, the
shrinker tries to minimize the command sequence. Async commands that create
refs used by downstream commands are protected from removal:

```
Sequence:
1. CreateAuthorization  → creates auth_ref     ← Protected (ref used below)
2. GetAuthorization     → uses auth_ref        ← Can be removed (read-only)
3. CaptureAuthorization → uses auth_ref        ← Uses the ref

During shrinking:
- GetAuthorization may be removed (probe, read-only)
- CreateAuthorization is kept because CaptureAuthorization needs its ref
```

## Adapter.Injector (Webhook Events)

Use Adapter.Injector when external systems **push** events to your test
(webhooks, callbacks, message queues) rather than you polling for them.

### When to Use

- Payment gateway sends webhook on completion
- Message queue delivers async results
- External service calls back with status updates

### Implementation

```elixir
defmodule MyTest.PaymentWebhookAdapter do
  use PropertyDamage.Adapter.Injector

  alias MyTest.Events.{PaymentApproved, PaymentDeclined}

  # Declare which events this adapter can emit
  @emits [PaymentApproved, PaymentDeclined]

  @impl true
  def setup(config) do
    # Start a mock webhook server
    {:ok, server} = Plug.Cowboy.http(
      WebhookHandler,
      [event_queue: config.event_queue, adapter: __MODULE__],
      port: config[:webhook_port] || 4001
    )

    {:ok, %{server: server, event_queue: config.event_queue}}
  end

  @impl true
  def teardown(%{server: server}) do
    Plug.Cowboy.shutdown(server)
    :ok
  end

  @impl true
  def to_event(%{"type" => "payment.approved", "payment_id" => id, "amount" => amt}) do
    {:ok, %PaymentApproved{payment_id: id, amount: amt}}
  end

  def to_event(%{"type" => "payment.declined", "payment_id" => id, "reason" => r}) do
    {:ok, %PaymentDeclined{payment_id: id, reason: r}}
  end

  def to_event(_unknown) do
    :skip  # Ignore unrecognized webhooks
  end
end
```

### Webhook Handler

```elixir
defmodule MyTest.WebhookHandler do
  use Plug.Router

  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :match
  plug :dispatch

  post "/webhooks/payment" do
    event_queue = conn.private[:event_queue]
    adapter = conn.private[:adapter]

    case adapter.to_event(conn.body_params) do
      {:ok, event} ->
        PropertyDamage.EventQueue.push(event_queue, adapter, event)
        send_resp(conn, 200, ~s({"received": true}))

      :skip ->
        send_resp(conn, 200, ~s({"skipped": true}))

      {:error, reason} ->
        send_resp(conn, 400, Jason.encode!(%{error: reason}))
    end
  end
end
```

### Using Adapter.Injector

Register injector adapters when running tests:

```elixir
PropertyDamage.run(
  model: MyTest.Model,
  adapter: MyTest.HTTPAdapter,
  adapter_config: %{base_url: "http://localhost:4000"},
  injector_adapters: [MyTest.PaymentWebhookAdapter],
  max_runs: 100
)
```

The executor drains injected events after each command, applying them to
projections just like events from regular command execution.

### Model Configuration

Declare which events can be injected in your model:

```elixir
defmodule MyTest.Model do
  @behaviour PropertyDamage.Model

  def injectable_events do
    [PaymentApproved, PaymentDeclined]
  end

  # ... rest of model
end
```

## Polling Adapter.Injector (Advanced)

For systems where you must **actively poll** for status changes but want events
processed through the injection system (e.g., between commands rather than
blocking a single command), you can create a polling Adapter.Injector:

```elixir
defmodule MyTest.AuthorizationPollerAdapter do
  use PropertyDamage.Adapter.Injector

  @emits [AuthorizationApproved, AuthorizationDeclined]

  @impl true
  def setup(config) do
    {:ok, poller} = AuthorizationPoller.start_link(
      base_url: config[:base_url],
      event_queue: config[:event_queue],
      adapter_module: __MODULE__,
      poll_interval_ms: config[:poll_interval_ms] || 200
    )

    {:ok, %{poller: poller}}
  end

  @impl true
  def teardown(%{poller: poller}) do
    GenServer.stop(poller)
    :ok
  end

  @impl true
  def to_event(%AuthorizationApproved{} = event), do: {:ok, event}
  def to_event(%AuthorizationDeclined{} = event), do: {:ok, event}
  def to_event(_), do: :skip

  # Called by main adapter after creating an authorization
  def watch(poller, authorization_id) do
    AuthorizationPoller.watch(poller, authorization_id)
  end
end

defmodule MyTest.AuthorizationPoller do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def watch(poller, authorization_id) do
    GenServer.cast(poller, {:watch, authorization_id})
  end

  @impl true
  def init(opts) do
    state = %{
      base_url: Keyword.fetch!(opts, :base_url),
      event_queue: Keyword.fetch!(opts, :event_queue),
      adapter_module: Keyword.fetch!(opts, :adapter_module),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 200),
      pending: %{}
    }

    schedule_poll(state.poll_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast({:watch, id}, state) do
    {:noreply, %{state | pending: Map.put(state.pending, id, :watching)}}
  end

  @impl true
  def handle_info(:poll, state) do
    new_pending =
      Enum.reduce(state.pending, %{}, fn {id, _}, acc ->
        case poll_authorization(state.base_url, id) do
          {:settled, event} ->
            PropertyDamage.EventQueue.push(
              state.event_queue,
              state.adapter_module,
              event
            )
            acc  # Remove from pending

          :processing ->
            Map.put(acc, id, :watching)  # Keep watching
        end
      end)

    schedule_poll(state.poll_interval_ms)
    {:noreply, %{state | pending: new_pending}}
  end

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)

  defp poll_authorization(base_url, id) do
    case Req.get("#{base_url}/authorizations/#{id}") do
      {:ok, %{body: %{"status" => "approved", "amount" => amt}}} ->
        {:settled, %AuthorizationApproved{authorization_id: id, amount: amt}}

      {:ok, %{body: %{"status" => "declined", "reason" => r}}} ->
        {:settled, %AuthorizationDeclined{authorization_id: id, reason: r}}

      _ ->
        :processing
    end
  end
end
```

## Safety vs Liveness: `@trigger at: :teardown`

Verifying an eventually-consistent effect has two halves, and they need
different tools:

- **Liveness** ("the effect *eventually* happens") is what `@poll_state`
  expresses: its poller resolves the instant its predicate is first true, then
  stops. This is a reachability check.
- **Safety** ("the effect *never* happens too much": at most once, never
  exceeds N) is the dual. A `@poll_state` predicate *cannot* express it: a value
  can pass *through* the correct number on its way to overshooting, and the
  poller resolves on that transient pass and stops watching. Its natural
  evaluation point is the moment the system has **settled**, on the final state.

That settled checkpoint is `@trigger at: :teardown`. It runs once, on the merged
final projection state, after both the state pollers (`@poll_state`) and the
resource pollers have finalized, and before `Adapter.teardown/1`. A persistent
over-application (a counter left above its expected value, a job applied twice)
is still visible there and reports as a clear, named assertion failure rather
than as a generic poll timeout. A genuine `@poll_state` liveness timeout
preempts the checkpoint (a timeout is itself a not-settled outcome).

```elixir
defmodule JobProjection do
  use PropertyDamage.Model.Projection

  def init, do: %{expected: 0, applied: 0, max_applied: 0}

  # Count what SHOULD happen from the commands...
  def apply(%{expected: e} = s, %Enqueue{}), do: %{s | expected: e + 1}
  # ...and accumulate what DID happen from the async effects.
  def apply(%{applied: a, max_applied: m} = s, %Applied{}) do
    %{s | applied: a + 1, max_applied: max(m, a + 1)}
  end
  def apply(s, _), do: s

  # Liveness: the effect eventually reaches the expected count.
  @poll_state after: Enqueue, timeout: {5, :seconds}, interval: {50, :milliseconds}
  def eventually_applied(_s, %Enqueue{}), do: fn s -> s.applied >= s.expected end

  # Safety: it never over-applies. Evaluated on the settled state.
  @trigger at: :teardown
  def assert_effectively_once(state, _phase) do
    if state.max_applied > state.expected do
      PropertyDamage.fail!("over-applied",
        applied: state.max_applied, expected: state.expected)
    end
  end
end
```

### The accumulator contract

A `:teardown` check runs on the **final folded state**, so it can only detect a
violation the projection still *remembers*. Accumulate evidence (a maximum, a
sticky `violated?` flag, an application count) rather than snapshotting the
latest value. The `max_applied` field above is the pattern: an overshoot to 2
leaves `max_applied == 2` even if the value later heals back to 1. A snapshot
projection (`applied` alone) that heals before settling would silently miss the
transient. This is the single biggest footgun of `at: :teardown`; design the
projection to keep the evidence.

PropertyDamage verifies **effectively-once** (at-least-once delivery plus an
idempotent or deduplicated effect, observed at the value level), not distributed
exactly-once. Detection is also observation-granular: a transient overshoot that
*no event ever observes* (it exists only between polls and self-heals) is
invisible to the framework. The settled checkpoint covers every *persistent*
overshoot fully.

## Summary

| Pattern | Use When | Implementation |
|---------|----------|----------------|
| **Probe** | Read-only query waiting for data | Return `{:retry, reason}` from adapter |
| **Async (internal poll)** | Create + wait for completion | Poll inside `execute/3` |
| **Async (runtime.inject)** | Create + wait, need accurate event timing | Call `runtime.inject.(event)` mid-execution |
| **Async (process dict)** | Create + wait, prefer Settle module | Track state in process dictionary |
| **Adapter.Injector** | External system pushes webhooks | Implement `to_event/1` callback |
| **Polling Adapter.Injector** | Poll but inject events between commands | Background GenServer + EventQueue |

Choose the simplest pattern that fits your use case:

- **Most async create operations**: Use **internal polling** (simplest)
- **Need intermediate state visibility**: Use **runtime.inject** for accurate event timing
- **External webhooks/callbacks**: Use **Adapter.Injector**
