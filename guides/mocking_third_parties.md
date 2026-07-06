# Mocking Third-Party Services

How to control external API behavior during property-based tests using
`PropertyDamage.MockServiceAdapter`.

## When to Use What

| Scenario | Tool | Examples |
|----------|------|---------|
| Application-level responses | **MockServiceAdapter** | Payment declined, email bounced, API rate limit |
| Infrastructure-level faults | **Nemesis** | Network partition, latency spike, DNS failure |

**Decision rule:** Is the fault something the external API returns (HTTP 402,
timeout response, error body)? Use MockServiceAdapter. Is the fault something
that prevents the call from completing (network down, connection refused)?
Use Nemesis.

MockServiceAdapter controls what the third-party API *says*.
Nemesis controls whether the third-party API is *reachable*.

## MockServiceAdapter Behaviour

The mock sits between your SUT and the external service, intercepting requests
and returning controlled responses:

```
┌──────────┐       ┌─────────┐       ┌───────────────────┐
│   Test   │──────>│   SUT   │──────>│ MockServiceAdapter │
│ Framework│<──────│         │<──────│   (controlled)     │
└──────────┘       └─────────┘       └───────────────────┘
      │                                       │
      │<──────── injected events ─────────────┘
```

### Callbacks

| Callback | Purpose |
|----------|---------|
| `setup/1` | Start the mock server (HTTP, gRPC, etc.) |
| `teardown/1` | Stop the mock server |
| `init_state/0` | Initial mock state (default behavior, counters, etc.) |
| `on_command/2` | React to commands -- update mock behavior |
| `on_event/2` | React to events -- update mock state (optional) |
| `handle_request/2` | Intercept SUT request, return response + optional events |

### Return values from handle_request/2

```elixir
{:ok, response}                  # Return response, no events injected
{:ok, response, events}          # Return response and inject events into framework
{:error, term()}                 # Simulate connection error / timeout
```

The `state` argument to `handle_request/2` includes a `:projections` key with
current projection states, enabling realistic responses based on test state.

## Complete Example: Payment Processor Mock

### Events

<!-- pd-doc-verify: runnable -->
```elixir
defmodule PaymentAuthorized do
  import PropertyDamage, only: [external: 0]
  defstruct [:order_id, :amount, transaction_id: external()]
end

defmodule PaymentDeclined do
  defstruct [:order_id, :reason]
end

defmodule PaymentTimedOut do
  defstruct [:order_id]
end
```

### Mock Module

```elixir
defmodule MyTest.PaymentGatewayMock do
  use PropertyDamage.MockServiceAdapter

  @emits [PaymentAuthorized, PaymentDeclined, PaymentTimedOut]

  @impl true
  def setup(config) do
    {:ok, pid} = MockServer.start_link(port: config[:port] || 4445, handler: __MODULE__)
    {:ok, %{server: pid}}
  end

  @impl true
  def teardown(%{server: pid}) do
    MockServer.stop(pid)
    :ok
  end

  @impl true
  def init_state do
    %{
      behavior: :success,
      decline_reason: nil,
      request_log: []
    }
  end

  @impl true
  def on_command(%ConfigurePaymentProvider{behavior: b, reason: r}, state) do
    %{state | behavior: b, decline_reason: r}
  end
  def on_command(_cmd, state), do: state

  @impl true
  def on_event(_event, state), do: state

  @impl true
  def handle_request(%{path: "/authorize", body: body}, state) do
    # Record the request
    state = update_in(state.request_log, &[body | &1])

    case state.behavior do
      :success ->
        resp = %{status: 200, body: %{transaction_id: "txn_#{System.unique_integer([:positive])}"}}
        events = [%PaymentAuthorized{order_id: body["order_id"], amount: body["amount"]}]
        {:ok, resp, events}

      :decline ->
        resp = %{status: 402, body: %{error: state.decline_reason}}
        events = [%PaymentDeclined{order_id: body["order_id"], reason: state.decline_reason}]
        {:ok, resp, events}

      :timeout ->
        events = [%PaymentTimedOut{order_id: body["order_id"]}]
        {:error, :timeout}

      :partial_failure ->
        # Authorize succeeds but with a warning flag
        resp = %{status: 200, body: %{transaction_id: "txn_partial", warning: "retry_suggested"}}
        events = [%PaymentAuthorized{order_id: body["order_id"], amount: body["amount"]}]
        {:ok, resp, events}
    end
  end

  def handle_request(_request, _state) do
    {:ok, %{status: 404, body: %{error: "not_found"}}}
  end
end
```

