# Model Specification

## Purpose

Models orchestrate stateful property-based tests by defining which commands run, when they are valid, how they are parameterized, and the test lifecycle. A model ties together commands, projections, and optional simulators without knowing transport details or command internals.

Reference Decision Records: DR-001 (Models as Behaviour Modules), DR-002 (Model and Command Agnosticism), DR-003 (Reuse Through Standard Elixir), DR-007 (Model-Level Command Wiring), DR-013 (Terminal States), DR-026 (Invariant Catalog and Anti-Vacuity Coverage)

## Requirements

### Requirement: Required Callbacks

Models SHALL implement two required callbacks: `commands/0` returning a list of command specifications, and `command_sequence_projection/0` returning the projection module used during command sequence generation.

#### Scenario: Commands callback returns command list
- **WHEN** a model implements `commands/0`
- **THEN** it returns a list of command specifications
- **AND** each specification identifies a command module with optional configuration

#### Scenario: Command sequence projection callback
- **WHEN** a model implements `command_sequence_projection/0`
- **THEN** it returns a single projection module
- **AND** this projection's state drives command filtering, selection, and simulation

### Requirement: Command Specification Formats

Models SHALL accept commands in multiple formats. All formats SHALL be normalized to a consistent internal representation of `{weight, module, spec}` tuples.

#### Scenario: Bare module format
- **WHEN** a command is specified as a bare module atom (e.g., `CreateOrder`)
- **THEN** it is normalized with weight 1 and the command's default spec

#### Scenario: Tuple with integer weight (legacy)
- **WHEN** a command is specified as `{Module, weight}` where weight is a positive integer
- **THEN** it is normalized with the given weight and the command's default spec

#### Scenario: Tuple with keyword options
- **WHEN** a command is specified as `{Module, opts}` where opts is a keyword list
- **THEN** the options are passed to the command's `command_spec/1` as overrides
- **AND** the weight is extracted from the resolved spec

#### Scenario: Map format with command key
- **WHEN** a command is specified as `%{command: Module, ...}`
- **THEN** the map fields (excluding `:command`) are passed as overrides to `command_spec/1`
- **AND** the result is normalized to the standard tuple format

### Requirement: Command Wiring Options

Models SHALL support three wiring options for commands: `:weight` for relative selection frequency, `:when` for precondition filtering, and `:with` for generator overrides.

#### Scenario: Weight controls selection frequency
- **WHEN** command A has weight 3 and command B has weight 1
- **AND** both commands pass their `when:` predicates
- **THEN** command A is selected approximately 75% of the time

#### Scenario: When predicate filters commands
- **WHEN** a command's `when:` function receives the current projection state
- **AND** the function returns `false`
- **THEN** that command is excluded from selection for the current step

#### Scenario: When predicate defaults to always true
- **WHEN** a command does not specify a `when:` option
- **THEN** it is always eligible for selection regardless of state

#### Scenario: With function provides generator overrides
- **WHEN** a command has a `with:` function
- **THEN** the function receives the current projection state
- **AND** returns a map of overrides passed to the command's generator
- **AND** this enables state-dependent parameterization (e.g., selecting existing refs)

#### Scenario: With defaults to empty map
- **WHEN** a command does not specify a `with:` option
- **THEN** an empty map is passed as overrides to the command's generator

### Requirement: Command Sequence Generation Loop

The framework SHALL generate command sequences through an iterative loop: check state, filter commands by `when:` predicates, select a command by weight, generate an instance using `with:` overrides, simulate execution to predict events, apply predicted events to the projection, and repeat.

#### Scenario: Full generation cycle
- **WHEN** the framework generates a command sequence
- **THEN** it initializes the command sequence projection via `init/0`
- **AND** filters available commands by evaluating each `when:` predicate against the current state
- **AND** selects one command from valid candidates using weighted random selection
- **AND** generates command data using the command's generator with `with:` overrides
- **AND** calls the simulator to predict resulting events
- **AND** applies predicted events to the projection to update state
- **AND** repeats until the configured maximum commands or `terminate?/3` returns true

#### Scenario: No valid commands available
- **WHEN** all commands' `when:` predicates return false for the current state
- **THEN** the sequence generation stops for the current step

### Requirement: Simulator Integration

Models MAY define a simulator module that predicts expected events for each command during symbolic sequence generation. The simulator enables the generation loop to maintain realistic state without executing against the system under test.

#### Scenario: External simulator module
- **WHEN** a model implements `simulator/0` returning a separate module
- **THEN** that module's `simulate/2` is called with each generated command and current state
- **AND** the returned events are applied to the command sequence projection

#### Scenario: Inline simulator
- **WHEN** a model implements both the Model and Simulator behaviours
- **AND** `simulator/0` returns the model module itself
- **THEN** the model's own `simulate/2` is used during sequence generation

#### Scenario: No simulator defined
- **WHEN** a model does not implement `simulator/0`
- **THEN** the framework operates without event prediction during generation

### Requirement: Test Lifecycle

Models SHALL support a four-phase lifecycle: `setup_once` runs once at the start, `setup_each` runs before every execution (including shrink attempts), `teardown_each` runs after every execution, and `teardown_once` runs once after all shrinking is complete.

