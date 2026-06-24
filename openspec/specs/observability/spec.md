# Observability Specification

## Purpose

Observability provides telemetry instrumentation, coverage tracking, progress reporting, and visual diagram generation for PropertyDamage test runs. These capabilities enable monitoring, dashboards, CI quality gates, real-time feedback during long-running tests, and documentation of execution flows.

## Requirements

### Requirement: Telemetry Events

The system SHALL emit `:telemetry` events at key execution points, all prefixed with `[:property_damage, ...]`.

#### Scenario: Run lifecycle events

- **WHEN** a test run starts
- **THEN** the system SHALL emit `[:property_damage, :run, :start]` with measurements `%{system_time: integer()}` and metadata including model, adapter, max_runs, max_commands, and seed
- **AND** when the run completes, it SHALL emit `[:property_damage, :run, :stop]` with measurements `%{duration: integer(), total_commands: integer()}` and metadata including result (`:ok` or `:error`) and runs_completed
- **AND** when the run crashes, it SHALL emit `[:property_damage, :run, :exception]` with kind, reason, and stacktrace

#### Scenario: Sequence execution events

- **WHEN** a command sequence starts execution
- **THEN** the system SHALL emit `[:property_damage, :sequence, :start]` with run_number, command_count, and branching flag
- **AND** when the sequence completes, it SHALL emit `[:property_damage, :sequence, :stop]` with duration, success flag, and commands_executed count

#### Scenario: Command execution events

- **WHEN** a command is executed against the SUT
- **THEN** the system SHALL emit `[:property_damage, :command, :start]` with command module, index, and run_number
- **AND** when the command completes, it SHALL emit `[:property_damage, :command, :stop]` with duration, success flag, and events_count

#### Scenario: Check execution events

- **WHEN** a check (assertion) is evaluated
- **THEN** the system SHALL emit `[:property_damage, :check, :start]` with check_name and projection module
- **AND** when the check completes, it SHALL emit `[:property_damage, :check, :stop]` with duration, passed flag, and optional message

#### Scenario: Shrinking events

- **WHEN** shrinking begins after a failure
- **THEN** the system SHALL emit `[:property_damage, :shrink, :start]` with original_length
- **AND** for each shrink iteration, it SHALL emit `[:property_damage, :shrink, :iteration]` with iteration number, current_length, and success flag
- **AND** when shrinking completes, it SHALL emit `[:property_damage, :shrink, :stop]` with duration, iterations count, original_length, and shrunk_length

#### Scenario: Coarse progress and result events

- **WHEN** a long-running operation reports progress through the unified projection (DR-022) and a telemetry handler is attached
- **THEN** the system SHALL emit a coarse `[:property_damage, <operation>, :progress]` event for each intermediate update and `[:property_damage, <operation>, :result]` at completion, where `<operation>` is one of `:test_run`, `:load_test`, `:mutation`, or `:differential`
- **AND** measurements SHALL be `%{at: integer(), elapsed_ms: non_neg_integer()}` and metadata SHALL be `%{data: <payload struct>, run_id: term()}`
- **AND** for `run/1` these events SHALL be distinct from and additional to the fine-grained `sequence`/`command`/`check`/`shrink` events, which remain unchanged
- **AND** these events SHALL fire only when a handler is attached, preserving the zero-cost-when-unobserved guarantee

#### Scenario: Handler attachment

- **WHEN** a telemetry handler is attached via `:telemetry.attach/4`
- **THEN** it SHALL receive all matching PropertyDamage events with their measurements and metadata

### Requirement: Coverage Tracking

The system SHALL track and report coverage metrics for property-based test execution, including command coverage, transition coverage, state coverage, and assertion (invariant) coverage (DR-026). Coverage metrics SHALL be accumulated across all sequences generated within a run, not a single representative sequence.

#### Scenario: Command coverage

- **WHEN** coverage tracking is enabled
- **THEN** the system SHALL track which command modules have been executed and how often
- **AND** command coverage SHALL be reported as the percentage of defined commands executed at least once

#### Scenario: Transition coverage (transition matrix)

- **WHEN** commands are executed in sequence
- **THEN** the system SHALL record which command pairs (A followed by B) have been tested
- **AND** transition counts SHALL be available as a matrix of `{from_command, to_command}` pairs

#### Scenario: State class coverage

- **WHEN** a `state_classifier` function is provided
- **THEN** the system SHALL classify each projection state into a state class
- **AND** track state class counts and state class transitions

