# Idempotency Testing with Stutter

PropertyDamage's stutter testing automatically retries commands against your SUT
to verify idempotent behavior. This guide covers configuration, comparison modes,
and writing commands that participate in idempotency testing.

## Why Idempotency Matters

Distributed systems retry requests. Timeouts, network partitions, and load
balancer retries all cause duplicate delivery. If your SUT creates two orders
when a `CreateOrder` command is retried, you have an idempotency bug.

Stutter testing catches these bugs by probabilistically re-executing commands
during property test runs and comparing the results.

## How Stutter Testing Works

During the concrete execution phase, the framework may re-execute a command
after its initial execution:

1. **First execution** -- Events are applied to projections normally.
2. **Retry executions** -- Events are captured but NOT applied to projections.
3. **Comparison** -- Retry events are compared against the first execution's events.
4. **Violation** -- Any mismatch is reported as an idempotency violation.

This design tests SUT idempotency without requiring your projections to be
idempotent themselves. Only the first execution's events flow through the
projection pipeline.

## Enabling Stutter Testing

Pass a `:stutter` keyword list to `PropertyDamage.run/1`:

```elixir
PropertyDamage.run(
  model: MyModel,
  adapter: MyAdapter,
  stutter: [
    probability: 0.3,
    max_repeats: 2,
    delay_ms: {10, 100}
  ]
)
```

Stutter testing is disabled by default. Providing the `:stutter` option enables
it.

## Configuration Options

| Option | Type | Default | Description |
|---|---|---|---|
| `probability` | `float` | `0.1` | Chance each command is retried (0.0--1.0) |
| `max_repeats` | `pos_integer` | `2` | Maximum retry count per stuttered command |
| `delay_ms` | `integer \| {min, max}` | `{0, 100}` | Delay between retries in milliseconds |
| `commands` | `:all \| [module]` | `:all` | Which commands to stutter |
| `comparison` | see below | `:strict` | How to compare original and retry events |

### Targeting Specific Commands

Limit stutter testing to particular commands:

```elixir
stutter: [
  probability: 0.5,
  commands: [CreateOrder, SubmitPayment]
]
```

## Comparison Modes

### Strict (default)

Events from the retry must exactly equal the original events:

```elixir
stutter: [comparison: :strict]
```

Use when your SUT returns identical responses on retry (e.g., same JSON body,
same event payloads).

### Structural

Ignore non-deterministic fields like timestamps or request IDs:

```elixir
stutter: [comparison: {:structural, [:timestamp, :updated_at, :request_id]}]
```

The framework drops the listed fields from both event sets before comparison.
Two events that differ only in ignored fields are considered equivalent.

### Custom

Provide a function that receives the original and retry event lists:

```elixir
stutter: [
  comparison: {:custom, fn original_events, retry_events ->
    if length(original_events) == length(retry_events) do
      :match
    else
      {:mismatch, %{expected: original_events, actual: retry_events}}
    end
  end}
]
```

Return `:match` or `{:mismatch, details}`.

## Command Callbacks

Commands interact with stutter testing through three optional callbacks defined
in the `PropertyDamage.Command` behaviour.

### `idempotent?/0`

Return `false` to exclude a command from stutter testing. Commands are assumed
idempotent by default.

```elixir
defmodule IncrementCounter do
  @behaviour PropertyDamage.Command

  # Non-idempotent by design -- exclude from stutter testing
  def idempotent?, do: false

  def generator(_state) do
    StreamData.fixed_map(%{counter_id: StreamData.string(:alphanumeric, length: 8)})
  end
end
```

### `idempotency_key/1`

Return a key string that the adapter can include in requests (e.g., as an HTTP
header). If not implemented, no idempotency key is provided.

```elixir
defmodule CreateOrder do
  @behaviour PropertyDamage.Command

  defstruct [:amount, :idempotency_key]

  def idempotency_key(%__MODULE__{idempotency_key: key}), do: key

  def generator(_state) do
    StreamData.fixed_map(%{
      amount: StreamData.integer(1..10_000),
      idempotency_key: StreamData.string(:alphanumeric, length: 16)
    })
  end
end
```

