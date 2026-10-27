# Failure Analysis Specification

## Purpose

Failure analysis provides intelligent post-mortem tooling for PropertyDamage test failures. It fingerprints failures for comparison, clusters similar failures to surface root causes, verifies fixes with seed variations, classifies error origins (SUT vs test code), suggests missing invariants, generates structured reports, compares passing/failing traces, and replays production event logs through model projections for incident analysis.

Reference DRs: DR-049 (Expansions, Roots That Run as Several Commands), DR-050 (Shrinking Along the Expansion Axis, and the Replay Artifact), DR-055 (Failure Report Layout), DR-056 (One Report Layout, Two Renderers)

## Requirements

### Requirement: Structured Failure Reason

A run's `failure_reason` SHALL be a single structured type,
`%PropertyDamage.Failure{}` (DR-041), not a loose family of `{:tag, ...}` tuples.
It SHALL nest one class struct under `type`: `Failure.Check`,
`Failure.Execution`, or `Failure.Framework`, so that illegal class/kind
combinations are unrepresentable, and SHALL record the producing branch (if any)
as `branch_id` on the envelope (absorbing the former `{:branch_failure, id,
inner}` wrapper). Each class struct SHALL own a `kind` from a closed, documented
set; kinds SHALL be globally unique atoms across the three classes. The framework
SHALL expose `Failure.class/1`, `kind/1`, `name/1`, `detail/1`, `branch_id/1`,
and `partial_events/1` accessors.

#### Scenario: Kinds partition into three classes

- **WHEN** a run fails
- **THEN** `Failure.class/1` SHALL return `:check` for a property/invariant violation (`:check_failed`, `:idempotency_violation`, `:linearization`, `:poll_timeout`, `:settle_timeout`, `:projection_violation`)
- **AND** `:execution` for a command-execution failure (`:adapter_error`, `:nemesis_error`, `:stutter_execution_failed`, `:resource_poller_error`, `:poll_error`, `:retry_from_sync_command`, `:malformed_adapter_return`)
- **AND** `:framework` for a framework-level failure (`:placeholder_resolution`, `:unknown`)

#### Scenario: Report views derive from the failure reason

- **WHEN** a `FailureReport` is built from a `%Failure{}` reason
- **THEN** `FailureReport.failure_type/1` SHALL return the kind, `check_name/1` the name, `failure_message/1` a human-readable description, and `idempotency_violation/1` / `poll_timeout_info/1` the relevant payload; all derived from `report.failure_reason` rather than stored as denormalized fields

### Requirement: Failure Fingerprinting

The system SHALL extract comparable features from each failure report, producing a fingerprint that captures the failure type, check name, triggering command type, command shape, event types, sequence length, sequence shape, state keys, error category, and error pattern.

#### Scenario: Fingerprint from a check failure

- **WHEN** a failure report's `failure_reason` is a `%PropertyDamage.Failure{}` of kind `:check_failed` naming `:NonNegativeBalance` (so `FailureReport.failure_type/1` is `:check_failed` and `check_name/1` is `:NonNegativeBalance`)
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

### Requirement: Cluster Fix Verification

The system SHALL verify a fix against a cluster of similar failures by re-running each clustered member that carries a seed against the model and adapter, reporting how many members are now fixed, how many still fail, and how many cannot be re-run.

#### Scenario: Fully fixed cluster

- **WHEN** every clustered failure carries a seed and none of them reproduce after the fix
- **THEN** the cluster verification status SHALL be `:fully_fixed`
- **AND** the fixed count SHALL equal the cluster size and the remaining count SHALL be zero

#### Scenario: Partially fixed cluster

- **WHEN** some seeded members pass and at least one still reproduces
- **THEN** the cluster verification status SHALL be `:partially_fixed`
- **AND** the fingerprints that still reproduce SHALL be listed as remaining failures

#### Scenario: Not fixed cluster

- **WHEN** every seeded member still reproduces the failure
- **THEN** the cluster verification status SHALL be `:not_fixed`

#### Scenario: Members without a seed

- **WHEN** a clustered fingerprint carries no seed, or no adapter is supplied to re-run it
- **THEN** that member SHALL be counted as `unknown` rather than fixed or remaining
- **AND** when no member can be re-run the cluster verification status SHALL be `:unknown`

