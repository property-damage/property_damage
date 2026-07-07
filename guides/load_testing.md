# Load Testing with PropertyDamage

This guide covers running sustained load tests against your system using
PropertyDamage's arrival rate scheduling and worker pool architecture.

## Overview

Load testing differs from integration testing:

| Aspect | Integration Testing | Load Testing |
|--------|---------------------|--------------|
| Goal | Find bugs via randomized sequences | Measure performance under sustained load |
| Duration | Short (seconds) | Long (minutes to hours) |
| Concurrency | Sequential or low | High concurrent arrivals |
| Metrics | Pass/fail, bug count | Throughput, latency, error rates |

PropertyDamage load testing uses an **arrival rate model**:

```
Runner (GenServer)
  ├── Metrics (GenServer) - Collects metrics from all workers
  ├── WorkerPool (GenServer) - Manages workers with persistent contexts
  │   ├── Worker 1 - Holds adapter context, executes sequences
  │   ├── Worker 2
  │   └── Worker N
  └── Arrivals (Tasks) - Spawned at configured rate
```

Each **arrival** checks out a worker, runs a command sequence, then returns
the worker to the pool. The arrival rate controls how many new sequences
start per second.

## Quick Start

```elixir
alias PropertyDamage.LoadTest.{Runner, Report}

# Start a load test
{:ok, runner} = Runner.start_link(
  model: MyApp.Model,
  adapter: MyApp.HTTPAdapter,
  adapter_config: %{base_url: "http://localhost:4000"},
  arrival_rate: 50,           # 50 new sequences per second
  duration: {2, :minutes}
)

# Wait for completion
{:ok, report} = Runner.await(runner)

# Display results
IO.puts(Report.format(report, :terminal))

# Or save to file
Report.save(report, "load_test_report.md", :markdown)
```

### The `run/1` entry point

The Quick Start above drives the async `Runner` surface directly. The simplest
way to run a load test is the one-shot `PropertyDamage.LoadTest.run/1`, the same
entry point `benches/openapi_bench` uses. It starts a runner, blocks until the
run finishes, and returns the final report:

```elixir
{:ok, report} = PropertyDamage.LoadTest.run(
  model: MyApp.Model,
  adapter: MyApp.HTTPAdapter,
  adapter_config: %{base_url: "http://localhost:4000"},
  arrival_rate: 50,
  duration: {2, :minutes}
)

IO.puts(PropertyDamage.LoadTest.format(report, :terminal))
```

