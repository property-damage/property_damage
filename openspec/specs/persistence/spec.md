# Persistence Specification

## Purpose

Persistence provides durable storage and retrieval of failure data, seed management, regression test orchestration, and step-by-step replay for debugging. It enables teams to save discovered failures, build regression suites, share seeds, and interactively debug failures without re-running full test suites.

Reference: DR-020 (Composable, Version-Aware Libraries)

## Requirements

### Requirement: Failure Persistence

The system SHALL save and load failure reports to `.pd` files using Erlang term format for lossless struct preservation.

#### Scenario: Save a failure report

- **WHEN** a failure report is saved to a directory
- **THEN** the system SHALL write a `.pd` file containing a version header, the Erlang term-encoded `FailureReport` struct, and a checksum for integrity verification
- **AND** the filename SHALL follow the pattern `{timestamp}-{failure_type}-{check_name}-seed{seed}.pd`
- **AND** the version header SHALL record the current format version (`7`, since a report's `failure_reason` is a nested `%PropertyDamage.Failure{}` and the six denormalized failure fields are gone — DR-041; event-log entries carry a `fold_index` and the trace carries `command_fold_ordinals` + verified `linearization` for the derived per-step state timeline — DR-040; positions are `%Sequence.Position{}` structs — DR-039; the report composes a `RunTrace` — DR-033), which tracks the `FailureReport` struct shape

#### Scenario: Save with custom filename

- **WHEN** a failure report is saved with a `:filename` option
- **THEN** the system SHALL use the provided filename instead of the auto-generated one

#### Scenario: No overwrite by default

- **WHEN** a failure report is saved and a file with the same name already exists
- **THEN** the system SHALL return `{:error, reason}` unless `:overwrite` is set to `true`

#### Scenario: Load a failure report

- **WHEN** a `.pd` file is loaded
- **THEN** the system SHALL return the original `FailureReport` struct with all data intact

#### Scenario: List saved failures

- **WHEN** a directory is queried for saved failures
- **THEN** the system SHALL return all `.pd` files in that directory

### Requirement: Version-Aware Format

The system SHALL include version metadata in persisted files and warn when loading files from different versions.

#### Scenario: Version metadata on save

- **WHEN** a failure report is saved
- **THEN** the file SHALL include the PropertyDamage version, the Elixir version, and dependency versions

#### Scenario: PropertyDamage version mismatch warning

- **WHEN** a `.pd` file is loaded and the PropertyDamage version differs from the current version
- **THEN** the system SHALL return a `{:property_damage_version_mismatch, saved_version, current_version}` warning

#### Scenario: Dependency version mismatch warning

- **WHEN** a `.pd` file is loaded and a dependency version differs from the current environment
- **THEN** the system SHALL return a `{:dependency_version_mismatch, dep, saved_version, current_version}` warning

#### Scenario: Missing dependency warning

- **WHEN** a `.pd` file references a dependency not present in the current environment
- **THEN** the system SHALL return a `{:dependency_missing, dep, saved_version}` warning

#### Scenario: Pre-v7 format versions are refused

- **WHEN** a `.pd` (or `.pdtrace`) file written under an earlier format version (`1`, `2`, `3`, `4`, `5`, or `6`) is loaded
- **THEN** the system SHALL return `{:error, {:unsupported_format_version, version, 7}}` without attempting to decode the payload
- **AND** the system SHALL NOT synthesize the missing data: a pre-v7 file stores `failure_reason` as a raw `{:tag, ...}` tuple and carries the six now-deleted denormalized failure fields, so there is no honest in-place upgrade; the user re-captures the failure under the current version instead (the framework is unpublished and such files exist only as regenerable test fixtures)

> This supersedes the DR-040 requirement that named format version `6` and refused versions `1`–`5`; version `7` (DR-041) is now current and versions `1`–`6` are refused. It also carries forward the earlier supersessions of the tolerant-loading / trace-synthesis rules.

### Requirement: Seed Library

The system SHALL maintain an ephemeral, self-pruning working set of recently-failing seeds that `PropertyDamage.run/1` replays before random exploration (DR-023). The library is not a durable regression corpus: a seed reproduces its sequence only while the model's generators are byte-stable, so durable regressions are the Export subsystem's responsibility. Persistence is a plain JSON file via `save`/`load`; there is no export/import sharing format.

#### Scenario: Add a seed to the library

- **WHEN** a failure is added to the seed library
- **THEN** an entry SHALL be created with the seed value, model module name, failure type, check name, user-provided tags, discovery timestamp, and an initial `consecutive_passes` streak of 0
- **AND** the `failure_type`, `check_name`, and captured `dependency_versions` SHALL be inert descriptive metadata that participate in no verdict logic

#### Scenario: Seed tagging

- **WHEN** a seed is added with tags (e.g., `:race_condition`, `:edge_case`, `:currency`)
- **THEN** those tags SHALL be stored with the entry

#### Scenario: Streak tracking on replay

- **WHEN** a library seed is replayed with a binary pass/fail verdict (signatures are not compared)
- **THEN** a passing replay SHALL increment the entry's `consecutive_passes` streak and update `last_run`
- **AND** a failing replay SHALL reset the streak to 0, refresh the entry's descriptive `failure_type`/`check_name` from the new report, and update `last_run`

#### Scenario: Self-pruning after consecutive passes

- **WHEN** an entry's `consecutive_passes` streak reaches the prune threshold `K` (default 3, configurable via the `seed_library_prune_after` run option)
- **THEN** the entry SHALL be removed from the library after the replay pass
- **AND** a flaky seed (whose streak keeps resetting) SHALL self-retain, while a fixed or no-longer-reproducing seed SHALL age out

#### Scenario: Atomic persistence

- **WHEN** the library is saved
- **THEN** the system SHALL write to a temporary file in the same directory and rename it over the destination, so a concurrent reader never observes a partially-written file
- **AND** the working set SHALL be best-effort and non-authoritative (concurrent writers are last-writer-wins; a lost append is harmless)

#### Scenario: Tolerant loading

- **WHEN** a library file written by an older version is loaded
- **THEN** the system SHALL tolerate missing fields, dropping the obsolete `status`/`run_count`/`fail_count` and assuming a fresh `consecutive_passes` streak of 0

#### Scenario: Integration with PropertyDamage.run

- **WHEN** `seed_library:` is enabled on `PropertyDamage.run/1` (`true` for the default file, or a path) and the library is non-empty
- **THEN** the system SHALL replay every library seed (most-recently-discovered first) before random exploration, updating streaks and pruning as above, without consuming `max_runs`
- **AND** if any replay still fails, the system SHALL skip random exploration and halt, returning a shrunk `FailureReport` for a representative still-failing seed
- **AND** if all replays pass, random exploration SHALL proceed
- **AND** a new failure discovered during exploration SHALL be appended to the same file, deduplicated by seed
- **WHEN** `seed_library:` is `false` (default)
- **THEN** the system SHALL neither read nor write any seed library file

### Requirement: Regression Test Management

The system SHALL automatically manage regression tests from discovered failures with deduplication.

#### Scenario: Automatic failure persistence

- **WHEN** the `:regression` option includes `save_failures: "failures/"`
- **THEN** each discovered failure SHALL be automatically saved to that directory

#### Scenario: Deduplication of similar failures

- **WHEN** `dedup: true` is set in regression options
- **THEN** new failures SHALL be compared against existing persisted failures using fingerprint similarity
- **AND** failures with similarity above the threshold (default 0.90) SHALL NOT be saved again

#### Scenario: Regression test generation

- **WHEN** the `:regression` option includes `generate_tests: "test/regressions/"`
- **THEN** the system SHALL generate ExUnit test files from each unique failure

#### Scenario: Composable handlers

- **WHEN** regression handlers are composed via `Regression.compose/1`
- **THEN** all handlers SHALL execute in sequence for each failure report

### Requirement: Replay

The system SHALL support step-by-step re-execution of a saved command sequence for interactive debugging.

#### Scenario: Functional replay

- **WHEN** `PropertyDamage.replay(failure)` is called
- **THEN** the system SHALL return all steps, where each step includes the command index, command struct, command name, produced events, projection states after execution, ref resolution map, and step result

#### Scenario: Interactive replay session

- **WHEN** `Replay.start(failure)` is called
- **THEN** the system SHALL return a session that can be advanced one command at a time via `Replay.step(session)`

#### Scenario: Jump to failure point

- **WHEN** `Replay.step_to(session, index)` is called
- **THEN** the system SHALL execute all commands up to and including the given index and return the session at that point

#### Scenario: Step state inspection

- **WHEN** a replay step is returned
- **THEN** the step SHALL include `projections_before` (state before command) and `projections` (state after command) for comparison

#### Scenario: CLI replay as a regression check

- **WHEN** `mix pd.replay <failure-file>` is run on a saved `.pd` file
- **THEN** the system SHALL load the failure (reading its recorded model and adapter from the file, requiring no model/adapter flags), re-execute the shrunk sequence through the engine, and print each step with its result
- **AND** the task SHALL exit `0` only when every step passes (the failure no longer reproduces), `1` when the failure reproduces (any step fails its check or errors during execution), and `125` when the replay cannot run at all (the project does not compile, the file fails to load, it records no model/adapter, or the sequence is branching)
- **AND** the `125` exit SHALL distinguish a replay that could not run (indeterminate) from one where the failure reproduces, so `git bisect run` skips such commits rather than marking them bad
- **AND** a branching (parallel) failure, a load error, or a missing model/adapter SHALL produce a clear message and the `125` exit rather than a crash

#### Scenario: CLI bisect to find the regressing commit

- **WHEN** `mix pd.bisect <failure-file> --good <ref> [--bad <ref>]` is run on a saved `.pd` file
- **THEN** the system SHALL drive `git bisect` between the good and bad refs, replaying the failure at each candidate commit and classifying it from `mix pd.replay`'s exit code (`0` good, `1` bad, `125` skip), and report the first commit where the failure reproduces
- **AND** the system SHALL refuse to start when the working tree has uncommitted changes, and SHALL error cleanly on an invalid `--good`/`--bad` ref, in both cases without leaving a bisect in progress
- **AND** the system SHALL copy the failure file outside the working tree before bisecting (so it survives checkouts of commits where it is not tracked) and SHALL always run `git bisect reset` afterward, restoring the original branch on success, error, and exception
- **AND** the system SHALL replay the saved concrete shrunk sequence rather than re-generating from the seed, so the search remains valid across commits that changed generators, command weights, or `when:` predicates

### Requirement: Run Trace Persistence (DR-033)

A `RunTrace` SHALL be serializable to and loadable from disk independently of a `FailureReport`, so that traces captured in separate processes or on separate commits (for example, a passing run on one CI job and a failing run on another) can be collected and compared later. Trace files SHALL use the same binary framing as reports, with the payload gaining an explicit `kind` (`:run_trace` or `:failure_report`) that loaders dispatch on. Trace serialization SHALL record the run identity including `run_nonce` and `mint_epoch` (DR-034), the `plan_fingerprint` (DR-036), and the source revision, and SHALL carry a format version. When a `FailureReport` composes a `RunTrace` (DR-033), the persisted report format SHALL advance to version 4; older report files SHALL continue to load under this domain's tolerant-loading rules, with the loader synthesizing the embedded trace from the legacy fields (`shrunk_sequence` as the plan with `plan_source: :shrunk`, the event log, and the scalar identity; `run_nonce`, `mint_epoch`, the executed record, and `plan_fingerprint` absent as `nil`) so the step interface keeps working on pre-v4 files. The dependency-version capture and struct-drift checks SHALL extend to walk the embedded trace.

#### Scenario: Trace round-trips independently

- **WHEN** a `RunTrace` is saved and later loaded, possibly in a different process
- **THEN** the loaded trace SHALL reproduce the plan, executed commands, event log, identity (including nonce, epoch, and fingerprint), and outcome sufficient for comparison

#### Scenario: Report format version advances

- **WHEN** a `FailureReport` composing a `RunTrace` is persisted
- **THEN** the file SHALL be written at format version 4
- **AND** pre-v4 report files SHALL still load without data loss

#### Scenario: Pre-v4 report loads with a synthesized trace

- **WHEN** a v3 (or older) report file is loaded
- **THEN** the loader SHALL synthesize the embedded `RunTrace` from the legacy fields
- **AND** `FailureReport.steps/1` and `event_entries_at/2` SHALL work on the loaded report exactly as they did before the composition