### `acceptable_retry_events/0`

Declare alternative event types that are valid on retry. A `CreateOrder` retry
might return `OrderAlreadyExists` instead of `OrderCreated` -- both are correct
idempotent behavior.

```elixir
defmodule CreateOrder do
  @behaviour PropertyDamage.Command

  def acceptable_retry_events do
    [OrderCreated, OrderAlreadyExists]
  end
end
```

When acceptable retry events are declared, the framework checks whether all
retry event modules are either in the acceptable list or match the original
event modules. Both count as a match.

## Adapter Integration

On retry executions, the adapter receives stutter context through the
`%PropertyDamage.Runtime{}` handle passed as the third argument to `execute/3`.
On the first (non-retry) execution `runtime.stutter` is `nil` -- only retries
populate it. You can also use `PropertyDamage.Runtime.stuttering?(runtime)` to
test whether the current execution is a retry.

```elixir
defmodule MyAdapter do
  @behaviour PropertyDamage.Adapter

  def execute(
        %CreateOrder{} = cmd,
        _user_context,
        %PropertyDamage.Runtime{stutter: %{idempotency_key: key}}
      )
      when is_binary(key) do
    # Retry execution -- include idempotency header
    headers = [{"Idempotency-Key", key}]
    result = HttpClient.post("/orders", %{amount: cmd.amount}, headers: headers)
    {:ok, [result.event]}
  end

  def execute(%CreateOrder{} = cmd, _user_context, _runtime) do
    # First execution -- runtime.stutter is nil
    result = HttpClient.post("/orders", %{amount: cmd.amount})
    {:ok, [result.event]}
  end
end
```

The `runtime.stutter` map contains:

- `attempt` -- attempt number (2, 3, ...)
- `is_retry` -- always `true` for retry executions
- `idempotency_key` -- the key from `idempotency_key/1`, or `nil`

## Writing Idempotency Invariants

Use an assertion projection to enforce idempotency rules alongside stutter
testing:

```elixir
defmodule IdempotencyProjection do
  use PropertyDamage.Model.Projection

  def init, do: %{seen_keys: MapSet.new(), creation_counts: %{}}

  def apply(state, %OrderCreated{idempotency_key: key}) do
    %{state |
      seen_keys: MapSet.put(state.seen_keys, key),
      creation_counts: Map.update(state.creation_counts, key, 1, &(&1 + 1))
    }
  end

  def apply(state, _event), do: state

  @trigger every: :command
  def assert_no_duplicate_creation(state, _event) do
    duplicates = Enum.filter(state.creation_counts, fn {_k, v} -> v > 1 end)

    if duplicates != [] do
      PropertyDamage.fail!("duplicate creation detected", duplicates: duplicates)
    end
  end
end
```

## Violations

When stutter testing detects a mismatch, it produces a
`PropertyDamage.Stutter.Violation` struct:

```
Idempotency violation at command index 3
Command: CreateOrder
  Attempt 1: [OrderCreated]
  Attempt 2: [OrderCreated]
```

In this example, the SUT created a second order on retry instead of returning
an idempotent response.

To debug violations:

1. Check the **command index** to identify which command in the sequence failed.
2. Compare the **attempt events** -- the first attempt shows expected behavior,
   subsequent attempts show what the retry produced.
3. Use `seed:` to reproduce the exact sequence deterministically.
4. If the violation is expected (e.g., a legitimately non-idempotent command),
   implement `idempotent?/0` returning `false` on that command.

## Full Example

```elixir
# Run with stutter testing, ignoring timestamps in comparison
PropertyDamage.run(
  model: OrderModel,
  adapter: OrderApiAdapter,
  max_runs: 200,
  stutter: [
    probability: 0.3,
    max_repeats: 2,
    delay_ms: {10, 50},
    comparison: {:structural, [:timestamp, :request_id]}
  ]
)
```
