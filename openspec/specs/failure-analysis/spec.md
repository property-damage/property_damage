# Failure Analysis Specification

## Purpose

Failure analysis provides intelligent post-mortem tooling for PropertyDamage test failures. It fingerprints failures for comparison, clusters similar failures to surface root causes, verifies fixes with seed variations, classifies error origins (SUT vs test code), suggests missing invariants, generates structured reports, compares passing/failing traces, and replays production event logs through model projections for incident analysis.

## Requirements

### Requirement: Failure Fingerprinting

The system SHALL extract comparable features from each failure report, producing a fingerprint that captures the failure type, check name, triggering command type, command shape, event types, sequence length, sequence shape, state keys, error category, and error pattern.

#### Scenario: Fingerprint from a check failure

- **WHEN** a failure report has `failure_type: :check_failed` and `check_name: :NonNegativeBalance`
- **THEN** the fingerprint SHALL contain `failure_type: :check_failed` and `check_name: :NonNegativeBalance`
- **AND** the fingerprint SHALL include the command type that triggered the failure
- **AND** the fingerprint SHALL include the event types produced before failure

#### Scenario: Short hash for display

- **WHEN** a fingerprint is generated from a failure report
- **THEN** the system SHALL produce a short hash string suitable for display and comparison

### Requirement: Similarity Scoring

The system SHALL compute a weighted similarity score between two failure fingerprints, returning a value between 0.0 (completely different) and 1.0 (identical).

#### Scenario: Weighted dimension comparison

- **WHEN** two fingerprints are compared
- **THEN** the similarity score SHALL be computed as a weighted sum across dimensions: failure_type (0.20), check_name (0.15), command_type (0.15), command_shape (0.10), event_types (0.10), sequence_shape (0.10), error_category (0.10), error_pattern (0.10)

#### Scenario: Similarity threshold

- **WHEN** two failures have a similarity score at or above 0.70
- **THEN** the system SHALL classify them as similar (`is_similar: true`)

#### Scenario: Detailed comparison breakdown

- **WHEN** a detailed comparison is requested
- **THEN** the system SHALL return the overall score, a per-component breakdown, and a boolean similarity determination

### Requirement: Pattern Clustering

The system SHALL cluster similar failures into groups using agglomerative clustering based on fingerprint similarity.

#### Scenario: Cluster formation

- **WHEN** multiple failures have pairwise similarity scores above the threshold (default 0.70)
- **THEN** they SHALL be grouped into the same cluster
- **AND** each cluster SHALL have a representative fingerprint, a size count, and a descriptive pattern

#### Scenario: Analysis summary

- **WHEN** a set of failures is analyzed
- **THEN** the system SHALL produce an analysis containing clusters, singleton count, total failure count, the most common pattern, and a pattern summary string

#### Scenario: Minimum cluster size

- **WHEN** a failure has no other failure with similarity above the threshold
- **THEN** it SHALL be counted as a singleton and not form a cluster

### Requirement: Fix Verification

The system SHALL verify that a fix is robust by re-running the original failing seed and seed variations against the model and adapter.

#### Scenario: Verified fix

- **WHEN** the original seed passes and all seed variations pass
- **THEN** the verification result status SHALL be `:verified`
- **AND** a confidence score SHALL be returned

#### Scenario: Still failing

- **WHEN** the original seed still reproduces the failure
- **THEN** the verification result status SHALL be `:still_failing`

#### Scenario: Partially fixed

- **WHEN** the original seed passes but some variations still fail
- **THEN** the verification result status SHALL be `:partially_fixed`
- **AND** the failed variation seeds SHALL be listed

#### Scenario: Flaky detection

- **WHEN** the original seed intermittently passes and fails across variations
- **THEN** the verification result status SHALL be `:flaky`

### Requirement: Error Origin Classification

The system SHALL classify each failure as originating from the SUT, the test code, or unknown, along with a confidence level (high, medium, low).

#### Scenario: SUT error with high confidence

- **WHEN** the failure reason is `:check_failed`, `:poll_timeout`, `:idempotency_violation`, or `:linearization_failed`
- **THEN** the origin SHALL be classified as `:sut_error` with confidence `:high`

