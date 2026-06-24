# Eventual Consistency Specification

## Purpose

Defines the settle retry logic, resource polling, state polling, and probe command semantics that enable the PropertyDamage framework to test eventually consistent systems where operations may not produce immediate results.

Reference DRs: DR-008 (Command Semantics -- probe/async), DR-018 (Command-Triggered Resource Polling), DR-024 (Lifecycle-Boundary Assertions), DR-026 (Invariant Catalog and Anti-Vacuity Coverage)

## Requirements

### Requirement: Settle Retry Logic

The system SHALL provide retry logic for probe and async commands, repeatedly executing them until they succeed or a timeout is reached. The settle mechanism SHALL support configurable timeout, interval, and backoff strategies.

#### Scenario: Successful settle before timeout
- **WHEN** a probe or async command is executed with settle logic
- **AND** the command succeeds within the timeout period
- **THEN** the framework SHALL return the successful result
- **AND** no further retries SHALL occur

#### Scenario: Timeout after exhausting retries
- **WHEN** a probe or async command is executed with settle logic
- **AND** the command does not succeed before the timeout expires
- **THEN** the framework SHALL return a timeout result with the last retry reason

#### Scenario: At least one attempt regardless of timeout
- **WHEN** a probe or async command is executed with settle logic
- **AND** the deadline is already reached (for example `timeout_ms: 0`)
- **THEN** the framework SHALL still attempt the command exactly once before timing out
- **AND** a resulting timeout SHALL carry the reason from that final attempt

#### Scenario: Malformed return is not treated as success
- **WHEN** the executed function returns a value outside the settle protocol (not `{:ok, _}`, `{:settled, _}`, `{:retry, _}`, or `{:error, _}`)
- **THEN** the framework SHALL surface it as an error (`{:error, {:malformed_settle_return, value}}`) rather than reporting it as a successful result

#### Scenario: Hard error stops retries immediately
- **WHEN** a command returns a hard error (as opposed to a retryable failure)
- **THEN** the framework SHALL stop retrying immediately
- **AND** the error SHALL be returned without waiting for the timeout

### Requirement: Settle Configuration

Settle behavior SHALL be configurable with `timeout_ms` (default 2000), `interval_ms` (default 300), and `backoff` strategy (`:linear` or `:exponential`). Configuration SHALL be sourced from the command spec's `:settle` field or from a legacy `settle_config/0` callback.

#### Scenario: Default configuration applied
- **WHEN** a command requires settling but provides no custom configuration
- **THEN** the framework SHALL use timeout of 2000ms, interval of 100ms, and linear backoff

#### Scenario: Custom configuration from command spec
- **WHEN** a command spec includes a `:settle` field with custom values
- **THEN** those values SHALL override the corresponding defaults

#### Scenario: Legacy settle_config callback
- **WHEN** a command module implements `settle_config/0`
- **THEN** the returned configuration SHALL be merged with defaults

### Requirement: Linear Backoff

When the backoff strategy is `:linear`, the system SHALL use a constant interval between retries for the entire settle duration.

#### Scenario: Constant retry interval
- **WHEN** settle is configured with `:linear` backoff and an interval of 100ms
- **THEN** each retry SHALL wait approximately 100ms before the next attempt
- **AND** the interval SHALL remain constant across all retries

### Requirement: Exponential Backoff

When the backoff strategy is `:exponential`, the system SHALL double the interval after each retry, capped so that the total wait does not exceed the timeout.

#### Scenario: Doubling interval
- **WHEN** settle is configured with `:exponential` backoff and an initial interval of 100ms
- **THEN** the first retry SHALL wait approximately 100ms
- **AND** the second retry SHALL wait approximately 200ms
- **AND** subsequent retries SHALL continue doubling

#### Scenario: Interval capped at remaining time
- **WHEN** the doubled interval would exceed the remaining time before timeout
- **THEN** the interval SHALL be capped to the remaining time

### Requirement: Resource Poller

The system SHALL support command-triggered background polling of external resources via the `ctx.start_poller` function available in adapter context. The poller SHALL periodically call a poll function and pass results to a handler.

#### Scenario: Poller started during command execution
- **WHEN** an adapter calls `ctx.start_poller.(opts)` during `execute/2`
- **THEN** a background polling process SHALL be spawned
- **AND** the poller SHALL call the configured `poll_fn` at the configured `interval_ms`