#### Scenario: Assertion (invariant) coverage (DR-026)

- **WHEN** assertions are evaluated during test runs
- **THEN** the system SHALL record how many times each assertion actually fired, keyed by its owning projection and name, counting firing at every evaluation site (synchronous `every:` on commands and observed events including the asynchronous paths of DR-025, lifecycle `at:` boundaries of DR-024, and `@poll_state` poller spawn)
- **AND** firing counts SHALL be attached to every result as `result.assertion_fires` and accumulated across all sequences of the run
- **AND** this recording SHALL be always-on (it does not require the `coverage: true` option)

#### Scenario: Whole-run coverage accumulation via coverage: true (DR-026)

- **WHEN** a run is invoked with `coverage: true`
- **THEN** the heavier coverage dimensions (command, transition, and state coverage) SHALL be accumulated across all generated sequences of the run
- **AND** an invariant or command exercised only in an earlier sequence (not the representative one) SHALL still be reported as covered

#### Scenario: Anti-vacuity — uncovered invariants (DR-026)

- **WHEN** an invariant declared in the model's catalog is never exercised by any of its checks during a run (zero firings)
- **THEN** the system SHALL report that invariant as uncovered (dynamic vacuity)
- **AND** an invariant exercised by at least one of its checks SHALL be reported as covered

#### Scenario: Coverage thresholds for CI

- **WHEN** `Coverage.meets_threshold?(coverage, command: 80, transition: 50)` is called
- **THEN** the system SHALL return `true` only if command coverage is at least 80% and transition coverage is at least 50%
- **AND** an `assertion_coverage:` threshold (DR-026) SHALL return `true` only if at least that percentage of catalog invariants were covered, enabling a strict "fail on any uncovered invariant" gate at `assertion_coverage: 100`

#### Scenario: Cumulative coverage across runs

- **WHEN** `Coverage.record(tracker, result)` is called multiple times
- **THEN** coverage metrics SHALL accumulate across all recorded results

### Requirement: Invariant Catalog and Coverage Reporting (DR-026)

The system SHALL expose the catalog of invariants a model verifies and report which were exercised. `PropertyDamage.assertion_coverage(result, model)` SHALL return the per-invariant coverage breakdown from a single result without re-executing the run. By default a run SHALL emit a terse one-line invariant-coverage footer through the existing reporter (DR-022), not unconditional stdout; the rich breakdown is available on demand and the heavier dimensions behind `coverage: true`.

#### Scenario: Coverage detail without re-execution

- **WHEN** `PropertyDamage.assertion_coverage(result, model)` is called on a passing result
- **THEN** the system SHALL return, per invariant, its `id`, `name`, `description`, check kind(s), fire count, and covered status
- **AND** it SHALL compute this by joining `result.assertion_fires` against the model's catalog, with no re-execution
- **AND** an invariant is covered when any of its checks fired

#### Scenario: Terse footer by default

- **WHEN** a run completes successfully and a verbose consumer is attached
- **THEN** the system SHALL emit a terse footer of the form `invariants: N/M exercised`, counting covered invariants out of the catalog total
- **AND** the footer SHALL be suppressed on failing runs
- **AND** firing data SHALL be present on the result for non-verbose and programmatic consumers regardless of the footer

#### Scenario: Catalog enumeration

- **WHEN** `PropertyDamage.assertion_catalog(model)` is called
- **THEN** the system SHALL return every invariant the model verifies, unioned across its projections and keyed by `{projection, id}` so two projections MAY reuse an `id` for distinct invariants

### Requirement: Progress Reporting

The system SHALL report progress for long-running operations (`PropertyDamage.run/1`, `PropertyDamage.Mutation.run/1`, `PropertyDamage.Differential.run/1`, and the load-test runner) through a single derived projection: a `%PropertyDamage.Progress{}` value fanned out to zero or more consumers. The projection SHALL be a view of authoritative state, never its source; an operation's return value remains the source of truth, and a terminal `*Result` payload carries a copy of it for consumers.

#### Scenario: Progress envelope and payloads

- **WHEN** an operation reports progress
- **THEN** the system SHALL build a `%PropertyDamage.Progress{}` envelope carrying common metadata (`:at`, `:elapsed_ms`, `:run_id`) and an operation-specific `:data` payload
- **AND** the payload's struct type SHALL be the discriminator (there is no `kind`/`operation` field), with one `{Update, Result}` payload pair per operation