### Requirement: Error Origin Classification

The system SHALL classify each failure as originating from the SUT, the test code, or unknown, along with a confidence level (high, medium, low).

#### Scenario: SUT error with high confidence

- **WHEN** the failure reason is a `%PropertyDamage.Failure{}` of kind `:check_failed`, `:poll_timeout`, `:idempotency_violation`, or `:linearization`
- **THEN** the origin SHALL be classified as `:sut_error` with confidence `:high`

#### Scenario: Test code error with high confidence

- **WHEN** the failure involves an `UndefinedFunctionError` in model/projection/command/adapter modules, or a `FunctionClauseError` in projection apply or command callbacks
- **THEN** the origin SHALL be classified as `:test_code_error` with confidence `:high`

#### Scenario: Ambiguous classification

- **WHEN** the failure is a generic exception during check execution or an adapter error
- **THEN** the origin SHALL be classified as `:unknown` with confidence `:low`
- **AND** the classification SHALL include evidence explaining the ambiguity

### Requirement: Actionable Banners and Hints

The system SHALL produce user-facing banners and hints based on error origin classification to guide debugging.

#### Scenario: SUT error banner

- **WHEN** a failure is classified as `:sut_error`
- **THEN** the printed report SHALL open with the banner `BUG DETECTED!` (DR-055)
- **AND** the Failure section SHALL name the violated invariant in its `Invariant` field when its name differs from the check's, and the check in its `Check` field

#### Scenario: Test code error banner

- **WHEN** a failure is classified as `:test_code_error`
- **THEN** the printed report SHALL open with the banner `TEST CODE ERROR` and a line saying the system under test is not at fault (DR-055)
- **AND** the Failure section SHALL say what went wrong in its `What went wrong` field, and name the module and callback involved in its `Hint` or `Location` field when the classification found them

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

The system SHALL produce structured failure reports containing location (run number, command index, seed), original and shrunk command sequences, projection states before and at failure, the complete event trail, and the structured failure reason. The shrunk sequence and event trail are served through the report's embedded `RunTrace` (DR-033); `shrunk_sequence/1` and `event_log/1` are accessors over the trace, not struct fields.

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

- **WHEN** a check failure is reported and the check validates an invariant with a description
- **THEN** the report SHALL headline the invariant's `name` and `description`, with the specific failing check shown as secondary detail
- **AND** when the invariant has no description, the report SHALL fall back to the check name as today

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
- **AND** at most one step SHALL have `failed?: true`: the command where the failure was localized, matched by position rather than by comparing the flattened index to `failed_at_index` (an executor index that diverges from the flattened ordinal for branch failures)
- **AND** `FailureReport.failure_step/1` (a failure-specific locator retained on the report, not on `RunTrace`) SHALL return that step, or `nil` for a non-localized failure (teardown / whole-run / linearization, where `failed_at_index` is `nil`)
- **AND** `FailureReport.event_entries_at/2` SHALL delegate to `RunTrace.event_entries_at/2`, returning the log entries for a command addressed by either its flattened index or its `%Sequence.Position{}`
- **AND** `steps/1` / `failure_step/1` SHALL be the ONLY structural accessors for the failing command and its entries: the report SHALL NOT carry materialized `command_at_failure` / `events_at_failure` fields (removed), and every renderer, exporter, and forensic analyzer SHALL obtain the failing command/events via the step interface (which resolves them branch-aware) rather than by re-walking `shrunk_sequence` / `event_log` / `failed_at_index`; in particular the event timeline's per-command provenance view (source badges + branch) SHALL be served from `steps/1` `entries` rather than a private `event_log` walk

### Requirement: Printed Failure Report Layout (DR-055, DR-056)

The `:terminal` and `:markdown` formats SHALL print one layout, built once from the report as plain data and printed by one renderer per format. The terminal report SHALL print a banner (`BUG DETECTED!`, or `TEST CODE ERROR` for a failure in test code) whose lines all have one width with and without color, then `Seed: <seed>`, then the sections `Failure`, `Minimal Reproduction (N roots)`, `Projections at <label>` (only when a compared side has state) and `Reproduction`, in that order. It SHALL NOT print Run Number, Command Index, Timestamp, State Transition, Event Log, Boundary Comparisons, Shrinking Statistics or Original Sequence. The markdown report SHALL open with `# BUG DETECTED!` or `# TEST CODE ERROR`, then the seed, then the terminal's `## ` headings in the same order, each section's body in one fenced block whose text equals the terminal body without color (`diff` for Projections, `elixir` for Reproduction). `Formatter.format/3` SHALL read `:color` for the terminal format and no other layout option. The `:json` and `:compact` formats SHALL NOT change.

