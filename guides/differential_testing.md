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
    {ReferenceAdapter, role: :reference},
    {SUTAdapter, name: "new-impl"}
  ],
  compare: :correctness,
  max_runs: 100
)
```

The reference target's results are treated as "correct" - divergences indicate
bugs in other targets.

### 2. Performance Comparison

Compare implementations for latency and throughput:

```elixir
{:ok, result} = PropertyDamage.Differential.run(
  model: MyModel,
  targets: [
    {RedisAdapter, name: "redis-backend"},
    {PostgresAdapter, name: "postgres-backend"}
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
    {HTTPAdapter, role: :reference, opts: [base_url: "https://prod.example.com"]},
    {HTTPAdapter, name: "staging", opts: [base_url: "https://staging.example.com"]}
  ],
  compare: :correctness
)

# Compare different database configurations
PropertyDamage.Differential.run(
  model: MyModel,
  targets: [
    {DBAdapter, name: "with-cache", opts: [cache: true]},
    {DBAdapter, name: "no-cache", opts: [cache: false]}
  ],
  compare: :both  # Check both correctness and performance
)
```

## Time-Separated Execution

Run tests now, compare against results from later (or vice versa).

### Export a Baseline

```elixir
PropertyDamage.Differential.run(
  model: MyModel,
  targets: [{ProdAdapter, name: "v2.3"}],
  compare: :performance,
  export_to: "baselines/v2.3.json",
  seed: 12345  # Use fixed seed for reproducibility
)
```

### Compare Against Baseline

Days or weeks later:

```elixir
{:ok, result} = PropertyDamage.Differential.run(
  model: MyModel,
  targets: [{ProdAdapter, name: "v2.4"}],
  compare: :performance,
  baseline: "baselines/v2.3.json"
)

if PropertyDamage.Differential.Result.divergent?(result) do
  IO.puts("Performance regression detected!")
  IO.puts(PropertyDamage.Differential.Result.format(result))
end
```

The baseline contains:
- Complete command sequences (as structs, not just seeds)
- Results per command
- Timing data
- Aggregate metrics

This makes baselines portable - they work even if your model changes.

## Execution Modes

### Interleaved (Default for Correctness)

Commands execute round-robin across targets:

```
Target A: cmd1 → cmd2 → cmd3
Target B: cmd1 → cmd2 → cmd3
         ↓     ↓     ↓
      compare compare compare
```

Divergences are detected immediately after each command.

### Sequential (Default for Performance)

Full sequence runs on each target:

```
Target A: cmd1 → cmd2 → cmd3 → cmd4 → cmd5
                                         ↓
Target B: cmd1 → cmd2 → cmd3 → cmd4 → cmd5
                                         ↓
                                     compare
```

Better for performance testing - no context switching overhead.

### Specifying Execution Mode

```elixir
PropertyDamage.Differential.run(
  model: MyModel,
  targets: [...],
  compare: :correctness,
  execution: :sequential  # Override default
)
```

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
# => :equivalent | :divergent | :complete

# Check for divergences
if PropertyDamage.Differential.Result.divergent?(result) do
  IO.puts("Found #{length(result.divergences)} divergences")

  for div <- result.divergences do
    IO.puts("Step #{div.step}: #{inspect(div.command)}")
    IO.puts("  Reference: #{inspect(div.reference_result)}")
    IO.puts("  #{div.divergent_target}: #{inspect(div.divergent_result)}")
  end
end

# Get metrics per target
for target <- result.targets do
  metrics = PropertyDamage.Differential.Result.metrics_for(result, target)
  IO.puts("#{target}: p50=#{metrics.latency_p50}µs, p99=#{metrics.latency_p99}µs")
end
```

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
{AdapterModule}
{AdapterModule, opts}

# opts can include:
#   name:  Display name (default: derived from module)
#   role:  :reference for oracle testing
#   opts:  Options passed to adapter's setup/1
```

### Optional Options

| Option | Default | Description |
|--------|---------|-------------|
| `:max_commands` | 50 | Maximum commands per sequence |
| `:max_runs` | 100 | Number of test sequences |
| `:seed` | random | Random seed for reproducibility |
| `:execution` | auto | `:interleaved` or `:sequential` |
| `:equivalence` | `:exact` | Equivalence strategy |
| `:baseline` | nil | Path to baseline file |
| `:export_to` | nil | Path to export results |
| `:warmup_runs` | 0 | Runs to discard before measuring |
| `:verbose` | false | Print progress |
| `:on_progress` | nil | Progress consumer (see [Monitoring Progress](#monitoring-progress)) |

## Monitoring Progress

Pass an `on_progress` function to observe a run as it happens. It receives a
`%PropertyDamage.Progress{}` projection (DR-022): a `DifferentialUpdate` per run
(interleaved) or per target (sequential), then a terminal `DifferentialResult`
carrying a copy of the final result. The same stream also drives `verbose:` and
the `[:property_damage, :differential, :progress | :result]` telemetry events.

```elixir
alias PropertyDamage.Progress
alias PropertyDamage.Progress.{DifferentialResult, DifferentialUpdate}

PropertyDamage.Differential.run(
  model: MyModel,
  targets: [{OracleAdapter, role: :reference}, {SUTAdapter, name: "new-impl"}],
  compare: :correctness,
  on_progress: fn
    %Progress{data: %DifferentialUpdate{phase: :run, run_number: n, total_runs: total}} ->
      IO.puts("run #{n}/#{total}")

    %Progress{data: %DifferentialUpdate{phase: :target, target_name: name}} ->
      IO.puts("running target #{name}")

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
        {SQLAdapter, role: :reference, name: "postgres",
         opts: [url: "postgres://localhost/orders"]},
        {SQLAdapter, name: "cockroach",
         opts: [url: "postgres://localhost:26257/orders"]}
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
    {HTTPAdapter, role: :reference, name: "v1",
     opts: [base_url: "https://api.example.com/v1"]},
    {HTTPAdapter, name: "v2",
     opts: [base_url: "https://api.example.com/v2"]}
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

1. **Use fixed seeds for baselines** - Makes comparisons reproducible

2. **Start with structural equivalence** - Exact matching often fails on
   auto-generated fields

3. **Warmup for performance tests** - Discard initial runs to avoid JIT effects

4. **Export baselines before deployments** - Create a comparison point

5. **Use interleaved for bug finding** - Detects divergences immediately

6. **Use sequential for performance** - Avoids context-switching overhead

7. **Compare in CI** - Catch regressions before they reach production

## What Differential Testing Detects

- Implementation bugs (oracle testing)
- Performance regressions
- Behavior changes between versions
- Environment-specific bugs
- Race conditions (with interleaved execution)
- Data migration errors

## Next Steps

- See `PropertyDamage.Differential` module docs for full API
- Read about [Chaos Engineering](chaos_engineering.md) for fault injection
- Use [Integration Testing](integration_testing.md) for live service testing
