# Idempotency Testing with Stutter

PropertyDamage's stutter testing automatically retries commands against your SUT
to verify idempotent behavior. This guide covers configuration, the `using:`
predicate that compares a retry, and writing commands that participate in idempotency testing.

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
  targets: [MyAdapter],
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
| `using` | `(original_events, retry_events -> answer)` | `&==/2` | How to compare original and retry events (see below) |

### Targeting Specific Commands

Limit stutter testing to particular commands:

```elixir
stutter: [
  probability: 0.5,
  commands: [CreateOrder, SubmitPayment]
]
```

## Comparing a Retry with `using:`

A retry agrees with the original when the `using:` predicate accepts it. The
predicate is a 2-arity function called `using.(original_events, retry_events)`,
with the same contract as `@compare`'s `using:` (see
[Differential Testing](differential_testing.md#using-the-agreement-predicate)).
It returns `:match` or `true` when the retry agrees, and `false`,
`{:mismatch, "text"}` or `{:mismatch, exception}` when it does not.

### Default: `==`

Without `using:`, the retry events must equal the original events under `==/2`:

```elixir
stutter: [probability: 0.3]
```

Use when your SUT returns identical responses on retry (same JSON body, same
event payloads).

### Ignoring non-deterministic fields

Strip the fields that legitimately differ with `PropertyDamage.Equivalence`:

```elixir
import PropertyDamage.Equivalence

stutter: [
  using: by_key(fn events -> drop_keys(events, [:timestamp, :updated_at, :request_id]) end)
]
```

`by_key/1` compares the two keys under `==/2` and keeps both in the mismatch, so
a violation shows the events as the key function saw them.

### Accepting an alternative answer

A `CreateOrder` retry might return `OrderAlreadyExists` instead of
`OrderCreated`: both are correct idempotent behavior. Write a predicate that
accepts it:

```elixir
stutter: [
  using: fn original, retry ->
    cond do
      original == retry -> :match
      Enum.all?(retry, &match?(%OrderAlreadyExists{}, &1)) -> :match
      true -> {:mismatch, "retry returned #{inspect(retry)}, expected #{inspect(original)}"}
    end
  end
]
```

The mismatch is an exception: by default a `PropertyDamage.ComparisonMismatch`
holding the original and the retry events, or the text you returned.

The predicate is an ordinary function, so you can try it directly. Here
`PropertyDamage.Equivalence.verdict/3` shows how the framework reads its answer:

<!-- pd-doc-verify: runnable -->
```elixir
accept_already_exists = fn original, retry ->
  if original == retry or Enum.all?(retry, &(&1 == :already_exists)),
    do: :match,
    else: {:mismatch, "retry differs"}
end

config = PropertyDamage.Stutter.parse_config(probability: 0.3, using: accept_already_exists)

:match = PropertyDamage.Equivalence.verdict(config.using, [:created], [:already_exists])
{:mismatch, %PropertyDamage.ComparisonMismatch{message: "retry differs"}} =
  PropertyDamage.Equivalence.verdict(config.using, [:created], [:created, :created])

# Without using:, events must be equal under ==/2
default = PropertyDamage.Stutter.parse_config(probability: 0.3)
:match = PropertyDamage.Equivalence.verdict(default.using, [:created], [:created])
{:mismatch, %PropertyDamage.ComparisonMismatch{left: [:created], right: [:gone]}} =
  PropertyDamage.Equivalence.verdict(default.using, [:created], [:gone])
```

The options `comparison:` (with `:strict`, `{:structural, _}`, `{:custom, _}`)
and the command key `acceptable_retry_events:` are removed. Passing either is
an error that names `using:`.

## Command Configuration

Commands interact with stutter testing through one `command_spec/1` key and one
per-instance callback.

### `idempotent:` spec key

Set `idempotent: false` to exclude a command from stutter testing. Commands are
assumed idempotent by default.

<!-- pd-doc-verify: runnable -->
```elixir
defmodule IncrementCounter do
  # Non-idempotent by design -- exclude from stutter testing
  use PropertyDamage.Command, idempotent: false

  defstruct [:counter_id]

  @impl true
  def generator(_overrides) do
    StreamData.fixed_map(%{counter_id: StreamData.string(:alphanumeric, length: 8)})
  end
end
```

### `idempotency_key/1` callback

Return a key string that the adapter can include in requests (e.g., as an HTTP
header). This is a per-instance callback (it reads the command struct). If not
implemented, no idempotency key is provided.

<!-- pd-doc-verify: runnable -->
```elixir
defmodule CreateOrder do
  use PropertyDamage.Command

  defstruct [:amount, :idempotency_key]

  @impl true
  def idempotency_key(%__MODULE__{idempotency_key: key}), do: key

  @impl true
  def generator(_overrides) do
    StreamData.fixed_map(%{
      amount: StreamData.integer(1..10_000),
      idempotency_key: StreamData.string(:alphanumeric, length: 16)
    })
  end
end
```

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

Use a check projection to enforce idempotency rules alongside stutter
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

  @check every: :command
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
an idempotent response. The violation's `mismatch` field holds the exception the
`using:` predicate produced (by default a `PropertyDamage.ComparisonMismatch`
with the original and the retry events).

Idempotency violations are **shrunk** like any other failure: the framework
re-runs candidate sequences with stutter forced on so the violation reproduces
regardless of the offending command's position, then minimizes to the smallest
sequence that still violates (often the single non-idempotent command). The
reported sequence is therefore the minimal reproduction, not the full random
sequence that first tripped it. Stutter decisions are deterministic per seed, so
re-running with the reported `seed:` reproduces the same violation.

To debug violations:

1. Check the **command index** to identify which command in the sequence failed.
2. Compare the **attempt events** -- the first attempt shows expected behavior,
   subsequent attempts show what the retry produced.
3. Use `seed:` to reproduce the exact sequence deterministically.
4. If the violation is expected (e.g., a legitimately non-idempotent command),
   set `idempotent: false` in that command's `command_spec/1`.

## Full Example

```elixir
# Run with stutter testing, ignoring timestamps in the comparison
import PropertyDamage.Equivalence

PropertyDamage.run(
  model: OrderModel,
  targets: [OrderApiAdapter],
  max_runs: 200,
  stutter: [
    probability: 0.3,
    max_repeats: 2,
    delay_ms: {10, 50},
    using: by_key(&drop_keys(&1, [:timestamp, :request_id]))
  ]
)
```
