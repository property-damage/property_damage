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
| `pool_size` | Number of workers (see below) | auto |
| `ramp_up` | How to ramp up to target rate | `:immediate` |
| `ramp_down` | How to ramp down at end | `:immediate` |
| `think_time` | `{min_ms, max_ms}` between commands | `{0, 0}` |
| `arrival_jitter` | `{min_ms, max_ms}` jitter per arrival | `{0, 0}` |
| `max_queue_size` | Queue depth before dropping arrivals | `100` |
| `metrics_interval` | How often to sample metrics | `{1, :second}` |
| `on_metrics` | Callback for periodic metrics | `nil` |
| `on_complete` | Callback when test finishes | `nil` |
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
| **Drop** | Arrival that couldn't run (pool exhausted) |

A single arrival may execute multiple commands before the sequence terminates.

### Throughput Section

```
┌─ Throughput ─────────────────────────────────────────────────────────┐
│ Total Commands:    15,234                                            │
│ Commands/Second:   50.78                                             │
│ Arrivals Spawned:  3,048                                             │
│ Arrivals/Second:   10.16                                             │
│ Arrivals Dropped:  152 (4.99%)                                       │
└──────────────────────────────────────────────────────────────────────┘
```

- **Total Commands**: Individual operations completed
- **Commands/Second**: Average command throughput
- **Arrivals Spawned**: Sequences that started
- **Arrivals/Second**: Actual arrival rate achieved
- **Arrivals Dropped**: Sequences that couldn't start (pool full)

If `Total Commands ≈ Arrivals Spawned`, each sequence runs ~1 command.
If `Total Commands >> Arrivals Spawned`, sequences run multiple commands.

### Worker Pool Section

```
┌─ Worker Pool ────────────────────────────────────────────────────────┐
│ Pool Size:       100                                                 │
│ Utilization:     0.00%                                               │
│ Total Checkouts: 3,048                                               │
│ Avg Queue Time:  12.34ms                                             │
└──────────────────────────────────────────────────────────────────────┘
```

- **Pool Size**: Number of workers available
- **Utilization**: Percentage of workers in use (snapshot at report time)
- **Total Checkouts**: How many times workers were borrowed
- **Avg Queue Time**: How long arrivals waited for a worker

Note: Utilization shows 0% at test end because all workers are returned.
Check the throughput chart for runtime utilization patterns.

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

When arrivals are being dropped or throughput is lower than expected:

### 1. Increase Pool Size

By default, pool size auto-calculates as `min(arrival_rate * 2, 500)` with
a minimum of 10 workers. Override this with the `pool_size` option:

```elixir
Runner.start_link(
  arrival_rate: 50,
  duration: {5, :minutes},
  pool_size: 200,  # Override auto-calculated value
  # ...
)
```

**When to increase pool size:**

- Commands are slow (>100ms average) and you're seeing drops
- The SUT can handle more concurrent requests than the default allows
- You need to stress test connection pooling behavior

**When to decrease pool size:**

- You want to limit concurrency to avoid overwhelming the SUT
- Testing how the system behaves under resource constraints
- Simulating a fixed number of concurrent users

**Sizing guidance:**

```
Required workers ≥ arrival_rate × avg_command_latency_seconds

Example: 50 arrivals/sec with 200ms avg latency
  → 50 × 0.2 = 10 workers minimum
  → Auto-calc gives: min(50 × 2, 500) = 100 workers (plenty of headroom)

Example: 50 arrivals/sec with 2s avg latency (slow commands)
  → 50 × 2 = 100 workers minimum
  → Auto-calc gives: 100 workers (borderline - consider pool_size: 150)
```

### 2. Increase max_queue_size

When all workers are busy, arrivals queue up. Once the queue exceeds
`max_queue_size`, arrivals are dropped:

```elixir
Runner.start_link(
  # ...
  max_queue_size: 500  # Default is 100
)
```

A larger queue absorbs traffic bursts but increases memory usage and
queue wait times.

### 3. Lower Arrival Rate

Match the arrival rate to what your system can actually handle:

```elixir
# If you're seeing 30% drops at rate 100, try rate 70
Runner.start_link(
  arrival_rate: 70,
  # ...
)
```

### 4. Reduce Command Latency

Faster commands mean workers become available sooner:

- **Optimize SUT**: Database indexes, caching, query optimization
- **Connection pooling**: Reuse HTTP connections in your adapter
- **Reduce polling**: If commands poll for async results, reduce intervals

### 5. Check Sequence Length

If `Total Commands ≈ Arrivals Spawned`, your sequences terminate after
~1 command. Check your model's `terminate?/3` implementation:

```elixir
# This terminates immediately - only 1 command per sequence
def terminate?(_state, _history, _step), do: true

# This runs 5-10 commands per sequence
def terminate?(_state, _history, step), do: step >= Enum.random(5..10)
```

Longer sequences mean more commands per arrival, potentially improving
overall throughput efficiency.

## Real-Time Monitoring

Use callbacks to monitor progress:

```elixir
Runner.start_link(
  # ...
  on_metrics: fn snapshot ->
    IO.puts("RPS: #{snapshot.requests_per_second}, " <>
            "p95: #{snapshot.latency_p95}ms, " <>
            "errors: #{snapshot.total_errors}")
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
| High drop rate (>10%) | Pool saturation | Increase pool size or lower arrival rate |
| Commands ≈ Arrivals | Early termination | Check `terminate?/3` returns `false` initially |
| 0% utilization | Snapshot timing | Normal - check history for runtime patterns |
| High avg queue time | Pool undersized | Increase pool size |
| Low arrivals/sec vs target | Ramp-up or drops | Check ramp config and drop rate |
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
  model: ToyBankTest.Model,
  adapter: ToyBankTest.Adapters.HTTPAdapter,
  adapter_config: %{base_url: "http://localhost:4555"},
  arrival_rate: 50,
  duration: {5, :minutes},
  ramp_up: {:linear, {30, :seconds}},
  ramp_down: {:linear, {15, :seconds}},
  think_time: {10, 50},
  on_metrics: fn m ->
    IO.puts("[#{m.duration_ms}ms] #{m.requests_per_second} cmd/s, " <>
            "p95=#{m.latency_p95}ms, drops=#{m.arrivals_dropped}")
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
