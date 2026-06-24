# Projection Specification

## Purpose

Projections are the state management and invariant verification mechanism for stateful property-based tests. They serve a dual purpose: reducing commands and events into tracked state, and defining assertions that verify invariants hold throughout test execution. A single behaviour supports both roles, from state-only projections that drive command generation to assertion-only projections that validate system correctness.

Reference Decision Records: DR-004 (Unified Projection Type), DR-005 (Projection Naming), DR-009 (Projections See Commands and Events), DR-012 (Trigger-Based Assertions), DR-014 (Assertion Modes), DR-024 (Lifecycle-Boundary Assertions), DR-025 (Continuous Async-Observation Checking), DR-026 (Invariant Catalog and Anti-Vacuity Coverage)

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

A `@trigger every:` assertion fires on **every observed event** regardless of how the event reached the run, not only on a command's own returned events (DR-025). An event observed asynchronously — a resource-poller or injector-adapter event, a mock-service event, or a nemesis event — is matched by `every:` exactly as a command's own event is, on its `step_type` (`:event`) and module. The `every: :command` form is the opt-out for assertions that should fire only after commands.

#### Scenario: Trigger every step
- **WHEN** an assertion is decorated with `@trigger every: 1`
- **THEN** it runs after every command and event processing step

#### Scenario: Trigger every command
- **WHEN** an assertion is decorated with `@trigger every: :command`
- **THEN** it runs after any command is processed but not after events

#### Scenario: Trigger every event
- **WHEN** an assertion is decorated with `@trigger every: :event`
- **THEN** it runs after any event is processed but not after commands
- **AND** "any event" includes asynchronously-observed events (resource-poller, injector-adapter, mock-service, and nemesis events), not only a command's own returned events

#### Scenario: Trigger fires on an asynchronously-observed event
- **WHEN** a projection declares `@trigger every: :event` (or `every: 1`, or `every: SomeEvent`)
- **AND** an event matching the trigger is observed asynchronously (for example injected by a resource poller, an injector adapter, a mock service, or a nemesis)
- **THEN** the assertion SHALL be evaluated on the projection state after that event is folded in

#### Scenario: every: :command does not fire on events
- **WHEN** a projection declares `@trigger every: :command`
- **THEN** the assertion SHALL NOT be evaluated on any event, whether a command's own returned event or an asynchronously-observed one

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

#### Scenario: Non-positive sampling count is rejected
- **WHEN** an assertion is decorated with a sampling count of zero or negative (e.g. `@trigger every: {0, :command}` or `@trigger every: 0`)
- **THEN** the framework raises an ArgumentError at compile time rather than allowing a runtime ArithmeticError

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
- **AND** supported units are `:millisecond(s)`, `:second(s)`, and `:minute(s)` (singular and plural forms are both accepted)
- **AND** an unrecognized unit raises an ArgumentError

### Requirement: Lifecycle-Boundary Assertions via @trigger at:

Projections SHALL support synchronous assertions whose timing is a lifecycle phase boundary, declared with the `at:` option on `@trigger`. Where `every:` samples an assertion during the command loop, `at:` fires it exactly once at a phase boundary. Supported phases are `:startup` (the initial `init/0` state, after `setup/1` and before the first command) and `:teardown` (the fully-settled final state, after all pollers have finalized and before `teardown/1`). Lifecycle-boundary assertions take the same two arguments as other synchronous assertions; because no command or event triggers them, the second argument is the phase atom.

#### Scenario: Trigger at teardown evaluates the settled final state
- **WHEN** an assertion is decorated with `@trigger at: :teardown`
- **THEN** it runs exactly once, on the merged final projection state after every observed event has been folded in
- **AND** the second argument passed to the assertion is `:teardown`

#### Scenario: Trigger at startup evaluates the initial state
- **WHEN** an assertion is decorated with `@trigger at: :startup`
- **THEN** it runs exactly once, on the initial `init/0` projection state before any command is processed
- **AND** the second argument passed to the assertion is `:startup`

#### Scenario: A safety bound is expressed as an at: :teardown assertion
- **WHEN** a projection accumulates evidence of a safety property (for example a maximum observed value or a sticky violation flag)
- **AND** an assertion decorated with `@trigger at: :teardown` checks that property
- **THEN** a violation that persists to the settled state is detected and reported as that named assertion failure

#### Scenario: Unrecognized at: phase is rejected
- **WHEN** an assertion is decorated with `@trigger at:` and a phase other than `:startup` or `:teardown`
- **THEN** the framework raises an ArgumentError at compile time

#### Scenario: Lifecycle-boundary assertion metadata
- **WHEN** a lifecycle-boundary assertion is detected
- **THEN** its metadata includes the assertion name, type `:synchronous`, function name, and the normalized trigger spec recording the `at:` phase
- **AND** the metadata shape is consistent with other synchronous assertions (the `assert_` prefix is stripped from `name`)

### Requirement: Assertion Detection and Metadata