#### Scenario: Test code error with high confidence

- **WHEN** the failure involves an `UndefinedFunctionError` in model/projection/command/adapter modules, or a `FunctionClauseError` in projection apply or command callbacks
- **THEN** the origin SHALL be classified as `:test_code_error` with confidence `:high`

#### Scenario: Ambiguous classification

- **WHEN** the failure is a generic exception during assertion execution or an adapter error
- **THEN** the origin SHALL be classified as `:unknown` with confidence `:low`
- **AND** the classification SHALL include evidence explaining the ambiguity

### Requirement: Actionable Banners and Hints

The system SHALL produce user-facing banners and hints based on error origin classification to guide debugging.

#### Scenario: SUT error banner

- **WHEN** a failure is classified as `:sut_error`
- **THEN** the report SHALL include a banner indicating the likely SUT bug and the violated invariant name

#### Scenario: Test code error banner

- **WHEN** a failure is classified as `:test_code_error`
- **THEN** the report SHALL include a banner indicating a likely test configuration issue with the specific module and callback involved

### Requirement: Invariant Suggestions

The system SHALL analyze a model's commands, events, and projections to suggest missing invariant checks, categorized by priority (high, medium, low).

#### Scenario: Numeric field detection

- **WHEN** events contain fields with numeric names (balance, amount, count, quantity)
- **THEN** the system SHOULD suggest non-negative check invariants with priority `:high`

#### Scenario: Reference field detection

- **WHEN** events contain fields matching reference patterns (account_ref, user_id, order_id)
- **THEN** the system SHOULD suggest existence check invariants

#### Scenario: Currency and consistency detection

- **WHEN** events contain currency or type fields
- **THEN** the system SHOULD suggest consistency check invariants

#### Scenario: Status field detection

- **WHEN** events contain status fields
- **THEN** the system SHOULD suggest valid state transition check invariants

#### Scenario: Timestamp field detection

- **WHEN** events contain timestamp fields
- **THEN** the system SHOULD suggest ordering check invariants

#### Scenario: Suggestion output format

- **WHEN** suggestions are generated
- **THEN** each suggestion SHALL include a type, priority, description, rationale, and optionally example code
- **AND** suggestions SHALL be filterable by focus area (`:numeric`, `:references`, `:consistency`, `:all`)

### Requirement: Structured Failure Reports

The system SHALL produce structured failure reports containing location (run number, command index, seed), original and shrunk command sequences, projection states before and at failure, the complete event trail, and the structured failure reason. The shrunk sequence and event trail are served through the report's embedded `RunTrace` (DR-033) — `shrunk_sequence/1` and `event_log/1` are accessors over the trace, not struct fields.

#### Scenario: Report creation

- **WHEN** a test failure occurs
- **THEN** a `FailureReport` SHALL be created with seed, run_number, original_sequence, failed_at_index, failure_reason, and an embedded `RunTrace` whose plan serves as the shrunk sequence (DR-033)

#### Scenario: Multiple output formats

- **WHEN** a report is formatted
- **THEN** the system SHALL support `:terminal`, `:markdown`, `:json`, and `:compact` output formats

#### Scenario: Report with error origin

- **WHEN** a failure report is created
- **THEN** it SHALL include the error origin classification from `ErrorOrigin.classify/2`

#### Scenario: Report names the violated invariant (DR-026)

- **WHEN** an assertion failure is reported and the assertion validates an invariant with a description
- **THEN** the report SHALL headline the invariant's `name` and `description`, with the specific failing assertion shown as secondary detail
- **AND** when the invariant has no description, the report SHALL fall back to the assertion name as today

#### Scenario: Report renders per-command labels (DR-028 amendment, P7)

- **WHEN** a failure report is created for a sequence whose commands implement `label/2`
- **THEN** the report SHALL carry a `command_labels` map keyed by the flattened (`Sequence.to_list/1`) command index, populated only with non-nil labels
- **AND** each label SHALL be computed lazily at report construction against that command's `command_sequence_projection` pre-state
- **AND** the `:terminal`, `:markdown`, and `:json` formats SHALL render each command's label next to that command in the minimal-reproduction sequence
- **AND** a command without a label SHALL render exactly as before