### Configuration Command

<!-- pd-doc-verify: runnable -->
```elixir
defmodule ConfigurePaymentProvider do
  use PropertyDamage.Command

  defstruct [:behavior, :reason]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      behavior: StreamData.member_of([:success, :decline, :timeout]),
      reason: StreamData.member_of([nil, "insufficient_funds", "card_expired", "fraud_detected"])
    }
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end
```

### Model Integration

```elixir
defmodule PaymentTestModel do
  @behaviour PropertyDamage.Model

  @impl true
  def commands do
    [
      {CreateOrder, weight: 5},
      {SubmitPayment,
        weight: 3,
        when: fn s -> map_size(s.orders) > 0 end,
        with: fn s -> %{order_id: StreamData.member_of(Map.keys(s.orders))} end},
      {ConfigurePaymentProvider, weight: 1}   # Low weight -- mostly success
    ]
  end

  @impl true
  def command_sequence_projection, do: PaymentState

  @impl true
  def assertion_projections, do: [PaymentInvariant]
end
```

### Rollback Invariant

```elixir
defmodule PaymentInvariant do
  use PropertyDamage.Model.Projection

  def init, do: %{orders: %{}, payments: %{}}

  def apply(state, %OrderCreated{id: id, amount: amt}) do
    put_in(state, [:orders, id], %{amount: amt, status: :pending})
  end
  def apply(state, %PaymentAuthorized{order_id: id}) do
    put_in(state, [:orders, id, :status], :authorized)
  end
  def apply(state, %PaymentDeclined{order_id: id}) do
    put_in(state, [:orders, id, :status], :declined)
  end
  def apply(state, _), do: state

  @trigger every: PaymentDeclined
  def assert_rollback_on_decline(state, %PaymentDeclined{order_id: id}) do
    order = state.orders[id]
    if order.status != :declined do
      PropertyDamage.fail!("order not rolled back after decline",
        order_id: id, status: order.status)
    end
  end
end
```

## Wiring the Mock into a Run

Declare the mock with the `:mock_services` option of `PropertyDamage.run/1`.
Each entry is a mock module or a `{module, config}` tuple:

```elixir
PropertyDamage.run(
  model: PaymentTestModel,
  adapter: PaymentAdapter,
  mock_services: [{MyTest.PaymentGatewayMock, %{port: 4445}}]
)
```

For every run the framework:

1. starts a `PropertyDamage.MockServiceRegistry`,
2. registers the mock (`init_state/0`) and calls its `setup/1` with the entry's
   config merged with `%{registry: pid, event_queue: pid}` -- this is where a
   mock starts its HTTP listener,
3. calls `on_command/2` on every command before it executes,
4. after each command, flushes the events the mock pushed, folds them into
   projections (recorded with `source: :mock`), and calls `on_event/2`,
5. calls `teardown/1` and stops the registry at the end.

The same registry is reused across a failure's shrink attempts, so a
mock-dependent failure keeps reproducing as it minimizes.

### Driving handle_request/2

The framework never calls `handle_request/2` itself: only the SUT (or its
stand-in) knows when it makes an outbound call. Whatever plays that transport
reads the mock's state from the registry, calls `handle_request/2`, and pushes
the returned events back so the framework can fold them:

```elixir
alias PropertyDamage.MockServiceRegistry

{:ok, state} = MockServiceRegistry.get_handler_state(registry, MyTest.PaymentGatewayMock)
{:ok, response, events} = MyTest.PaymentGatewayMock.handle_request(request, state)
:ok = MockServiceRegistry.push_events(registry, MyTest.PaymentGatewayMock, events)
```

`get_handler_state/2` merges the mock's own state with the current projection
states under a `:projections` key, so responses can reflect real test state.

In a real HTTP mock this glue lives inside the listener the mock started in
`setup/1`, which closed over the `registry` pid it was handed. For an in-process
SUT, the adapter can reach the registry directly on the runtime handle:

