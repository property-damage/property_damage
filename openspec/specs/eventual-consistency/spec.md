# Eventual Consistency Specification

## Purpose

Defines the settle retry logic, resource polling, state polling, and probe command semantics that enable the PropertyDamage framework to test eventually consistent systems where operations may not produce immediate results.

Reference DRs: DR-008 (Command Semantics -- probe/async), DR-018 (Command-Triggered Resource Polling), DR-024 (Lifecycle-Boundary Assertions), DR-026 (Invariant Catalog and Anti-Vacuity Coverage), DR-030 (Command-Correlated Injector Events -- liveness over a correlated set, poll-timeout locality), DR-044 (Variants and the Lockstep Scheduler -- pollers inside multi-target runs), DR-046 (Boundary Observations, the Convergence Loop and Adapter Errors -- convergence versus settle versus `@eventually`)

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

Settle behavior SHALL be configurable with `timeout_ms` (default 2000), `interval_ms` (default 300), and `backoff` strategy (`:linear` or `:exponential`). Configuration SHALL be sourced from the command spec's `:settle` field (DR-028); there is no separate `settle_config/0` callback.

#### Scenario: Default configuration applied
- **WHEN** a command requires settling but provides no custom configuration
- **THEN** the framework SHALL use timeout of 2000ms, interval of 300ms, and linear backoff

#### Scenario: Custom configuration from command spec
- **WHEN** a command spec includes a `:settle` field with custom values
- **THEN** those values SHALL override the corresponding defaults

### Requirement: Linear Backoff

When the backoff strategy is `:linear`, the system SHALL use a constant interval between retries for the entire settle duration.

#### Scenario: Constant retry interval
- **WHEN** settle is configured with `:linear` backoff and an interval of 300ms
- **THEN** each retry SHALL wait approximately 300ms before the next attempt
- **AND** the interval SHALL remain constant across all retries

### Requirement: Exponential Backoff

When the backoff strategy is `:exponential`, the system SHALL double the interval after each retry, capped so that the total wait does not exceed the timeout.

#### Scenario: Doubling interval
- **WHEN** settle is configured with `:exponential` backoff and an initial interval of 300ms
- **THEN** the first retry SHALL wait approximately 300ms
- **AND** the second retry SHALL wait approximately 600ms
- **AND** subsequent retries SHALL continue doubling

#### Scenario: Interval capped at remaining time
- **WHEN** the doubled interval would exceed the remaining time before timeout
- **THEN** the interval SHALL be capped to the remaining time

### Requirement: Resource Poller

The system SHALL support command-triggered background polling of external resources via the `runtime.start_poller` function on the `%PropertyDamage.Runtime{}` handle passed to `execute/3` (DR-027). The poller SHALL periodically call a poll function and pass results to a handler.

#### Scenario: Poller started during command execution
- **WHEN** an adapter calls `runtime.start_poller.(opts)` during `execute/3`
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

### Requirement: State Poller for Temporal Checks

The system SHALL support `@eventually` temporal checks that spawn a background poller to periodically check a predicate against projection state. The poller SHALL succeed when the predicate becomes true or fail on timeout.

#### Scenario: Predicate becomes true
- **WHEN** a `@eventually` check is triggered by a matching event
- **AND** the predicate evaluates to true within the timeout
- **THEN** the state poller SHALL report success

#### Scenario: Predicate times out
- **WHEN** a `@eventually` check is triggered
- **AND** the predicate never becomes true before the timeout
- **THEN** the state poller SHALL report failure with diagnostic information
- **AND** the report SHALL include the trigger event, predicate source, final state, elapsed time, and poll count

#### Scenario: Poll timeout attributed to its triggering command (DR-030)
- **WHEN** a `@eventually` poller times out
- **THEN** the failure's `failed_at_index` SHALL be the `command_index` of the command whose event opened the poll window, so the shrinker can truncate to it

#### Scenario: Liveness over a correlated set (DR-030)
- **WHEN** a command correlates an injector event via `awaits/2` and a `@eventually` predicate asserts that the command's correlated set becomes non-empty
- **THEN** the predicate observes the awaited event once it is folded and attributed, and the framework's existing `@eventually` finalize drain (which already awaits the internal event queue) supplies the wait — no separate await loop exists

#### Scenario: Configurable polling parameters
- **WHEN** a `@eventually` check specifies timeout and interval
- **THEN** the poller SHALL use those values for its polling cycle

#### Scenario: Poller spawn counts as invariant firing (DR-026)
- **WHEN** a matching `after:` event is observed and a `@eventually` poller is spawned
- **THEN** the check SHALL be counted as having fired for invariant-coverage purposes, regardless of whether the poller later succeeds, times out, or remains pending at shutdown
- **AND** an invariant whose `@eventually` poller is never spawned (its `after:` event never occurred) SHALL be reported as uncovered

### Requirement: Pollers in Multi-Target Runs (DR-044)

