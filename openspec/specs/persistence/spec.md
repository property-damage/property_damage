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
