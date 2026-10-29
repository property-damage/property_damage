# Failure Analysis Specification

## Purpose

Failure analysis provides intelligent post-mortem tooling for PropertyDamage test failures. It fingerprints failures for comparison, clusters similar failures to surface root causes, verifies fixes with seed variations, classifies error origins (SUT vs test code), suggests missing invariants, generates structured reports, compares passing/failing traces, and replays production event logs through model projections for incident analysis.

Reference DRs: DR-049 (Expansions, Roots That Run as Several Commands), DR-050 (Shrinking Along the Expansion Axis, and the Replay Artifact), DR-054 (Log Lines for the Failure Report), DR-055 (Failure Report Layout), DR-056 (One Report Layout, Two Renderers), DR-057 (HTML Failure Report)

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

The system SHALL produce structured failure reports containing location (run number, command index, seed), original and shrunk command sequences, projection states before and at failure, the complete event trail, and the structured failure reason. The shrunk sequence and event trail are served through the report's embedded `RunTrace` (DR-033); `shrunk_sequence/1` and `event_log/1` are accessors over the trace, not struct fields. A report of kind `:diverged` or `:did_not_converge` SHALL also carry `reference_trace` (the reference target's `RunTrace` of the reported run) and `reference_state_at_failure` (the reference's projection state at the failing boundary, cut as DR-040 defines), and every other kind SHALL leave both `nil` (DR-055). Every report SHALL carry `shrink_stop`: `:done` when the shrinker finished inside its budget or never ran, `:max_iterations` or `:max_time` when a budget ran out first (DR-055).

#### Scenario: Report creation

- **WHEN** a test failure occurs
- **THEN** a `FailureReport` SHALL be created with seed, run_number, original_sequence, failed_at_index, failure_reason, and an embedded `RunTrace` whose plan serves as the shrunk sequence (DR-033)

#### Scenario: Multiple output formats

- **WHEN** a report is formatted
- **THEN** the system SHALL support `:terminal`, `:markdown`, `:json`, and `:compact` output formats
- **AND** the `:json` format SHALL keep every field of the report, the sections the printed formats dropped included (DR-055)

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

The `:terminal` and `:markdown` formats SHALL print one layout, built once from the report as plain data and printed by one renderer per format. The terminal report SHALL print a banner (`BUG DETECTED!`, or `TEST CODE ERROR` for a failure in test code) whose lines all have one width with and without color, then `Seed: <seed>`, then the sections `Failure`, `Minimal Reproduction (N roots)`, `Projections at <label>` (only when a compared side has state) and `Reproduction`, in that order. It SHALL NOT print Run Number, Command Index, Timestamp, State Transition, Event Log, Boundary Comparisons, Shrinking Statistics or Original Sequence. The markdown report SHALL open with `# BUG DETECTED!` or `# TEST CODE ERROR`, then the seed, then the terminal's `## ` headings in the same order, each section's body in one fenced block whose text equals the terminal body without color (`diff` for Projections, `elixir` for Reproduction). `Formatter.format/3` SHALL read `:color` for the terminal format and no other layout option. The `:json` format SHALL keep every field it carried before this layout and SHALL gain `reference_trace` and `reference_projections` for a comparison failure (DR-055) and the `logs` key (DR-054); the `:compact` format SHALL NOT change.

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

#### Scenario: A shrinker that ran out of budget says so (DR-055)

- **WHEN** the report's `shrink_stop` is `:max_iterations` or `:max_time`
- **THEN** the Failure section SHALL print a `Shrink` field that says the shrinker stopped at its iteration (or time) budget, so the reproduction may not be minimal
- **AND** a report whose `shrink_stop` is `:done` or `nil` SHALL print no `Shrink` field

#### Scenario: Reproduction binds the targets once

- **WHEN** the report's `targets` is not empty
- **THEN** Reproduction SHALL print `targets = [...]` once and every call SHALL name `targets: targets`
- **AND** when a target holds a pid, a reference, a port or a function, also inside a list or a tuple, a line under the binding SHALL name each place by its path (`config.server`, a list or tuple element by its index) and say to rebuild the list as the test does

### Requirement: Failure Report Replay Fields and Footer (DR-050)

`FailureReport` SHALL carry `run` (the campaign run the failure happened in, counted from 1), `replay` (the replay artifact term, `{:refused, where}` or `nil`), `replay_path` (the file or `nil`) and `replay_status` (`:written`, `:disabled`, `{:write_failed, reason}`, `:refused`, `:unavailable`, `:reproduced`, `:not_reproduced` or `nil`). The printed report SHALL end with, in this order: the reproduction command (`reproduction_command/1`, the seed path); the comment `# Regenerate the failing variant:` and the `PropertyDamage.Expansion.for/5` call for the failing target (`expansion_command/1`), both omitted when the report records no target, since it has no name to regenerate with (`expansion_command/1` then returns `nil`); and the comment `# Replay the shrunk failure:` (`# Replay the unshrunk failure:` when no shrink step ran) and the `only: [replay: path]` call (`replay_command/1`); when the report has targets, each call SHALL name `targets: targets`, bound once above it (DR-055, DR-056), in place of the list. The replay call SHALL name a non-default `compare: [converge_within: ms]` and `check_mode:` as `reproduction_command/1` does. That call SHALL be the last code line of the report. When there is no file, the last lines SHALL say why: `replay_dir: false`, a refusal naming the target, the root, the leaf and the field path, or the write error. `targets_source/1` SHALL print each target's `expansion:` when it is not `:random`, so that a pasted call runs the targets as the failing run did.

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

### Requirement: Log Lines in the Printed Report (DR-054, DR-055)

The `:terminal` and `:markdown` reports SHALL print every log line of the reported run (DR-054) in the target's listing, under the step that wrote it, merged with that step's events in timestamp order; on an equal millisecond a line SHALL print before an event. A line SHALL print at the event column as `+S.SSs`, a space, the badge `log` padded to five columns, a space, then the tags in brackets separated by spaces when it has tags, then the message; a message over several lines SHALL continue at the message's column. Offsets of events and lines SHALL count from one origin per target: the earliest timestamp among that target's events and lines. A string SHALL print as written; any other value SHALL print through the report's one `inspect/2` call, with syntax colors when the report is colored; a function SHALL be called each time the report is formatted and its result printed by those rules, and one that raises, throws or exits SHALL print `(log line raised: ...)`. The lines of the adapter's `setup/1` SHALL print before the first listed step under the note `adapter setup/1`, and those of its `teardown/1` after the last listed step under the note `adapter teardown/1`, each only when there are some. For a comparison failure each listing SHALL hold its own target's lines. Only the reported run's lines SHALL print: no line of a shrink attempt or of a target the report does not list. The `:json` format SHALL carry the lines under `logs` (see "Tag Filters and `PD_LOG`"); the `:compact` format SHALL NOT print lines.

#### Scenario: A timed-out step shows the lines written before the kill
- **WHEN** an adapter logs two tagged lines and then hangs past its timeout
- **THEN** the `:execution_failed` report SHALL print both lines under the timed-out step with their offsets and tags

#### Scenario: A divergence lists each target's lines
- **WHEN** the report is `:diverged`
- **THEN** the Reference listing SHALL hold the reference's lines and the Variant listing the variant's, each under its step with that step's events

#### Scenario: A setup failure shows the adapter's setup lines
- **WHEN** the adapter's `setup/1` logs and then fails
- **THEN** the `:setup_failed` report SHALL print the line under the `adapter setup/1` note, on the lockstep and the branching path alike
- **AND** the lines of the target's injector and mock setup and teardown SHALL print once each, under the `adapter setup/1` and `adapter teardown/1` notes

#### Scenario: A fault lifted at the end of a failed run shows its restore line
- **WHEN** a nemesis fault is still active when the run fails, and its `restore/2` logs at the end of the run
- **THEN** the report SHALL print that line under the nemesis step that injected the fault

#### Scenario: A shrunk report shows the reported run's lines only
- **WHEN** a failure is shrunk
- **THEN** each listed step SHALL show the lines of its one execution in the reported run, and no line of a shrink attempt

### Requirement: Setup Lines and Gaps in the Printed Report (DR-054, DR-055, DR-056)

A report built with `setup_log:` (the lines `PropertyDamage.Log.capture/1` returned) SHALL print them once, in a section whose heading starts with `Setup`, right after Failure and before Minimal Reproduction, whatever the number of targets. The section SHALL be present exactly when the report's `setup_log` is not empty. Its first body line SHALL say that the lines are shared by every run; each following line SHALL be a log line in the form of the target listings, at the event column, in timestamp order (stable), with offsets counted from the earliest setup line. A setup line SHALL never enter a target's offset origin. Function and value messages SHALL follow the rules of the listings. The `:markdown` report SHALL carry the section's plain body in one fence. `shrink_further/2` SHALL keep the given report's `setup_log` on the report it returns. `FailureReport.setup_log` SHALL be set on every report `PropertyDamage.run/1` builds, `only: [replay: path]` included. The `:json` format SHALL carry the setup lines once under `logs.setup`; the `:compact` format SHALL NOT print setup lines.

Where a step's retry cap dropped attempts (see the execution-engine requirement "Log Lines Keep a Step's First and Last Attempts"), the listing SHALL print each gap in its place among the step's lines as `... N attempts omitted (M lines)`, at the event column with no offset and no badge, with comma thousands separators and the singular `1 attempt` and `1 line`; faint when colored; the markdown report SHALL print the plain text. A step whose omitted attempts logged nothing SHALL show no gap.

#### Scenario: The Setup section sits between Failure and the reproduction
- **WHEN** a run with `setup_log: lines` fails, with one target or with two that diverge
- **THEN** the report SHALL print one Setup section, right after Failure, whose first body line says the lines are shared by every run and whose other lines are the setup lines in the log line form

#### Scenario: No lines, no section
- **WHEN** a run has no `setup_log:` or `setup_log: []`
- **THEN** the report SHALL print no Setup section

#### Scenario: A setup line does not move a target's offsets
- **WHEN** a setup line carries a timestamp far earlier than any event
- **THEN** the offsets of the target listings SHALL be those of the same report without setup lines

#### Scenario: A replay prints the Setup section
- **WHEN** `only: [replay: path]` runs with `setup_log: lines`
- **THEN** the report SHALL print the Setup section

#### Scenario: A gap prints in its place
- **WHEN** a step's cap dropped 296 attempts that wrote 1,184 lines
- **THEN** the listing SHALL print `... 296 attempts omitted (1,184 lines)` between the first attempt's lines and the kept ones

### Requirement: Tag Filters and `PD_LOG` for the Printed Log Lines (DR-054)

`log: [only: tags, except: tags]` SHALL be accepted by `PropertyDamage.run/1` (so by `only: [replay: path]` and `only: [run: n]` too) and by `PropertyDamage.ExUnit.format_failure/2` (the arity-1 form keeps its meaning). Each of `only:` and `except:` SHALL be a non-empty list of atoms, and an empty list, a non-list or a non-atom element SHALL raise `NimbleOptions.ValidationError` naming the key. A line SHALL print when it has no tags, or when (the filter has no `only:` or the line carries a listed `only:` tag) and (the filter has no `except:` or the line carries no listed `except:` tag). The filter SHALL hide whole lines only: a line that prints SHALL print exactly as it does without a filter, and hiding a line SHALL NOT move another line's offset, because every offset origin counts from all of a target's lines. The filter SHALL apply to the step lines of every listed target, the adapter `setup/1` and `teardown/1` lines and the `setup_log:` lines; the Setup section and the adapter notes, which print only when they have lines, SHALL be absent when the filter hides all of theirs. A retry-cap gap is not a line: it SHALL always print, with its counts unchanged. `keep_attempts:` SHALL keep its meaning and no filter SHALL change which lines a run keeps.

Every report `PropertyDamage.run/1` builds SHALL hold the run's filter in `FailureReport.log_filter` (`nil` for none), and `shrink_further/2` SHALL keep it. The filter is memory only: `Persistence.save/3` SHALL write `log_filter: nil`, `Persistence.load/1` SHALL return `log_filter: nil`, a version-15 file saved before the field existed included, and a replay artifact SHALL carry none. The persistence version SHALL stay 15.

The environment variable `PD_LOG` SHALL hold the same filter as text, `only:a,b except:c`, either part optional, parts separated by whitespace, each key at most once, at least one tag per part, spaces around a colon or comma tolerated, tag names matched as strings and no atom created. When set and not blank, it SHALL replace the in-code filter and SHALL NOT merge with it; an empty or whitespace-only value SHALL count as unset. A value that does not parse SHALL raise `ArgumentError` whose message quotes the value and shows the expected syntax with an example. `PD_LOG` SHALL be read only when a report is formatted, so the verdict, the shrink and the replay artifact of a run SHALL be byte-identical with and without it, and a run under an invalid value SHALL complete and return its report. The filter that applies SHALL be, in order: `PD_LOG`; else a `log:` in the format options of `Formatter.format/3` or `format_failure/2`, which replaces the report's own; else the report's own; else none. `format_failure/2` SHALL raise `ArgumentError` for any key but `log:`, and for any key but `only:` and `except:` under `log:`, `keep_attempts:` included. The `:compact` format SHALL ignore filters and `PD_LOG`.

When a filter applied, the `:terminal` and `:markdown` reports SHALL print, once, a `Log filter` field at the end of the Failure section that names every listed tag of both parts and the source, `(from the log: option)` or `(from PD_LOG)`; without a filter they SHALL print no such field. A tag listed in `only:` or `except:` that no line of the report carries (no line of `setup_log` and of the failing target's and the reference's trace) SHALL be named, in the order given and without duplicates, in one `Log warning` field after it: `no line carries the tag :sed`. The warning SHALL be absent when every listed tag is carried.

The `:json` format SHALL gain a top-level `logs` key built from the same layout and filter as the terminal: `filter` (`only`, `except`, `source` as `"log_option"` or `"PD_LOG"`; null without a filter), `unknown_tags`, `setup` (the setup lines once), `target` and `reference` (null when the report lists one target), each with `name`, `adapter_setup`, `adapter_teardown` and `steps` (`label`, `root` and `lines`, in report order). A line SHALL be `kind: "line"`, `message` (plain text: a string as written, any other value through `inspect/2` with `pretty: true`, a function called with the raise marker), `tags` (strings), `file`, `line`, `offset_ms` and `attempt`; a gap SHALL be `kind: "gap"`, `attempts` and `lines`. A hidden line SHALL appear nowhere in `logs`, and every other JSON key SHALL be unchanged. The JSON output is not the persistence format.

#### Scenario: only: shows the tagged and the untagged lines
- **WHEN** a step logged lines tagged `[:http]`, `[:http, :headers]`, `[:seed]` and one untagged, and the report prints under `only: [:headers]`
- **THEN** the step SHALL show the `[:http, :headers]` line and the untagged line only

#### Scenario: except: wins over only:
- **WHEN** a line is tagged `[:http, :body]` and the filter is `only: [:http], except: [:body]`
- **THEN** the line SHALL be hidden

#### Scenario: A shown line is unchanged
- **WHEN** the same report prints with and without a filter
- **THEN** each line that prints under the filter SHALL be byte-identical to the same line without it, offsets included

#### Scenario: A misspelled tag is named
- **WHEN** the filter lists `:sed` and no line carries it
- **THEN** the report SHALL print one `Log warning` field naming `:sed`

#### Scenario: PD_LOG replaces the in-code filter
- **WHEN** `PD_LOG="only:headers"` is set and the run gave `log: [only: [:seed], except: [:body]]`
- **THEN** the report SHALL apply `only: [:headers]` alone and name `PD_LOG` as its source

#### Scenario: A value that does not parse
- **WHEN** `PD_LOG="only"` is set
- **THEN** the run SHALL complete and return its report, and formatting it SHALL raise `ArgumentError` quoting `"only"` and showing the syntax

#### Scenario: A saved report holds no filter
- **WHEN** a report built with `log: [only: [:http]]` is saved and loaded again
- **THEN** the loaded report SHALL have `log_filter: nil` and the file SHALL be version 15

### Requirement: HTML Failure Report (DR-057)

A failing run SHALL write its failure report as one HTML page into a directory when the run option `report_html: dir` (default `false`, which writes no page) or the environment variable `PD_REPORT_HTML` names one (DR-057). When `PD_REPORT_HTML` is set and not blank, it SHALL replace the option; a blank value SHALL count as unset. The directory SHALL be created when missing. A file error while writing the page SHALL cost one logged warning and SHALL NOT change the report (DR-057). A value of `report_html:` that is neither a string nor `false` SHALL raise `NimbleOptions.ValidationError`.

`PropertyDamage.FailureReport.HTML.render/1` SHALL return one page that holds the terminal report text without color, as built by `Formatter.format/3` for `:terminal`, and the viewer that reads it. The text SHALL follow the layout of the printed report and apply the same log tag filter (DR-054, DR-057), so the page body SHALL carry nothing the terminal text does not carry. The page SHALL load nothing from the network (DR-057).

The page SHALL be named after the model, the failing target, the failure kind and the seed, so a later failure with the same four replaces it, and SHALL be written by a rename of a temporary file in the same directory (DR-057). `HTML.write/2` SHALL rebuild `index.html` in the directory after each page, and `HTML.write_index/1` SHALL rebuild it from the report pages present, in file name order, leaving out any page whose title cannot be read (DR-057).

#### Scenario: PD_REPORT_HTML replaces report_html:
- **WHEN** the run gives `report_html: "dir_a"`, `PD_REPORT_HTML="dir_b"` is set and the run fails
- **THEN** the page SHALL be written into `dir_b` and none into `dir_a` (DR-057)

#### Scenario: A blank PD_REPORT_HTML is unset
- **WHEN** the run gives `report_html: "dir_a"`, `PD_REPORT_HTML` is whitespace only and the run fails
- **THEN** the page SHALL be written into `dir_a` (DR-057)

#### Scenario: The page carries the terminal text without color
- **WHEN** a report is rendered with `HTML.render/1`
- **THEN** the page SHALL embed the text `Formatter.format(report, :terminal, color: false)` returns, as data a script reads, and SHALL reference no resource outside the file (DR-057)

#### Scenario: The report tag filter applies to the page
- **WHEN** the report holds `log_filter` `only: [:http]` or `PD_LOG` is set
- **THEN** the embedded text SHALL hide the same lines the terminal report hides (DR-054, DR-057)

#### Scenario: An unwritable directory costs a warning
- **WHEN** the run fails and the directory in `report_html:` cannot be created
- **THEN** the run SHALL log one warning and SHALL return its report unchanged (DR-057)

#### Scenario: The index lists the pages present
- **WHEN** a directory holds two report pages and a file that is not a report page, and `HTML.write_index/1` runs on it
- **THEN** `index.html` SHALL list the two pages in file name order and not the other file (DR-057)
