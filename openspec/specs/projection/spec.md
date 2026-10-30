# Projection Specification

## Purpose

Projections are the state management and invariant verification mechanism for stateful property-based tests. They serve a dual purpose: reducing commands and events into tracked state, and defining checks that verify invariants hold throughout test execution. A single behaviour supports both roles, from state-only projections that drive command generation to check-only projections that validate system correctness.

Reference Decision Records: DR-004 (Unified Projection Type), DR-005 (Projection Naming), DR-009 (Projections See Commands and Events), DR-012 (Trigger-Based Assertions), DR-014 (Assertion Modes), DR-024 (Lifecycle-Boundary Assertions), DR-025 (Continuous Async-Observation Checking), DR-026 (Invariant Catalog and Anti-Vacuity Coverage), DR-042 (One Engine for Property-Based, Differential and Path-Equivalence Runs), DR-046 (Boundary Observations, the Convergence Loop and Adapter Errors), DR-049 (Expansions, Roots That Run as Several Commands), DR-052 (A Check's Verdict Is Its Return Value)

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

### Requirement: Synchronous Checks via @check

Projections SHALL support synchronous checks decorated with the `@check` module attribute. Triggered checks run immediately when their condition is met. Check functions take two arguments: the current projection state and the command or event that triggered the check.

A `@check every:` check fires on **every observed event** regardless of how the event reached the run, not only on a command's own returned events (DR-025). An event observed asynchronously (a resource-poller or injector-adapter event, a mock-service event, or a nemesis event) is matched by `every:` exactly as a command's own event is, on its `step_type` (`:event`) and module. The `every: :command` form is the opt-out for checks that should fire only after commands.

#### Scenario: Trigger every step
- **WHEN** a check is decorated with `@check every: 1`
- **THEN** it runs after every command and event processing step

#### Scenario: Trigger every command
- **WHEN** a check is decorated with `@check every: :command`
- **THEN** it runs after any command is processed but not after events

#### Scenario: Trigger every event
- **WHEN** a check is decorated with `@check every: :event`
- **THEN** it runs after any event is processed but not after commands
- **AND** "any event" includes asynchronously-observed events (resource-poller, injector-adapter, mock-service, and nemesis events), not only a command's own returned events

#### Scenario: Trigger fires on an asynchronously-observed event
- **WHEN** a projection declares `@check every: :event` (or `every: 1`, or `every: SomeEvent`)
- **AND** an event matching the trigger is observed asynchronously (for example injected by a resource poller, an injector adapter, a mock service, or a nemesis)
- **THEN** the check SHALL be evaluated on the projection state after that event is folded in

#### Scenario: every: :command does not fire on events
- **WHEN** a projection declares `@check every: :command`
- **THEN** the check SHALL NOT be evaluated on any event, whether a command's own returned event or an asynchronously-observed one

#### Scenario: Trigger on specific module
- **WHEN** a check is decorated with `@check every: CreateOrder`
- **THEN** it runs only when a `CreateOrder` command or event is processed

#### Scenario: Trigger on module list
- **WHEN** a check is decorated with `@check every: [Cmd1, Cmd2]`
- **THEN** it runs when any of the listed command or event modules is processed

#### Scenario: Trigger every Nth step (sampling)
- **WHEN** a check is decorated with `@check every: 10`
- **THEN** it runs on every 10th processing step

#### Scenario: Trigger every Nth command
- **WHEN** a check is decorated with `@check every: {5, :command}`
- **THEN** it runs on every 5th command

#### Scenario: Trigger every Nth of specific module
- **WHEN** a check is decorated with `@check every: {3, CreateOrder}`
- **THEN** it runs on every 3rd occurrence of `CreateOrder`

#### Scenario: Non-positive sampling count is rejected
- **WHEN** a check is decorated with a sampling count of zero or negative (e.g. `@check every: {0, :command}` or `@check every: 0`)
- **THEN** the framework raises an ArgumentError at compile time rather than allowing a runtime ArithmeticError

#### Scenario: Check passes by returning a truthy value (DR-052)
- **WHEN** a triggered check function returns a value other than `nil` or `false`
- **THEN** the check SHALL be considered to have passed

#### Scenario: Check fails by returning nil or false (DR-052)
- **GIVEN** a check `net_covers_fees` that returns `nil`
- **WHEN** it is triggered, in the executor, in forensics or in the load-test worker, under `every:` or `at:`
- **THEN** the check SHALL fail as a check failure with the same state snapshot as a raise
- **AND** the failure message SHALL name the check, show the returned value and give the three accepted forms: "check `net_covers_fees` returned `nil`; a check passes by returning a truthy value: a predicate, `condition or fail!(...)`, or a body that ends with `:ok`"

#### Scenario: Check fails with a returned reason (DR-052)
- **WHEN** a triggered check function returns `{:fail, "text"}`
- **THEN** the check SHALL fail with a `PropertyDamage.CheckFailed` carrying that text, the same exception `fail!("text")` raises
- **AND WHEN** it returns `{:fail, exception}`, the check SHALL fail with that exception

#### Scenario: A non-verdict return fails with the grammar nudge (DR-052)
- **WHEN** a triggered check function returns a bare exception struct or an `{:error, _}` tuple
- **THEN** the check SHALL fail carrying the value and the sentence "a verdict is truthy, `nil`/`false`, or `{:fail, reason}`"

#### Scenario: Check fails by raising
- **WHEN** a triggered check function raises an exception
- **THEN** the check is considered to have failed

#### Scenario: A check ending in if without else is a compile error (DR-052)
- **GIVEN** a `@check` clause, first or later, whose last expression is an `if` or `unless` without `else`
- **WHEN** the projection compiles
- **THEN** compilation SHALL fail with a CompileError naming the clause and the rewrite: "`net_covers_fees/2` ends in `if` without `else`, which returns `nil` when the check passes; write `condition or fail!(...)`"
- **AND** an `if` with `else`, or an `if` that is not the last expression, SHALL compile

### Requirement: Temporal Checks via @eventually

Projections SHALL support temporal checks decorated with the `@eventually` module attribute. These spawn background pollers when a trigger event occurs, periodically checking if a predicate becomes true within a timeout. The decorated function SHALL return a 1-arity predicate function over the projection state, whose return is a verdict read with the grammar of `@check` (DR-052; see the eventual-consistency specification).

#### Scenario: Poll state spawns poller on matching event
- **WHEN** a check is decorated with `@eventually after: PaymentInitiated, timeout: 5, interval: {100, :milliseconds}`
- **AND** a `PaymentInitiated` event is processed
- **THEN** the framework spawns a background poller

#### Scenario: Poll state predicate is checked periodically
- **WHEN** a poller is spawned
- **THEN** the predicate function returned by the check is evaluated at the configured interval
- **AND** polling continues until the predicate returns a truthy value, returns `{:fail, reason}`, raises, or the timeout expires

#### Scenario: Eventually checks support multiple trigger events
- **WHEN** a check is decorated with `@eventually after: [EventA, EventB], ...`
- **THEN** the poller spawns when either `EventA` or `EventB` is processed

#### Scenario: Time values default to seconds
- **WHEN** a `@eventually` timeout or interval is specified as a bare integer
- **THEN** the value is interpreted as seconds

#### Scenario: Time values support explicit units
- **WHEN** a `@eventually` timeout or interval is specified as `{value, :milliseconds}`
- **THEN** the value is interpreted in the given unit
- **AND** supported units are `:millisecond(s)`, `:second(s)`, and `:minute(s)` (singular and plural forms are both accepted)
- **AND** an unrecognized unit raises an ArgumentError

### Requirement: Lifecycle-Boundary Checks via @check at:

Projections SHALL support synchronous checks whose timing is a lifecycle phase boundary, declared with the `at:` option on `@check`. Where `every:` samples a check during the command loop, `at:` fires it exactly once at a phase boundary. Supported phases are `:startup` (the initial `init/0` state, after `setup/1` and before the first command) and `:teardown` (the fully-settled final state, after all pollers have finalized and before `teardown/1`). Lifecycle-boundary checks take the same two arguments as other synchronous checks; because no command or event triggers them, the second argument is the phase atom.

#### Scenario: Trigger at teardown evaluates the settled final state
- **WHEN** a check is decorated with `@check at: :teardown`
- **THEN** it runs exactly once, on the merged final projection state after every observed event has been folded in
- **AND** the second argument passed to the check is `:teardown`

#### Scenario: Trigger at startup evaluates the initial state
- **WHEN** a check is decorated with `@check at: :startup`
- **THEN** it runs exactly once, on the initial `init/0` projection state before any command is processed
- **AND** the second argument passed to the check is `:startup`

#### Scenario: A safety bound is expressed as an at: :teardown check
- **WHEN** a projection accumulates evidence of a safety property (for example a maximum observed value or a sticky violation flag)
- **AND** a check decorated with `@check at: :teardown` checks that property
- **THEN** a violation that persists to the settled state is detected and reported as that named check failure

#### Scenario: Unrecognized at: phase is rejected
- **WHEN** a check is decorated with `@check at:` and a phase other than `:startup` or `:teardown`
- **THEN** the framework raises an ArgumentError at compile time

#### Scenario: Lifecycle-boundary check metadata
- **WHEN** a lifecycle-boundary check is detected
- **THEN** its metadata includes the check name, type `:synchronous`, function name, and the normalized trigger spec recording the `at:` phase
- **AND** the metadata shape is consistent with other synchronous checks (the `assert_` prefix is stripped from `name`)

### Requirement: Boundary Observations via @compare (DR-046)

Projections SHALL support boundary observations: public functions `def name(state, root)` decorated with `@compare`. A run with two or more targets compares its targets only through these functions. Each target evaluates the function on its own projection state with the root command as the second argument, and the value of every non-reference target is judged against the reference's. The observation's key is `{projection, name}`.

`@compare` takes two options. `every:` is the schedule: `1` (default, every boundary), `N` (every Nth boundary), `{N, Module}` (every Nth root of that module), `Module` or `[Modules]` (after those roots) and `:end` or `[Modules, :end]` (the final boundary, compared after every target finalized its run). A key SHALL be compared at most once per boundary. A function SHALL carry one `@compare`, written above its first clause.

`@compare` SHALL be a plain module attribute, read at `@on_definition` as `@check` and `@eventually` are (DR-051); `use PropertyDamage.Model.Projection` SHALL NOT replace `Kernel.@/1`.

`using:` SHALL name the relation in one of three forms (DR-051): `:fun` calls `fun(reference_value, variant_value)` in the projection module, public or private; `{Mod, :fun}` calls the public `Mod.fun(reference_value, variant_value)`; `{Mod, :fun, args}` calls the public `Mod.fun(reference_value, variant_value, arg1, ..., argN)`. `Mod` MAY be `__MODULE__`, and then the function MAY be private. `args` SHALL be literals a module attribute can hold. Without `using:` the relation is `==`. The relation's return is a verdict (DR-052): truthy to agree, `false`, `nil` or `{:fail, reason}` to disagree. The framework SHALL check the named function at compile time: an unknown form, a function value, a local function that is missing or has the wrong arity, and a module that does not export the function SHALL each be a `CompileError` that names the observation, the `using:` term and the expected arity. The check of another module SHALL call `Code.ensure_compiled!/1` and SHALL add a compile-time dependency on that module. `__compare_using__/1` SHALL return a 2-arity function built from the named form, and `__compares__/0` SHALL record the `using:` term as written.

A boundary observation MAY return `{:pending, reason}` when its target will reach a comparable value with no further command, through asynchronous catch-up only. A pending side SHALL NOT be a disagreement.

#### Scenario: A boundary observation is evaluated at its scheduled boundary
- **GIVEN** a projection function marked `@compare every: CreateOrder`
- **WHEN** a run with two targets completes a `CreateOrder` root
- **THEN** both targets evaluate the function on their own projection state with that root as the second argument
- **AND** the non-reference value is judged against the reference value by `using:`

#### Scenario: The default relation is equality
- **GIVEN** a `@compare` without `using:`
- **WHEN** two values are judged
- **THEN** they agree if and only if `==/2` holds

#### Scenario: A pending side is not a disagreement
- **WHEN** one target's observation returns `{:pending, reason}` and the other returns a value
- **THEN** the boundary is not in agreement yet
- **AND** the result is neither a divergence nor a failure until the convergence bound expires

#### Scenario: A second @compare on another clause is a compile error
- **WHEN** `@compare` precedes a later clause of a function that already carries one
- **THEN** compilation fails with a message naming the function

#### Scenario: A projection may import another @ macro (DR-051)
- **GIVEN** a projection module that excludes `Kernel.@/1` and imports its own `@/1` macro, which forwards `@compare` to `Kernel.@/1`
- **WHEN** a function carries `@compare`
- **THEN** the observation SHALL be registered
- **AND** without such an import, `Kernel.@/1` SHALL be in scope in the projection module

#### Scenario: A misplaced @compare is a compile error
- **WHEN** `@compare` precedes a private function, a function of another arity, `init/0` or `apply/2`, is combined with `@check` or `@eventually`, is repeated on one function, or has no function after it
- **THEN** compilation fails with a message naming the problem

#### Scenario: The three named forms call their function (DR-051)
- **GIVEN** `@compare using: :fun`, `using: {Mod, :fun}` or `using: {Mod, :fun, args}`
- **WHEN** a reference value and a variant value are judged
- **THEN** the framework SHALL call `fun(reference_value, variant_value)`, `Mod.fun(reference_value, variant_value)` or `Mod.fun(reference_value, variant_value, arg1, ..., argN)`
- **AND** a private function of the projection SHALL be accepted for `:fun` and for `{__MODULE__, :fun}` and `{__MODULE__, :fun, args}`

#### Scenario: A using: that names no relation is a compile error (DR-051)
- **WHEN** `using:` is an unknown form, a function value (a capture or a closure), or `{Mod, :fun, args}` with a function value in `args`
- **THEN** compilation SHALL fail with a `CompileError` naming the observation and the `using:` term, and listing the named forms (for a function value in `args`, the form to write instead)
- **WHEN** `using:` names a local function that is missing or has another arity, or a module that does not export the function with the expected arity
- **THEN** compilation SHALL fail with a `CompileError` naming the observation, the `using:` term and the expected arity

#### Scenario: One target does not evaluate observations
- **WHEN** a run has one target
- **THEN** no `@compare` function is called

### Requirement: A Model with Expansions Compares at the End (DR-049)

A model that defines `expansions/0` SHALL declare at least one `@compare` whose schedule reaches the final boundary: `every: 1` (the default) or a schedule that names `:end`. The framework SHALL check the declaration at run start, before any `Adapter.setup/1`, with one target as with several. Targets that ran different leaves are compared only at root boundaries, so each boundary observation SHALL return a value on which every target can agree: no identifier that differs per target and no count that differs per path.

#### Scenario: The default schedule reaches the end
- **GIVEN** a model with `expansions/0` and a `@compare` without `every:`
- **WHEN** the run starts
- **THEN** the model SHALL load

#### Scenario: An explicit end schedule
- **GIVEN** a model with `expansions/0` whose only `@compare` is `every: :end`
- **WHEN** the run starts
- **THEN** the model SHALL load

#### Scenario: Only a mid-run schedule
- **GIVEN** a model with `expansions/0` whose only `@compare` is `every: {5, CreateOrder}`
- **WHEN** the run starts
- **THEN** the run SHALL fail with an error that names `expansions/0` and `@compare every: :end`

#### Scenario: One target still needs the declaration
- **GIVEN** a one-target run of a model with `expansions/0` and no `@compare`
- **WHEN** the run starts
- **THEN** the run SHALL fail with the same error

### Requirement: Checks Fire per Leaf (DR-049)

For a root that runs as an expansion, a `@check every: Module` SHALL fire on a leaf of that module, and a `@check every: N` SHALL count steps per target, leaves included. A `@compare` schedule SHALL count roots.

#### Scenario: A module check fires on a leaf
- **GIVEN** a `@check every: Capture` and a root `Pay` that one target runs as `[Authorize, Capture]`
- **WHEN** that target executes the `Capture` leaf
- **THEN** the check SHALL fire after that leaf

#### Scenario: A step counter differs between targets
- **GIVEN** a `@check every: 2` and two targets that ran different numbers of leaves for the same roots
- **WHEN** both targets finish the run
- **THEN** each target's check count SHALL follow the steps that target executed

#### Scenario: A compare schedule counts roots
- **GIVEN** a `@compare every: {2, Pay}` and two `Pay` roots that one target ran as three leaves each
- **WHEN** the run reaches the second `Pay` root
- **THEN** the comparison SHALL happen once, after every leaf of that root

### Requirement: Check Detection and Metadata

The framework SHALL detect checks at compile time using an `@on_definition` hook. Check metadata SHALL be stored and accessible via the `__checks__/0` function on the projection module.

#### Scenario: Checks discovered at compile time
- **WHEN** a projection module is compiled
- **THEN** all functions preceded by `@check` or `@eventually` are recorded as checks
- **AND** their metadata is stored in the module's `__checks__/0` function

#### Scenario: Synchronous check metadata
- **WHEN** a synchronous check is detected
- **THEN** its metadata includes the check name, type `:synchronous`, normalized trigger spec, function name, and the `invariant_id` it validates (DR-026)

#### Scenario: Polling check metadata
- **WHEN** a polling check is detected
- **THEN** its metadata includes the check name, type `:polling`, the function name, normalized eventually spec, captured predicate source, and the `invariant_id` it validates (DR-026)
- **AND** the metadata shape is consistent with synchronous checks (both carry `name`, `type`, `function_name`, and `invariant_id`, with the `assert_` prefix stripped from `name`)

#### Scenario: Default invariant id (DR-026)
- **WHEN** a check is decorated with neither `validates:` nor an inline `id:`
- **THEN** its `invariant_id` SHALL default to the check's `assert_`-stripped logical name, so every check validates a same-named invariant by default

#### Scenario: At most one check attribute per function
- **WHEN** a check function is decorated with more than one `@check` (or more than one `@eventually`), or with both `@check` and `@eventually`
- **THEN** the compiler raises a CompileError rather than silently using one of them

#### Scenario: At most one timing per @check function
- **WHEN** a single `@check` declares both a `during-run` timing (`every:`) and a `lifecycle-boundary` timing (`at:`)
- **THEN** the compiler raises a CompileError, because a check SHALL carry exactly one timing

### Requirement: Invariant Declaration and Linking via @invariant and validates: (DR-026)

A check validates a named **invariant**: a first-class entity with a stable `id`, a human-readable `name` defaulting to `id`, and an optional `description`, represented by `%PropertyDamage.Invariants.Invariant{}` and built by `Invariant.new!/1`. A projection MAY declare invariants centrally with an accumulating `@invariant` module attribute whose value is the `new!/1` keyword list, and a check links to one with `validates: :id` on `@check`/`@eventually` or declares one inline with `id:` (plus optional `description:`). Invariant identity is scoped per projection: `id`s SHALL be unique within a projection and `validates:` SHALL resolve within the same projection. Invariant metadata SHALL be accessible via `__invariants__/0` returning a map of `id` to `%Invariant{}`. There is no `:kind` field on the struct; safety-versus-liveness is a property of a check, surfaced in the catalog.

#### Scenario: Central declaration
- **WHEN** a projection declares `@invariant id: :balance_nonneg, description: "Balance never drops below zero"`
- **THEN** `__invariants__/0` includes `%Invariant{id: :balance_nonneg, name: :balance_nonneg, description: "Balance never drops below zero"}`
- **AND** the `name` defaults to the `id` when not given

#### Scenario: Linking a check to an invariant
- **WHEN** a check is decorated with `@check every: 5, validates: :balance_nonneg`
- **THEN** its metadata records `invariant_id: :balance_nonneg`
- **AND** the invariant is exercised by that check

#### Scenario: Inline declaration and check in one
- **WHEN** a check is decorated with `@check every: 5, id: :balance_nonneg, description: "…"`
- **THEN** the invariant `:balance_nonneg` is declared and that check is registered as validating it

#### Scenario: Duplicate invariant id is rejected
- **WHEN** an `id` is declared more than once (across `@invariant` and inline `id:`, including byte-identical redeclaration)
- **THEN** the compiler raises a CompileError

#### Scenario: Dangling validates: is rejected
- **WHEN** a check declares `validates: :typo` referencing an `id` no invariant declares in that projection
- **THEN** the compiler raises a CompileError identifying the unresolved reference
- **AND** this check is a pure compile-time set-membership test, independent of any description resolver

#### Scenario: Declared-but-unchecked invariant warns (static vacuity)
- **WHEN** an invariant is declared with no check validating it
- **THEN** the compiler emits a warning, and `mix pd.validate` reports it as static vacuity

#### Scenario: Invariant well-formedness
- **WHEN** `@invariant` omits `:id`, or `description` is not a binary
- **THEN** `Invariant.new!/1` raises, surfaced as a CompileError

#### Scenario: Description lookup is lazy and fallback-tolerant
- **WHEN** `Invariant.fetch!(id, ctx)` resolves an invariant for reporting
- **THEN** it returns the local `%Invariant{}`, raising only on an unknown `id`
- **AND** a configured description resolver MAY override only the `description`, best-effort with fallback to the local description, at report time only

### Requirement: assert_* Prefix Convention and Enforcement

Functions with an `assert_` prefix are conventionally used for checks but the prefix is not required. However, a function named `assert_*` that takes two arguments and lacks a `@check` or `@eventually` attribute SHALL raise a CompileError.

#### Scenario: assert_* without attribute raises CompileError
- **WHEN** a two-argument function named `assert_something` is defined
- **AND** it is not preceded by a `@check` or `@eventually` attribute
- **THEN** the compiler raises a CompileError indicating the missing attribute

#### Scenario: Non-assert_* name with trigger works
- **WHEN** a function with a non-`assert_` name (e.g., `check_balance`) is preceded by `@check`
- **THEN** it is registered as a valid check without error

#### Scenario: assert_* with trigger works
- **WHEN** a function named `assert_balance_positive` is preceded by `@check`
- **THEN** it is registered as a valid check without error

### Requirement: Simplified Check-Only Projections

Projections MAY omit `init/0` and `apply/2` to serve purely as check containers. The framework SHALL provide default implementations that initialize to an empty map and return state unchanged.

#### Scenario: Check-only projection
- **WHEN** a projection defines only `@check`-decorated check functions
- **AND** does not implement `init/0` or `apply/2`
- **THEN** the projection compiles successfully with default implementations
- **AND** checks receive an empty map as state and the triggering command or event

### Requirement: Dual Projection Roles

Projections SHALL serve two distinct roles in models. The command sequence projection (returned by `command_sequence_projection/0`) drives command generation by maintaining state for precondition evaluation and generator parameterization. Check projections (returned by `check_projections/0`) verify invariants during execution.

#### Scenario: Command sequence projection drives generation
- **WHEN** a projection is designated as the command sequence projection
- **THEN** its state is passed to `when:` predicates for command filtering
- **AND** its state is passed to `overrides:` functions for generator overrides
- **AND** its state is passed to the simulator for event prediction

#### Scenario: Check projections verify invariants
- **WHEN** projections are listed in `check_projections/0`
- **THEN** they receive commands and events during execution
- **AND** their checks fire according to their trigger configurations

#### Scenario: Same behaviour for both roles
- **WHEN** a projection module is used as either a command sequence projection or a check projection
- **THEN** it uses the same `PropertyDamage.Model.Projection` behaviour for both roles

### Requirement: Use Macro Infrastructure

The `use PropertyDamage.Model.Projection` macro SHALL set up the check detection infrastructure including the `@behaviour` declaration, accumulating `@checks` attribute, `@check` and `@eventually` attribute registration, the `@on_definition` hook, and the `@before_compile` hook.

#### Scenario: Use macro sets up behaviour
- **WHEN** a module invokes `use PropertyDamage.Model.Projection`
- **THEN** the module declares `@behaviour PropertyDamage.Model.Projection`
- **AND** check detection hooks are registered
- **AND** the `__checks__/0` function is generated at compile time

### Requirement: Declared Docs Capture

A module that invokes `use PropertyDamage.Model.Projection` SHALL keep its own docs and the path of its source file, and `PropertyDamage.Docs.fetch/1` SHALL return them, also when the module was compiled from a script. The captured map SHALL include private functions and SHALL NOT include macros or names that start with `__`. The map SHALL hold docs, lines and the file path, never source text. `use PropertyDamage.Model.Projection` MUST come before every `def` and `defp` of the module whose name does not start with `__`, including those that another `use` defines; a function defined earlier SHALL be a `CompileError` at the line of the `use`, even when the module overrides that function later. The captured moduledoc SHALL be the one set by the end of the module body or by a `@before_compile` registered before `use`; a `@before_compile` registered after `use` that sets only `@moduledoc` is not seen, and a module that needs it captured MUST set `@moduledoc` in the module body or register that callback before `use`. When the beam no longer holds the captured map and has no docs chunk, `PropertyDamage.Docs.fetch/1` SHALL return `:unavailable` and SHALL NOT raise.

#### Scenario: A module compiled from a script keeps its docs
- **GIVEN** a projection module that invokes `use PropertyDamage.Model.Projection` and is compiled from a script
- **WHEN** a caller invokes `PropertyDamage.Docs.fetch/1` with that module
- **THEN** it returns `{:ok, docs}` with the moduledoc, the absolute path of the script, and the doc and first-clause line of each function
- **AND** `Code.fetch_docs/1` finds no docs for the same module

#### Scenario: Hidden and missing docs read differently
- **GIVEN** a projection with one function marked `@doc false` and one function with no `@doc`
- **WHEN** a caller invokes `PropertyDamage.Docs.fetch/1` with the module
- **THEN** the hidden function reads `doc: false` and the undocumented function reads `doc: nil`

#### Scenario: A function written before use is a compile error
- **GIVEN** a module that defines a function before it invokes `use PropertyDamage.Model.Projection`
- **WHEN** the module is compiled
- **THEN** compilation fails with a `CompileError` at the line of the `use`
- **AND** the message names each such function as `name/arity`

#### Scenario: A function that another use defines before use is a compile error
- **GIVEN** a module that invokes `use GenServer` before it invokes `use PropertyDamage.Model.Projection`
- **WHEN** the module is compiled
- **THEN** compilation fails with a `CompileError` at the line of `use PropertyDamage.Model.Projection`
- **AND** the message names each default that `use GenServer` defines, such as `child_spec/1`, as `name/arity`

#### Scenario: A function that another use defines stays a compile error when the module overrides it
- **GIVEN** a module that invokes `use GenServer` before it invokes `use PropertyDamage.Model.Projection`
- **AND** the module overrides every default that `use GenServer` defines after `use PropertyDamage.Model.Projection`
- **WHEN** the module is compiled
- **THEN** compilation fails with a `CompileError` at the line of `use PropertyDamage.Model.Projection`
- **AND** the message names each overridden default, such as `child_spec/1`, as `name/arity`

#### Scenario: A macro or a `__`-prefixed function before use compiles
- **GIVEN** a module that defines a macro and a function whose name starts with `__` before it invokes `use PropertyDamage.Model.Projection`
- **WHEN** the module is compiled
- **THEN** compilation succeeds and the captured map holds neither of them

#### Scenario: A beam stripped of its attributes has no docs
- **GIVEN** a module that invokes `use PropertyDamage.Model.Projection`, compiled from a script, whose beam is stripped with `:beam_lib.strip/1`
- **WHEN** a caller invokes `PropertyDamage.Docs.fetch/1` with that module
- **THEN** it returns `:unavailable` without raising
