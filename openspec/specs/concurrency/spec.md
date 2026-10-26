# Concurrency Specification

## Purpose

Defines the branching execution model for command sequences with branches, linearization checking for consistency verification, and stutter/idempotency testing. Branches execute one after another, so the branching path checks the SUT's observed events against the model under reordering and detects no race (DR-053); stutter testing verifies idempotent behavior in the SUT.

## Requirements

### Requirement: Branching Sequences

The system SHALL support branching command sequences consisting of a linear prefix, two or more branches, and an optional linear suffix. The prefix executes first, the branches execute one after another, and the suffix executes after all branches complete.

#### Scenario: Prefix then branches then suffix
- **WHEN** a branching sequence is executed
- **THEN** the prefix commands SHALL execute sequentially first
- **AND** the branches SHALL execute one after another after the prefix completes
- **AND** the suffix commands SHALL execute sequentially after all branches complete

#### Scenario: State forked at branch point
- **WHEN** execution transitions from prefix to branches
- **THEN** the projection state SHALL be forked at the branch point
- **AND** each branch SHALL start from the same forked state

### Requirement: Branch Execution (DR-053)

Branches in a branching sequence SHALL execute one after another on the one adapter context, each from the forked post-prefix model state, with the order inside each branch preserved. The linearization checker SHALL judge the branch commands against the simulator's predictions over the interleavings that preserve that order. No two commands overlap at the SUT, so the branching path SHALL NOT be described as detecting races.

#### Scenario: Intra-branch ordering preserved
- **WHEN** a branch contains commands [A, B, C]
- **THEN** command A SHALL complete before B begins
- **AND** command B SHALL complete before C begins

#### Scenario: Branches do not overlap
- **WHEN** two branches execute
- **THEN** no command of the second branch SHALL begin before every command of the first has completed
- **AND** the checker MAY explain the observed events by any interleaving that preserves the order inside each branch

### Requirement: Linearization Checking

After the branches have executed, the system SHALL verify that the observed results can be explained by some valid sequential ordering of all branch commands. This verification SHALL preserve happens-before ordering within each branch.

#### Scenario: Valid linearization found
- **WHEN** branch execution completes
- **AND** there exists a sequential ordering that preserves intra-branch order and produces the observed final state
- **THEN** the system SHALL accept the execution as linearizable
- **AND** the valid ordering SHALL be recorded in the result

#### Scenario: No valid linearization exists
- **WHEN** branch execution completes
- **AND** no sequential ordering of the commands can produce the observed final state while preserving intra-branch order
- **THEN** the system SHALL report a linearization failure indicating that no ordering explains the observed events against the simulator

#### Scenario: Happens-before preserved
- **WHEN** the system generates candidate linearizations
- **THEN** each candidate SHALL respect the happens-before relationship within every branch
- **AND** candidates that violate intra-branch ordering SHALL NOT be considered

### Requirement: Stutter/Idempotency Testing

The system SHALL support probabilistic command retries to verify that the SUT behaves idempotently. When enabled, selected commands are executed multiple times and retry results are compared to the initial execution.

#### Scenario: Command selected for stuttering
- **WHEN** stutter testing is enabled with a configured probability
- **AND** a command is probabilistically selected for stuttering
- **THEN** the command SHALL be executed once normally
- **AND** then retried up to `max_repeats` additional times

#### Scenario: Retry events not applied to projections
- **WHEN** a stuttered command is retried
- **THEN** events from the initial execution SHALL be applied to projections
- **AND** events from retry executions SHALL be captured but NOT applied to projections

#### Scenario: Idempotency eligibility from command spec
- **WHEN** a command declares `idempotent: false` in its `command_spec/1` (DR-028)
- **THEN** the command SHALL be excluded from stutter selection
- **AND** a command that declares no `:idempotent` value defaults to eligible (`true`)

### Requirement: Stutter Configuration

Stutter testing SHALL be configurable with probability, max_repeats, delay_ms (range or fixed), a commands filter, and a `using:` relation.

#### Scenario: Configuration with defaults
- **WHEN** stutter testing is enabled without custom options
- **THEN** the default probability SHALL be 0.1 (10%)
- **AND** the default max_repeats SHALL be 2
- **AND** the default delay SHALL be a random value between 0 and 100ms
- **AND** the default commands filter SHALL be `:all`
- **AND** the default `using:` relation SHALL be equality, `{Kernel, :==}`

