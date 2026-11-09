# Load Testing Specification

## Purpose

Define the load testing subsystem that leverages PropertyDamage's stateful property-based testing infrastructure to generate realistic, model-driven load against a system under test, with dynamic worker scaling, arrival rate control, ramp strategies, and comprehensive metrics collection.

Reference Decision Records: DR-042 (One Engine for Property-Based, Differential and Path-Equivalence Runs)

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
- **THEN** the worker SHALL execute a command sequence through the engine's stepping interface (`PropertyDamage.Executor.Stepping`), using the model, adapter, and projections
- **AND** the sequence SHALL be independent of sequences run by other workers

### Requirement: Worker Session Phases

A worker SHALL run each sequence as an engine session, in this order: the `@check at: :startup` checks, the model's `setup_each/0` commands, the sequence's roots, finalization (the `@eventually` checks the session started and the `@check at: :teardown` checks), and the model's `teardown_each/0` commands. Each root SHALL run through the same step a property run uses (placeholder resolution, the adapter call under `timeout/1`, settle, projections and step checks), and the worker SHALL drain the event queue after each root. A worker SHALL NOT apply the model's `expansions/0`: it runs each root as itself.

#### Scenario: Setup, eventual and teardown run

- **GIVEN** a model with a `setup_each/0` command, a `teardown_each/0` command and a projection with an `@eventually` check
- **WHEN** a load test runs it with `check_mode:` other than `:disabled`
- **THEN** each worker sequence SHALL run the setup command before the first root, the `@eventually` check after a root's events trigger it, and the teardown command after the last root

#### Scenario: Checks follow check mode

- **WHEN** a load test runs with `check_mode: :disabled`
- **THEN** the worker SHALL run no startup, step, `@eventually` or teardown check
- **AND** the worker SHALL still run the setup and teardown commands, settle and stutter

#### Scenario: A failed root does not end the sequence

- **WHEN** a root's adapter call returns an error, raises, or exceeds its timeout, or a placeholder in the root does not resolve
- **THEN** the worker SHALL count one error for that root and continue with the next root

#### Scenario: A failed setup command ends the sequence

- **WHEN** a setup command fails
- **THEN** the worker SHALL count one error, run none of the sequence's roots, and record no request for the setup command

#### Scenario: Worker result

- **WHEN** a worker finishes a sequence
- **THEN** `Worker.execute_sequence/1` SHALL return `{:ok, result}` with the counts of commands run, errors and check failures

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

The framework SHALL support ramp-down strategies for graceful load reduction at the end of a test.

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

### Requirement: Request Latency

The latency of a request SHALL be the wall-clock time of the engine step (`Stepping.step/4`) of one root command: placeholder resolution, the adapter call, settle, projection updates, step checks and stutter retries. Think time, the drain after the root, finalization, and setup and teardown commands SHALL NOT be part of any request's latency. Only roots SHALL count as requests.

#### Scenario: Think time is excluded

- **WHEN** a load test runs with `think_time: {100, 100}` against an adapter that answers at once
- **THEN** the recorded latency of each root SHALL NOT include the 100 ms of think time

#### Scenario: Setup and teardown commands are not requests

- **WHEN** a sequence runs one setup command, three roots and one teardown command
- **THEN** the metrics system SHALL record three requests for that sequence

### Requirement: Memory-Bounded Metrics

The metrics system SHALL use reservoir sampling to bound memory usage for percentile calculation.

#### Scenario: High-volume latency tracking

- **WHEN** millions of command executions are recorded
- **THEN** the metrics system SHALL maintain a fixed-size reservoir (default 1000 samples)
- **AND** SHALL compute accurate percentile approximations from the reservoir

### Requirement: Check Mode

The load test check mode SHALL default to `:disabled`. In `:record` mode, execution SHALL continue after check failures rather than halting.

#### Scenario: Default check mode

- **WHEN** a load test is started without specifying check mode
- **THEN** the framework SHALL use `:disabled` mode and evaluate no check

#### Scenario: Recorded checks

- **WHEN** a load test is started with `check_mode: :record`
- **THEN** check failures SHALL be counted in metrics but SHALL NOT halt the test

#### Scenario: Disabled checks

- **WHEN** check mode is set to `:disabled`
- **THEN** the framework SHALL skip check evaluation entirely during the load test, the startup, step, `@eventually` and teardown checks included

### Requirement: Retired Check Mode Key Is Rejected (DR-042)

The load test SHALL reject the retired option `assertion_mode:` with a validation error that names its replacement `check_mode:`.

