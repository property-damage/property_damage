# Command Specification

## Purpose

Commands are the semantic building blocks of stateful property-based tests. Each command defines a pure generator that produces field maps, a specification describing execution and shrinking behavior, and optional metadata callbacks. Commands are deliberately decoupled from state shape and execution transport, enabling reuse across different models and adapters.

Reference Decision Records: DR-006 (Pure Command Generators), DR-008 (Command Semantics), DR-019 (Command Spec Pattern), DR-028 (Single command_spec Surface), DR-030 (Event Correlation via Awaits)

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

Commands SHALL support a `command_spec/1` callback that returns a complete specification map. The spec map SHALL contain the keys `:command`, `:execution`, `:settle`, `:shrink`, `:when`, `:with`, `:weight`, `:observables`, `:idempotent`, and `:acceptable_retry_events`. `command_spec/1` is the single surface for a command's static metadata (DR-028); there are no separate per-metadata callbacks.

#### Scenario: Default spec from use macro
- **WHEN** a module uses `PropertyDamage.Command` without options
- **THEN** `command_spec/1` returns a map with framework defaults
- **AND** the `:command` field is set to the module itself
- **AND** `:execution` defaults to `:sync`
- **AND** `:shrink` defaults to `:neutral`
- **AND** `:weight` defaults to `1`
- **AND** `:when` defaults to a function that always returns true
- **AND** `:with` defaults to an empty map
- **AND** `:observables` defaults to an empty list
- **AND** `:idempotent` defaults to `true`
- **AND** `:acceptable_retry_events` defaults to an empty list

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

### Requirement: Static Metadata Spec Keys

A command's static metadata for shrinking, validation, and debugging SHALL be declared on the `command_spec/1` map (DR-028), not via separate per-metadata callbacks. The framework SHALL resolve every static read through the materialized spec map and use the framework defaults when a key is not specified.

#### Scenario: Observables spec key
- **WHEN** a command declares `:observables` in its `command_spec/1`
- **THEN** it is a list of event modules that this command can produce
- **AND** the framework uses this for validation and causality tracking during shrinking
- **AND** a command that declares no `:observables` defaults to an empty list

#### Scenario: Read-only via shrink key
- **WHEN** a command declares `shrink: :prefer_remove`
- **THEN** the command is prioritized for removal during shrinking
- **AND** there is no separate `read_only?` boolean: read-only IS the `:prefer_remove` shrink hint

#### Scenario: Label callback (per-instance)
- **WHEN** a command implements the per-instance `label/2` callback with state and command arguments
- **THEN** it returns a human-readable string for debugging output
- **AND** returning `nil` indicates no special label

#### Scenario: Label rendered in failure reports and exports
- **WHEN** a failure report is constructed for a sequence containing labeled commands
- **THEN** each command's label is computed lazily (only at report construction, never during generation or passing runs)
- **AND** the label is computed against the `command_sequence_projection` pre-state for that command, reconstructed by folding the shrunk sequence in flattened (`Sequence.to_list/1`) order with the same `apply(command)`-then-`apply(events)` recipe generation uses
- **AND** the non-nil label appears next to the command in the rendered failure report (terminal, markdown, JSON) and in every exported reproduction (ExUnit, scripts, Livebook)
- **AND** a command without `label/2`, or whose `label/2` returns `nil` or raises, contributes no annotation and never fails report construction

### Requirement: Idempotency Testing Metadata

Commands SHALL control stutter/idempotency testing behavior via `command_spec/1` keys (`:idempotent`, `:acceptable_retry_events`) and the per-instance `idempotency_key/1` callback.

#### Scenario: Idempotent command included in stutter testing
- **WHEN** a command's `command_spec/1` has `idempotent: true` (the default)
- **THEN** the command is included in stutter testing

#### Scenario: Non-idempotent command excluded from stutter testing
- **WHEN** a command declares `idempotent: false` in its `command_spec/1`
- **THEN** the command is excluded from stutter testing

#### Scenario: Idempotency key provided
- **WHEN** a command implements the per-instance `idempotency_key/1` callback
- **THEN** the returned key is passed to the adapter in the stutter context
- **AND** the adapter can include the key in request metadata (e.g., HTTP headers)

#### Scenario: Acceptable retry events declared
- **WHEN** a command declares `:acceptable_retry_events` in its `command_spec/1`
- **THEN** retry responses matching any listed event module are accepted as correct
- **AND** this allows different-but-valid responses on retry (e.g., created vs. already exists)

### Requirement: Event Correlation via Awaits

Commands MAY implement the optional `awaits/2` callback (DR-030) to correlate inbound injector events back to the command that semantically owns them. `awaits(state, command)` SHALL return a list of `PropertyDamage.Await` structs, each carrying a `match` predicate `(event -> boolean)` built from the command's resolved fields and captured response. This is **pure correlation**: a matching injector event is attributed to the declaring command's `command_index`; the callback SHALL NOT block, time out, or assert. Judgment over a command's correlated set is expressed in projections (a `@poll_state` for liveness, a `@trigger`/`@invariant` for safety). A command that does not implement `awaits/2` correlates nothing (default `[]`).

