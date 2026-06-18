# Command Specification

## Purpose

Commands are the semantic building blocks of stateful property-based tests. Each command defines a pure generator that produces field maps, a specification describing execution and shrinking behavior, and optional metadata callbacks. Commands are deliberately decoupled from state shape and execution transport, enabling reuse across different models and adapters.

Reference Decision Records: DR-006 (Pure Command Generators), DR-008 (Command Semantics), DR-019 (Command Spec Pattern)

## Requirements

### Requirement: Pure Generator Architecture

Commands SHALL define a `generator/1` callback that accepts an overrides map and returns a StreamData generator of plain maps (not structs). The framework SHALL wrap generated maps into the command struct automatically. Generators MUST NOT depend on test state or the system under test; state-dependent logic belongs in the Model.

#### Scenario: Generator produces field maps
- **WHEN** a command's generator is invoked with an empty overrides map
- **THEN** it returns a StreamData generator that yields plain maps
- **AND** each map contains keys corresponding to the command struct's fields

#### Scenario: Generator applies overrides
- **WHEN** a command's generator is invoked with an overrides map containing field keys
- **THEN** the overrides replace the corresponding default generators
- **AND** raw values in the overrides map are automatically lifted to constant generators

#### Scenario: Generator composability
- **WHEN** a specialized command calls another command's generator
- **THEN** the returned generator can be extended with additional fields
- **AND** the composition produces valid field maps

### Requirement: Command Spec Pattern

Commands SHALL support a `command_spec/1` callback that returns a complete specification map. The spec map SHALL contain the keys `:command`, `:execution`, `:settle`, `:shrink`, `:when`, `:with`, and `:weight`.

#### Scenario: Default spec from use macro
- **WHEN** a module uses `PropertyDamage.Command` without options
- **THEN** `command_spec/1` returns a map with framework defaults
- **AND** the `:command` field is set to the module itself
- **AND** `:execution` defaults to `:sync`
- **AND** `:shrink` defaults to `:neutral`
- **AND** `:weight` defaults to `1`
- **AND** `:when` defaults to a function that always returns true
- **AND** `:with` defaults to an empty map

#### Scenario: Module-level defaults via use options
- **WHEN** a module uses `PropertyDamage.Command` with options like `execution: :probe`
- **THEN** `command_spec/1` returns a map where those options override framework defaults
- **AND** unspecified fields retain their framework default values

#### Scenario: Call-time overrides from Model
- **WHEN** the Model passes overrides (e.g., `weight: 2`) to `command_spec/1`
- **THEN** call-time overrides take highest priority
- **AND** module defaults take second priority
- **AND** framework defaults fill in remaining fields

### Requirement: Spec Priority Layering

