# Shrinking Specification

## Purpose

Defines the two-phase shrinking algorithm that reduces failing command sequences to minimal reproductions while preserving failure equivalence, including dependency-aware removal, probe command prioritization, argument simplification, and branching sequence support.

Reference DRs: DR-017 (Hierarchical Delta Debugging), DR-025 (Continuous Async-Observation Checking), DR-045 (One Runner for One or More Targets), DR-046 (Boundary Observations, the Convergence Loop and Adapter Errors), DR-048 (Setup and Teardown Commands), DR-049 (Expansions, Roots That Run as Several Commands)

## Requirements

### Requirement: Failure Equivalence

A shrunk sequence SHALL only be accepted if it reproduces the same failure as the original. Failure equivalence is determined by a failure signature consisting of the failure kind, the check name and the index of the variant that failed (DR-045).

#### Scenario: Same failure type and check name
- **WHEN** a candidate shrunk sequence is executed
- **AND** it produces a failure with the same type and check name as the original
- **THEN** the candidate SHALL be accepted as a valid shrink

#### Scenario: Different failure type rejected
- **WHEN** a candidate shrunk sequence produces a failure with a different type than the original
- **THEN** the candidate SHALL be rejected
- **AND** the shrinker SHALL continue trying other candidates

#### Scenario: Different check rejected
- **WHEN** the original failure is a named check failure
- **AND** a candidate shrunk sequence fails via a *different* check
- **THEN** the candidate SHALL be rejected (check failures are distinguished by name, not conflated) (DR-025)

#### Scenario: Same check observed synchronously or asynchronously is equivalent
- **WHEN** the original failure and a candidate failure are the same named check
- **THEN** they SHALL be equivalent regardless of whether the check fired on a command's own event, an asynchronously-observed event, or the `at: :teardown` settled checkpoint

#### Scenario: Different variant or kind rejected (DR-045)
- **WHEN** a candidate shrunk sequence fails in a variant other than the original's, or with a failure kind other than the original's
- **THEN** the candidate SHALL be rejected, even if the check name is equal

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

The failure signature SHALL be a tuple `{kind, name, variant_index}`, returned by `Shrinker.failure_signature/2`, where kind identifies the category of failure, name is `Failure.name/1` (the specific check for a check failure, the `@compare` key `{projection, function}` for a divergence or a failure to converge, nil for other failures) and variant_index is the index of the target that failed. A signature rebuilt into a failure (`Failure.from_signature/2`) SHALL yield the same signature. `Shrinker.equivalent_failures?/2` SHALL compare `{reason, variant_index}` pairs.

#### Scenario: Check failure signature
- **WHEN** a failure is caused by a check violation
- **THEN** the signature SHALL contain the failure kind, the check name and the variant index

#### Scenario: Non-check failure signature
- **WHEN** a failure is caused by a non-check condition other than a divergence (e.g., adapter error, linearization failure)
- **THEN** the signature SHALL contain the failure kind, nil for the check name and the variant index

#### Scenario: Divergence signature names the observation
- **WHEN** a failure is a divergence
- **THEN** the signature SHALL contain `:diverged`, the `@compare` key `{projection, function}` and the variant index (DR-046)
- **AND** the `ComparisonMismatch` SHALL be detail and SHALL NOT be part of the signature

#### Scenario: A failure to converge has a signature
- **WHEN** a failure is a side still pending at the convergence bound
- **THEN** the signature SHALL contain `:did_not_converge`, the `@compare` key and the variant index
- **AND** `Failure.from_signature/2` SHALL rebuild a failure with the same signature

#### Scenario: Check failure signature includes the check name
- **WHEN** a failure is a named check failure (`@check` / `@check at:` check)
- **THEN** the signature SHALL record the check name, so failures of distinct checks are not treated as equivalent (DR-025)

#### Scenario: Asynchronously-observed check failure carries a location
- **WHEN** an `@check every:` check fails on an asynchronously-observed event
- **THEN** the failure SHALL carry the observing event's `command_index` as `failed_at_index`, so the shrinker's truncation can target it (the truncation is still verified to reproduce the failure before being accepted)

### Requirement: Variant-Aware Shrinking (DR-045)