#### Scenario: Awaits correlates an injector event to its command
- **WHEN** a command implements `awaits/2` returning a `%Await{match: predicate}`
- **AND** an injector event satisfies the predicate
- **THEN** the framework attributes that event to the command's `command_index` (instead of the ambient `nil`)

#### Scenario: Match predicate built from the resolved command
- **WHEN** `awaits/2` is evaluated after execution and placeholder capture
- **THEN** the `match` predicate MAY close over the command's resolved fields and captured response (the correlation key)

#### Scenario: Persistent correlation outlives the command
- **WHEN** a matching injector event arrives in a later drain (including at finalize)
- **THEN** it is still attributed to the command that declared the matching await

#### Scenario: First-registered wins on overlap
- **WHEN** an injector event satisfies the matchers of more than one command
- **THEN** it is attributed to the first-registered command (deterministic)
- **AND** the framework logs an overlap diagnostic

#### Scenario: Unmatched injector events remain ambient
- **WHEN** an injector event satisfies no registered await
- **THEN** it folds with `command_index: nil` as before

#### Scenario: Simulator predicts the awaited event
- **WHEN** a command declares `awaits/2` and the model implements `simulate/2`
- **THEN** `simulate/2` SHALL predict the awaited event, so the simulated projection state matches a live correlated run (the `awaits/2` ↔ `simulate/2` contract)

### Requirement: Spec-less Command Defaults

A command module that does not implement `command_spec/1` SHALL resolve to the framework defaults layered with any Model-supplied overrides. There is no per-callback legacy fallback (DR-028 supersedes the DR-019 legacy path): a command's static metadata is either declared on `command_spec/1` or defaulted.

#### Scenario: Spec-less command resolves to defaults
- **WHEN** a command implements only `generator/1` (no `command_spec/1`)
- **THEN** the framework uses all framework defaults (`:sync` execution, `:neutral` shrink, weight 1, empty observables, idempotent true)

#### Scenario: Model overrides layer over defaults for spec-less commands
- **WHEN** a spec-less command is listed in the Model with overrides (e.g., `shrink: :prefer_keep`)
- **THEN** the resolved spec applies those overrides over the framework defaults

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

### Requirement: Client-Minted Run-Scoped Values (DR-034)

A command generator MAY mark a field as run-scoped via `PropertyDamage.mint_per_run/1`, meaning the field's value SHALL be minted client-side at execution rather than fixed during symbolic generation. In the symbolic plan the field SHALL be a placeholder, so the plan stays a pure function of the effective seed and remains positionally identical across runs that share it. At execution the value SHALL be resolved deterministically from `(run_nonce, command_index, field)` using seeded generation only (never wall-clock reads, `:rand` at call time, `UUID.uuid4/0`, or other unrecorded entropy), so it is unique per run yet reproducible given the recorded `run_nonce`. `mint_per_run/1` SHALL contrast with `external/0`: `external` captures a value the SUT returns, whereas `mint_per_run` mints a value the client sends.

#### Scenario: Run-scoped field is a placeholder symbolically

- **WHEN** a generator field is `mint_per_run(:uuid)`
- **THEN** the generated plan SHALL carry a placeholder at that field, not a concrete value
- **AND** the plan SHALL be identical across runs that share the effective seed

#### Scenario: Resolved deterministically at execution

- **WHEN** the command executes with a given `run_nonce`
- **THEN** the field SHALL resolve to a value derived purely from `(run_nonce, command_index, field)`
- **AND** re-executing with the same `run_nonce` SHALL produce the same value

#### Scenario: Distinct across runs on a shared SUT

- **WHEN** the same plan is executed multiple times with distinct `run_nonce` values against a SUT that is not reset between runs
- **THEN** each execution SHALL mint distinct values, avoiding duplicate-identity collisions

### Requirement: Value Provenance Classification (DR-034)

Each value appearing in a run's executed commands and events SHALL be classifiable into one of three provenance classes, and the framework SHALL make this classification available to consumers (notably run comparison): `plan-generated` (a pure function of the effective seed), `run-scoped` (minted via `mint_per_run`, a function of the `run_nonce`), and `server-resolved` (captured from SUT output, e.g. via `external`). Provenance SHALL determine how a cross-run difference is interpreted: a differing `plan-generated` value across runs that claim the same plan is a comparability violation; a differing `run-scoped` value is expected by design; a differing `server-resolved` value is an observed behavioral difference.

#### Scenario: Provenance available to consumers

- **WHEN** a value is resolved during execution
- **THEN** the framework SHALL record enough provenance for a consumer to classify it as plan-generated, run-scoped, or server-resolved

#### Scenario: Differing plan-generated value signals incomparability

- **WHEN** two runs assert the same plan identity but a plan-generated value differs between them
- **THEN** the framework SHALL treat the runs as not comparable
