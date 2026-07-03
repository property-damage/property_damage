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

## Server-Generated Values (`external()`)

Realistic load uses the same models as correctness testing, including commands
that chain a server-generated id. When a command produces a value its event marks
with `external()` (see the "External Field Markers" section of the
[Writing Commands](writing_commands.md) guide), each worker captures that
concrete value and resolves it into the later commands in the same sequence,
exactly as in `PropertyDamage.run/1`. Capture is per worker, so concurrent
arrivals never share or clobber each other's ids.

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
| `assertion_mode` | `:disabled`, `:log`, or `:fail` | `:disabled` |

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
