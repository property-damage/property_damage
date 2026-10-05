# Differential Testing

PropertyDamage supports differential testing - running the same command sequences
against multiple implementations and comparing results.

## What is Differential Testing?

Differential testing answers: **"Do these implementations behave the same?"**

Instead of defining expected outcomes, you compare outputs from different sources.
If they diverge, something is wrong. This is particularly powerful when you have:

- A reference implementation (oracle) to compare against
- Two systems that should be equivalent
- Old vs new versions during migrations

## Use Cases

| Use Case | Description |
|----------|-------------|
| **Oracle Testing** | Compare SUT against a known-correct reference implementation |
| **Performance Comparison** | Compare latency/throughput across backends |
| **Regression Testing** | Compare old vs new versions of the same system |
| **Migration Validation** | Verify legacy and new systems produce identical results |
| **Environment Comparison** | Compare staging vs production behavior |

## Quick Start

### 1. Oracle Testing (Correctness)

Compare your system under test against a reference implementation:

```elixir
PropertyDamage.Differential.run(
  model: MyModel,
  targets: [
    ReferenceAdapter,
    {SUTAdapter, name: "new-impl"}
  ],
  compare: :correctness,
  max_runs: 100
)
```

The first target in the `targets:` list is the reference oracle - its results are
treated as "correct" and divergences indicate bugs in other targets.

### 2. Performance Comparison

Compare implementations for latency and throughput:

```elixir
{:ok, result} = PropertyDamage.Differential.run(
  model: MyModel,
  targets: [
    {RedisAdapter, name: "redis", config: %{host: "localhost"}},
    {PostgresAdapter, name: "postgres", config: %{url: "postgres://localhost/db"}}
  ],
  compare: :performance,
  max_runs: 100,
  warmup_runs: 10
)

IO.puts(PropertyDamage.Differential.Result.format(result, format: :full))
```

### 3. Same Adapter, Different Configs

A powerful pattern is comparing the same adapter with different configurations:

```elixir
# Compare staging vs production
PropertyDamage.Differential.run(
  model: MyModel,
  targets: [
    {HTTPAdapter, name: "prod", config: %{base_url: "https://prod.example.com"}},
    {HTTPAdapter, name: "staging", config: %{base_url: "https://staging.example.com"}}
  ],
  compare: :correctness
)

# Compare different database configurations
PropertyDamage.Differential.run(
  model: MyModel,
  targets: [
    {DBAdapter, name: "with-cache", config: %{cache: true}},
    {DBAdapter, name: "no-cache", config: %{cache: false}}
  ],
  compare: :both  # Check both correctness and performance
)
```

## How a Run Executes

Each run generates one command sequence and runs it against every target in
**lockstep**. Every command is a root. Every target executes root `r`, the
comparison runs, and only then does any target start root `r + 1`:

```
Target A: cmd1 → cmd2 → cmd3
Target B: cmd1 → cmd2 → cmd3
         ↓       ↓       ↓
      compare compare compare
```

Each target runs as a **variant**: its own process, with its own projections,
event queue, injectors, mocks and pollers. A variant runs the full engine, so
checks, settle, stutter and nemesis work as they do in `PropertyDamage.run/1`.

A run stops at the first root where a target answers differently from the
reference. That is a divergence. The next run starts from a fresh setup.

### Concurrency

`concurrency:` decides how the variants reach each boundary:

| Value | Behavior |
|-------|----------|
| `:serial` (default) | One variant at a time, in target order. Commands never overlap. |
| `:parallel` | All variants at once. The run takes about as long as its slowest target. |

Under `:parallel`, targets that share a system must isolate their slices of it
through `config:` (a tenant or a key prefix per target). Otherwise one target's
command changes what another observes.

```elixir
PropertyDamage.Differential.run(
  model: MyModel,
  targets: [...],
  compare: :correctness,
  concurrency: :parallel
)
```

`compare: :performance` and `compare: :both` require `concurrency: :serial`,
because overlapping targets would mix their load into each other's latency.

The old `execution:` option is removed. Passing it raises an option error that
names `concurrency:`.

### Setup and teardown per run