The shrinker SHALL shrink a failure of a run against one or more targets. Every shrink attempt SHALL run the model's setup commands, then the candidate through `PropertyDamage.Scheduler.run/1` with every target, each target set up and torn down for that attempt, with the run's effective seed, `run_number: 0` and a fresh mint epoch. The reference target's sequence SHALL be the shrink target, because every target runs the same roots. A candidate SHALL be accepted only with the same failure signature (`{kind, name, variant_index}`) at the same or an earlier root, by truncation at the failing root. The shrunk sequence SHALL be reproduced once; if it does not reproduce, the report SHALL fall back to the original run. `Shrinker.shrink/2` SHALL take the options `targets:`, `variant_index:`, `concurrency:`, `compare:` (`[converge_within: ms]`) and `check_mode:`. A candidate SHALL be judged by the primary failure of its run alone: `other_failures` SHALL NOT take part in the signature.

#### Scenario: Divergence is shrunk
- **WHEN** a run fails with kind `:diverged`
- **THEN** the shrinker SHALL remove commands while the same variant still diverges from the reference on the same `@compare` key, at the same or an earlier root
- **AND** every candidate SHALL run in every target

#### Scenario: A failure to converge is shrunk
- **WHEN** a run fails with kind `:did_not_converge`
- **THEN** the shrinker SHALL remove commands while the same variant is still pending on the same key at the bound, at the same or an earlier root
- **AND** every attempt SHALL wait the convergence bound at the failing boundary

#### Scenario: A divergence on another observation is rejected
- **GIVEN** a divergence on observation X in variant 1
- **WHEN** a candidate diverges in variant 1 on observation Y
- **THEN** the shrinker SHALL reject the candidate

#### Scenario: The primary failure is the shrink target
- **GIVEN** a run whose primary failure is in variant 1 and whose `other_failures` hold a failure in variant 2
- **WHEN** a candidate fails in variant 1 with the primary's signature and variant 2 no longer fails
- **THEN** the shrinker SHALL accept the candidate

#### Scenario: Setup failures are not shrunk
- **WHEN** a run fails with kind `:setup_failed`
- **THEN** the framework SHALL report the original sequence without shrinking (DR-048)

#### Scenario: Branching sequences keep the linear engine
- **WHEN** a branching sequence fails (one target only)
- **THEN** its run, shrink and reproduction SHALL use the linear engine

#### Scenario: Re-shrink with several targets
- **WHEN** `shrink_further/2` is called
- **THEN** it SHALL use `report.targets` by default
- **AND** SHALL accept a `targets:` override with one or more entries and the options `concurrency:` and `compare:`
- **AND** SHALL default `compare:` to the report's `compare` and re-shrink a stutter failure with the report's `stutter` configuration
- **AND** SHALL reject `equivalence:` with an error that names `@compare`
- **AND** export file names SHALL hash the signature triple

### Requirement: Invalid Candidates Are Not Counterexamples (DR-045)

