# Async and Eventual Consistency

This guide covers patterns for testing systems with asynchronous operations and
eventual consistency, including:

- **Probe commands** - Query until data appears
- **Async commands** - Create resource and poll until settled
- **Mid-execution injection** - Emit events as they happen during polling
- **Built-in resource poller** - Let `runtime.start_poller` poll in the background
- **Adapter.Injector** - Handle webhook/callback events

Three different waits appear in this guide, with three different bounds. They
are told apart in [Settle, Convergence and `@eventually`](#settle-convergence-and-eventually):
**settle** (one system catching up with itself for one adapter call),
**convergence** (two or more targets agreeing at a boundary) and `@eventually`
(a condition that must become true within a timeout).

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

## A runnable probe example

Before the reference material below, here is the smallest end-to-end example that
actually settles: a `:probe` command that retries until an eventually-consistent
store catches up. It has no external dependencies (the "store" is an in-process
`Agent` that only reveals a shipped widget ~150ms later), so you can paste it into
`warehouse_probe.exs` and run `mix run warehouse_probe.exs`.

<!-- pd-doc-verify: runnable -->
```elixir
defmodule Warehouse.Events do
  defmodule WidgetShipped do
    defstruct [:sku]
  end

  defmodule WidgetArrived do
    defstruct [:sku]
  end
end

defmodule Warehouse.Commands.ShipWidget do
  use PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:sku]

  @impl true
  def generator(overrides \\ %{}) do
    %{sku: StreamData.string(:alphanumeric, min_length: 3, max_length: 6)}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Warehouse.Commands.AwaitWidget do
  # :probe = read-only, retried until it settles or times out.
  use PropertyDamage.Command,
    execution: :probe,
    shrink: :prefer_remove,
    settle: %{timeout_ms: 2_000, interval_ms: 50, backoff: :linear}

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:sku]

  @impl true
  def generator(overrides \\ %{}) do
    # sku is filled in by the model from state (a widget that was shipped).
    %{sku: nil}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Warehouse.Adapter do
  use PropertyDamage.Adapter

  # PropertyDamage.log/2 is a macro: it records the file and line of the call.
  require PropertyDamage

  alias Warehouse.Commands.{ShipWidget, AwaitWidget}
  alias Warehouse.Events.{WidgetShipped, WidgetArrived}

  # The "warehouse" is eventually consistent: a shipped widget only becomes
  # visible ~150ms later, so AwaitWidget must retry.
  @delivery_ms 150

  @impl true
  def setup(_config) do
    {:ok, store} = Agent.start_link(fn -> %{} end)
    {:ok, %{store: store}}
  end

  @impl true
  def teardown(%{store: store}), do: Agent.stop(store)

  @impl true
  def execute(%ShipWidget{sku: sku}, %{store: store}, _runtime) do
    ready_at = System.monotonic_time(:millisecond) + @delivery_ms
    Agent.update(store, &Map.put(&1, sku, ready_at))
    {:ok, [%WidgetShipped{sku: sku}]}
  end

  def execute(%AwaitWidget{sku: sku}, %{store: store}, _runtime) do
    ready_at = Agent.get(store, &Map.get(&1, sku))
    now = System.monotonic_time(:millisecond)

    # One line per settle attempt: the report shows what each attempt saw.
    PropertyDamage.log("AwaitWidget #{sku}: ready_at #{inspect(ready_at)}")

    cond do
      is_nil(ready_at) -> {:retry, :unknown_sku}
      now >= ready_at -> {:ok, [%WidgetArrived{sku: sku}]}
      true -> {:retry, :in_transit}
    end
  end
end

defmodule Warehouse.State do
  use PropertyDamage.Model.Projection

  alias Warehouse.Events.{WidgetShipped, WidgetArrived}

  @impl true
  def init, do: %{shipped: MapSet.new(), arrived: MapSet.new()}

  @impl true
  def apply(state, %WidgetShipped{sku: sku}) do
    %{state | shipped: MapSet.put(state.shipped, sku)}
  end

  def apply(state, %WidgetArrived{sku: sku}) do
    %{state | arrived: MapSet.put(state.arrived, sku)}
  end

  def apply(state, _), do: state

  # safety: a widget can only arrive once the probe has settled, and it can only
  # arrive if it was shipped. This fires once per settled AwaitWidget probe.
  @check every: Warehouse.Events.WidgetArrived
  def assert_arrivals_were_shipped(state, %WidgetArrived{sku: sku}) do
    MapSet.member?(state.shipped, sku) or
      PropertyDamage.fail!("widget arrived without being shipped",
        sku: sku,
        shipped: state.shipped
      )
  end
end

defmodule Warehouse.Model do
  @behaviour PropertyDamage.Model.Simulator
  use PropertyDamage.Model

  alias Warehouse.Commands.{ShipWidget, AwaitWidget}
  alias Warehouse.Events.{WidgetShipped, WidgetArrived}
  alias Warehouse.State

  @impl true
  def commands do
    [
      {ShipWidget, weight: 2},
      {AwaitWidget,
       weight: 3,
       when: fn state -> MapSet.size(state.shipped) > 0 end,
       overrides: fn state ->
         %{sku: StreamData.member_of(MapSet.to_list(state.shipped))}
       end}
    ]
  end

  @impl true
  def command_sequence_projection, do: State

  @impl true
  def check_projections, do: [State]

  # The simulator predicts events during sequence generation, so AwaitWidget
  # (which needs a shipped sku to exist) becomes eligible to be generated.
  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(%ShipWidget{sku: sku}, _state), do: [%WidgetShipped{sku: sku}]
  def simulate(%AwaitWidget{sku: sku}, _state), do: [%WidgetArrived{sku: sku}]
end

result =
  PropertyDamage.run(
    model: Warehouse.Model,
    targets: [Warehouse.Adapter],
    max_commands: 6,
    max_runs: 20,
    seed: 1
  )

IO.inspect(result, label: "run result")
```

Running it prints a passing result whose `check_fires` count is the number of
`AwaitWidget` probes that actually settled (abridged: the result can carry more
keys, such as `:coverage` or `:metrics` when you ask for them; your exact count
varies with the seed and command mix):

```
run result: {:ok,
 %{
   seed: 1,
   targets: [%{index: 0, name: "Adapter"}],
   runs: 20,
   setup_commands: 0,
   teardown_commands: 0,
   total_commands: 120,
   check_fires: %{{Warehouse.State, :arrivals_were_shipped} => 58},
   compare_counts: %{},
   expansion_counts: %{"Adapter" => %{}}
 }}
```

Two details make this work, both expanded on below:

- **`execution: :probe`** tells the executor to wrap `AwaitWidget` in retry/settle
  logic: the adapter returns `{:retry, reason}` until the widget is visible, then
  `{:ok, events}`. See [Probe Commands](#probe-commands).
- **`simulator/0` + `simulate/2`** predict events during the symbolic generation
  phase (no SUT calls happen there), so `AwaitWidget`'s `when:` sees a shipped sku
  and the command is actually generated. Without a simulator the state-dependent
  command would never appear in a sequence.

## Command Semantics

Commands declare their behavior via the `:execution` key of `command_spec/1`:

| Semantics | Purpose | Mutates State? | Settle Behavior |
|-----------|---------|----------------|-----------------|
| `:sync` | Standard operations (default) | Yes | Execute once |
| `:probe` | Query and wait for consistency | No | Retry until success |
| `:async` | Create and wait for completion | Yes | Retry until complete |

### The `settle:` map

The per-command `settle:` map tunes the settle loop of a `:probe` or `:async`
command. The map merges per key over the framework defaults, so a key you omit
keeps its default. `settle: %{timeout_ms: 1_000}` waits up to one second and
keeps the default interval and backoff. A `settle:` set at call time in the
model's command list merges the same way over one set in `use`.

<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyApp.CheckStatus do
  use PropertyDamage.Command, execution: :probe, settle: %{timeout_ms: 1_000}

  defstruct [:id]

  @impl true
  def generator(_overrides \\ %{}), do: StreamData.constant(%{id: 1})
end

%{timeout_ms: 1_000, interval_ms: 300, backoff: :linear} =
  MyApp.CheckStatus.command_spec([]).settle
```

The full map spells out every key:

```elixir
settle: %{timeout_ms: 2_000, interval_ms: 300, backoff: :linear}
```

| Key | Default | Meaning |
|-----|---------|---------|
| `timeout_ms` | `2_000` | Longest the loop waits for the adapter call to stop answering `{:retry, reason}` |
| `interval_ms` | `300` | Pause between attempts |
| `backoff` | `:linear` | `:linear` keeps the interval constant; `:exponential` doubles it after each retry, capped by the time left |

The loop calls `adapter.execute/3` at least once. It stops on `{:ok, events}` or
`{:error, reason}`, and keeps going on `{:retry, reason}` until `timeout_ms`
passes. A timeout fails the run with a `:settle_timeout` failure holding the last
retry reason. A `:sync` command that returns `{:retry, reason}` fails with
`:retry_from_sync_command`, because only `:probe` and `:async` commands have a
settle loop.

Each settle attempt is a log scope: a `PropertyDamage.log/2` call in
`execute/3` lands under the attempt that wrote it, as in the adapter of the
[runnable example](#a-runnable-probe-example). A command that retries hundreds
of times would flood the report, so the report keeps the lines of the first
attempt and of the last three, and prints `... N attempts omitted (M lines)` where it
dropped the rest, with `M` the number of log lines in the dropped attempts. `log: [keep_attempts: n]` on `PropertyDamage.run/1` keeps the
last `n` attempts instead of three. An attempt that logs nothing leaves no
gap. See [Log Lines in the Failure Report](log_lines.md#retried-commands).

## Probe Commands

Use probes for **read-only queries** that may need to wait for eventual consistency.

### When to Use

- Checking if a resource exists after creation
- Waiting for a computed value to update
- Polling for state changes caused by other commands

### Implementation

```elixir
defmodule MyTest.Commands.GetOrder do
  # Probe semantics enables settle/retry logic; read-only commands are
  # prioritized for removal during shrinking; settle tunes retry behavior.
  use PropertyDamage.Command,
    execution: :probe,
    shrink: :prefer_remove,
    settle: %{
      timeout_ms: 5_000,     # Max time to wait
      interval_ms: 200,      # Time between retries
      backoff: :exponential  # :linear or :exponential
    }

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:order_id]

  @impl true
  def generator(overrides \\ %{}) do
    # Default to nil - Model provides actual order_id via overrides:
    %{order_id: nil}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end
```

The Model wires this probe with state-dependent order selection:

```elixir
def commands do
  [
    {GetOrder,
      when: fn state -> map_size(state.orders) > 0 end,
      overrides: fn state -> %{order_id: StreamData.member_of(Map.keys(state.orders))} end}
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

Keeping the operation id in the process dictionary does not fix this. Each
settle attempt runs `execute/3` in a fresh task, so a process-dictionary value
dies with its attempt and the retry repeats the create. State that must survive
between attempts lives in the adapter context (an `Agent` or ETS table started
in `setup/1`). Or avoid the retry altogether: poll inside `execute/3`, call
`runtime.inject`, or use `runtime.start_poller` (all below).

### Recommended Pattern: Internal Polling

Handle the entire create-and-poll flow inside `execute/3`:

```elixir
defmodule MyTest.Commands.CreateAuthorization do
  # Async semantics protects this command during shrinking
  # if downstream commands use its authorization_id
  use PropertyDamage.Command, execution: :async
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:account_id, :amount, :currency]

  @impl true
  def generator(overrides \\ %{}) do
    # account_id provided via Model's overrides: option
    %{
      account_id: nil,
      amount: StreamData.integer(100..10000),
      currency: StreamData.member_of(["USD", "EUR", "GBP"])
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

# The event marks server-generated fields with external()
defmodule MyTest.Events.AuthorizationCreated do
  import PropertyDamage, only: [external: 0]

  # authorization_id is server-generated
  defstruct [:account_id, :amount, :currency, :status, authorization_id: external()]
end

# The settled outcomes the adapters below return once the authorization resolves
defmodule MyTest.Events.AuthorizationApproved do
  defstruct [:authorization_id, :amount]
end

defmodule MyTest.Events.AuthorizationDeclined do
  defstruct [:authorization_id, :reason]
end
```

The Model wires this command with account selection:

```elixir
def commands do
  [
    {CreateAuthorization,
      when: fn state -> map_size(state.accounts) > 0 end,
      overrides: fn state -> %{account_id: StreamData.member_of(Map.keys(state.accounts))} end}
  ]
end
```

```elixir
defmodule MyTest.HTTPAdapter do
  use PropertyDamage.Adapter

  alias MyTest.Commands.CreateAuthorization
  alias MyTest.Events.{AuthorizationCreated, AuthorizationApproved, AuthorizationDeclined}

  @poll_timeout_ms 10_000
  @poll_interval_ms 200

  @impl true
  def setup(config), do: {:ok, %{client: Req.new(base_url: config[:base_url])}}

  @impl true
  def teardown(_ctx), do: :ok

  @impl true
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
  of the external's event module; an injected event of another module never resolves it
- Events returned from `execute/3` are processed **after** injected events
- Adapters that ignore the `runtime` handle continue to work unchanged

**When to use `runtime.inject`:**

- Model checks depend on intermediate states
- Projections need to track resources before they settle
- Event timeline accuracy matters for debugging/visualization
- You want to emit `Created` event immediately, then `Settled` event after polling

### Alternative: Built-in Resource Poller

To keep `execute/3` short and still see the later events, start a background
poller with `runtime.start_poller`. The command returns its first event at
once. The poller injects the later events between commands, and the executor
awaits every poller at the end of the sequence:

```elixir
def execute(%CreateAuthorization{} = cmd, %{client: client}, runtime) do
  {:ok, %{body: %{"id" => id}}} = Req.post(client, url: "/authorizations", json: %{amount: cmd.amount})

  runtime.start_poller.(
    poll_fn: fn -> Req.get(client, url: "/authorizations/#{id}") end,
    interval_ms: 200,
    timeout_ms: 10_000,
    handler: fn
      {:ok, %{body: %{"status" => "approved"}}} -> {:done, %AuthorizationApproved{authorization_id: id}}
      {:ok, %{body: %{"status" => "declined"}}} -> {:done, %AuthorizationDeclined{authorization_id: id}}
      _ -> :continue
    end
  )

  {:ok, [%AuthorizationCreated{authorization_id: id}]}
end
```

See the [Resource Polling guide](resource_polling.md) for the handler return
values, timeouts and error handling.

### Async Shrinking Protection

An `:async` command gets **shrinking protection**. When a test fails, the
shrinker tries to minimize the command sequence. It skips removing an async
command when a later command uses a value the async command produced through
`external()`, because the later command would lose its input and the candidate
would not reproduce the failure:

```
Sequence:
1. CreateAuthorization  → mints authorization_id   ← Protected (used below)
2. GetAuthorization     → uses authorization_id    ← Can be removed (read-only)
3. CaptureAuthorization → uses authorization_id    ← Needs the value

During shrinking:
- GetAuthorization may be removed (probe, read-only)
- CreateAuthorization is kept because CaptureAuthorization needs its value
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
    # `Plug.Cowboy.shutdown/1` takes the listener ref, not the pid that
    # `http/3` returns. Name the ref here so `teardown/1` can stop the listener.
    ref = MyTest.WebhookHandler.HTTP

    {:ok, _pid} = Plug.Cowboy.http(
      MyTest.WebhookHandler,
      [event_queue: config.event_queue, adapter: __MODULE__],
      ref: ref,
      port: config[:webhook_port] || 4001
    )

    {:ok, %{ref: ref, event_queue: config.event_queue}}
  end

  @impl true
  def teardown(%{ref: ref}) do
    Plug.Cowboy.shutdown(ref)
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
  # Cowboy passes the options given to `Plug.Cowboy.http/3` to `init/1`,
  # and `call/2` receives them. `copy_opts_to_assign` stores them in
  # `conn.assigns.webhook_opts` so each route can read them.
  use Plug.Router, copy_opts_to_assign: :webhook_opts

  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :match
  plug :dispatch

  post "/webhooks/payment" do
    event_queue = conn.assigns.webhook_opts[:event_queue]
    adapter = conn.assigns.webhook_opts[:adapter]

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
  targets: [{MyTest.HTTPAdapter,
    config: %{base_url: "http://localhost:4000"},
    injectors: [MyTest.PaymentWebhookAdapter]
  }],
  max_runs: 100
)
```

An injector's `setup/1` receives its target's `config:` map plus
`:event_queue`, so a key in `config:` is how an injector learns which system or
tenant it serves (above, `config[:webhook_port]` would come from that map). Its
`teardown/1` receives the context its `setup/1` returned, and a setup that
returns `{:error, reason}` fails the run as a `:setup_failed` report.

The executor drains injected events after each command, applying them to
projections just like events from regular command execution.

### Correlating events to a command (`awaits/2`)

By default an injected event is *ambient*: it folds into projections but is
attributed to no command (`command_index: nil`). When an inbound event is the
delayed result of a specific command (a webhook for the issue you just closed,
a callback for the payment you just initiated), declare the optional
`Command.awaits/2` callback so the framework correlates it back to that command:

```elixir
defmodule CloseIssue do
  use PropertyDamage.Command
  defstruct [:issue_id]

  @impl true
  def generator(overrides \\ %{}), do: # ...

  # Claim the webhook delivered for *this* issue.
  @impl true
  def awaits(_state, %__MODULE__{issue_id: id}) do
    [%PropertyDamage.Await{match: &match?(%IssueClosedWebhook{issue_id: ^id}, &1)}]
  end
end
```

`awaits/2` returns a list of `%PropertyDamage.Await{match}` structs; `match` is a
predicate `(event -> boolean)` built from the command's own (resolved) fields. A
matching injected event is then attributed to that command's `command_index`,
persistently for the rest of the run (a late arrival still correlates). When two
commands' matchers accept the same event, the first-registered wins and an
overlap diagnostic is logged.

`awaits/2` is **pure correlation** — it never blocks and asserts nothing.
Express judgment over a command's correlated set with ordinary projection
checks:

- **liveness** ("the webhook must arrive") — a `@eventually` over the correlated
  set (e.g. `fn s -> s.webhooks[id] >= 1 end`). A timeout is reported at the
  awaiting command's index.
- **safety / cardinality** ("exactly one webhook per close") — a `@check` or
  `@invariant` over the correlated set.

When you also run in simulator mode, have `Model.simulate/2` predict the awaited
event so the simulated projection state matches a live, correlated run (the
`awaits/2` ↔ `simulate/2` contract).

### Model Configuration

A model may declare which events can be injected. The callback is optional, and
a model without it still folds injected events into its projections. Its only
consumer is the validation check: every event listed in `injectable_events/0`
must appear in the `@emits` of at least one injector, or validation fails.

```elixir
defmodule MyTest.Model do
  use PropertyDamage.Model

  @impl true
  def injectable_events do
    [PaymentApproved, PaymentDeclined]
  end

  # ... rest of model
end
```

## Polling Adapter.Injector (Advanced)

For most polling needs, call `runtime.start_poller` from the main adapter's
`execute/3` instead. The framework starts a `PropertyDamage.ResourcePoller`
for you, routes its events through the injection system between commands, and
awaits it at the end of the sequence. See the
[Resource Polling guide](resource_polling.md).

Write a polling Adapter.Injector by hand when one long-lived process must watch
many resources across commands, or when the poll loop needs state that a
`poll_fn` and `handler` pair cannot hold. The injector starts the poller in
`setup/1`, and the poller pushes events to the shared `EventQueue` (e.g.,
between commands rather than blocking a single command).

The main adapter cannot reach the injector's context, so it cannot read a poller
pid from it. Register the poller under a name instead. Any process on the node
then reaches it by that name:

```elixir
defmodule MyTest.AuthorizationPollerAdapter do
  use PropertyDamage.Adapter.Injector

  alias MyTest.AuthorizationPoller
  alias MyTest.Events.{AuthorizationApproved, AuthorizationDeclined}

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
end

defmodule MyTest.AuthorizationPoller do
  use GenServer

  alias MyTest.Events.{AuthorizationApproved, AuthorizationDeclined}

  # The name lets the main adapter call watch/1 without holding a pid
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def watch(authorization_id) do
    GenServer.cast(__MODULE__, {:watch, authorization_id})
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

The main adapter hands each new authorization to the poller by name:

```elixir
def execute(%CreateAuthorization{} = cmd, %{base_url: base_url}, _runtime) do
  {:ok, %{body: %{"id" => id}}} = Req.post("#{base_url}/authorizations", json: %{amount: cmd.amount})
  MyTest.AuthorizationPoller.watch(id)
  {:ok, [%AuthorizationCreated{authorization_id: id}]}
end
```

A registered name allows one poller per node, so several targets that each list
this injector would collide on the name. In that case use `runtime.start_poller`.

## Writing an `@eventually` predicate

The function an `@eventually` returns is polled on the projection state, and
its return is a verdict (DR-052):

| The predicate returns | The poller |
|-----------------------|------------|
| a truthy value | is satisfied and stops |
| `nil` or `false` | waits for the next poll ("not yet") |
| `{:fail, reason}` | ends the window at once as a check failure with that reason ("never") |
| a bare exception struct or `{:error, _}` | fails at once: neither is a verdict |
| raises, exits or throws | fails at once, naming the check, the poll count and what escaped |

Write the predicate as a **total** function of the state: a value for every
state, including the states before the system has caught up. A predicate that
reads `s.payments[id].status` raises while the payment does not exist yet, and
that raise is a check failure at the first poll, not "not yet". Read with
`get_in/2`, `match?/2` or a `case` with a fallback clause instead, and say
"never" when the state shows the wait is over:

```elixir
@eventually after: PaymentInitiated, timeout: 5, interval: {100, :milliseconds}
def payment_confirmed(_state, %PaymentInitiated{id: id}) do
  fn state ->
    case get_in(state, [:payments, id, :status]) do
      :confirmed -> true
      :failed -> {:fail, "payment #{id} reached :failed"}
      _not_yet -> false
    end
  end
end
```

A payment that reached `:failed` ends the window at once with that message,
instead of waiting out the `timeout:` to report that it never became
`:confirmed`. A window that does time out reports that the predicate never
became true, and nothing else: with a total predicate, nothing else can have
happened.

## Safety vs liveness: `@check at: :teardown`

Verifying an eventually-consistent effect has two halves, and they need
different tools:

- **liveness** ("the effect *eventually* happens") is what `@eventually`
  expresses: its poller resolves the instant its predicate is first true, then
  stops. This is a reachability check.
- **safety** ("the effect *never* happens too much": at most once, never
  exceeds N) is the dual. A `@eventually` predicate *cannot* express it: a value
  can pass *through* the correct number on its way to overshooting, and the
  poller resolves on that transient pass and stops watching. Its natural
  evaluation point is the moment the system has **settled**, on the final state.

That settled checkpoint is `@check at: :teardown`. It runs once, on the merged
final projection state, after both the state pollers (`@eventually`) and the
resource pollers have finalized, and before `Adapter.teardown/1`. A persistent
over-application (a counter left above its expected value, a job applied twice)
is still visible there and reports as a clear, named check failure rather
than as a generic poll timeout. A genuine `@eventually` liveness timeout
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

  # liveness: the effect eventually reaches the expected count.
  @eventually after: Enqueue, timeout: {5, :seconds}, interval: {50, :milliseconds}
  def eventually_applied(_s, %Enqueue{}), do: fn s -> s.applied >= s.expected end

  # safety: it never over-applies. Evaluated on the settled state.
  @check at: :teardown
  def assert_effectively_once(state, _phase) do
    state.max_applied <= state.expected or
      PropertyDamage.fail!("over-applied", applied: state.max_applied, expected: state.expected)
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

### Recipe: nothing left pending

A run can end with an operation still unfinished: the system accepted it and
never completed it. `@eventually` and `@check at: :teardown` cover different
halves of that case, and the recipe uses both:

- `@eventually` per operation bounds the wait for one step the operation must
  reach, such as "the job starts". It names the operation whose step never
  happened, but a window that times out ends the run before the teardown
  checkpoint.
- A `@check at: :teardown` on your own projection judges the settled state. It
  fails when any operation is not in its final status, including an operation
  that no `@eventually` covers or whose `@eventually` was satisfied by an
  earlier step.

The projection tracks every operation by id and keeps its last status, so the
teardown check reads the final folded state (see the accumulator contract
above). Here `JobStarted` satisfies the `@eventually`, and only `JobCompleted`
makes a job final:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule Jobs.Events do
  defmodule JobSubmitted, do: defstruct([:id])
  defmodule JobStarted, do: defstruct([:id])
  defmodule JobCompleted, do: defstruct([:id])
end

defmodule Jobs.Commands.SubmitJob do
  use PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:id]

  @impl true
  def generator(overrides \\ %{}) do
    %{id: StreamData.integer(1..1_000)}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Jobs.Adapter do
  use PropertyDamage.Adapter

  alias Jobs.Commands.SubmitJob
  alias Jobs.Events.{JobSubmitted, JobStarted, JobCompleted}

  @impl true
  def setup(_config), do: {:ok, %{}}

  @impl true
  def teardown(_ctx), do: :ok

  @impl true
  def execute(%SubmitJob{id: id}, _ctx, _runtime) do
    {:ok, [%JobSubmitted{id: id}, %JobStarted{id: id}, %JobCompleted{id: id}]}
  end