#### Scenario: One label per step in every section

- **WHEN** a report is printed
- **THEN** every listed command SHALL carry the label `Sequence.Position.label/2` gives it: `[i]` for a root, `[i.j]` for a leaf listed under root `[i]` (never the root's generated id), `[branch b.i]`, `[setup i]`, `[teardown i]`, and for a suffix command its reading-order index
- **AND** the Failure section's `At` field, every line marked `►` and the Projections heading SHALL carry the failing step's label, and every `►` line SHALL end with `◄── diverged`, `◄── did not converge` or `◄── failed`
- **AND** a failure tied to no step SHALL print no `►` and no `At` field
- **AND** a command that prints over several lines SHALL start on the line after its label, so the notes and the `◄──` mark end the label's line and never split the printed value

#### Scenario: A comparison failure lists both sides

- **WHEN** the report's kind is `:diverged` or `:did_not_converge`
- **THEN** Minimal Reproduction SHALL list the reference under `Reference: target "<name>"` and the failing variant under `Variant: target "<name>"`, each with its own events, and the root at the failing boundary SHALL be marked in both, also when the variant ran it as leaves
- **AND** the Failure section SHALL print both values, the `using:` relation as written (`==` without one) and the time waited against the bound (`still differing after N ms (bound M ms)`, or `still pending`)
- **AND** it SHALL print `Mismatch` only when the relation failed with a reason
- **AND** the Projections `-` and `+` sides SHALL be the reference's and the variant's states cut at the failing boundary (DR-040), so that nothing either side folded after the boundary shows

#### Scenario: Events sit under their step

- **WHEN** a listed step has events
- **THEN** they SHALL print under it in timestamp order, each with its offset from the earliest timestamp of that target's event log and with `event` or the source badge of its source
- **AND** entries tied to no command SHALL print after the listing under `Not tied to a command`

#### Scenario: Values print in full

- **WHEN** a command, an event, a Failure value or a projection attribute is printed
- **THEN** it SHALL print through one `inspect/2` call with no element or string limit, and a projection SHALL print one attribute per line, equal attributes once and differing ones as a `-` line then a `+` line

#### Scenario: Reproduction binds the targets once

- **WHEN** the report's `targets` is not empty
- **THEN** Reproduction SHALL print `targets = [...]` once and every call SHALL name `targets: targets`
- **AND** when a target holds a pid, a reference, a port or a function, also inside a list or a tuple, a line under the binding SHALL name each place by its path (`config.server`, a list or tuple element by its index) and say to rebuild the list as the test does

### Requirement: Failure Report Replay Fields and Footer (DR-050)

`FailureReport` SHALL carry `run` (the campaign run the failure happened in, counted from 1), `replay` (the replay artifact term, `{:refused, where}` or `nil`), `replay_path` (the file or `nil`) and `replay_status` (`:written`, `:disabled`, `{:write_failed, reason}`, `:refused`, `:unavailable`, `:reproduced`, `:not_reproduced` or `nil`). The printed report SHALL end with, in this order: the reproduction command (`reproduction_command/1`, the seed path); the comment `# Regenerate the failing variant:` and the `PropertyDamage.Expansion.for/5` call for the failing target (`expansion_command/1`); and the comment `# Replay the shrunk failure:` (`# Replay the unshrunk failure:` when no shrink step ran) and the `only: [replay: path]` call (`replay_command/1`); when the report has targets, each call SHALL name `targets: targets`, bound once above it (DR-055, DR-056), in place of the list. The replay call SHALL name a non-default `compare: [converge_within: ms]` and `check_mode:` as `reproduction_command/1` does. That call SHALL be the last code line of the report. When there is no file, the last lines SHALL say why: `replay_dir: false`, a refusal naming the target, the root, the leaf and the field path, or the write error. `targets_source/1` SHALL print each target's `expansion:` when it is not `:random`, so that a pasted call runs the targets as the failing run did.

#### Scenario: The footer ends with the replay call
- **WHEN** a failing run writes an artifact
- **THEN** the report's last code line SHALL be `PropertyDamage.run(model: M, targets: targets, only: [replay: "<path>"])`
- **AND** the regenerate call SHALL come before the replay label

#### Scenario: A pasted call keeps each target's expansion mode
- **GIVEN** a failing run with a target on `expansion: :reference`
- **WHEN** the report prints the `targets = [...]` binding
- **THEN** the binding SHALL include `expansion: :reference` for that target

#### Scenario: No artifact says why
- **WHEN** a run fails with `replay_dir: false`
- **THEN** the report SHALL say that no artifact was written because of `replay_dir: false`, in place of the replay call

### Requirement: Regenerating a Target's Sequence (DR-050)

`PropertyDamage.Expansion.for(model, seed, run, name, opts \\ [])` SHALL return `{:ok, %{prefix: [struct], roots: [struct], choices: [choice], sequence: [struct]}}` for the target `name`, or `{:error, message}` naming the model, the run, the name or the option at fault. It SHALL run no target and no adapter. `run` SHALL count from 1, and run n SHALL generate from `PropertyDamage.Generator.run_seed(seed, n - 1)`, so `for(model, report.seed, 1, name)` regenerates a failing run as it ran before shrinking. `sequence` SHALL equal the commands the named target executed (the setup prefix, then every root's commands in order, without the teardown), and the result SHALL be the same in every OS process. `opts` SHALL accept `:targets` (the run's `targets:`, from which the name's `expansion:` mode and the reference are read; without it, the name is a `:random` target) and `:max_commands`.

#### Scenario: The result equals what the target ran
- **GIVEN** a run recorded with a recording adapter
- **WHEN** `Expansion.for(M, seed, 1, name)` runs
- **THEN** its `sequence` SHALL equal the commands the adapter of target `name` executed

#### Scenario: A reference target
- **GIVEN** `targets:` in which `name` is on `expansion: :reference`
- **WHEN** `Expansion.for/5` runs with that `targets:`
- **THEN** it SHALL return the reference's concrete sequence

#### Scenario: An unknown name
- **WHEN** `name` is not in `targets:`
- **THEN** it SHALL return `{:error, message}` that names the name

### Requirement: Replay Artifact Generation (DR-050)

A failing run SHALL write one replay artifact after shrinking, in the format the persistence requirement "Replay Artifact File (DR-050)" specifies, into `replay_dir:`. With `shrink: false` it SHALL hold the unshrunk run and the footer SHALL say so. The run SHALL refuse to build the artifact when a command field (inside lists, tuples and maps, map keys included) holds a function, pid, reference, port, improper list or non-binary bitstring. A refusal SHALL set `replay` to `{:refused, where}` and `replay_status` to `:refused`, SHALL name the target, the root, the leaf and the field path (a refused map key marked `{:key, text}`), and SHALL leave the failure reported and reproducible from its seed. A latency budget failure and a branching sequence SHALL have no artifact (`replay_status: :unavailable`).

#### Scenario: A function in a command is refused
- **GIVEN** a command whose field holds an anonymous function
- **WHEN** the run fails
- **THEN** `report.replay` SHALL be `{:refused, where}` naming the target, the root, the leaf and the field
- **AND** the footer SHALL say that the artifact was refused and why

#### Scenario: A pid used as a map key is refused
- **GIVEN** a command whose map field has a pid as a key
- **WHEN** the run fails
- **THEN** the refusal path SHALL end in `{:key, text}` with the key's printed form

#### Scenario: A refusal does not hide the failure
- **WHEN** the artifact is refused
- **THEN** `run/1` SHALL still return the failure report

### Requirement: Re-execution Paths Read the Recorded Data (DR-050)

Every path that executes a failure again SHALL take each target's concrete commands from the report's `replay` term, or from the choices the report's trace records when the report has no term, and SHALL NOT raise for a target that ran leaves. A report loaded from a version-15 `.pd` file SHALL behave the same. `PropertyDamage.shrink_further/2` SHALL work for every recorded target, SHALL recompute `expansions` and `expansion_counts` for the further-shrunk run, and SHALL write its smaller artifact over the incoming report's file; it SHALL raise, naming `replay_dir:`, only when the report holds neither a term nor choices. `PropertyDamage.Replay.run/2` and `start/2` SHALL replay any recorded target, each leaf as a step. `PropertyDamage.Analysis.isolate_trigger/2` on a reference that ran leaves SHALL vary one concrete command of the reference's sequence and re-run the reference alone, and SHALL raise `ArgumentError` for a non-reference target that ran leaves. Because every variation runs one target alone, `isolate_trigger/2` SHALL return `{:error, :not_applicable}` for a `:diverged` or `:did_not_converge` report. Export SHALL emit the reference's concrete leaves; the ExUnit export SHALL emit `only: [replay: path]` when the report has a file and the seed path otherwise. The seed-library replay and `RunTrace.capture/1` SHALL recompute from the seed. `RunComparison` SHALL align two runs at root level.

#### Scenario: Replay of a leaf-running target
- **GIVEN** a report whose second target ran a root as two leaves
- **WHEN** `Replay.run/2` replays that target
- **THEN** each leaf SHALL be one step and no error SHALL be raised

#### Scenario: shrink_further writes over the same seed's file
- **GIVEN** a report whose artifact is at `dir/Model_seed3.replay.exs`
- **WHEN** `shrink_further/2` finds a smaller failing run
- **THEN** it SHALL write the smaller artifact to the same path
- **AND** the returned report's `replay_path` SHALL name that path

#### Scenario: shrink_further without recorded data
- **WHEN** `shrink_further/2` receives a report with no `replay` term and no recorded choices
- **THEN** it SHALL raise an error that names `replay_dir:`

#### Scenario: isolate_trigger on the reference's leaves
- **GIVEN** a report whose reference ran a root as leaves
- **WHEN** `Analysis.isolate_trigger/2` runs
- **THEN** it SHALL name the concrete command whose variation stops the failure, re-running the reference alone

#### Scenario: isolate_trigger refuses another target
- **WHEN** `Analysis.isolate_trigger/2` receives a report whose failing target is not the reference and ran leaves
- **THEN** it SHALL raise `ArgumentError`

#### Scenario: isolate_trigger on a divergence
- **WHEN** `Analysis.isolate_trigger/2` receives a report of kind `:diverged` or `:did_not_converge`
- **THEN** it SHALL return `{:error, :not_applicable}` without running any target

#### Scenario: The ExUnit export names the file
- **WHEN** a report with a replay file is exported as an ExUnit test
- **THEN** the test SHALL call `PropertyDamage.run/1` with `only: [replay: path]`

### Requirement: Run Trace as the Execution Record (DR-033)

The framework SHALL model the complete record of a single run as a `PropertyDamage.RunTrace`, independent of outcome. A `RunTrace` SHALL carry the run identity (`seed`, `run_number`, `run_nonce`, `mint_epoch` (DR-034), `model`, `adapter`, UTC `timestamp`, and best-effort `source_revision`), the plan (`plan`, the `%Sequence{}` this run executed; deliberately NOT named `original_sequence`, whose report-level meaning is the generated plan of the failing exploration run), a `plan_source` of `:generated` (a pure function of the effective seed) or `:shrunk` (a shrinker product, not regenerable from the seed), the canonical `plan_fingerprint` (DR-036), the concrete executed commands with their resolved and minted values keyed branch-aware by `%Sequence.Position{}`, the complete `EventLog` with per-entry provenance, the `command_labels`, and an `outcome` of `:pass` or `{:fail, reason}`. The executor SHALL always accumulate the resolved concrete command per position (including within branch workers, merged with branch state) so the executed record exists whenever a trace is materialized. `RunTrace` SHALL be the sole owner of the structural step query interface: `RunTrace.steps/1` and `RunTrace.event_entries_at/2` describe any run regardless of outcome, using the same branch-aware `%Sequence.Position{}` identity the failure report already uses. A `FailureReport` SHALL compose the `RunTrace` of the run the report describes: the shrunk minimal reproduction when its re-execution reproduced the failure, otherwise the original failing run (the existing non-reproduction fallback), and add only failure-specific concerns: the locators `failure_step/1` and `failure_index/1`, the shrink relationship (`original_sequence` vs the trace's plan), and the failure classification. Deep execution-record structures SHALL live once, on the trace: the report SHALL NOT carry `event_log` or `shrunk_sequence` struct fields; `FailureReport.event_log/1` and `FailureReport.shrunk_sequence/1` SHALL be accessors over the embedded trace, while scalar identity (`seed`, `run_number`, `model`, `adapter`, `timestamp`) MAY remain duplicated on the report as its locator surface. Full `RunTrace` capture SHALL be on demand (`RunTrace.capture/1`, DR-035), not retained for every exploration run.

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

### Requirement: Per-Step State Timeline and Projection Purity (DR-040)

Per-command projection state SHALL be DERIVED from a `RunTrace`, never captured per step. The executor SHALL record the run's real fold order additively: each `EventLog.Entry` SHALL carry a `fold_index` stamped when its event folds into projections (`nil` for entries that are recorded but never folded, i.e. `:stutter` retries and `:telemetry` spans), and the trace SHALL carry `command_fold_ordinals` (each command's own fold ordinal by position) and the verified branch `linearization`. From this record the framework SHALL derive two state views: a FAITHFUL view (`RunTrace.state_at/2`, `state_before/2`, `state_timeline/1`) that replays the real fold order so async / injected events land where they folded, and a CANONICAL view (`RunTrace.canonical_state_timeline/1`) that folds each step's command then its attributed events in flattened order and is therefore fold-order-independent. Branching faithful replay SHALL mirror the executor's branch merge: branch steps fold branch-locally from the post-prefix state, and suffix steps fold the merged state (branches replayed in verified `linearization` order when recorded, else branch order) then the suffix. The framework SHALL provide a projection-purity check (`FailureReport.verify_projections/1`, `RunTrace.verify_projections/4`): the faithful-derived state at the failing step MUST equal the runtime `state_at_failure` snapshot (and `state_before_failure` at its step), and a mismatch SHALL be reported as `{:non_pure_projections, [module]}` naming the projection module(s) whose `apply/2` is not a pure function of `(state, event)`. Because the faithful view replays the real fold order, a pure-but-async projection SHALL NOT be reported as non-pure. This is a two-point sample (before + at the failing step), an explicitly partial coverage. A generation-side companion (`PropertyDamage.audit_projections/2`, run by `mix pd.audit`) SHALL fold each generated plan twice and name any projection whose two folds disagree.

#### Scenario: Faithful state matches the runtime snapshot

- **WHEN** the faithful per-step state is derived at the failing step of a report built from a real run
- **THEN** it SHALL equal the runtime `state_at_failure` snapshot (and `state_before_failure` at that step) for a model whose projections are pure, on both linear and branching runs

#### Scenario: Impure projection is detected

- **WHEN** a projection's `apply/2` reads a value outside `(state, event)` (a clock, a counter, the environment)
- **THEN** the projection-purity check SHALL report `{:non_pure_projections, modules}` naming that projection, and SHALL NOT accuse a pure projection folded in the same run

#### Scenario: Pure-but-async projection does not false-positive

- **WHEN** an event folds outside command attribution (an async injector/queue event) but every projection is pure
- **THEN** the faithful-derived state SHALL still equal the runtime snapshot, so the projection-purity check SHALL return `:ok`

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
- **AND** `stop_on_first_failure` is `true` (the default)
- **THEN** the system SHALL halt at the first violation and return `{:error, failure}` with the failure step and violation details

#### Scenario: Collecting every violation

- **WHEN** production events are replayed with `stop_on_first_failure: false`
- **THEN** the system SHALL replay every event to completion and return `{:ok, success}`
- **AND** `success.violations` SHALL contain one violation record per violating event, in replay order
- **AND** each violation record SHALL carry the same detail shape as the `{:error, failure}` result (failure reason, failure step, event at failure, state before/after, events leading to failure)
- **AND** `success.violations` SHALL be an empty list when no invariant was violated

#### Scenario: Event mapping

- **WHEN** production events have different field names or structures than framework event structs
- **THEN** the system SHALL use an `EventMapping` behaviour module to translate production events
- **AND** events returning `:skip` from the mapping SHALL be excluded from replay