#### Scenario: Commands filter limits scope
- **WHEN** stutter is configured with a specific list of command modules
- **THEN** only those command types SHALL be eligible for stuttering
- **AND** all other commands SHALL execute normally without retries

### Requirement: Stutter Comparison Through `using:` (DR-046)

The system SHALL compare a retry's events with the original events through the `using:` option of `stutter:`, which SHALL accept the named forms of `@compare`'s `using:` beside a 2-arity function, since a run option is runtime data (DR-051 item 6): `{Mod, :fun}` calls `Mod.fun(original_events, retry_events)`, `{Mod, :fun, args}` calls `Mod.fun(original_events, retry_events, arg1, ..., argN)`, and a function is called `using.(original_events, retry_events)`. The relation's return is a verdict (DR-052), truthy to agree, and `false`, `nil`, `{:fail, text}` or `{:fail, exception}` otherwise; equality by default. A named function the module does not export, a function value inside `args`, and any other value MUST be rejected with an option error that names `using:`, and the error and the documentation SHALL teach the named form first. The `comparison:` option, with its `:strict`, `{:structural, _}`, `{:custom, _}` and `:acceptable` values, MUST be rejected with an error that names `using:`.

#### Scenario: Default comparison
- **WHEN** `stutter:` has no `using:`
- **THEN** retry events MUST equal the initial events under `==/2` for the result to be a match

#### Scenario: A named relation decides (DR-051)
- **WHEN** `using:` is `{Mod, :fun}` or `{Mod, :fun, args}`
- **THEN** `Mod.fun` SHALL be called with the original and the retry events, then the args
- **AND** its answer SHALL determine match or mismatch

#### Scenario: A named relation that does not exist is rejected (DR-051)
- **WHEN** `using:` is `{Mod, :fun}` and `Mod` does not export `fun/2`
- **THEN** the framework SHALL raise an option error that names `using:` and `fun/2`, before any adapter setup

#### Scenario: A function decides
- **WHEN** `using:` is a 2-arity function
- **THEN** it SHALL be called with the original and the retry events
- **AND** its answer SHALL determine match or mismatch

#### Scenario: A relation accepts an alternative answer
- **GIVEN** a relation that returns `true` when the retry answers `AlreadyExists`
- **WHEN** a retried command answers `AlreadyExists`
- **THEN** the retry SHALL NOT be an idempotency violation

#### Scenario: A removed key is rejected
- **WHEN** `stutter:` carries `comparison:`
- **THEN** the framework SHALL raise an option error that names `using:`

### Requirement: Stutter Violation Reporting

When retry events do not match the initial execution according to the `using:` relation, the system SHALL record an idempotency violation with all attempt details and the mismatch (an exception, by default a `PropertyDamage.ComparisonMismatch` holding the original and the retry events).

#### Scenario: Violation recorded
- **WHEN** a stuttered command's retry produces different events than the initial execution
- **THEN** the system SHALL record a violation containing the command, command index, all attempts with their events, and the mismatch

### Requirement: Command Opt-Out from Stuttering

Commands MAY opt out of stutter testing by declaring themselves as non-idempotent.

#### Scenario: Non-idempotent command skipped
- **WHEN** a command's module returns `false` from its idempotency declaration
- **THEN** that command SHALL NOT be selected for stutter testing regardless of probability

### Requirement: Stutter Context in Adapter

During retry executions, the adapter SHALL receive stutter context containing the attempt number, a retry flag, and the idempotency key (if provided by the command).

#### Scenario: Adapter receives retry context
- **WHEN** a command is retried as part of stutter testing
- **THEN** the adapter context SHALL include a stutter map with `attempt` (2 or higher), `is_retry: true`, and the `idempotency_key`
- **AND** the adapter MAY use the idempotency key in outbound request headers

### Requirement: Acceptable Retry Events Are Removed (DR-046)

The command key `acceptable_retry_events:` SHALL NOT exist. A command that may answer a retry differently from the original SHALL be handled by the `using:` relation of the `stutter:` option.

#### Scenario: The key is rejected
- **WHEN** a command passes `acceptable_retry_events:` to `use PropertyDamage.Command`
- **THEN** compilation or model validation SHALL fail with an error that names `using:`
