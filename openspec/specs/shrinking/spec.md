# Shrinking Specification

## Purpose

Defines the two-phase shrinking algorithm that reduces failing command sequences to minimal reproductions while preserving failure equivalence, including dependency-aware removal, probe command prioritization, argument simplification, and branching sequence support.

Reference DR: DR-017 (Hierarchical Delta Debugging)

## Requirements

### Requirement: Failure Equivalence

A shrunk sequence SHALL only be accepted if it reproduces the same failure as the original. Failure equivalence is determined by a failure signature consisting of the failure type and check name.

#### Scenario: Same failure type and check name
- **WHEN** a candidate shrunk sequence is executed
- **AND** it produces a failure with the same type and check name as the original
- **THEN** the candidate SHALL be accepted as a valid shrink

#### Scenario: Different failure type rejected
- **WHEN** a candidate shrunk sequence produces a failure with a different type than the original
- **THEN** the candidate SHALL be rejected
- **AND** the shrinker SHALL continue trying other candidates

#### Scenario: Failure at same or earlier index
- **WHEN** a candidate shrunk sequence produces the equivalent failure
- **THEN** the failure SHALL occur at the same or an earlier command index than in the original sequence

### Requirement: Two-Phase Shrinking

The system SHALL shrink in two phases: Phase 1 removes unnecessary commands from the sequence, and Phase 2 simplifies argument values in the remaining commands.

#### Scenario: Phase 1 then Phase 2
- **WHEN** shrinking begins on a failing sequence
- **THEN** the shrinker SHALL first attempt to remove commands (Phase 1)
- **AND** then attempt to simplify arguments in remaining commands (Phase 2)

#### Scenario: Phase 2 optional
- **WHEN** shrinking configuration disables argument shrinking
- **THEN** only Phase 1 (sequence shrinking) SHALL be performed

### Requirement: Phase 1 Sequence Shrinking Steps

Phase 1 SHALL proceed in three ordered steps: first drop commands that were never executed (after the failure point), then apply hierarchical shrinking by dependency depth, then apply linear shrinking on individual commands.

#### Scenario: Drop unexecuted commands
- **WHEN** a sequence failed at command index N
- **THEN** all commands after index N SHALL be removed first

#### Scenario: Hierarchical shrinking by depth
- **WHEN** commands remain after dropping unexecuted ones
- **THEN** the shrinker SHALL build a dependency graph, group commands by depth, and attempt to remove entire groups while preserving the failure

#### Scenario: Linear shrinking of individuals
- **WHEN** hierarchical shrinking completes
- **THEN** the shrinker SHALL attempt to remove each remaining command individually

### Requirement: Hierarchical Dependency Graph

The shrinker SHALL build a directed acyclic graph of command dependencies based on reference production and consumption. Commands SHALL be grouped by depth in this graph, and groups SHALL be tried for removal starting from the deepest level.

#### Scenario: Graph built from reference flow
- **WHEN** the shrinker analyzes a command sequence
- **THEN** it SHALL identify which commands produce references and which consume them
- **AND** edges SHALL connect producers to consumers

#### Scenario: Group removal by depth
- **WHEN** hierarchical shrinking is applied
- **THEN** commands at the greatest depth SHALL be tried for removal first
- **AND** if removing a group preserves the failure, those commands SHALL be permanently removed

### Requirement: Reference-Aware Removal

The shrinker SHALL NOT remove a command whose produced reference is consumed by a downstream command that remains in the sequence.

#### Scenario: Producer retained when consumer present
- **WHEN** command A produces a reference consumed by command B
- **AND** command B remains in the candidate sequence
- **THEN** command A SHALL NOT be removed

#### Scenario: Producer removable when no consumers remain
- **WHEN** command A produces a reference
- **AND** no remaining commands consume that reference
- **THEN** command A MAY be removed if the failure is still reproduced

### Requirement: Probe Command Shrinking Priority

Probe (read-only) commands SHALL be prioritized for removal during shrinking, since they do not modify system state and are less likely to be essential to reproducing a failure.

#### Scenario: Probes removed before state-modifying commands
- **WHEN** the shrinker evaluates commands for removal
- **THEN** probe commands SHALL be attempted for removal before non-probe commands

### Requirement: Argument Shrinking

In Phase 2, the system SHALL simplify argument values in remaining commands: integers shrink toward 0, strings shrink toward empty, and lists shrink toward empty. Symbolic references SHALL never be shrunk.

#### Scenario: Integer shrinks toward zero
- **WHEN** a command contains an integer argument
- **THEN** the shrinker SHALL attempt to replace it with values closer to 0

#### Scenario: String shrinks toward empty
- **WHEN** a command contains a string argument
- **THEN** the shrinker SHALL attempt to replace it with shorter strings or an empty string