Like `PropertyDamage.run/1` for correctness testing, `run/1` takes a keyword
list and returns a single result: `{:ok, report}` on completion or
`{:error, reason}` if the runner fails to start. The difference is what happens
between those points. `PropertyDamage.run/1` explores many short sequences
hunting for bugs and returns run statistics (or a failure report);
`LoadTest.run/1` sustains concurrent arrivals for the configured `duration` and
returns a load report (see [Understanding the Report](#understanding-the-report)).

When you need to observe or stop a run in flight, use the async facade instead
of `run/1`. `PropertyDamage.LoadTest` exposes `start/1` (returns
`{:ok, runner}`), `await/2`, `status/1`, `get_metrics/1`, and `stop/1` over the
`Runner` process shown in the Quick Start; `run/1` is exactly `start/1` followed
by `await/2`. `format/2`, `summary/1`, and `save/3` render a report and delegate
to `PropertyDamage.LoadTest.Report`.

`run/1` validates its options against a NimbleOptions schema
(`PropertyDamage.Options.load_test_schema/0`, the authority for what is
accepted). The required options are `model`, `adapter`, `arrival_rate`, and
`duration`; everything in [Configuration Options](#configuration-options) below
is optional.

## Server-Generated Values (`external()`)

Realistic load uses the same models as correctness testing, including commands
that chain a server-generated id. When a command produces a value its event marks
with `external()` (see the "External Field Markers" section of the
[Writing Commands](writing_commands.md) guide), each worker captures that
concrete value and resolves it into the later commands in the same sequence,
exactly as in `PropertyDamage.run/1`. Capture is per worker, so concurrent
arrivals never share or clobber each other's ids.

## Invariants under sustained load

A load test drives your invariants against a SUT that is *never reset between a
worker's sequences*: each worker keeps its adapter context for the whole run (by
design, so connections and sessions are reused the way a real client would reuse
them). This is unlike `PropertyDamage.run/1`, where each sequence starts from a
fresh `setup/1`. Two consequences for the invariants you check under load:

- **Accumulation-robust.** A worker's later sequence sees state left behind by
  its earlier sequences. An invariant that assumes it starts from an empty store
  will get false failures. Assert only on facts the *current* sequence
  established, and treat pre-existing state as legitimate.
- **Concurrency-robust.** Many workers hit the shared SUT at once. An invariant
  that assumes it is the only writer of a key will see interference. Either
  namespace the state each worker touches so workers cannot collide, or write the
  invariant so cross-worker writes cannot violate it.

`benches/openapi_bench` demonstrates the pattern against a live HTTP KV API. Its
load adapter (`OpenapiBench.LoadAdapter`) mints a unique namespace in `setup/1`
and maps every model key into that namespace, so concurrent workers never share a
server key. Its projection (`OpenapiBench.LoadConsistency`) is a read-your-own-write
check that only asserts on reads of keys the *current sequence* wrote — a read of
a key this sequence never wrote may legitimately observe leftover state from an
earlier sequence and is skipped. Together those two moves keep the invariant
meaningful under sustained concurrent load while still catching a genuine dropped
write.

## Configuration Options

### Required Options

| Option | Description | Example |
|--------|-------------|---------|
| `model` | Your PropertyDamage model module | `MyApp.Model` |
| `adapter` | Your adapter module | `MyApp.HTTPAdapter` |
| `arrival_rate` | Target sequences per second | `50` or `{100, {1, :seconds}}` |
| `duration` | Test length | `{5, :minutes}` |

### Optional Options

| Option | Description | Default |
|--------|-------------|---------|
| `adapter_config` | Adapter configuration | `%{}` |
| `ramp_up` | How to ramp up to target rate | `:immediate` |
| `ramp_down` | How to ramp down at end | `:immediate` |
| `think_time` | `{min_ms, max_ms}` between commands | `{0, 0}` |
| `arrival_jitter` | `{min_ms, max_ms}` jitter per arrival | `{0, 0}` |
| `metrics_interval` | How often to sample metrics (snapshot cadence) | `{1, :seconds}` |
| `on_progress` | Progress consumer: `LoadUpdate` snapshots + a terminal `LoadResult` | `nil` |
| `assertion_mode` | `:disabled`, `:record`, `:log`, or `:halt` | `:disabled` |
| `run_nonce` | `non_neg_integer` seeding client-minted run-scoped values (DR-034); set it only for reproducible minted values | strong random entropy |

### Arrival Rate Formats

```elixir
# Simple: arrivals per second
arrival_rate: 100

# Explicit: count per time unit
arrival_rate: {100, {1, :seconds}}
arrival_rate: {10, {100, :milliseconds}}
arrival_rate: {6000, {1, :minutes}}
```

## Ramp Strategies

Control how the arrival rate changes over time:

```elixir
# Immediate - full rate from the start
ramp_up: :immediate

# Linear - gradually increase over duration
ramp_up: {:linear, {30, :seconds}}

# Step - increase in discrete steps
ramp_up: {:step, 5, {10, :seconds}}  # 5 steps, 10 seconds each

# Exponential - exponential growth curve
ramp_up: {:exponential, {1, :minute}}
```

Example with ramp-up and ramp-down:

```elixir
Runner.start_link(
  model: MyModel,
  adapter: MyAdapter,
  arrival_rate: 100,
  duration: {5, :minutes},
  ramp_up: {:linear, {30, :seconds}},    # 30s to reach full rate
  ramp_down: {:linear, {15, :seconds}}   # 15s to wind down
)
```

## Understanding the Report

### Report structure

The value `run/1` (or `await/2`) returns is a plain map, not a struct, with three
top-level keys: `report.metrics`, `report.pool_stats`, and `report.config`. The
formatters above render it, but you can read the fields directly for assertions
or custom reporting.

`report.metrics` is the final metrics snapshot. The adopter-relevant fields:

| Field | Meaning |
|-------|---------|
| `total_requests` | Total commands executed (the report calls these "commands") |
| `requests_per_second` | Mean command throughput over the run |
| `latency_min` / `latency_p50` / `latency_p95` / `latency_p99` / `latency_max` / `latency_mean` | Per-command latency stats in ms |
| `total_errors` / `error_rate` | Execution error count and percentage of commands |
| `errors_by_type` | `%{error_type => count}` |
| `arrivals_spawned` / `arrivals_completed` / `arrivals_per_second` | Arrival (sequence) counts and rate |
| `by_command` | `%{command_module => %{count, latency_p50, latency_p95, latency_mean, error_count}}` |
| `duration_ms` | Wall-clock length of the run |
| `active_sessions` / `completed_sessions` | Session gauges at snapshot time |
| `assertion_failures` / `assertion_failure_rate` / `failures_by_exception` | Populated when `assertion_mode` is not `:disabled` (`failures_by_exception` is `%{exception_module => count}`) |
| `recent_assertion_failures` | Bounded list of recent assertion-failure detail maps |
| `history` | Time series: a list of `%{timestamp, rps, latency_p95, active_sessions, error_rate}` points |

`report.pool_stats` describes the dynamic worker pool:

| Field | Meaning |
|-------|---------|
| `total_created` | Total workers the pool created over the run |
| `peak_in_use` | Maximum workers checked out at once |
| `peak_utilization` | `peak_in_use / total_created` |
| `avg_utilization` | Mean utilization across checkout samples |
| `utilization` | Instantaneous utilization at report time |
| `total_checkouts` / `total_checkins` | How many times workers were borrowed and returned |
| `available` / `in_use` | Idle and busy worker counts at report time |

`report.config` echoes the run configuration: `model`, `adapter`, `arrival_rate`,
and `duration_ms`.

```elixir
{:ok, report} = PropertyDamage.LoadTest.run(opts)

report.metrics.latency_p95
report.metrics.by_command
report.pool_stats.peak_in_use
```

### Key Terminology

| Term | Meaning |
|------|---------|
| **Arrival** | One command sequence spawned |
| **Command** | One individual operation executed |
| **Completed arrival** | An arrival whose worker ran its sequence to completion (a worker that fails `adapter.setup/1` is spawned but never completes) |

A single arrival may execute multiple commands before the sequence terminates.

### Throughput Section

```
┌─ Throughput ─────────────────────────────────────────────────────────┐
│ Total Commands:    15,234                                            │
│ Commands/Second:   50.78                                             │
│ Arrivals Spawned:  3,048                                             │
│ Arrivals Completed: 2,896                                            │
│ Arrivals/Second:   10.16                                             │
└──────────────────────────────────────────────────────────────────────┘
```

- **Total Commands**: Individual operations completed
- **Commands/Second**: Average command throughput
- **Arrivals Spawned**: Sequences that started
- **Arrivals Completed**: Sequences that ran to completion (a gap below Spawned
  means workers failed to start or sequences errored out)
- **Arrivals/Second**: Actual arrival rate achieved

If `Total Commands ≈ Arrivals Spawned`, each sequence runs ~1 command.
If `Total Commands >> Arrivals Spawned`, sequences run multiple commands.

### Worker Pool Section

```
┌─ Worker Pool ────────────────────────────────────────────────────────┐
│ Workers Created: 142                                                 │
│ Peak Workers:    100                                                 │
│ Peak Utilization: 85.00%                                             │
│ Avg Utilization: 62.34%                                              │
│ Total Checkouts: 3,048                                               │
└──────────────────────────────────────────────────────────────────────┘
```

- **Workers Created**: Total workers the pool created over the run
- **Peak Workers**: Maximum workers in use at once
- **Peak Utilization**: Maximum utilization seen during the test
- **Avg Utilization**: Average utilization across all checkout attempts
- **Total Checkouts**: How many times workers were borrowed

High peak utilization (>90%) indicates the pool grew to meet bursts; high
average utilization (>70%) indicates sustained load on the pool.

### Latency Section

```
┌─ Latency (ms) ───────────────────────────────────────────────────────┐
│ Min:     5.23       │ p50:   45.67      │ Mean:  52.34              │
│ Max:     523.45     │ p95:   125.89     │ p99:   234.56             │
└──────────────────────────────────────────────────────────────────────┘
```

Latency is measured per **command**, not per HTTP request. If a command
internally makes multiple HTTP calls (e.g., polling), the latency includes
all of them.

## Throughput Tuning

When throughput is lower than expected, or `Arrivals Completed` lags well
behind `Arrivals Spawned`:

### 1. The worker pool sizes itself

There is no `pool_size` option. The worker pool is dynamic: a worker is
checked out (or created on demand) for each arrival, so it grows to whatever
concurrency the arrival rate and command latency demand. You do not tune it.

So a large gap between `Arrivals Spawned` and `Arrivals Completed` is not pool
saturation: it means workers could not start or their sequences errored out
(for example `adapter.setup/1` failed). That points at the adapter or the SUT
refusing connections, not at a queue depth to raise. Watch `pool_utilization`
and `peak_workers` in `Runner.status/1` to see how far the pool grew.

### 2. Lower Arrival Rate

Match the arrival rate to what your system can actually handle:

```elixir
# If completions lag spawns at rate 100, try rate 70
Runner.start_link(
  arrival_rate: 70,
  # ...
)
```

### 3. Reduce Command Latency

Faster commands mean workers become available sooner:

- **Optimize SUT**: Database indexes, caching, query optimization
- **Connection pooling**: Reuse HTTP connections in your adapter
- **Reduce polling**: If commands poll for async results, reduce intervals

### 4. Check Sequence Length

If `Total Commands ≈ Arrivals Spawned`, your sequences terminate after
~1 command. Check your model's `terminate?/3` implementation:

```elixir
# This terminates immediately - only 1 command per sequence
def terminate?(_state, _history, _step), do: true

# This runs 5-10 commands per sequence
def terminate?(_state, _history, step), do: step >= 8
```

Longer sequences mean more commands per arrival, potentially improving
overall throughput efficiency.

## Real-Time Monitoring

Use the `on_progress` consumer to monitor progress. It receives a
`%PropertyDamage.Progress{}` projection (DR-022): periodic snapshots arrive as a
`LoadUpdate`, and a terminal `LoadResult` carries a copy of the final report. The
consumer runs in an isolated notifier process, so a slow callback never stalls
arrival scheduling.

```elixir
alias PropertyDamage.Progress
alias PropertyDamage.Progress.{LoadResult, LoadUpdate}

Runner.start_link(
  # ...
  on_progress: fn
    %Progress{data: %LoadUpdate{snapshot: snapshot}} ->
      IO.puts("RPS: #{snapshot.requests_per_second}, " <>
              "p95: #{snapshot.latency_p95}ms, " <>
              "errors: #{snapshot.total_errors}")

    %Progress{data: %LoadResult{report: _report}} ->
      IO.puts("load test complete")
  end,
  metrics_interval: {5, :seconds}
)
```

Or check status programmatically:

```elixir
status = Runner.status(runner)
# %{
#   phase: :steady,
#   current_rate: {50, {1, :seconds}},
#   pool_utilization: 0.75,
#   in_flight: 38,
#   progress_percent: 45.2
# }
```

## Troubleshooting

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| Completed << Spawned | Workers failing to start (`adapter.setup`) or SUT refusing connections | Check adapter setup and SUT connection limits; lower arrival rate |
| Commands ≈ Arrivals | Early termination | Check `terminate?/3` returns `false` initially |
| Peak util 100%, avg util low | Bursty traffic | Add ramp-up to smooth the arrival curve |
| Peak and avg util both high | Sustained overload | Lower arrival rate or scale the SUT |
| Low arrivals/sec vs target | Ramp-up or failed arrivals | Check ramp config and the Spawned/Completed gap |
| Latency spikes | SUT bottleneck | Profile SUT, check for resource contention |

## Report Formats

### Terminal

Colored output with ASCII charts for interactive use:

```elixir
IO.puts(Report.format(report, :terminal))
```

### Markdown

Detailed report suitable for documentation:

```elixir
Report.save(report, "results/load_test.md", :markdown)
```

### JSON

Machine-readable format for analysis pipelines:

```elixir
json = Report.format(report, :json)
File.write!("results/load_test.json", json)
```

## Example: Full Load Test Script

```elixir
alias PropertyDamage.LoadTest.{Runner, Report}

# Configuration
config = [
  model: MyApp.Model,
  adapter: MyApp.HTTPAdapter,
  adapter_config: %{base_url: "http://localhost:4000"},
  arrival_rate: 50,
  duration: {5, :minutes},
  ramp_up: {:linear, {30, :seconds}},
  ramp_down: {:linear, {15, :seconds}},
  think_time: {10, 50},
  on_progress: fn
    %PropertyDamage.Progress{data: %PropertyDamage.Progress.LoadUpdate{snapshot: m}} ->
      IO.puts("[#{m.duration_ms}ms] #{m.requests_per_second} cmd/s, " <>
              "p95=#{m.latency_p95}ms, completed=#{m.arrivals_completed}")

    _ ->
      :ok
  end
]

# Run test
IO.puts("Starting load test...")
{:ok, runner} = Runner.start_link(config)
{:ok, report} = Runner.await(runner)

# Output results
IO.puts(Report.format(report, :terminal))
Report.save(report, "load_test_#{System.os_time(:second)}.md", :markdown)

# Summary
IO.puts("\n#{Report.summary(report)}")
```

## Next Steps

- [Integration Testing](integration_testing.md) - Correctness testing
- [Chaos Engineering](chaos_engineering.md) - Fault injection under load
- [Debugging Failures](debugging_failures.md) - Analyzing test failures