Every run sets every target up and tears it down again. Each variant calls
`Adapter.setup/1` in its own process, one variant after another in target
order. No variant executes the first command before every setup has returned.
If a setup fails, the run ends with a failure that names the variant, and the
variants already set up are torn down.

So `setup/1` runs once per run per target, and it may find state that an
earlier run left behind. Write it to be idempotent (see the `setup/1` notes in
`PropertyDamage.Adapter`).

### Pollers, injectors and mocks

An adapter may call `runtime.start_poller` in a multi-target run, and a target
may declare `injectors:` and `mocks:` in its `targets:` entry. Each belongs to
its own variant: its events reach that variant only, and its pollers stop when
the variant ends.

## Server-Generated Values (`external()`)

Sequences that chain a server-generated id work under differential testing. When
a command produces a value its event marks with `external()` (see the "External
Field Markers" section of the [Writing Commands](writing_commands.md) guide), the
captured concrete value is resolved into any later command that consumes it,
exactly as in `PropertyDamage.run/1`.

Each target captures its own values: the same consumer placeholder resolves to
whatever *that* adapter produced. This is the point under differential testing,
since two implementations legitimately hand out different ids for the same
operation. The id fields then surface as ordinary divergences under exact
equivalence; ignore them with a [structural or custom](#equivalence-strategies)
strategy if only the rest of the payload matters.

## Equivalence Strategies

For correctness comparison, results must be "equivalent". Configure this:

### Exact (Default)

Results must be identical:

```elixir
compare: :correctness,
equivalence: :exact
```

### Structural

Ignores common non-deterministic fields (id, timestamps, uuids):

```elixir
compare: :correctness,
equivalence: :structural
```

This normalizes:
- Fields named `id`, `uuid`, `ref`, `*_id`, `*_ref`
- Fields named `*_at`, `timestamp`, `created`, `updated`
- UUIDs matching standard format
- ISO8601 datetime strings

### Custom Function

Define your own equivalence logic:

```elixir
compare: :correctness,
equivalence: fn reference_result, target_result ->
  # Custom comparison logic
  case {reference_result, target_result} do
    {{:ok, ref_data}, {:ok, target_data}} ->
      # Compare only specific fields
      ref_data.status == target_data.status &&
        ref_data.amount == target_data.amount

    {{:error, _}, {:error, _}} ->
      # Both errored - consider equivalent
      true

    _ ->
      false
  end
end
```

## Understanding Results

```elixir
{:ok, result} = PropertyDamage.Differential.run(...)

# Check status
result.status
# => :equivalent | :divergent | :failed

# The reference and every target are %{index: i, name: n}
result.reference
# => %{index: 0, name: "ReferenceAdapter"}

# Check for divergences
if PropertyDamage.Differential.Result.divergent?(result) do
  IO.puts("Found #{length(result.divergences)} divergences")

  for div <- result.divergences do
    IO.puts("Run #{div.run}, root #{div.root}: #{inspect(div.command)}")
    IO.puts("  Reference: #{inspect(div.reference_result)}")
    IO.puts("  #{div.variant.name}: #{inspect(div.divergent_result)}")
  end
end

# Check for a failure
if result.status == :failed do
  %{kind: kind, variant: variant, run: run, root: root, reason: reason} = result.failure
  IO.puts("#{kind} in #{variant.name} (run #{run}, root #{inspect(root)}): #{inspect(reason)}")
end

# Get metrics per target
for %{name: name} <- result.targets do
  metrics = PropertyDamage.Differential.Result.metrics_for(result, name)
  IO.puts("#{name}: p50=#{metrics.latency_p50}µs, p99=#{metrics.latency_p99}µs")
end
```

### Divergences

Each entry of `result.divergences` is a map with these keys:

| Key | Meaning |
|-----|---------|
| `variant` | `%{index, name}` of the target that diverged |
| `root` | 0-based index of the command where it diverged |
| `run` | 0-based run that found it |
| `command` | the command struct |
| `reference_result` | the reference target's answer |
| `divergent_result` | the divergent target's answer |
| `results` | every target's answer, keyed by target name |
| `seed` | the campaign seed |

`result.divergences` lists the divergences oldest first. Nothing is shrunk: a
divergence is the first differing root of its generated sequence.

An answer is `{:ok, events}` (the events the command injected, then the events
it returned; for a `:probe` or `:async` command, the events it settled to) or
`{:error, reason}` (the adapter's own error). With two or more targets, an
adapter error is an answer like any other: it is compared, and the target
continues. With one target it ends the run, as in `PropertyDamage.run/1`.

### Failures

A failure ends the whole campaign: no later run starts. The result then has
`status: :failed`, and divergences found in earlier runs stay listed.
`result.failure` is a map:

| Key | Meaning |
|-----|---------|
| `kind` | `:check_failed`, `:setup_failed` or `:execution_failed` |
| `variant` | `%{index, name}` of the target it happened in |
| `run` | 0-based run |
| `root` | 0-based command index, or `nil` when no command is to blame |
| `reason` | the `%PropertyDamage.Failure{}`, the exception the adapter raised, or what `setup/1` returned |

- `:check_failed`: a check failed in that target, at a command, at the
  `:startup` phase (`root` is `nil`), or while the run finished (an
  `@eventually` timeout, a `:teardown` check).
- `:setup_failed`: `setup/1` returned an error or raised.
- `:execution_failed`: the adapter raised, a command could not be executed, or
  the target's process crashed. A failure is never compared.

### Result Formatting

```elixir
# Summary
IO.puts(PropertyDamage.Differential.Result.format(result))

# Full with metrics and divergences
IO.puts(PropertyDamage.Differential.Result.format(result, format: :full))

# Just metrics
IO.puts(PropertyDamage.Differential.Result.format(result, format: :metrics))

# Just divergences
IO.puts(PropertyDamage.Differential.Result.format(result, format: :divergences))
```

## Options Reference

### Required Options

| Option | Description |
|--------|-------------|
| `:model` | Model module implementing `PropertyDamage.Model` |
| `:targets` | List of target specifications |
| `:compare` | `:correctness`, `:performance`, or `:both` |

### Target Specification

```elixir
AdapterModule                           # Bare module name
{AdapterModule, name: "display-name"}   # Explicit display name
{AdapterModule, config: %{key: value}}  # Configuration for setup/1
{AdapterModule, name: "name", config: %{key: value}}  # Both
```

The **first entry in the `targets:` list is the reference oracle** (no special marker needed).
The `config:` option is a map of key-value pairs passed to the adapter's `setup/1` callback.
Each target may have the same adapter module with different configs for isolation
(e.g., distinct tenants).

A bare module takes its last module segment as its name (`MyApp.ReferenceAdapter`
is `"ReferenceAdapter"`). Two entries must not share a name, so give entries on the
same adapter distinct `name:` values.

An entry may also carry `injectors:` (a list of injector adapter modules) and
`mocks:` (a list of `Mod` or `{Mod, config_map}`). Both are set up per run for that
target only.

### Isolating Targets on the Same System

When comparing two targets that run on the same system (for example, the same
database server), isolation is critical to avoid state leakage. The `config:` field
is your isolation boundary: pass a distinct tenant, schema, database name, or port
to each target so they do not collide. For example, when testing two database
configurations against the same PostgreSQL server, pass a different database name
to each:

```elixir
targets: [
  {DBAdapter, name: "replica-1", config: %{db: "test_db_1"}},
  {DBAdapter, name: "replica-2", config: %{db: "test_db_2"}}
]
```

The `mix pd.validate --targets "<list>"` command warns when two targets share the
same adapter module *and* an identical `config:`, since that usually signals a
configuration mistake. Fix it by giving each target its own config.

### Optional Options

| Option | Default | Description |
|--------|---------|-------------|
| `:max_commands` | 50 | Maximum commands per sequence |
| `:max_runs` | 100 | Number of test sequences |
| `:seed` | random | Random seed for reproducibility |
| `:concurrency` | `:serial` | `:serial` or `:parallel` (see [Concurrency](#concurrency)) |
| `:equivalence` | `:exact` | Equivalence strategy |
| `:warmup_runs` | 0 | Runs to discard before measuring |
| `:verbose` | false | Print progress |
| `:on_progress` | nil | Progress consumer (see [Monitoring Progress](#monitoring-progress)) |

## Monitoring Progress

Pass an `on_progress` function to observe a run as it happens. It receives a
`%PropertyDamage.Progress{}` projection (DR-022): a `DifferentialUpdate` per run,
then a terminal `DifferentialResult`
carrying a copy of the final result. The same stream also drives `verbose:` and
the `[:property_damage, :differential, :progress | :result]` telemetry events.

```elixir
alias PropertyDamage.Progress
alias PropertyDamage.Progress.{DifferentialResult, DifferentialUpdate}

PropertyDamage.Differential.run(
  model: MyModel,
  targets: [OracleAdapter, {SUTAdapter, name: "new-impl"}],
  compare: :correctness,
  on_progress: fn
    %Progress{data: %DifferentialUpdate{phase: :run, run_number: n, total_runs: total}} ->
      IO.puts("run #{n}/#{total}")

    %Progress{data: %DifferentialResult{result: result}} ->
      IO.puts("done: #{result.status}")
  end
)
```

The authoritative result is still the `{:ok, result}` return value;
`DifferentialResult` is a copy emitted for consumers.

## Example: Migration Validation

Testing a database migration from PostgreSQL to CockroachDB:

```elixir
defmodule MigrationTest do
  def validate_migration do
    # Define adapter that works with both databases
    # (same schema, different connection strings)

    {:ok, result} = PropertyDamage.Differential.run(
      model: OrderModel,
      targets: [
        {SQLAdapter, name: "postgres",
         config: %{url: "postgres://localhost/orders"}},
        {SQLAdapter, name: "cockroach",
         config: %{url: "postgres://localhost:26257/orders"}}
      ],
      compare: :both,
      max_runs: 500,
      equivalence: :structural,  # Ignore auto-generated IDs
      verbose: true
    )

    case result.status do
      :equivalent ->
        IO.puts("Migration validated! Results are equivalent.")
        IO.puts("Performance comparison:")
        IO.puts(PropertyDamage.Differential.Result.format(result, format: :metrics))

      :divergent ->
        IO.puts("DIVERGENCE DETECTED!")
        IO.puts(PropertyDamage.Differential.Result.format(result, format: :full))

      :failed ->
        IO.puts("A target failed before the comparison finished.")
        IO.puts(PropertyDamage.Differential.Result.format(result, format: :full))
    end
  end
end
```

## Example: API Version Comparison

Comparing v1 and v2 of an API:

```elixir
PropertyDamage.Differential.run(
  model: UserModel,
  targets: [
    {HTTPAdapter, name: "v1",
     config: %{base_url: "https://api.example.com/v1"}},
    {HTTPAdapter, name: "v2",
     config: %{base_url: "https://api.example.com/v2"}}
  ],
  compare: :correctness,
  equivalence: fn v1_result, v2_result ->
    # V2 returns additional fields - only compare common ones
    case {v1_result, v2_result} do
      {{:ok, v1}, {:ok, v2}} ->
        Map.take(v2, Map.keys(v1)) == v1
      _ ->
        v1_result == v2_result
    end
  end
)
```

## Best Practices

1. **Use fixed seeds** - Makes comparisons reproducible

2. **Start with structural equivalence** - Exact matching often fails on
   auto-generated fields

3. **Warmup for performance tests** - Discard initial runs to avoid JIT effects

4. **Keep `concurrency: :serial` for performance** - Overlapping targets mix
   their load into each other's latency

5. **Make `setup/1` idempotent** - Every run calls it again, and a crashed run
   may have left state behind

6. **Compare in CI** - Catch regressions before they reach production

## What Differential Testing Detects

- Implementation bugs (oracle testing)
- Performance regressions
- Behavior changes between versions
- Environment-specific bugs
- Race conditions (with `concurrency: :parallel`, when the targets are isolated)
- Data migration errors

## Next Steps

- See `PropertyDamage.Differential` module docs for full API
- Read about [Chaos Engineering](chaos_engineering.md) for fault injection
- Use [Integration Testing](integration_testing.md) for live service testing