#### Scenario: Setup once runs before all executions
- **WHEN** a property test begins
- **THEN** `setup_once/1` is called exactly once with the test configuration
- **AND** it runs before any command sequences are executed

#### Scenario: Setup once is not re-run during shrinking
- **WHEN** a failure is found and the framework begins shrinking
- **THEN** `setup_once/1` is NOT called again
- **AND** only `setup_each/1` and `teardown_each/1` run for each shrink attempt

#### Scenario: Setup each runs before every execution
- **WHEN** a command sequence is about to be executed (initial run or shrink attempt)
- **THEN** `setup_each/1` is called before the execution begins
- **AND** this applies to every shrink attempt as well

#### Scenario: Teardown each runs after every execution
- **WHEN** a command sequence execution completes (whether it passes or fails)
- **THEN** `teardown_each/1` is called for cleanup

#### Scenario: Teardown once runs after all shrinking
- **WHEN** all shrinking is complete (or no shrinking was needed)
- **THEN** `teardown_once/1` is called exactly once for final cleanup

#### Scenario: Lifecycle callbacks are optional
- **WHEN** a model does not implement any lifecycle callbacks
- **THEN** the framework proceeds without calling them
- **AND** no error is raised for missing lifecycle callbacks

#### Scenario: Setup failure aborts execution
- **WHEN** `setup_once/1` returns `{:error, reason}`
- **THEN** the test is aborted

#### Scenario: Setup each failure skips execution
- **WHEN** `setup_each/1` returns `{:error, reason}`
- **THEN** that specific execution is skipped

### Requirement: Terminal States

Models MAY implement `terminate?/3` to control when command generation stops. The callback receives the current state, the command that just executed, and the events it produced.

#### Scenario: Terminate on specific command
- **WHEN** `terminate?/3` pattern-matches a specific command type and returns `true`
- **THEN** the framework stops generating further commands after that command

#### Scenario: Terminate on state condition
- **WHEN** `terminate?/3` inspects the state and returns `true` based on a state predicate
- **THEN** the framework stops generating further commands

#### Scenario: Terminate on event
- **WHEN** `terminate?/3` inspects the events list and finds a terminal event
- **THEN** the framework stops generating further commands

#### Scenario: No terminate callback
- **WHEN** a model does not implement `terminate?/3`
- **THEN** the framework generates commands until the configured `max_commands` limit

### Requirement: Optional Projection and Event Callbacks

Models MAY implement `assertion_projections/0` returning a list of invariant-checking projections, and `injectable_events/0` returning a list of event modules that can arrive from outside command execution.

#### Scenario: Assertion projections declared
- **WHEN** a model implements `assertion_projections/0`
- **THEN** the returned projection modules verify invariants during execution
- **AND** their assertions fire according to their trigger configurations

#### Scenario: No assertion projections
- **WHEN** a model does not implement `assertion_projections/0`
- **THEN** the framework defaults to an empty list and no assertion projections run

#### Scenario: Injectable events declared
- **WHEN** a model implements `injectable_events/0`
- **THEN** the returned event modules are recognized as valid events from external sources
- **AND** this is used for validation against adapter injector declarations

### Requirement: Invariant Catalog Enumeration (DR-026)

The framework SHALL enumerate the catalog of invariants a model verifies. `PropertyDamage.assertion_catalog(model)` SHALL walk the model's projections — the command-sequence projection plus any assertion projections, deduplicated — union their declared invariants, and return one catalog keyed by `{projection, id}`, each entry carrying the invariant and the checks (with their kinds) that validate it.

#### Scenario: Catalog unions across projections
- **WHEN** `assertion_catalog/1` is called on a model whose projections declare invariants
- **THEN** the result SHALL include every invariant from every projection
- **AND** a projection listed both as the command-sequence projection and as an assertion projection SHALL be visited once (deduplicated)

#### Scenario: Same id in two projections stays distinct
- **WHEN** two different projections each declare an invariant with the same `id`
- **THEN** the catalog SHALL keep them as distinct entries keyed by `{projection, id}`

### Requirement: Model-Command Agnosticism

Models SHALL NOT know transport details (HTTP, database, etc.). Commands SHALL NOT know state shape or precondition logic. This separation enables independent evolution and reuse of both components.

#### Scenario: Model references commands without transport knowledge
- **WHEN** a model defines its command list
- **THEN** it references command modules and wiring options only
- **AND** it contains no HTTP endpoints, database queries, or transport-specific code

#### Scenario: Commands are reusable across models
- **WHEN** the same command module is used in two different models
- **AND** each model provides different `when:` and `with:` configurations
- **THEN** the command works correctly in both models without modification

### Requirement: Command Spec Resolution

The framework SHALL resolve command specs by calling `command_spec/1` when available, falling back to legacy callbacks when it is not. Model-provided overrides SHALL be merged into the resolved spec.

#### Scenario: Resolution via command_spec/1
- **WHEN** a command module exports `command_spec/1`
- **THEN** the framework calls it with the Model's overrides as the argument
- **AND** uses the returned map as the resolved spec

#### Scenario: Resolution via legacy callbacks
- **WHEN** a command module does not export `command_spec/1`
- **THEN** the framework builds a spec from `semantics/0`, `settle_config/0`, and `read_only?/0`
- **AND** merges Model-provided overrides on top of the legacy-derived spec
