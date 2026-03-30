# Projection Specification

## Purpose

Projections are the state management and invariant verification mechanism for stateful property-based tests. They serve a dual purpose: reducing commands and events into tracked state, and defining assertions that verify invariants hold throughout test execution. A single behaviour supports both roles, from state-only projections that drive command generation to assertion-only projections that validate system correctness.

Reference Decision Records: DR-004 (Unified Projection Type), DR-005 (Projection Naming), DR-009 (Projections See Commands and Events), DR-012 (Trigger-Based Assertions), DR-014 (Assertion Modes)

## Requirements

### Requirement: State Tracking Callbacks

Projections SHALL define an `init/0` callback that returns the initial state and an `apply/2` callback that reduces commands and events into updated state. Both callbacks are optional and have sensible defaults.

#### Scenario: Custom init returns initial state
- **WHEN** a projection implements `init/0`
- **THEN** it is called once at the start of each test run
- **AND** the returned value becomes the initial projection state

#### Scenario: Default init returns empty map
- **WHEN** a projection does not implement `init/0`
- **THEN** the framework provides a default that returns `%{}`

#### Scenario: Apply reduces state
- **WHEN** a projection implements `apply/2`
- **AND** a command or event is processed
- **THEN** `apply/2` is called with the current state and the command or event struct
- **AND** the returned value becomes the new projection state

#### Scenario: Default apply returns state unchanged
- **WHEN** a projection does not implement `apply/2`
- **THEN** the framework provides a default that returns the state unchanged

#### Scenario: Apply can raise for transition invariants
- **WHEN** `apply/2` detects an invalid state transition
- **THEN** it MAY raise an exception to signal the violation

### Requirement: Projections See Both Commands and Events

Projections SHALL receive both commands and events through their `apply/2` callback. This is a deliberate deviation from pure event sourcing that enables richer invariant checking.

#### Scenario: Apply receives commands
- **WHEN** a command is executed
- **THEN** the projection's `apply/2` is called with the command struct

#### Scenario: Apply receives events
- **WHEN** events are produced from command execution
- **THEN** the projection's `apply/2` is called with each event struct

### Requirement: Synchronous Assertions via @trigger

Projections SHALL support synchronous assertions decorated with the `@trigger` module attribute. Triggered assertions run immediately when their condition is met. Assertion functions take two arguments: the current projection state and the command or event that triggered the assertion.

#### Scenario: Trigger every step
- **WHEN** an assertion is decorated with `@trigger every: 1`
- **THEN** it runs after every command and event processing step

#### Scenario: Trigger every command
- **WHEN** an assertion is decorated with `@trigger every: :command`
- **THEN** it runs after any command is processed but not after events

#### Scenario: Trigger every event
- **WHEN** an assertion is decorated with `@trigger every: :event`
- **THEN** it runs after any event is processed but not after commands

#### Scenario: Trigger on specific module
- **WHEN** an assertion is decorated with `@trigger every: CreateOrder`
- **THEN** it runs only when a `CreateOrder` command or event is processed

#### Scenario: Trigger on module list
- **WHEN** an assertion is decorated with `@trigger every: [Cmd1, Cmd2]`
- **THEN** it runs when any of the listed command or event modules is processed

#### Scenario: Trigger every Nth step (sampling)
- **WHEN** an assertion is decorated with `@trigger every: 10`
- **THEN** it runs on every 10th processing step

#### Scenario: Trigger every Nth command
- **WHEN** an assertion is decorated with `@trigger every: {5, :command}`
- **THEN** it runs on every 5th command

#### Scenario: Trigger every Nth of specific module
- **WHEN** an assertion is decorated with `@trigger every: {3, CreateOrder}`
- **THEN** it runs on every 3rd occurrence of `CreateOrder`

#### Scenario: Assertion passes by returning without raising
- **WHEN** a triggered assertion function returns without raising an exception
- **THEN** the assertion is considered to have passed

#### Scenario: Assertion fails by raising
- **WHEN** a triggered assertion function raises an exception
- **THEN** the assertion is considered to have failed

### Requirement: Temporal Assertions via @poll_state

Projections SHALL support temporal assertions decorated with the `@poll_state` module attribute. These spawn background pollers when a trigger event occurs, periodically checking if a predicate becomes true within a timeout. The decorated function SHALL return a predicate function `(state -> boolean)`.

#### Scenario: Poll state spawns poller on matching event
- **WHEN** an assertion is decorated with `@poll_state after: PaymentInitiated, timeout: 5, interval: {100, :milliseconds}`
- **AND** a `PaymentInitiated` event is processed
- **THEN** the framework spawns a background poller

