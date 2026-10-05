# Differential Testing

PropertyDamage supports differential testing: `PropertyDamage.run/1` takes several
`targets:` and runs the same command sequences against all of them, comparing
the results. One target is an ordinary run; two or more targets add the comparison.

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
PropertyDamage.run(
  model: MyModel,
  targets: [
    ReferenceAdapter,
    {SUTAdapter, name: "new-impl"}
  ],
  compare: :correctness,
  max_runs: 100
)
```

The first target in the `targets:` list is the reference oracle: its results are
treated as "correct" and a divergence indicates a bug in another target. The call
returns `{:ok, stats}` when no run failed, or `{:error, report}` when a target
diverged or failed (see [Understanding Results](#understanding-results)).

### 2. Performance Comparison

Compare implementations for latency and throughput:

```elixir
{:ok, stats} = PropertyDamage.run(
  model: MyModel,
  targets: [
    {RedisAdapter, name: "redis", config: %{host: "localhost"}},
    {PostgresAdapter, name: "postgres", config: %{url: "postgres://localhost/db"}}
  ],
  compare: :performance,
  max_runs: 100,
  warmup_runs: 10
)

for {name, metrics} <- stats.metrics do
  IO.puts("#{name}: p50=#{metrics.latency_p50}µs, p99=#{metrics.latency_p99}µs")
end
```

### 3. Same Adapter, Different Configs

A powerful pattern is comparing the same adapter with different configurations:

```elixir
# Compare staging vs production
PropertyDamage.run(
  model: MyModel,
  targets: [
    {HTTPAdapter, name: "prod", config: %{base_url: "https://prod.example.com"}},
    {HTTPAdapter, name: "staging", config: %{base_url: "https://staging.example.com"}}
  ],
  compare: :correctness
)

# Compare different database configurations
PropertyDamage.run(
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
reference. That is a divergence, and it is a failure like any other: it ends the
campaign, the framework shrinks the sequence and reproduces it, and `run/1`
returns `{:error, report}` with `kind: :diverged`. The report is the only record: no later run starts.

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
PropertyDamage.run(
  model: MyModel,
  targets: [...],
  compare: :correctness,
  concurrency: :parallel
)
```

`compare: :performance` and `compare: :both` require `concurrency: :serial`,
because overlapping targets would mix their load into each other's latency.

The `execution:` option is removed. Passing it raises an option error that
names `concurrency:`.

### Setup and teardown per run

Every run sets every target up and tears it down again. Each variant calls
`Adapter.setup/1` in its own process, one variant after another in target
order. No variant executes the first command before every setup has returned.
If a setup fails, the run ends with a `:setup_failed` report that names the
variant, and the variants already set up are torn down.

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
operation. The id fields then surface as divergent answers under exact
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

`run/1` returns `{:ok, stats}` when no run failed in any kind, and
`{:error, report}` (a `%PropertyDamage.FailureReport{}`) for the first run that did.

```elixir
case PropertyDamage.run(model: MyModel, targets: [ReferenceAdapter, NewAdapter], max_runs: 100) do
  {:ok, stats} ->
    # stats.targets is a list of %{index: i, name: n}; the first is the reference
    IO.puts("#{stats.runs} runs agreed across #{length(stats.targets)} targets")

  {:error, %PropertyDamage.FailureReport{kind: :diverged} = report} ->
    %{index: _, name: name} = report.variant
    IO.puts("#{name} diverged at root #{report.failed_at_index}")

    for command <- PropertyDamage.Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(report)) do
      IO.puts("  #{inspect(command)}")
    end

    IO.puts(PropertyDamage.FailureReport.reproduction_command(report))

  {:error, %PropertyDamage.FailureReport{kind: kind, variant: variant}} ->
    IO.puts("#{kind} in #{variant.name}")
end
```

### Divergences

A divergence is a report with `kind: :diverged`. It carries:

| Field | Meaning |
|-------|---------|
| `variant` | `%{index, name}` of the first target that answered differently from the reference |
| `failed_at_index` | 0-based index of the root where it diverged |
| `failure_reason` | a `%PropertyDamage.Failure{}` of type `Failure.Divergence`, holding `root`, `reference_result`, `divergent_result` and `results` (every target's answer, keyed by target name) |
| `targets` | the run's `targets:` entries, so the reproduction names the same targets |
| `concurrency` | `:serial` or `:parallel` |
| `seed` | the campaign seed |

The framework shrinks a divergence before it reports it. Every shrink attempt
runs the candidate sequence on every target, each set up and torn down for that
attempt. A candidate counts only if the same target still diverges, with the
same failure kind, at the same or an earlier root. The reference's sequence is
what shrinks, because all targets run the same commands.
`PropertyDamage.FailureReport.shrunk_sequence/1` returns the shrunk sequence, and
`PropertyDamage.FailureReport.reproduction_command/1` returns a command that
reruns the failure with the exact `targets:` entries (non-default `name:` and
`config:`) and a non-default `concurrency:`.

Under `check_mode: :record`, a check failure recorded at or before the
divergence root is reported instead of the divergence.

An answer is `{:ok, events}` (the events the command injected, then the events
it returned; for a `:probe` or `:async` command, the events it settled to) or
`{:error, reason}` (the adapter's own error). With two or more targets, an
adapter error is an answer like any other: it is compared, and the target
continues. With one target it ends the run with kind `:execution_failed`.

### Failure kinds

Every failed run is a report with a `kind`, the `variant` that failed and
`failed_at_index`, the failing root. `failed_at_index` is `nil` for a setup
failure and for a startup check, which belong to no command.

| Kind | Meaning |
|------|---------|
| `:check_failed` | A check failed in that target, at a command, at the `:startup` phase, or while the run finished (an `@eventually` timeout, a `:teardown` check). |
| `:diverged` | The target's answer at a root differs from the reference's under `equivalence:`. |
| `:setup_failed` | `setup/1` returned an error or raised. An injector or mock setup that raised inside the target counts too. A setup failure is not shrunk. |
| `:execution_failed` | The adapter raised at a root, or answered `{:error, _}` in a one-target run, or a nemesis, stutter or placeholder step failed. |

`:execution_failed` is provisional. Whether an agreed adapter error counts as a
comparable answer in every run, a one-target run included, is not decided yet.

### Performance metrics

Under `compare: :performance` or `:both`, `stats.metrics` maps each target name to
its latency metrics (`latency_p50`, `latency_p95`, `latency_p99`, `latency_mean`,
`latency_min`, `latency_max`, in microseconds, plus `total_commands` and
`error_count`):

```elixir
{:ok, stats} = PropertyDamage.run(model: MyModel, targets: targets, compare: :performance)