#### Scenario: Consumer fan-out

- **WHEN** an operation has one or more progress consumers
- **THEN** each consumer (a `(PropertyDamage.Progress.t -> any())` function) SHALL receive every progress value
- **AND** a consumer that raises or exits SHALL be caught and logged without aborting the operation

#### Scenario: Zero cost when unobserved

- **WHEN** an operation has no progress consumers (verbose off, no `on_progress:`, and no telemetry handler attached)
- **THEN** the system SHALL NOT build any `%PropertyDamage.Progress{}` value

#### Scenario: Synchronous fan-out for batch operations

- **WHEN** a batch operation (`run/1`, `Mutation.run/1`, `Differential.run/1`) reports progress
- **THEN** consumers SHALL be invoked synchronously, in order, in the calling process, completing before the operation returns (a slow consumer only lengthens the run)

#### Scenario: Non-blocking dispatch for load tests

- **WHEN** a load test reports progress
- **THEN** the system SHALL dispatch through an isolated notifier process so that a slow consumer cannot stall arrival scheduling
- **AND** it SHALL guarantee delivery of the terminal `*Result` once load generation has stopped
- **AND** when its bounded buffer overflows it SHALL deterministically decimate buffered intermediate updates (exempting the first update and the terminal result) without reordering the survivors

#### Scenario: Verbose output is a consumer

- **WHEN** `verbose: true` is set
- **THEN** the system SHALL install a built-in printing consumer that renders the progress stream to stdout: for `run/1` the run header (model, adapter, max_runs, max_commands, optional seed), per-run progress (current run number out of total, command count, and branch info if applicable, updated in-place with a carriage return), and the success or failure summary; for mutation and differential a status line per item
- **AND** the printed output SHALL be identical to the prior `verbose:` output

#### Scenario: User callback is a consumer

- **WHEN** an `on_progress:` function is provided
- **THEN** the system SHALL install it as an additional consumer, receiving each intermediate `%PropertyDamage.Progress{}` (`data: *Update{}`) and finally the terminal result (`data: *Result{}`)

#### Scenario: Seed library replay reporting

- **WHEN** the seed-library replay phase runs (`seed_library:` enabled, non-empty library)
- **THEN** the system SHALL print a start banner and, on halt, a summary to stdout unconditionally (not gated on `verbose:`), each stating what is happening, why, the prune threshold, and how to disable the library
- **AND** per-seed pass/fail/prune lines SHALL print only under `verbose:`
- **AND** the banner, per-seed updates, and summary SHALL also be emitted as `ReplayUpdate` progress payloads through the unified reporter (classified under the `:test_run` operation), so `on_progress:` and telemetry consumers observe them too

### Requirement: Sequence Diagram Generation

The system SHALL generate visual sequence diagrams from test executions in Mermaid, PlantUML, and WebSequence formats.

#### Scenario: Mermaid format

- **WHEN** a diagram is generated with format `:mermaid`
- **THEN** the output SHALL be valid Mermaid sequence diagram syntax with participants Test, SUT, and optionally State

#### Scenario: PlantUML format

- **WHEN** a diagram is generated with format `:plantuml`
- **THEN** the output SHALL be valid PlantUML sequence diagram syntax

#### Scenario: WebSequence format

- **WHEN** a diagram is generated with format `:websequence`
- **THEN** the output SHALL be valid sequencediagram.org format

#### Scenario: Diagram from failure report

- **WHEN** `Diagram.from_failure_report(report, format)` is called
- **THEN** the diagram SHALL show the command execution flow, events returned from the SUT, and the failure point

#### Scenario: State changes in diagrams

- **WHEN** the `:show_state` option is `true`
- **THEN** the diagram SHALL include state changes after each command

#### Scenario: Failure highlighting

- **WHEN** the `:highlight_failure` option is `true` (default)
- **THEN** the command that triggered the failure SHALL be visually distinguished in the diagram
- **AND** the violated check or error SHALL be annotated

#### Scenario: Branch visualization

- **WHEN** the `:show_branches` option is `true` (default) and the sequence contains parallel branches
- **THEN** the diagram SHALL show the branching execution flow

#### Scenario: Configurable options

- **WHEN** a diagram is generated
- **THEN** the system SHALL accept options for title, show_state, show_timestamps, max_value_length (default 50), highlight_failure, and show_branches
