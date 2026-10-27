# Persistence Specification

## Purpose

Persistence provides durable storage and retrieval of failure data, seed management, regression test orchestration, and step-by-step replay for debugging. It enables teams to save discovered failures, build regression suites, share seeds, and interactively debug failures without re-running full test suites.

Reference: DR-050 (Shrinking Along the Expansion Axis, and the Replay Artifact), DR-020 (Composable, Version-Aware Libraries), DR-042 (One Engine for Property-Based, Differential and Path-Equivalence Runs), DR-045 (One Runner for One or More Targets), DR-046 (Boundary Observations, the Convergence Loop and Adapter Errors), DR-047 (Latency Is a Measurement with a Campaign-End Budget), DR-049 (Expansions, Roots That Run as Several Commands)

## Requirements

### Requirement: Failure Persistence

The system SHALL save and load failure reports to `.pd` files using Erlang term format for lossless struct preservation.

#### Scenario: Save a failure report

- **WHEN** a failure report is saved to a directory
- **THEN** the system SHALL write a `.pd` file containing a version header, the Erlang term-encoded `FailureReport` struct, and a checksum for integrity verification
- **AND** the filename SHALL follow the pattern `{timestamp}-{failure_type}-{check_name}-seed{seed}.pd`
- **AND** the version header SHALL record the current format version (`15`, since the report carries `check_mode`, `campaign`, `original_failed_at_index` and `run_check_fires` (the check firings of the run the report describes), and a report lacking `run`, `replay`, `replay_path` or `check_mode` is refused; version `14` added `run`, `replay`, `replay_path` and `replay_status`, and an expansion entry may be `:identity` (DR-050); version `13` added `expansions`, `expansion_counts` and the trace's `expansion` (DR-049); version `12` added `latency` and `metrics` (DR-047); version `11` added `setup_commands` and `teardown_commands` and the sequence's setup and teardown sections (DR-048); version `10` added `compare`, `compare_counts` and `other_failures` in place of `equivalence` and a divergence holds the `@compare` key, the two values and the mismatch, DR-046; the report carries `kind`, `variant`, `targets` and `concurrency` in place of `adapter`, DR-045; the persisted vocabulary is the check vocabulary: `%Failure.Check{}` and `check_fires`, DR-042; a report's `failure_reason` is a nested `%PropertyDamage.Failure{}` and the six denormalized failure fields are gone, DR-041; event-log entries carry a `fold_index` and the trace carries `command_fold_ordinals` + verified `linearization` for the derived per-step state timeline, DR-040; positions are `%Sequence.Position{}` structs, DR-039; the report composes a `RunTrace`, DR-033), which tracks the `FailureReport` struct shape

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

#### Scenario: Pre-v15 format versions are refused

- **WHEN** a `.pd` (or `.pdtrace`) file written under an earlier format version (`1` through `14`) is loaded
- **THEN** the system SHALL return `{:error, {:unsupported_format_version, version, 15}}` without attempting to decode the payload
- **AND** the system SHALL NOT synthesize the missing data: a v14 file stores neither the run's `check_mode` a reproduction reuses, nor the `campaign` a latency budget was judged over, nor the `original_failed_at_index`; a v13 file stores neither the report's `run` nor its replay artifact (`replay`, `replay_path`, `replay_status`), which every re-execution path reads (DR-050); a v12 file stores neither the report's `expansions` and `expansion_counts` nor the trace's `expansion`, the concrete leaves each target ran (DR-049); a v11 file stores neither the run's `latency:` option nor the latency `metrics` (DR-047); a v10 file has no `setup_commands` or `teardown_commands`, which v11 adds so a report reproduces without re-drawing them (DR-048); a v9 file stores the report's `equivalence` and a `Failure.Divergence` holding `reference_result` and `divergent_result`, which v10 replaced with `compare`, `compare_counts`, `other_failures` and a divergence holding the `@compare` key, the two values and the mismatch (DR-046); older files predate the `kind`, `variant` and `targets` fields (DR-045), the `%Failure.Check{}` and `check_fires` names (DR-042) and the nested `%Failure{}` shape (DR-041). There is no honest in-place upgrade, so the user re-captures the failure under the current version (the framework is unpublished and such files exist only as regenerable test fixtures)

#### Scenario: A report carries the concrete leaves each target ran (DR-049)

- **WHEN** a failure report from a run of a model with `expansions/0` is saved at version 15
- **THEN** the file SHALL carry `expansions` (per target name, one element per executed root: the root index, the entry key and the leaf modules), `expansion_counts` (per target name and root module, the count per entry key and `:forced`) and the trace's `expansion` (per target name, the choice at every root with its leaves and aliases)
- **AND** a loaded report SHALL let `Replay`, `shrink_further/2` and export run what each target ran without picking again

#### Scenario: A report carries its replay artifact (DR-050)

- **WHEN** a failure report is saved at version 15
- **THEN** the file SHALL carry `run`, `replay` (the artifact term, `{:refused, where}` or `nil`), `replay_path` and `replay_status`
- **AND** a loaded report SHALL let `shrink_further/2`, `Replay`, `Analysis.isolate_trigger/2` and export run what each target ran without a draw
- **AND** the `.pdtrace` format SHALL share the version number

#### Scenario: A report carries its run options and the original failing index

- **WHEN** a failure report is saved at version 15
- **THEN** the file SHALL carry `check_mode` (the run's `check_mode:`), `campaign` (`%{seed:, max_runs:}` for a `:latency_exceeded` report, `nil` otherwise) and `original_failed_at_index`
- **AND** a version-15 file whose report lacks `run`, `replay`, `replay_path` or `check_mode` SHALL be refused with `{:error, {:missing_field, field}}`, never loaded with a drift warning

#### Scenario: A report carries the comparison record and the latency record

- **WHEN** a failure report from a run with two or more targets is saved
- **THEN** the file SHALL carry `compare` (`[converge_within: ms]`), `compare_counts` (per `@compare` key: `compared_at`, `waited_at`, `waited_ms`) and `other_failures` (each with the variant, the root and the failure)
- **AND** the file SHALL carry `latency` (the option as given) and `metrics` (per target name, `nil` when `latency:` is off)
- **AND** a key-named failure SHALL round trip, including its name when the key is a tuple

#### Scenario: JSON export of the comparison record

- **WHEN** `export_json/1` writes a report
- **THEN** it SHALL write `kind`, `variant`, `targets`, `compare`, `compare_counts` and `other_failures`
- **AND** it SHALL NOT write `adapter` or `equivalence`

> Version `15` is now current and versions `1`-`14` are refused. The step from `14` adds the report's `check_mode`, `campaign`, `original_failed_at_index` and `run_check_fires`, and refuses a report lacking `run`, `replay`, `replay_path` or `check_mode`. It supersedes the version `14` requirement of DR-050, whose step from `13` added the report's `run`, `replay`, `replay_path` and `replay_status`, and the entry value `:identity`. It also carries forward the earlier supersessions of the tolerant-loading / trace-synthesis rules.

### Requirement: Replay Artifact File (DR-050)

A failing run SHALL write a replay artifact as a second persisted format, beside the `.pd` file's binary encoding. The artifact SHALL be one Elixir source file, named `<model last name segment>_seed<seed>.replay.exs`, holding one literal term after the header line `# PropertyDamage replay artifact, format 1`. The term SHALL hold `format`, `model`, `seed`, `run`, `targets` (names in order with their `expansion:`, the reference first), `failure` (the kind, name, variant index and root index as data), `prefix`, `roots` (with their ids) and `choices` (per target name, per root: `root_id`, `entry`, `commands`, `aliases`). The artifact SHALL NOT hold the failure's exception or mismatch, the teardown commands or a timestamp, and two writes of the same failure SHALL produce the same bytes. A write SHALL replace the file only when it records the same failure (kind, name and failing target) under the same targets, or does not read as an artifact; when the file records another failure or other targets, the run SHALL write `<model last name segment>_seed<seed>_<k>.replay.exs` with the smallest `k` from 2 whose file is free, records the same failure or does not read as an artifact, and the report's `replay_path` and footer SHALL name the file written. The file's format number is independent of the `.pd` version.

The loader SHALL read the file as data: it SHALL parse the source with `Code.string_to_quoted/2` with `existing_atoms_only: true` and accept only literals (atoms, booleans, `nil`, numbers, strings, charlists, lists, tuples, maps and `%Module{}` literals). It SHALL create no atom: an atom (or a module name) the running system does not know SHALL be refused, naming it. It SHALL load no module: a `%Module{}` literal in a command's own place (an element of `prefix`, a root's `command`, an element of a choice's `commands`) SHALL be accepted only when `Module` was loaded before the loader ran and is a command module (it exports `generator/1`) or `PropertyDamage.Placeholder` or `PropertyDamage.Sequence.Position`; a `%Module{}` literal anywhere else, at any depth of a command's fields, SHALL be accepted when `Module` was loaded before the loader ran and defines a struct; any other SHALL be refused with `{:error, {:unknown_struct_module, Module}}`, and `only: [replay: path]` SHALL raise `ArgumentError` naming the module before any target is set up. It SHALL NOT evaluate the source and SHALL NOT decode an Erlang binary. It SHALL refuse a call, capture, function, pipe, sigil, module attribute, variable or second term, naming the node and its line, and it SHALL refuse a missing header, a header for another format, and a term whose `format` disagrees with the header, naming both.

#### Scenario: The same failure writes the same file

- **GIVEN** a failing run at a fixed seed with `replay_dir:` set to a directory
- **WHEN** the run fails twice
- **THEN** both runs SHALL write byte-identical files at the same path

#### Scenario: The loader refuses code

- **GIVEN** an artifact whose term holds a function call
- **WHEN** `only: [replay: path]` loads it
- **THEN** the loader SHALL refuse it naming the call and its line, and no code SHALL run

#### Scenario: A failure of the same seed under other targets keeps the first file

- **GIVEN** an artifact a failure of seed S wrote at `dir/Model_seedS.replay.exs`
- **WHEN** another failure of seed S under other `targets:` writes into `dir`
- **THEN** it SHALL write `dir/Model_seedS_2.replay.exs`, leave the first file's bytes unchanged, and its report SHALL name the second path

#### Scenario: The loader creates no atom and loads no module

- **GIVEN** an artifact naming an atom the running system does not know, or a struct literal of a module on the code path that is not loaded (as a command or inside a command's field), or of a loaded module that is not a command (such as `%URI{}`) as a command
- **WHEN** it is loaded
- **THEN** the loader SHALL refuse it naming the atom or the module, no atom SHALL be created and the module SHALL stay unloaded

#### Scenario: A command field holds a struct of a loaded module

- **GIVEN** an artifact whose command has a field holding a `%Date{}`, directly or inside a list or map
- **WHEN** it is loaded
- **THEN** the loader SHALL return the command with the `Date` in that field

#### Scenario: A header for another format is refused

- **GIVEN** an artifact whose header says `format 2`
- **WHEN** it is loaded
- **THEN** the loader SHALL refuse it naming both formats

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

#### Scenario: Replay of a model with expansions runs the recorded leaves (DR-049)

- **GIVEN** a saved report from a model with `expansions/0`
- **WHEN** `Replay.start(failure)` and `Replay.step_to(session, index)` run it
- **THEN** the replay SHALL execute the leaves that the replayed target recorded for each root, in order, without picking expansions again
- **AND** each step SHALL carry the root index in `index` and the leaf's position in `leaf_index`
- **AND** `step_to(session, index)` SHALL execute every leaf of root `index`
- **WHEN** the report records no choices for the replayed target
- **THEN** the replay SHALL raise an error that names the target

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

### Requirement: Log Lines Live Only in Memory (DR-054)

A run's log lines SHALL be dropped when the run ends, unless the run is the one a failure report describes. `Persistence.save/3` and `Persistence.save_trace/3` SHALL write every `RunTrace` they hold (a report's `trace` and `reference_trace`) with `logs: %{}`, and `Persistence.load/1` and `Persistence.load_trace/1` SHALL return every trace with `logs: %{}`, a version-15 file saved before the field existed included. The format version SHALL stay 15. A replay artifact, an export and every other file PropertyDamage writes SHALL carry no line text.

#### Scenario: A saved report holds no line
- **WHEN** a report whose traces hold log lines is saved and loaded again
- **THEN** the file SHALL not contain the lines' text, and the loaded report's `trace` and `reference_trace` SHALL have `logs: %{}`

#### Scenario: A file saved before the field existed loads
- **WHEN** a version-15 report file whose traces lack `logs` is loaded
- **THEN** each trace SHALL have `logs: %{}` and the report SHALL print in the terminal and markdown formats

#### Scenario: A replay artifact holds no line
- **WHEN** a run that logged writes its replay artifact
- **THEN** no file in the replay directory SHALL contain the text of a line