Before running a shrink candidate, the shrinker SHALL validate it against the model: fold it through the model's command-sequence projection and simulator and check each command's `when:` predicate. A candidate whose validation returns false or raises SHALL be invalid and SHALL NOT be run or accepted. Shrinking builds sequences the generator never would (an argument halved to 0, a command whose referenced entity's creating command was removed); model code that raises on such a sequence says the model cannot simulate it, not that the system under test is wrong.

#### Scenario: A candidate the model cannot simulate is not a counterexample
- **GIVEN** a model whose projection raises when it folds an event that references an entity the state does not hold
- **WHEN** a shrink candidate keeps a command that references an entity whose creating command was removed
- **THEN** the candidate's validation SHALL raise
- **AND** the shrinker SHALL treat the candidate as invalid and SHALL NOT accept it as a reproduction

### Requirement: Setup and Teardown Commands Under Shrinking (DR-048)

The shrinker SHALL NOT treat a setup or teardown command as a candidate: it SHALL NOT drop, reorder, expand or simplify one. Every attempt SHALL re-execute the report's setup commands before the candidate roots in every target. Every attempt SHALL re-draw the teardown commands against the simulated state after that attempt's last root. Candidate validation SHALL start from the state the setup commands leave, so a candidate is simulated after the setup commands. An attempt in which a setup failed SHALL NOT be a reproduction: the shrinker SHALL reject the candidate, and the attempt SHALL count against the budget.

#### Scenario: Setup commands survive every candidate
- **GIVEN** a failing run with two setup commands and five roots
- **WHEN** the shrinker removes roots
- **THEN** every candidate SHALL run both setup commands, unchanged and in their original order

#### Scenario: Teardown commands follow the candidate
- **GIVEN** a teardown command whose `overrides:` reads an id the last root created
- **WHEN** the shrinker removes the root that created it and a different root becomes last
- **THEN** the attempt SHALL draw the teardown command against the state after the new last root

#### Scenario: A candidate that depends on setup state is valid
- **GIVEN** a root whose `when:` reads a user the setup commands created
- **WHEN** the shrinker validates a candidate that keeps that root
- **THEN** validation SHALL see the user in the state and SHALL accept the candidate

#### Scenario: An attempt whose setup failed is not a reproduction
- **GIVEN** a shrink attempt in which a setup command answers `{:error, _}`
- **WHEN** the attempt ends
- **THEN** the shrinker SHALL reject the candidate even if the original failure was also a setup failure
- **AND** the attempt SHALL count against `max_shrink_attempts`

### Requirement: Expansions Under Shrinking (DR-049)

For a model with `expansions/0`, a shrink candidate SHALL be a list of roots. The shrinker SHALL delete roots and SHALL simplify root arguments, and SHALL NOT delete, reorder or simplify a leaf on its own, and SHALL NOT replace the entry a target ran at a root. A failing run SHALL carry, per target name, the choice at every root: the entry key, the leaf sequence, the aliases and the leaf pick seed. Roots SHALL carry a stable id, their index at generation. Every candidate SHALL realize each target's choices again for the surviving roots, against the candidate's simulated state, without picking again: the surviving root keeps its entry and leaf seed, `overrides:` functions of arity 1 and 2 are evaluated again, and the aliases are rebuilt. A simplified root SHALL go through the same entry and leaf seed. A `:reference` target SHALL copy the reference's candidate sequence. The failure signature SHALL stay `{kind, name, variant_index}` with the root index as the index.

A candidate in which a leaf of a carried entry fails its precondition SHALL run that root as itself in that target and SHALL count it as "identity, forced". A candidate whose expansion function raises, or no longer returns the carried entry for a simplified root, SHALL be invalid: the shrinker SHALL NOT run it and SHALL NOT accept it.

#### Scenario: A surviving root keeps its entry
- **GIVEN** a failing run in which target "second" ran `Pay[1] = [Authorize, Capture]` at root 3
- **WHEN** the shrinker deletes root 0
- **THEN** the candidate SHALL run the same entry for that root in "second", with the same leaf seed, at the root's new index
- **AND** the reproduction's report SHALL name `Pay[1]` for "second" at the failing root

#### Scenario: A candidate never picks again
- **WHEN** the shrinker runs a candidate
- **THEN** the framework SHALL NOT pick an entry for any root of any target

#### Scenario: Argument simplification re-realizes the leaves
- **GIVEN** a root `Incr k 5` that ran as `Incr[1]`
- **WHEN** the shrinker simplifies the amount to 3
- **THEN** the leaves SHALL come from `Incr k 3` through entry index 1 and the same leaf seed

#### Scenario: A failing leaf precondition forces the identity
- **WHEN** a candidate state makes a leaf's `when:` false in a carried entry
- **THEN** that root SHALL run as itself in that target
- **AND** the report's `expansion_counts` SHALL count it as `:forced`

#### Scenario: A vanished entry invalidates the candidate
- **GIVEN** an expansion function that offers entry 1 only for `amount >= 2`
- **WHEN** the shrinker simplifies a root that ran entry 1 to `amount: 1`
- **THEN** the candidate SHALL be invalid and SHALL NOT run

#### Scenario: A raise invalidates the candidate
- **WHEN** an expansion function raises for a simplified root during shrinking
- **THEN** the candidate SHALL be invalid, the shrink SHALL go on, and `PropertyDamage.run/1` SHALL return the failure report

#### Scenario: Re-shrinking carries the recorded choices
- **WHEN** `shrink_further/2` re-shrinks a saved report
- **THEN** it SHALL carry the choices the report recorded for every target
- **AND** it SHALL raise an error that names the target when the report records no choices for it