#### Scenario: Load test started with `assertion_mode:`
- **WHEN** a load test is started with `assertion_mode:` in its options
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError` with the message "`assertion_mode:` was renamed `check_mode:`"

### Requirement: Command Timeouts

The framework SHALL support per-command timeouts to prevent hung commands from causing unbounded worker pool growth.

#### Scenario: Command exceeds timeout

- **WHEN** a command execution exceeds the timeout specified by the adapter's `timeout/1` callback
- **THEN** the framework SHALL stop waiting and report `PropertyDamage.CommandTimeoutError` as the command's adapter error
- **AND** the worker SHALL count one error and continue with the sequence

#### Scenario: Default timeout

- **WHEN** an adapter specifies `default_timeout: 30` and a command has no specific timeout override
- **THEN** the framework SHALL apply a 30-second timeout to that command's execution

### Requirement: Stutter Option

The load test SHALL accept the `stutter:` option with the validation `PropertyDamage.run/1` applies, SHALL leave stutter off when the option is absent, and SHALL pass the parsed configuration to every worker, which applies it to each root as a property run does.

#### Scenario: Stutter retries run in a load test

- **GIVEN** a load test with `stutter: [probability: 1.0, max_repeats: 1]` against an idempotent adapter
- **WHEN** a worker runs a sequence
- **THEN** the worker SHALL retry each root once and compare the retry's events with the original's (probability 1.0 stutters every root)
- **AND** `phase_counts.stutter_retries` SHALL be above zero

#### Scenario: A stutter mismatch

- **WHEN** a retry's events differ from the original's
- **THEN** the worker SHALL end that sequence and count one check failure

#### Scenario: Invalid stutter option

- **WHEN** a load test is started with an invalid `stutter:` value
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError`

### Requirement: Phase Counts

The metrics snapshot SHALL carry `phase_counts`, a map with the keys `setup_commands`, `teardown_commands`, `eventual_checks` and `stutter_retries`, each the sum over the run. `setup_commands` and `teardown_commands` SHALL count the commands the adapter answered, `eventual_checks` the `@eventually` windows the run opened, and `stutter_retries` the retries whose events the event log kept. `format/2` and `summary/1` SHALL show the counts when any is above zero and SHALL omit them when all are zero.

#### Scenario: Counts after a run with every phase

- **GIVEN** a model with a setup command, a teardown command and an `@eventually` check, and a load test with `check_mode: :record` and `stutter:` on
- **WHEN** the load test completes
- **THEN** `report.metrics.phase_counts` SHALL have every count above zero
- **AND** the terminal and markdown formats SHALL show a "Phases" section and `summary/1` a `Phases:` line

#### Scenario: Counts after a run with no phase

- **GIVEN** a model with no setup or teardown command and no `@eventually` check, and a load test with stutter off
- **WHEN** the load test completes
- **THEN** every count SHALL be zero
- **AND** `format/2` and `summary/1` SHALL omit the phase counts

### Requirement: Model and Adapter Reuse

The load test SHALL use the same Model, Adapter, and Projection stack as property testing.

#### Scenario: Shared model

- **WHEN** a load test is configured with a model module
- **THEN** the framework SHALL use the same `commands/0`, weights, preconditions, and projections as property-based testing

### Requirement: Reproducible Worker Sequences

Each worker SHALL draw its sequences from a seed derived from the load test's `seed`, its worker id and the sequence number, through the same sized and seeded generation path a property run uses. The load test SHALL take a positive integer `seed:` option, SHALL draw one at random when the option is absent, and SHALL record it as `config.seed` in the report and in its terminal, markdown and JSON formats.

#### Scenario: The same seed sends the same commands
- **GIVEN** two load tests with the same model, `seed:` and `run_nonce`
- **WHEN** each worker draws its nth sequence
- **THEN** both tests SHALL draw the same commands for each worker and sequence number

#### Scenario: A default seed is recorded
- **WHEN** a load test starts without a `seed:` option
- **THEN** the load test SHALL draw a seed at random
- **AND** the report SHALL record it as `config.seed`

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
- **THEN** the framework SHALL return a report containing throughput metrics, latency percentiles, error summaries, check failure summaries, worker pool statistics, and timing information

#### Scenario: Report formatting

- **WHEN** a report is formatted for output
- **THEN** the framework SHALL support terminal and markdown output formats

### Requirement: Live Progress Callback

The framework SHALL support a periodic progress callback for real-time observation during the test, delivered through the unified progress projection (DR-022).

#### Scenario: On-progress callback

- **WHEN** `on_progress` is configured with a 1-arity function
- **THEN** the framework SHALL invoke it periodically (cadence set by `metrics_interval`) with a `%PropertyDamage.Progress{}` whose `:data` is a `PropertyDamage.Progress.LoadUpdate` carrying a current metrics snapshot
- **AND** at completion it SHALL invoke the callback once with a terminal `%PropertyDamage.Progress{}` whose `:data` is a `PropertyDamage.Progress.LoadResult` carrying a copy of the final report
- **AND** the callback SHALL be dispatched through an isolated notifier process so a slow callback cannot stall arrival scheduling

#### Scenario: Removed legacy callbacks

- **WHEN** configuring live observation
- **THEN** the framework SHALL NOT support the former `on_metrics`/`on_complete` options (removed in favor of `on_progress`); `metrics_interval` is retained as the snapshot cadence

### Requirement: Think Time

The framework SHALL support configurable think time between command executions within a session.

#### Scenario: Think time range

- **WHEN** `think_time: {100, 500}` is configured
- **THEN** each worker SHALL pause for a random duration between 100ms and 500ms between command executions within a session