#### Scenario: List shrinks toward empty
- **WHEN** a command contains a list argument
- **THEN** the shrinker SHALL attempt to remove list elements

#### Scenario: Placeholders never shrunk
- **WHEN** a command contains a placeholder for a server-generated value
- **THEN** that placeholder SHALL NOT be modified during argument shrinking

### Requirement: Branching Sequence Shrinking

For branching sequences, the shrinker SHALL additionally attempt to remove entire branches, shrink individual branches, and convert the sequence to linear form.

#### Scenario: Remove entire branch
- **WHEN** a branching sequence has multiple branches
- **THEN** the shrinker SHALL attempt removing each branch entirely
- **AND** accept the removal if the failure is still reproduced

#### Scenario: Shrink individual branches
- **WHEN** branches remain after branch removal attempts
- **THEN** the shrinker SHALL apply command removal within each branch independently

#### Scenario: Convert to linear
- **WHEN** the failure does not require parallel execution to reproduce
- **THEN** the shrinker SHALL attempt converting the branching sequence to a linear sequence

### Requirement: Deterministic Shrinking

Given the same seed and the same initial failure, shrinking SHALL produce the same shrunk result, provided the SUT behaves deterministically.

#### Scenario: Reproducible shrink output
- **WHEN** shrinking is run twice with the same seed, sequence, and failure
- **AND** the SUT produces identical behavior both times
- **THEN** the shrunk sequence SHALL be identical in both runs

### Requirement: Shrinking Configuration

The shrinker SHALL support configuration of: `granularity_threshold` (default 8) controlling when to switch from hierarchical to linear shrinking, `max_iterations` (default 1000) limiting total shrink attempts, `max_time_ms` (default 30000) setting a time budget, and a `shrink_arguments` flag (default true) controlling whether Phase 2 runs.

#### Scenario: Granularity threshold controls strategy
- **WHEN** the remaining sequence length is below the granularity threshold
- **THEN** the shrinker SHALL switch from hierarchical to linear shrinking

#### Scenario: Max iterations limit
- **WHEN** the shrinker reaches the maximum number of iterations
- **THEN** shrinking SHALL stop and return the best result found so far

#### Scenario: Time budget exceeded
- **WHEN** the elapsed shrinking time exceeds `max_time_ms`
- **THEN** shrinking SHALL stop and return the best result found so far

### Requirement: Re-shrinking with a Larger Budget

The system SHALL support re-running the shrinker over an already-shrunk failure with a fresh budget, to recover reductions the original run missed. `PropertyDamage.shrink_further/2` SHALL accept a `:strategy` (`:quick` | `:thorough` | `:exhaustive`, default `:thorough`) that derives the iteration and time budgets (overridable via `:max_iterations` and `:max_time_ms`), re-shrink the report's `shrunk_sequence`, and return an updated report whose `original_sequence` is preserved and whose `shrink_iterations`/`shrink_time_ms` accumulate onto the prior values. It SHALL return `{:error, :missing_model_or_adapter}` when the report records no model or adapter.

#### Scenario: Re-shrink reduces a non-minimal sequence
- **WHEN** `shrink_further/2` is run on a report whose shrunk sequence is not yet minimal
- **THEN** it SHALL return `{:ok, report}` with a smaller (or equal) shrunk sequence that still reproduces the same failure
- **AND** the returned report SHALL preserve `original_sequence` and accumulate the shrink effort onto the prior `shrink_iterations`/`shrink_time_ms`

#### Scenario: Re-shrink requires a model and adapter
- **WHEN** `shrink_further/2` is run on a report that records no model or adapter
- **THEN** it SHALL return `{:error, :missing_model_or_adapter}` rather than crashing

#### Scenario: CLI re-shrink with a larger budget
- **WHEN** `mix pd.reshrink <failure-file>` is run on a saved `.pd` file
- **THEN** the system SHALL load the failure (reading its recorded model and adapter from the file), re-shrink the sequence with the selected strategy/budget, and print the before/after command counts
- **AND** the task SHALL write nothing by default, write the smaller report to `--output PATH`, or replace the input file with `--overwrite`
- **AND** the task SHALL exit zero on any successful re-shrink (whether or not the sequence got smaller) and non-zero only on a real error (load failure, missing model/adapter, or a requested write failure), since re-shrink is not a pass/fail regression gate

### Requirement: Failure Signature

The failure signature SHALL be a tuple of `{type, check_name}` where type identifies the category of failure and check_name identifies the specific check (or nil for non-check failures).

#### Scenario: Check failure signature
- **WHEN** a failure is caused by a check violation
- **THEN** the signature SHALL contain the failure type and the check name

#### Scenario: Non-check failure signature
- **WHEN** a failure is caused by a non-check condition (e.g., adapter error, linearization failure)
- **THEN** the signature SHALL contain the failure type and nil for the check name