end

defmodule Jobs.Projection do
  use PropertyDamage.Model.Projection

  alias Jobs.Events.{JobSubmitted, JobStarted, JobCompleted}

  @impl true
  def init, do: %{}

  @impl true
  def apply(jobs, %JobSubmitted{id: id}), do: Map.put(jobs, id, :submitted)
  def apply(jobs, %JobStarted{id: id}), do: Map.put(jobs, id, :started)
  def apply(jobs, %JobCompleted{id: id}), do: Map.put(jobs, id, :completed)
  def apply(jobs, _event), do: jobs

  # Each job is picked up within a bound.
  @eventually after: JobSubmitted, timeout: {2, :seconds}, interval: {50, :milliseconds}
  def job_started(_jobs, %JobSubmitted{id: id}) do
    fn jobs -> Map.get(jobs, id) in [:started, :completed] end
  end

  # Nothing is left pending when the run settles.
  @check at: :teardown
  def nothing_left_pending(jobs, _phase) do
    pending = for {id, status} <- Enum.sort(jobs), status != :completed, do: "job-#{id}"
    pending == [] or PropertyDamage.fail!("jobs left pending", pending: pending)
  end
end

defmodule Jobs.Model do
  use PropertyDamage.Model

  @impl true
  def commands, do: [{Jobs.Commands.SubmitJob, weight: 1}]

  @impl true
  def command_sequence_projection, do: Jobs.Projection

  @impl true
  def check_projections, do: [Jobs.Projection]