#### Scenario: Structural step query interface

- **WHEN** a `FailureReport` is inspected structurally
- **THEN** `FailureReport.steps/1` SHALL delegate to `RunTrace.steps/1` (DR-033) on the report's embedded trace, returning the run as an ordered list of `%RunTrace.Step{position, flattened_index, command, executed_command, entries, label, failed?}`, one per command in `Sequence.to_list/1` (flattened) reading order; `command` is the plan's symbolic command (unchanged semantics for existing consumers) and `executed_command` is the concrete resolved command actually sent (`nil` when not captured, e.g. a command that never executed)
- **AND** each step's `position` SHALL be a `%Sequence.Position{section, offset}` naming the command's section (`:prefix`, `:suffix`, or `{:branch, id}`) and its offset within that section, giving each command an identity that is unambiguous across parallel branches even when they share an executor command index
- **AND** each step's `entries` SHALL be the full `EventLog.Entry` structs whose `(command_index, branch_id)` resolve to that step's position, in log order, preserving each event's provenance (`source`, `branch_id`; the bare event is `entry.event`) so a nemesis / mock / stutter event attributed to the command stays distinguishable from SUT output; entries carrying no command index (e.g. injector or telemetry events) SHALL belong to no step
- **AND** at most one step SHALL have `failed?: true` — the command where the failure was localized, matched by position rather than by comparing the flattened index to `failed_at_index` (an executor index that diverges from the flattened ordinal for branch failures)
- **AND** `FailureReport.failure_step/1` (a failure-specific locator retained on the report, not on `RunTrace`) SHALL return that step, or `nil` for a non-localized failure (teardown / whole-run / linearization, where `failed_at_index` is `nil`)
- **AND** `FailureReport.event_entries_at/2` SHALL delegate to `RunTrace.event_entries_at/2`, returning the log entries for a command addressed by either its flattened index or its `%Sequence.Position{}`
- **AND** `steps/1` / `failure_step/1` SHALL be the ONLY structural accessors for the failing command and its entries: the report SHALL NOT carry materialized `command_at_failure` / `events_at_failure` fields (removed), and every renderer, exporter, and forensic analyzer SHALL obtain the failing command/events via the step interface (which resolves them branch-aware) rather than by re-walking `shrunk_sequence` / `event_log` / `failed_at_index`; in particular the event timeline's per-command provenance view (source badges + branch) SHALL be served from `steps/1` `entries` rather than a private `event_log` walk

### Requirement: Run Trace as the Execution Record (DR-033)

