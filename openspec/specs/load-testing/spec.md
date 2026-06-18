# Load Testing Specification

## Purpose

Define the load testing subsystem that leverages PropertyDamage's stateful property-based testing infrastructure to generate realistic, model-driven load against a system under test, with dynamic worker scaling, arrival rate control, ramp strategies, and comprehensive metrics collection.

## Requirements

### Requirement: Arrival Rate Configuration

The load test SHALL be configured with an arrival rate (commands per time unit), not a fixed thread count. The framework SHALL schedule command executions to match the target arrival rate.

#### Scenario: Configuring arrival rate

- **WHEN** a load test is started with `arrival_rate: 100` and `duration: {2, :minutes}`
- **THEN** the framework SHALL target 100 command arrivals per second for 2 minutes
- **AND** SHALL dynamically adjust worker allocation to meet this rate

#### Scenario: Rate normalization

- **WHEN** the arrival rate is specified as `{count, {time, unit}}`
- **THEN** the framework SHALL normalize the rate to a per-second value for scheduling

### Requirement: Dynamic Worker Pool

The worker pool SHALL grow on demand to match the target arrival rate. Workers SHALL be created when no idle workers are available and reused when returned.

#### Scenario: On-demand worker creation

- **WHEN** a new arrival is scheduled and no idle workers are available in the pool
- **THEN** the pool SHALL create a new Worker process
- **AND** the new worker SHALL call `adapter.setup/1` once at creation

#### Scenario: Worker reuse

- **WHEN** a worker completes a command sequence execution
- **THEN** the worker SHALL be returned to the pool as available
- **AND** subsequent arrivals SHALL reuse the existing worker rather than creating a new one

#### Scenario: Pool statistics tracking

- **WHEN** the load test is running
- **THEN** the pool SHALL track total workers created, peak concurrent workers in use, total checkouts, total checkins, and utilization samples

### Requirement: Worker Lifecycle

Each worker SHALL hold a persistent adapter context and execute independent command sequences.

#### Scenario: Worker setup

- **WHEN** a new worker is created by the pool
- **THEN** the worker SHALL call the adapter's `setup/1` with the provided adapter configuration
- **AND** SHALL hold the resulting context for the lifetime of the worker

#### Scenario: Worker sequence execution

- **WHEN** a worker is checked out for an arrival
- **THEN** the worker SHALL execute a command sequence using the model, adapter, and projections
- **AND** the sequence SHALL be independent of sequences run by other workers

### Requirement: Ramp Strategies

The framework SHALL support four ramp strategies for controlling how load is applied over time: immediate, linear, step, and exponential.

#### Scenario: Immediate ramp

- **WHEN** the ramp strategy is `:immediate`
- **THEN** the framework SHALL start at the full target arrival rate from the beginning of the test

#### Scenario: Linear ramp

- **WHEN** the ramp strategy is `{:linear, duration}`
- **THEN** the framework SHALL gradually increase the arrival rate from zero to the target rate over the specified duration

#### Scenario: Step ramp

- **WHEN** the ramp strategy is `{:step, count, interval}`
- **THEN** the framework SHALL increase the arrival rate in `count` discrete steps
- **AND** each step SHALL occur after the specified interval

#### Scenario: Exponential ramp

- **WHEN** the ramp strategy is `{:exponential, duration}`
- **THEN** the framework SHALL increase the arrival rate following an exponential growth curve over the specified duration

#### Scenario: Ramp plan generation

- **WHEN** a ramp strategy and target rate are provided
- **THEN** `RampStrategy.plan/2` SHALL return a list of `{time_ms, rate_spec}` tuples defining the rate at each point in time

### Requirement: Ramp Down

The framework SHOULD support ramp-down strategies for graceful load reduction at the end of a test.

#### Scenario: Linear ramp down

- **WHEN** `ramp_down: {:linear, {10, :seconds}}` is configured
- **THEN** the framework SHALL gradually reduce the arrival rate from the target rate to zero over 10 seconds before ending the test

### Requirement: Metrics Collection

The framework SHALL collect per-command and aggregated latency metrics, throughput metrics, and error tracking using lock-free concurrent data structures.

#### Scenario: Latency percentiles

- **WHEN** command executions complete during a load test
- **THEN** the metrics system SHALL compute p50, p95, p99, min, max, and mean latency values
- **AND** SHALL provide these both per-command and in aggregate

#### Scenario: Throughput tracking

- **WHEN** a load test is running
- **THEN** the metrics system SHALL track total requests, requests per second, and success/error rates

#### Scenario: Error tracking

- **WHEN** command executions fail during a load test
- **THEN** the metrics system SHALL record the total error count, error rate, and errors grouped by type

#### Scenario: Per-command breakdown

- **WHEN** metrics are requested
- **THEN** the system SHALL provide a breakdown of latency and throughput metrics for each command type individually