end

{:ok, stats} =
  PropertyDamage.run(
    model: Jobs.Model,
    targets: [Jobs.Adapter],
    max_commands: 4,
    max_runs: 5,
    seed: 1
  )

IO.inspect(stats.check_fires, label: "check fires")
```

The adapter here completes every job, so the run passes and each check fires:
`job_started` once per submitted job and `nothing_left_pending` once per run.
Swap in an adapter that returns `JobSubmitted` and `JobStarted` for some job
but never `JobCompleted`, and the `@eventually` is still satisfied, so the run
fails at the teardown checkpoint with a failure named `nothing_left_pending`
and the message `jobs left pending: %{pending: ["job-62"]}`. A job that never
even starts fails earlier, as a `:poll_timeout` on `job_started`.

## Settle, Convergence and `@eventually`

Three waits share this guide's subject, and each has its own bound and its own
failure. Keep the words apart:

| Term | Meaning |
|------|---------|
| settle | one system catching up with itself per adapter call (the per-command `settle:` map) |
| convergence, the convergence loop | the variants reaching agreement at a boundary |
| the convergence bound | `converge_within:` |
| time to converge | the measured duration |
| did not converge | a side still pending at the bound (`:did_not_converge`) |
| diverged | ready sides that differ at the bound (`:diverged`) |

**Settle** is local knowledge: "my system has not settled yet", so the adapter
call is retried until it has or its own `settle:` timeout passes. It is how a
`:probe` command waits for one system.

**Convergence** applies to a run with two or more `targets:`. At each boundary
where a `@compare` observation is scheduled, the framework evaluates the
observation in every target and, while a side is `{:pending, reason}` or ready
sides differ, drains and folds every target's event queue, runs the async
checks, re-reads a `:probe` root in every target, and evaluates again, up to
`compare: [converge_within: ms]` (default `5_000`). Each re-read of a probe root
runs under that root's own `settle:`, so the loop can overshoot the bound by at
most one iteration, and the report states the time waited. See
[Differential Testing](differential_testing.md#the-convergence-loop).

**`@eventually`** is a liveness predicate on one target's projection state with
its own `timeout:`. A window that expires, or whose predicate says "never" with
`{:fail, reason}`, while the convergence loop waits is a check failure at once;
a polling window that has not expired does not block agreement.

The convergence loop ends by convergence, by divergence, or by the bound
expiring with a side still pending; only the third is did not converge.

| Wait | Scope | Declared on | Bound | Failure kind when it expires |
|------|-------|-------------|-------|------------------------------|
| settle | one adapter call of a `:probe` or `:async` command | the command's `settle:` map | `timeout_ms` (default 2000) | `:settle_timeout` |
| convergence | one boundary across two or more targets | the run's `compare:` option | `converge_within:` (default 5000 ms) | `:did_not_converge` |
| `@eventually` | one target's state after an event | the `@eventually` attribute | `timeout:` | `:poll_timeout` |

A report names the failure kind, so "did not converge" is never mistaken for a
settle timeout. A `:poll_timeout` or `:settle_timeout` can mean the system is
slow and not wrong: raise the matching bound before you hunt for a bug.

## Summary

| Pattern | Use When | Implementation |
|---------|----------|----------------|
| **Probe** | Read-only query waiting for data | Return `{:retry, reason}` from adapter |
| **Async (internal poll)** | Create + wait for completion | Poll inside `execute/3` |
| **Async (runtime.inject)** | Create + wait, need accurate event timing | Call `runtime.inject.(event)` mid-execution |
| **Adapter.Injector** | External system pushes webhooks | Implement `to_event/1` callback |
| **Resource poller** | Create + wait, polling in the background | Call `runtime.start_poller.(opts)` |
| **Polling Adapter.Injector** | One long-lived watcher process for many resources | Background GenServer + EventQueue |

Choose the simplest pattern that fits your use case:

- **Most async create operations**: Use **internal polling** (simplest)
- **Need intermediate state visibility**: Use **runtime.inject** for accurate event timing
- **Polling without blocking the command**: Use **runtime.start_poller**, and reach for a hand-rolled polling Adapter.Injector only when one process must watch many resources
- **External webhooks/callbacks**: Use **Adapter.Injector**