for {name, metrics} <- stats.metrics do
  IO.puts("#{name}: p50=#{metrics.latency_p50}µs, p99=#{metrics.latency_p99}µs")
end
```

### What stays one-target

Branching sequences run against one target: `branching:` with two or more
targets is an option error. `PropertyDamage.replay/2`,
`PropertyDamage.Analysis.isolate_trigger/2` and `PropertyDamage.RunTrace` work on
the report's reference target (with its name and config).
`PropertyDamage.shrink_further/2` re-shrinks with `report.targets` by default;
pass `targets:` (one or more entries), `concurrency:` or `equivalence:` to
override.

## Options Reference

### Required Options

| Option | Description |
|--------|-------------|
| `:model` | Model module implementing `PropertyDamage.Model` |
| `:targets` | List of target specifications (one or more) |

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
| `:compare` | `:correctness` | `:correctness`, `:performance`, or `:both` |
| `:equivalence` | `:exact` | `:exact`, `:structural` or a 2-arity function |
| `:metrics`, `:percentiles` | | Parameters of the performance metrics |
| `:warmup_runs` | 0 | Runs to discard before measuring |
| `:check_mode` | `:halt` | How a failing check is handled |
| `:verbose` | false | Print progress |
| `:on_progress` | nil | Progress consumer (see [Monitoring Progress](#monitoring-progress)) |

## Monitoring Progress

Pass an `on_progress` function to observe a run as it happens. It receives a
`%PropertyDamage.Progress{}` projection (DR-022): the same `RunUpdate` and
`RunResult` payloads as a one-target run. `RunResult` carries the failure `kind`
and the failing `variant`, and the verbose printer prints the failure kind and
the target name. The same stream drives `verbose:`.

The engine also emits `[:property_damage, :command, :start | :stop]` and
`[:property_damage, :check, :start | :stop]` telemetry events with
`variant: %{index, name}` and `run_number`, and
`[:property_damage, :sequence, :stop]` carries the `variant` the run failed in
(`nil` when it passed). Shrink attempts and the reproduction use `run_number: 0`.
Nothing is emitted unless a handler is attached.

```elixir
alias PropertyDamage.Progress
alias PropertyDamage.Progress.RunResult

PropertyDamage.run(
  model: MyModel,
  targets: [OracleAdapter, {SUTAdapter, name: "new-impl"}],
  on_progress: fn
    %Progress{data: %RunResult{kind: kind, variant: variant}} when not is_nil(kind) ->
      IO.puts("#{kind} in #{variant.name}")

    %Progress{} ->
      :ok
  end
)
```

The authoritative result is the return value of `run/1`.

## Example: Migration Validation

Testing a database migration from PostgreSQL to CockroachDB:

```elixir
defmodule MigrationTest do
  def validate_migration do
    # Define adapter that works with both databases
    # (same schema, different connection strings)

    result = PropertyDamage.run(
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

    case result do
      {:ok, stats} ->
        IO.puts("Migration validated! Results are equivalent.")
        IO.puts("Performance comparison:")

        for {name, metrics} <- stats.metrics do
          IO.puts("#{name}: p50=#{metrics.latency_p50}µs, p99=#{metrics.latency_p99}µs")
        end

      {:error, %PropertyDamage.FailureReport{kind: :diverged} = report} ->
        IO.puts("DIVERGENCE DETECTED in #{report.variant.name}!")
        IO.puts(PropertyDamage.FailureReport.reproduction_command(report))

      {:error, %PropertyDamage.FailureReport{kind: kind, variant: variant}} ->
        IO.puts("#{kind} in #{variant.name} before the comparison finished.")
    end
  end
end
```

## Example: API Version Comparison

Comparing v1 and v2 of an API:

```elixir
PropertyDamage.run(
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

- See the `PropertyDamage.run/1` docs for the full API, and `PropertyDamage.FailureReport` for the report
- Read about [Chaos Engineering](chaos_engineering.md) for fault injection
- Use [Integration Testing](integration_testing.md) for live service testing