The framework SHALL model the complete record of a single run as a `PropertyDamage.RunTrace`, independent of outcome. A `RunTrace` SHALL carry the run identity (`seed`, `run_number`, `run_nonce`, `mint_epoch` (DR-034), `model`, `adapter`, UTC `timestamp`, and best-effort `source_revision`), the plan (`plan`, the `%Sequence{}` this run executed — deliberately NOT named `original_sequence`, whose report-level meaning is the generated plan of the failing exploration run), a `plan_source` of `:generated` (a pure function of the effective seed) or `:shrunk` (a shrinker product, not regenerable from the seed), the canonical `plan_fingerprint` (DR-036), the concrete executed commands with their resolved and minted values keyed branch-aware by `%Sequence.Position{}`, the complete `EventLog` with per-entry provenance, the `command_labels`, and an `outcome` of `:pass` or `{:fail, reason}`. The executor SHALL always accumulate the resolved concrete command per position (including within branch workers, merged with branch state) so the executed record exists whenever a trace is materialized. `RunTrace` SHALL be the sole owner of the structural step query interface: `RunTrace.steps/1` and `RunTrace.event_entries_at/2` describe any run regardless of outcome, using the same branch-aware `%Sequence.Position{}` identity the failure report already uses. A `FailureReport` SHALL compose the `RunTrace` of the run the report describes — the shrunk minimal reproduction when its re-execution reproduced the failure, otherwise the original failing run (the existing non-reproduction fallback) — and add only failure-specific concerns: the locators `failure_step/1` and `failure_index/1`, the shrink relationship (`original_sequence` vs the trace's plan), and the failure classification. Deep execution-record structures SHALL live once, on the trace: the report SHALL NOT carry `event_log` or `shrunk_sequence` struct fields; `FailureReport.event_log/1` and `FailureReport.shrunk_sequence/1` SHALL be accessors over the embedded trace, while scalar identity (`seed`, `run_number`, `model`, `adapter`, `timestamp`) MAY remain duplicated on the report as its locator surface. Full `RunTrace` capture SHALL be on demand (`RunTrace.capture/1`, DR-035), not retained for every exploration run.

#### Scenario: Trace captured for a passing run

- **WHEN** a run is executed on an on-demand capture path (run comparison or flakiness investigation) and passes
- **THEN** the framework SHALL produce a `RunTrace` with `outcome: :pass`, `plan_source: :generated`, the full unshrunk executed plan, and its complete event log
- **AND** `RunTrace.steps/1` SHALL return one step per command in `Sequence.to_list/1` reading order, with the same branch-aware position identity used for failing runs

#### Scenario: FailureReport composes a RunTrace

- **WHEN** a `FailureReport` is created
- **THEN** its execution record (executed commands, event log, step interface) SHALL be served by an embedded `RunTrace` rather than by fields duplicated on the report
- **AND** `FailureReport.steps/1` and `FailureReport.event_entries_at/2` SHALL delegate to the embedded trace, preserving their existing branch-aware semantics
- **AND** `FailureReport.failure_step/1` and `FailureReport.failure_index/1` SHALL remain failure-specific locators defined over that trace

#### Scenario: Non-reproduction fallback trace

- **WHEN** the shrunk sequence's re-execution fails to reproduce the failure and the report falls back to the original failing run
- **THEN** the embedded trace SHALL be the original failing run's trace (`plan_source: :generated`), consistent with the sequence and event log the report already presents in that case
- **AND** the report SHALL remain internally consistent: `FailureReport.shrunk_sequence/1` and the trace's plan SHALL be the same sequence

#### Scenario: Exploration runs are not retained as traces

- **WHEN** ordinary exploration executes many runs in search of a failure
- **THEN** the framework SHALL NOT retain a full `RunTrace` for every exploration run
- **AND** it SHALL capture a full `RunTrace` only for runs on an explicit capture path and for the failing run that produces a report

### Requirement: Run Comparison Supersedes Trace Diffing (DR-035)

The passing/failing trace-diff surface previously provided by `PropertyDamage.Diff` (`compare_reports/2`, `compare_traces/2`, hand-built trace maps) SHALL be removed. Comparing runs SHALL instead be served by the Run Comparison subsystem specified in the differential-testing domain (DR-035), which aligns full `RunTrace` records (DR-033) rather than shrunk reports, classifies value provenance (DR-034), and renders a self-contained report.

#### Scenario: Legacy Diff module removed

- **WHEN** the framework is built after DR-035
- **THEN** `PropertyDamage.Diff` SHALL NOT exist
- **AND** run comparison SHALL be provided by `PropertyDamage.RunComparison` over `RunTrace` records

### Requirement: Production Forensics

The system SHALL replay production event logs through model projections to detect invariant violations during incident analysis.

#### Scenario: Event replay with no violations

- **WHEN** production events are replayed through model projections
- **AND** no invariant violations are detected
- **THEN** the system SHALL return `{:ok, %{final_state: state}}`

#### Scenario: Event replay with violation

- **WHEN** production events are replayed and an invariant violation is detected
- **THEN** the system SHALL return `{:error, failure}` with the failure step and violation details

#### Scenario: Event mapping

- **WHEN** production events have different field names or structures than framework event structs
- **THEN** the system SHALL use an `EventMapping` behaviour module to translate production events
- **AND** events returning `:skip` from the mapping SHALL be excluded from replay