#### Scenario: Handler returns :continue
- **WHEN** the handler function returns `:continue`
- **THEN** the poller SHALL continue polling at the next interval
- **AND** no events SHALL be injected

#### Scenario: Handler returns {:done, event}
- **WHEN** the handler function returns `{:done, event}`
- **THEN** the event SHALL be pushed to the event queue
- **AND** the poller SHALL stop

#### Scenario: Handler returns {:inject, event}
- **WHEN** the handler function returns `{:inject, event}`
- **THEN** the event SHALL be pushed to the event queue
- **AND** the poller SHALL continue polling

#### Scenario: Poller timeout
- **WHEN** the poller exceeds `timeout_ms` without the handler returning `{:done, ...}`
- **THEN** the poller SHALL stop
- **AND** the timeout behavior SHALL be determined by the `on_timeout` option (default: `:fail`)

### Requirement: State Poller for Temporal Assertions

The system SHALL support `@poll_state` temporal assertions that spawn a background poller to periodically check a predicate against projection state. The poller SHALL succeed when the predicate becomes true or fail on timeout.

#### Scenario: Predicate becomes true
- **WHEN** a `@poll_state` assertion is triggered by a matching event
- **AND** the predicate evaluates to true within the timeout
- **THEN** the state poller SHALL report success

#### Scenario: Predicate times out
- **WHEN** a `@poll_state` assertion is triggered
- **AND** the predicate never becomes true before the timeout
- **THEN** the state poller SHALL report failure with diagnostic information
- **AND** the report SHALL include the trigger event, predicate source, final state, elapsed time, and poll count

#### Scenario: Configurable polling parameters
- **WHEN** a `@poll_state` assertion specifies timeout and interval
- **THEN** the poller SHALL use those values for its polling cycle

#### Scenario: Poller spawn counts as invariant firing (DR-026)
- **WHEN** a matching `after:` event is observed and a `@poll_state` poller is spawned
- **THEN** the assertion SHALL be counted as having fired for invariant-coverage purposes, regardless of whether the poller later succeeds, times out, or remains pending at shutdown
- **AND** an invariant whose `@poll_state` poller is never spawned (its `after:` event never occurred) SHALL be reported as uncovered

### Requirement: Settled State and Safety Assertions

The system SHALL define a run's **settled state** as the projection state after both the state pollers (`@poll_state`) and the resource pollers have finalized: the point at which no poller is live and every observed event has been folded into projection state. The framework SHALL evaluate `@trigger at: :teardown` safety assertions (DR-024) on this settled state. Whereas `@poll_state` expresses liveness (a predicate that SHALL eventually become true), an `at: :teardown` assertion expresses safety (a property that SHALL hold on the settled state); the two are complementary.

#### Scenario: Settled state reflects late asynchronous observations
- **WHEN** a resource poller injects events after the last command, before the run finalizes
- **THEN** those events SHALL be folded into projection state before the settled state is evaluated

#### Scenario: Safety assertion catches a persistent over-application
- **WHEN** an asynchronous effect over-applies and the over-application persists to the settled state
- **AND** a projection accumulates evidence of it (for example a maximum observed value)
- **THEN** an `@trigger at: :teardown` assertion SHALL detect it and report a named safety failure, distinct from a poll timeout

#### Scenario: Liveness timeout preempts the settled checkpoint
- **WHEN** a `@poll_state` assertion times out in a mode that halts the run
- **THEN** the run SHALL report the poll timeout
- **AND** `@trigger at: :teardown` assertions SHALL NOT be evaluated, because a liveness timeout is itself a not-settled outcome

### Requirement: Probe Command Semantics

Probe commands SHALL represent read-only queries with settle semantics. During shrinking, probe commands SHALL be prioritized for removal since they do not affect system state.

#### Scenario: Probe commands use settle logic
- **WHEN** a command declares its semantics as `:probe`
- **THEN** execution SHALL use settle retry logic with the command's settle configuration

#### Scenario: Probes prioritized during shrinking
- **WHEN** the shrinker attempts to reduce a failing sequence
- **THEN** probe commands SHALL be considered for removal before state-modifying commands