The framework SHALL detect assertions at compile time using an `@on_definition` hook. Assertion metadata SHALL be stored and accessible via the `__assertions__/0` function on the projection module.

#### Scenario: Assertions discovered at compile time
- **WHEN** a projection module is compiled
- **THEN** all functions preceded by `@trigger` or `@poll_state` are recorded as assertions
- **AND** their metadata is stored in the module's `__assertions__/0` function

#### Scenario: Synchronous assertion metadata
- **WHEN** a synchronous assertion is detected
- **THEN** its metadata includes the assertion name, type `:synchronous`, normalized trigger spec, function name, and the `invariant_id` it validates (DR-026)

#### Scenario: Polling assertion metadata
- **WHEN** a polling assertion is detected
- **THEN** its metadata includes the assertion name, type `:polling`, the function name, normalized poll_state spec, captured predicate source, and the `invariant_id` it validates (DR-026)
- **AND** the metadata shape is consistent with synchronous assertions (both carry `name`, `type`, `function_name`, and `invariant_id`, with the `assert_` prefix stripped from `name`)

#### Scenario: Default invariant id (DR-026)
- **WHEN** an assertion is decorated with neither `validates:` nor an inline `id:`
- **THEN** its `invariant_id` SHALL default to the assertion's `assert_`-stripped logical name, so every assertion validates a same-named invariant by default

#### Scenario: At most one trigger attribute per assertion
- **WHEN** an assertion function is decorated with more than one `@trigger` (or more than one `@poll_state`), or with both `@trigger` and `@poll_state`
- **THEN** the compiler raises a CompileError rather than silently using one of them

#### Scenario: At most one timing per @trigger assertion
- **WHEN** a single `@trigger` declares both a `during-run` timing (`every:`) and a `lifecycle-boundary` timing (`at:`)
- **THEN** the compiler raises a CompileError, because an assertion SHALL carry exactly one timing

### Requirement: Invariant Declaration and Linking via @invariant and validates: (DR-026)

An assertion validates a named **invariant** — a first-class entity with a stable `id`, a human-readable `name` defaulting to `id`, and an optional `description`, represented by `%PropertyDamage.Invariants.Invariant{}` and built by `Invariant.new!/1`. A projection MAY declare invariants centrally with an accumulating `@invariant` module attribute whose value is the `new!/1` keyword list, and an assertion links to one with `validates: :id` on `@trigger`/`@poll_state` or declares one inline with `id:` (plus optional `description:`). Invariant identity is scoped per projection: `id`s SHALL be unique within a projection and `validates:` SHALL resolve within the same projection. Invariant metadata SHALL be accessible via `__invariants__/0` returning a map of `id` to `%Invariant{}`. There is no `:kind` field on the struct; safety-versus-liveness is a property of a check, surfaced in the catalog.

#### Scenario: Central declaration
- **WHEN** a projection declares `@invariant id: :balance_nonneg, description: "Balance never drops below zero"`
- **THEN** `__invariants__/0` includes `%Invariant{id: :balance_nonneg, name: :balance_nonneg, description: "Balance never drops below zero"}`
- **AND** the `name` defaults to the `id` when not given

#### Scenario: Linking a check to an invariant
- **WHEN** an assertion is decorated with `@trigger every: 5, validates: :balance_nonneg`
- **THEN** its metadata records `invariant_id: :balance_nonneg`
- **AND** the invariant is exercised by that assertion

#### Scenario: Inline declaration and check in one
- **WHEN** an assertion is decorated with `@trigger every: 5, id: :balance_nonneg, description: "…"`
- **THEN** the invariant `:balance_nonneg` is declared and that assertion is registered as a check of it

#### Scenario: Duplicate invariant id is rejected
- **WHEN** an `id` is declared more than once (across `@invariant` and inline `id:`, including byte-identical redeclaration)
- **THEN** the compiler raises a CompileError

#### Scenario: Dangling validates: is rejected
- **WHEN** an assertion declares `validates: :typo` referencing an `id` no invariant declares in that projection
- **THEN** the compiler raises a CompileError identifying the unresolved reference
- **AND** this check is a pure compile-time set-membership test, independent of any description resolver

#### Scenario: Declared-but-unchecked invariant warns (static vacuity)
- **WHEN** an invariant is declared with no assertion validating it
- **THEN** the compiler emits a warning, and `mix pd.validate` reports it as static vacuity

#### Scenario: Invariant well-formedness
- **WHEN** `@invariant` omits `:id`, or `description` is not a binary
- **THEN** `Invariant.new!/1` raises, surfaced as a CompileError

#### Scenario: Description lookup is lazy and fallback-tolerant
- **WHEN** `Invariant.fetch!(id, ctx)` resolves an invariant for reporting
- **THEN** it returns the local `%Invariant{}`, raising only on an unknown `id`
- **AND** a configured description resolver MAY override only the `description`, best-effort with fallback to the local description, at report time only

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
