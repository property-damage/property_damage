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

The system SHALL produce structured failure reports containing location (run number, command index, seed), original and shrunk command sequences, projection states before and at failure, the complete event trail, and the structured failure reason.

#### Scenario: Report creation

- **WHEN** a test failure occurs
- **THEN** a `FailureReport` SHALL be created with seed, run_number, original_sequence, shrunk_sequence, failed_at_index, and failure_reason

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

### Requirement: Diff-Based Debugging

The system SHALL compare passing and failing execution traces to identify the divergence point and display actionable differences.

#### Scenario: Report comparison

- **WHEN** a passing report and a failing report are compared
- **THEN** the system SHALL identify the command index where execution diverged

#### Scenario: Event diff

- **WHEN** events differ between passing and failing runs at the divergence point
- **THEN** the system SHALL show the events from each run side by side

#### Scenario: State diff

- **WHEN** projection states differ between two runs
- **THEN** the system SHALL show changed fields, added fields, and removed fields

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