#### Scenario: Poll state predicate is checked periodically
- **WHEN** a poller is spawned
- **THEN** the predicate function returned by the assertion is evaluated at the configured interval
- **AND** polling continues until the predicate returns true or the timeout expires

#### Scenario: Poll state supports multiple trigger events
- **WHEN** an assertion is decorated with `@poll_state after: [EventA, EventB], ...`
- **THEN** the poller spawns when either `EventA` or `EventB` is processed

#### Scenario: Time values default to seconds
- **WHEN** a `@poll_state` timeout or interval is specified as a bare integer
- **THEN** the value is interpreted as seconds

#### Scenario: Time values support explicit units
- **WHEN** a `@poll_state` timeout or interval is specified as `{value, :milliseconds}`
- **THEN** the value is interpreted in the given unit
- **AND** supported units are `:milliseconds`, `:seconds`, and `:minutes`

### Requirement: Assertion Detection and Metadata

The framework SHALL detect assertions at compile time using an `@on_definition` hook. Assertion metadata SHALL be stored and accessible via the `__assertions__/0` function on the projection module.

#### Scenario: Assertions discovered at compile time
- **WHEN** a projection module is compiled
- **THEN** all functions preceded by `@trigger` or `@poll_state` are recorded as assertions
- **AND** their metadata is stored in the module's `__assertions__/0` function

#### Scenario: Synchronous assertion metadata
- **WHEN** a synchronous assertion is detected
- **THEN** its metadata includes the assertion name, type `:synchronous`, normalized trigger spec, and function name

#### Scenario: Polling assertion metadata
- **WHEN** a polling assertion is detected
- **THEN** its metadata includes the assertion name, type `:polling`, normalized poll_state spec, and captured predicate source

### Requirement: assert_* Prefix Convention and Enforcement

Functions with an `assert_` prefix are conventionally used for assertions but the prefix is not required. However, a function named `assert_*` that takes two arguments and lacks a `@trigger` or `@poll_state` attribute SHALL raise a CompileError.

#### Scenario: assert_* without attribute raises CompileError
- **WHEN** a two-argument function named `assert_something` is defined
- **AND** it is not preceded by a `@trigger` or `@poll_state` attribute
- **THEN** the compiler raises a CompileError indicating the missing attribute

#### Scenario: Non-assert_* name with trigger works
- **WHEN** a function with a non-`assert_` name (e.g., `check_balance`) is preceded by `@trigger`
- **THEN** it is registered as a valid assertion without error

#### Scenario: assert_* with trigger works
- **WHEN** a function named `assert_balance_positive` is preceded by `@trigger`
- **THEN** it is registered as a valid assertion without error

### Requirement: Simplified Assertion-Only Projections

Projections MAY omit `init/0` and `apply/2` to serve purely as assertion containers. The framework SHALL provide default implementations that initialize to an empty map and return state unchanged.

#### Scenario: Assertion-only projection
- **WHEN** a projection defines only `@trigger`-decorated assertion functions
- **AND** does not implement `init/0` or `apply/2`
- **THEN** the projection compiles successfully with default implementations
- **AND** assertions receive an empty map as state and the triggering command or event

### Requirement: Dual Projection Roles

Projections SHALL serve two distinct roles in models. The command sequence projection (returned by `command_sequence_projection/0`) drives command generation by maintaining state for precondition evaluation and generator parameterization. Assertion projections (returned by `assertion_projections/0`) verify invariants during execution.

#### Scenario: Command sequence projection drives generation
- **WHEN** a projection is designated as the command sequence projection
- **THEN** its state is passed to `when:` predicates for command filtering
- **AND** its state is passed to `with:` functions for generator overrides
- **AND** its state is passed to the simulator for event prediction

#### Scenario: Assertion projections verify invariants
- **WHEN** projections are listed in `assertion_projections/0`
- **THEN** they receive commands and events during execution
- **AND** their assertions fire according to their trigger configurations

#### Scenario: Same behaviour for both roles
- **WHEN** a projection module is used as either a command sequence projection or an assertion projection
- **THEN** it uses the same `PropertyDamage.Model.Projection` behaviour for both roles

### Requirement: Use Macro Infrastructure

The `use PropertyDamage.Model.Projection` macro SHALL set up the assertion detection infrastructure including the `@behaviour` declaration, accumulating `@assertions` attribute, `@trigger` and `@poll_state` attribute registration, the `@on_definition` hook, and the `@before_compile` hook.

#### Scenario: Use macro sets up behaviour
- **WHEN** a module invokes `use PropertyDamage.Model.Projection`
- **THEN** the module declares `@behaviour PropertyDamage.Model.Projection`
- **AND** assertion detection hooks are registered
- **AND** the `__assertions__/0` function is generated at compile time