In a multi-target run (`PropertyDamage.run/1` with several `targets:`), every `@eventually` state poller and every resource poller SHALL belong to the variant whose command started it. A poller SHALL read only that variant's projections, and the events it pushes SHALL reach only that variant's event queue. `runtime.start_poller` SHALL be allowed in a multi-target run. A variant SHALL finalize its own pollers at the end of the run, and its pollers SHALL stop when the variant process exits.

#### Scenario: `@eventually` poller reads its own variant

- **GIVEN** two variants and a `@eventually` check that a command's event opens
- **WHEN** the check is triggered in one variant
- **THEN** the poller SHALL evaluate its predicate against that variant's projections only

#### Scenario: Resource poller events fold into their variant

- **WHEN** an adapter calls `runtime.start_poller.(opts)` in one variant of a multi-target run and the handler returns `{:inject, event}`
- **THEN** the event SHALL fold into that variant's projections at the next boundary drain
- **AND** SHALL NOT reach any other variant

#### Scenario: Poll timeout fails its own variant

- **WHEN** a `@eventually` poller of one variant times out while the run finalizes
- **THEN** the run's failure SHALL have the kind `:check_failed` and name that variant

#### Scenario: Pollers end with their variant

- **WHEN** the variant process exits, including by being killed
- **THEN** every state poller and resource poller it started SHALL stop

### Requirement: Settled State and Safety Checks

The system SHALL define a run's **settled state** as the projection state after both the state pollers (`@eventually`) and the resource pollers have finalized: the point at which no poller is live and every observed event has been folded into projection state. The framework SHALL evaluate `@check at: :teardown` safety checks (DR-024) on this settled state. Whereas `@eventually` expresses liveness (a predicate that SHALL eventually become true), an `at: :teardown` check expresses safety (a property that SHALL hold on the settled state); the two are complementary.

#### Scenario: Settled state reflects late asynchronous observations
- **WHEN** a resource poller injects events after the last command, before the run finalizes
- **THEN** those events SHALL be folded into projection state before the settled state is evaluated

#### Scenario: Safety check catches a persistent over-application
- **WHEN** an asynchronous effect over-applies and the over-application persists to the settled state
- **AND** a projection accumulates evidence of it (for example a maximum observed value)
- **THEN** an `@check at: :teardown` check SHALL detect it and report a named safety failure, distinct from a poll timeout

#### Scenario: Liveness timeout preempts the settled checkpoint
- **WHEN** a `@eventually` check times out in a mode that halts the run
- **THEN** the run SHALL report the poll timeout
- **AND** `@check at: :teardown` checks SHALL NOT be evaluated, because a liveness timeout is itself a not-settled outcome

### Requirement: Probe Command Semantics

Probe commands SHALL represent read-only queries with settle semantics. During shrinking, probe commands SHALL be prioritized for removal since they do not affect system state.

#### Scenario: Probe commands use settle logic
- **WHEN** a command declares its semantics as `:probe`
- **THEN** execution SHALL use settle retry logic with the command's settle configuration

#### Scenario: Probes prioritized during shrinking
- **WHEN** the shrinker attempts to reduce a failing sequence
- **THEN** probe commands SHALL be considered for removal before state-modifying commands

### Requirement: Settle, Convergence and Eventually Are Three Waits (DR-046)

The framework SHALL keep three waits apart, each with its own bound and its own failure. *Settle* is one system catching up with itself per adapter call, bounded by the command's `settle:` configuration. *Convergence* is the variants of a multi-target run reaching agreement at a boundary, bounded by `compare: [converge_within: ms]`. `@eventually` is a liveness predicate on one variant's projection state, bounded by its own `timeout:`. A report SHALL name which bound expired: a settle that ran out is an execution result of its command, a convergence that ran out is `:did_not_converge` or `:diverged`, and an `@eventually` that ran out is a poll timeout of kind `:check_failed`.

The convergence loop (DR-046) SHALL drain and fold every variant's event queue and run the async checks at each iteration, so late events and poller events fold before the observations are evaluated again. A window of `@eventually` that expires while the loop runs SHALL be a check failure at once; a polling window that has not expired SHALL NOT keep a boundary from agreeing. A `:probe` root SHALL be re-read in every variant at each iteration, each re-read running under the root's own settle.

#### Scenario: Convergence does not extend settle
- **GIVEN** a `:probe` root with a per-command settle of 300 ms and `converge_within: 100`
- **WHEN** the first read is stale
- **THEN** the loop SHALL start a re-read that runs to its own settle
- **AND** the report SHALL state the time waited, which exceeds the bound by at most that one iteration

#### Scenario: An expired eventually window fails at once
- **WHEN** an `@eventually` window expires while the convergence loop waits at a boundary
- **THEN** the run SHALL fail with a poll timeout of kind `:check_failed` without waiting for `converge_within:`

#### Scenario: A polling window does not block agreement
- **WHEN** every `@compare` observation agrees and an `@eventually` window is still open
- **THEN** the boundary SHALL be in agreement and the run SHALL continue

#### Scenario: Late events fold before the next evaluation
- **WHEN** an injector or poller delivers an event while the loop waits
- **THEN** the loop SHALL fold the event and evaluate again without waiting for the full 50 ms cadence