The framework SHALL resolve command specs using a three-tier priority system. Call-time overrides (from the Model's command list) SHALL take highest priority. Module defaults (from `use` options) SHALL take second priority. Framework defaults SHALL fill in any remaining unspecified fields.

#### Scenario: Override precedence
- **WHEN** a command defines `execution: :probe` via `use` options
- **AND** the Model specifies `execution: :async` in its command list
- **THEN** the resolved spec has `execution: :async`

#### Scenario: Framework defaults fill gaps
- **WHEN** neither the module nor the Model specifies a `:settle` value
- **THEN** the resolved spec uses the framework default settle configuration
- **AND** the default settle has `timeout_ms: 2000`, `interval_ms: 300`, and `backoff: :linear`

### Requirement: Execution Semantics

Commands SHALL support three execution modes via the `:execution` field: `:sync`, `:probe`, and `:async`.

#### Scenario: Synchronous execution
- **WHEN** a command's execution mode is `:sync`
- **THEN** the command represents a synchronous mutation of the system under test
- **AND** the command completes immediately upon adapter response

#### Scenario: Probe execution
- **WHEN** a command's execution mode is `:probe`
- **THEN** the command represents a read-only query against the system under test
- **AND** the framework applies settle/retry logic using the command's settle configuration
- **AND** the command does not mutate the system under test

#### Scenario: Async execution
- **WHEN** a command's execution mode is `:async`
- **THEN** the command represents an asynchronous operation that requires polling for completion
- **AND** the framework applies settle/retry logic using the command's settle configuration
- **AND** async commands whose refs are used by subsequent commands are protected during shrinking

### Requirement: Shrink Hints

Commands SHALL declare a shrinking priority via the `:shrink` field. The valid values SHALL be `:prefer_remove`, `:neutral`, and `:prefer_keep`.

#### Scenario: Prefer remove during shrinking
- **WHEN** a command's shrink hint is `:prefer_remove`
- **THEN** the shrinker prioritizes removing this command from failing sequences
- **AND** read-only commands typically use this hint

#### Scenario: Neutral shrinking
- **WHEN** a command's shrink hint is `:neutral`
- **THEN** the shrinker applies no special priority to this command
- **AND** this is the default for commands that do not specify a shrink hint

#### Scenario: Prefer keep during shrinking
- **WHEN** a command's shrink hint is `:prefer_keep`
- **THEN** the shrinker avoids removing this command from failing sequences
- **AND** this is appropriate for commands that are likely essential to reproducing a failure

### Requirement: Settle Configuration

Commands with `:probe` or `:async` execution semantics SHALL support a settle configuration controlling retry behavior for eventually consistent systems.

#### Scenario: Default settle configuration
- **WHEN** a probe or async command does not specify custom settle options
- **THEN** the framework uses `timeout_ms: 2000`, `interval_ms: 300`, `backoff: :linear`

#### Scenario: Custom settle configuration
- **WHEN** a command specifies `settle: %{timeout_ms: 5000, interval_ms: 200, backoff: :exponential}`
- **THEN** the framework retries using exponential backoff at 200ms intervals up to 5 seconds

### Requirement: Optional Metadata Callbacks

Commands MAY implement optional callbacks that provide metadata for shrinking, validation, and debugging. The framework SHALL detect these via `function_exported?/3` and use sensible defaults when they are not implemented.

#### Scenario: Downstream observables callback
- **WHEN** a command implements `downstream_observables/0`
- **THEN** it returns a list of event modules that this command can produce
- **AND** the framework uses this for validation and causality tracking during shrinking

#### Scenario: Read-only callback
- **WHEN** a command implements `read_only?/0` returning `true`
- **THEN** the command is prioritized for removal during shrinking

#### Scenario: Label callback
- **WHEN** a command implements `label/2` with state and command arguments
- **THEN** it returns a human-readable string for debugging output
- **AND** returning `nil` indicates no special label

#### Scenario: Metadata callbacks not implemented
- **WHEN** a command does not implement an optional metadata callback
- **THEN** the framework uses sensible defaults without raising an error

### Requirement: Idempotency Testing Callbacks

Commands MAY implement callbacks that control stutter/idempotency testing behavior.

#### Scenario: Idempotent command included in stutter testing
- **WHEN** a command does not implement `idempotent?/0` or returns `true`
- **THEN** the command is included in stutter testing by default

#### Scenario: Non-idempotent command excluded from stutter testing
- **WHEN** a command implements `idempotent?/0` returning `false`
- **THEN** the command is excluded from stutter testing

#### Scenario: Idempotency key provided
- **WHEN** a command implements `idempotency_key/1`
- **THEN** the returned key is passed to the adapter in the stutter context
- **AND** the adapter can include the key in request metadata (e.g., HTTP headers)

#### Scenario: Acceptable retry events declared
- **WHEN** a command implements `acceptable_retry_events/0`
- **THEN** retry responses matching any listed event module are accepted as correct
- **AND** this allows different-but-valid responses on retry (e.g., created vs. already exists)

### Requirement: Legacy Callback Fallback

The framework SHALL support legacy callbacks for backward compatibility. When a command does not implement `command_spec/1`, the framework SHALL build a spec from legacy callbacks `semantics/0`, `settle_config/0`, and `read_only?/0`.

#### Scenario: Legacy semantics callback
- **WHEN** a command implements `semantics/0` but not `command_spec/1`
- **THEN** the framework reads the execution mode from `semantics/0`

#### Scenario: Legacy read_only maps to shrink hint
- **WHEN** a command implements `read_only?/0` returning `true` but not `command_spec/1`
- **THEN** the framework sets `:shrink` to `:prefer_remove` in the resolved spec

#### Scenario: No legacy callbacks implemented
- **WHEN** a command implements neither `command_spec/1` nor any legacy callbacks
- **THEN** the framework uses all framework defaults (`:sync` execution, `:neutral` shrink, weight 1)

### Requirement: Separation of Concerns

Commands SHALL define WHAT operations exist and their fields. Models SHALL define WHEN to use commands and HOW to parameterize them. Adapters SHALL define HOW to execute commands against the system under test. Commands MUST NOT depend on state shape or transport details.

#### Scenario: Command reuse across models
- **WHEN** two different Models reference the same command module
- **AND** each Model provides different `when:` predicates and `with:` overrides
- **THEN** the command works correctly in both contexts without modification

#### Scenario: Command independence from adapter
- **WHEN** a command is defined with its generator and struct
- **THEN** it contains no references to HTTP, database, or other transport mechanisms
- **AND** all transport concerns are handled by the Adapter layer