#### Scenario: Time series history

- **WHEN** a load test runs over time
- **THEN** the metrics system SHALL record periodic snapshots (at the configured history interval) for trend analysis

### Requirement: Command-Centric Measurement

Metrics SHALL be command-centric: one command execution counts as one request, regardless of how many underlying operations (HTTP calls, polling retries) the adapter performs.

#### Scenario: Async command with polling

- **WHEN** a command execution internally performs 1 POST and 15 polling GETs
- **THEN** the metrics system SHALL record this as 1 request
- **AND** the latency SHALL reflect the total wall-clock time including polling

### Requirement: Memory-Bounded Metrics

The metrics system SHALL use reservoir sampling to bound memory usage for percentile calculation.

#### Scenario: High-volume latency tracking

- **WHEN** millions of command executions are recorded
- **THEN** the metrics system SHALL maintain a fixed-size reservoir (default 1000 samples)
- **AND** SHALL compute accurate percentile approximations from the reservoir

### Requirement: Assertion Mode

The load test assertion mode SHALL default to `:record`, continuing execution after assertion failures rather than halting.

#### Scenario: Default assertion mode

- **WHEN** a load test is started without specifying assertion mode
- **THEN** the framework SHALL use `:record` mode
- **AND** assertion failures SHALL be counted in metrics but SHALL NOT halt the test

#### Scenario: Disabled assertions

- **WHEN** assertion mode is set to `:disabled`
- **THEN** the framework SHALL skip assertion evaluation entirely during the load test

### Requirement: Command Timeouts

The framework SHALL support per-command timeouts to prevent hung commands from causing unbounded worker pool growth.

#### Scenario: Command exceeds timeout

- **WHEN** a command execution exceeds the timeout specified by the adapter's `timeout/1` callback
- **THEN** the framework SHALL raise `PropertyDamage.CommandTimeoutError`

#### Scenario: Default timeout

- **WHEN** an adapter specifies `default_timeout: 30` and a command has no specific timeout override
- **THEN** the framework SHALL apply a 30-second timeout to that command's execution

### Requirement: Model and Adapter Reuse

The load test SHALL use the same Model, Adapter, and Projection stack as property testing.

#### Scenario: Shared model

- **WHEN** a load test is configured with a model module
- **THEN** the framework SHALL use the same `commands/0`, weights, preconditions, and projections as property-based testing

### Requirement: External Value Capture Per Worker

The load test SHALL capture `external()` server-generated values and resolve them into downstream commands within a worker's sequence (DR-021), maintaining a separate placeholder registry per worker so concurrent arrivals do not share captured values.

#### Scenario: Consumer resolved within a worker's sequence

- **WHEN** a worker executes a sequence in which a command produces a value marked `external()` and a later command consumes it
- **THEN** the worker SHALL resolve the consumer to the concrete value captured from its own events before executing it

#### Scenario: Unresolved consumer

- **WHEN** a consumer's external value cannot be resolved (its producer errored before capture)
- **THEN** the worker SHALL record the command as an error rather than raising and aborting the worker

### Requirement: Load Test Reporting

The framework SHALL generate a summary report containing metrics, failures, and timing information.

#### Scenario: Report generation

- **WHEN** a load test completes
- **THEN** the framework SHALL return a report containing throughput metrics, latency percentiles, error summaries, assertion failure summaries, worker pool statistics, and timing information

#### Scenario: Report formatting

- **WHEN** a report is formatted for output
- **THEN** the framework SHALL support terminal and markdown output formats

### Requirement: Live Progress Callback

The framework SHOULD support a periodic progress callback for real-time observation during the test, delivered through the unified progress projection (DR-022).

#### Scenario: On-progress callback

- **WHEN** `on_progress` is configured with a 1-arity function
- **THEN** the framework SHALL invoke it periodically (cadence set by `metrics_interval`) with a `%PropertyDamage.Progress{}` whose `:data` is a `PropertyDamage.Progress.LoadUpdate` carrying a current metrics snapshot
- **AND** at completion it SHALL invoke the callback once with a terminal `%PropertyDamage.Progress{}` whose `:data` is a `PropertyDamage.Progress.LoadResult` carrying a copy of the final report
- **AND** the callback SHALL be dispatched through an isolated notifier process so a slow callback cannot stall arrival scheduling

#### Scenario: Removed legacy callbacks

- **WHEN** configuring live observation
- **THEN** the framework SHALL NOT support the former `on_metrics`/`on_complete` options (removed in favor of `on_progress`); `metrics_interval` is retained as the snapshot cadence

### Requirement: Think Time

The framework SHOULD support configurable think time between command executions within a session.

#### Scenario: Think time range

- **WHEN** `think_time: {100, 500}` is configured
- **THEN** each worker SHALL pause for a random duration between 100ms and 500ms between command executions within a session