```elixir
def execute(%SubmitPayment{} = cmd, ctx, %PropertyDamage.Runtime{mock_registry: registry}) do
  {:ok, state} = MockServiceRegistry.get_handler_state(registry, MyTest.PaymentGatewayMock)
  {:ok, resp, events} = MyTest.PaymentGatewayMock.handle_request(%{path: "/authorize", body: %{...}}, state)
  :ok = MockServiceRegistry.push_events(registry, MyTest.PaymentGatewayMock, events)
  {:ok, [%PaymentSubmitted{status: resp.status}]}
end
```

Returning events from `handle_request/2` is not enough on its own -- the
transport must `push_events/3` them into the registry for the framework to see
them. `runtime.mock_registry` is `nil` when the run declared no `:mock_services`.

## Mock Patterns

### State-Based Responses

The mock tracks previous calls and varies behavior accordingly. Useful for
simulating rate limits, quotas, or stateful APIs:

```elixir
@impl true
def handle_request(%{path: "/authorize", body: body}, state) do
  call_count = length(state.request_log)

  if call_count > 10 do
    # Rate limit after 10 calls
    {:ok, %{status: 429, body: %{error: "rate_limited", retry_after: 60}}}
  else
    {:ok, %{status: 200, body: %{transaction_id: "txn_#{call_count}"}}}
  end
end
```

### Event Injection

When the SUT calls the mock, the mock can inject events that update projections
in real time. This is how the test framework knows what happened inside the
external service:

```elixir
@impl true
def handle_request(%{path: "/charge", body: body}, state) do
  response = %{status: 200, body: %{id: "ch_123"}}

  # These events flow through projections just like SUT-produced events
  events = [
    %ChargeCreated{id: "ch_123", amount: body["amount"]},
    %ChargeSettled{id: "ch_123"}
  ]

  {:ok, response, events}
end
```

### Request Recording

Record all requests the SUT makes to the mock for later verification.
Use `on_command/2` to clear the log between test phases if needed:

```elixir
@impl true
def init_state, do: %{behavior: :success, request_log: []}

@impl true
def handle_request(%{path: path, body: body} = req, state) do
  state = update_in(state.request_log, &[%{path: path, body: body, at: System.monotonic_time()} | &1])
  # ... handle normally
end

# Assertion projection can check recorded requests
@trigger every: 10
def assert_no_duplicate_charges(state, _) do
  charges = Enum.filter(state.mock_requests, &(&1.path == "/charge"))
  order_ids = Enum.map(charges, & &1.body["order_id"])
  if length(order_ids) != length(Enum.uniq(order_ids)) do
    PropertyDamage.fail!("duplicate charge attempts", order_ids: order_ids)
  end
end
```

### Projection-Aware Responses

The mock's state includes projection data, so responses can reflect the actual
test state:

```elixir
@impl true
def handle_request(%{path: "/balance/" <> account_id}, state) do
  # Read from projection state to return realistic data
  balance = get_in(state.projections, [ModelState, :accounts, account_id, :balance]) || 0
  {:ok, %{status: 200, body: %{balance: balance}}}
end
```

## Best Practices

1. **Default to success.** Most test runs should exercise the happy path.
   Use low weights (1) for `ConfigurePaymentProvider` commands versus normal
   commands (3-5). This ensures the system works under normal conditions before
   you stress error paths.

2. **Test without mocks first.** Get your model working with a simple
   always-success adapter before adding mock complexity. Mock behavior
   configuration is a separate concern from core model correctness.

3. **Declare emitted events.** Use `@emits [Event1, Event2]` in your mock
   module. The framework uses this for validation and coverage checking.

4. **Keep mock state minimal.** Track only what you need for response decisions.
   Complex mock state is a sign that the mock is doing too much -- consider
   whether the behavior belongs in the SUT instead.

5. **Document mock behaviors.** Each behavior value (`:success`, `:decline`,
   `:timeout`) should have a clear, testable meaning. If you find yourself
   adding many behavior variants, consider whether some are redundant.

6. **Combine with Nemesis for full coverage.** MockServiceAdapter handles
   application-level failures (declined, invalid response). Nemesis handles
   infrastructure failures (network partition, latency). Use both together
   for comprehensive resilience testing.
