# Execution Engine Specification

## Purpose

Defines the two-phase execution model, adapter lifecycle, external field markers and placeholder resolution, event injection, and mock service support that together form the core runtime of the PropertyDamage SPBT framework.

Reference DRs: DR-011 (External Field Markers), DR-021 (Placeholder Resolution Identity), DR-015 (Adapter Separation), DR-016 (Injector Pattern), DR-018 (Resource Polling), DR-024 (Lifecycle-Boundary Assertions), DR-025 (Continuous Async-Observation Checking), DR-026 (Invariant Catalog and Anti-Vacuity Coverage). DR-010 (Symbolic References) is superseded.

## Requirements

### Requirement: Two-Phase Execution

The system SHALL execute command sequences in two distinct phases: a symbolic generation phase that produces command sequences without contacting the SUT, followed by a concrete execution phase that runs commands against the SUT and resolves placeholder values to real ones.

#### Scenario: Symbolic phase generates commands without SUT interaction
- **WHEN** the framework generates a command sequence
- **THEN** all commands SHALL contain placeholders for server-generated values
- **AND** no adapter calls SHALL be made during generation

#### Scenario: Concrete phase executes commands and resolves values
- **WHEN** the framework transitions to the concrete execution phase
- **THEN** each command SHALL be executed against the SUT via the adapter
- **AND** placeholders SHALL be replaced with concrete values captured from the SUT's events

### Requirement: Adapter Lifecycle

The adapter SHALL follow a strict setup/execute/teardown lifecycle: `setup/1` is called once to establish context, `execute/3` is called for each command in the sequence, and `teardown/1` is called once for cleanup. `teardown/1` receives the `setup/1` return exactly (the `user_context`). Lifecycle-boundary assertions (DR-024) are evaluated at the edges of this lifecycle: `@trigger at: :startup` assertions after `setup/1` and before the first command, and `@trigger at: :teardown` assertions on the settled state before `teardown/1`.

#### Scenario: Normal adapter lifecycle
- **WHEN** a command sequence is executed
- **THEN** the framework SHALL call `setup/1` exactly once before any command execution
- **AND** the framework SHALL call `execute/3` once per command in sequence order
- **AND** the framework SHALL call `teardown/1` exactly once after all commands complete

#### Scenario: Teardown on failure
- **WHEN** a command execution fails mid-sequence
- **THEN** the framework SHALL still call `teardown/1` for cleanup
- **AND** the framework SHALL log a warning if teardown itself raises an error

#### Scenario: Shrink attempts repeat the full lifecycle
- **WHEN** the shrinker re-executes a candidate sequence
- **THEN** the framework SHALL run the full setup/execute/teardown lifecycle for each shrink attempt

#### Scenario: Startup assertions gate the initial state
- **WHEN** a projection declares an `@trigger at: :startup` assertion
- **THEN** the framework SHALL evaluate it on the initial `init/0` state after `setup/1` and before the first `execute/3`
- **AND** a failing startup assertion SHALL halt the run before any command is executed

#### Scenario: Teardown assertions evaluate the settled state
- **WHEN** a run completes cleanly and a projection declares an `@trigger at: :teardown` assertion
- **THEN** the framework SHALL evaluate it once on the merged final projection state after both state pollers and resource pollers have finalized
- **AND** it SHALL be evaluated before `teardown/1` is called
- **AND** `teardown/1` SHALL still be called regardless of the assertion's verdict

#### Scenario: Teardown assertions do not run on early abort
- **WHEN** a run aborts before reaching the settled state (for example an adapter error, a synchronous `@trigger` failure, or a reference-resolution error)
- **THEN** `@trigger at: :teardown` assertions SHALL NOT be evaluated
- **AND** the framework SHALL report the proximate failure rather than a settled-state assertion result

### Requirement: Adapter Execute Arguments (user_context and runtime)

`execute/3` SHALL receive three arguments: the resolved command, the `user_context`, and a `%PropertyDamage.Runtime{}` handle (DR-027). The `user_context` SHALL be exactly what the adapter's `setup/1` returned, with no framework keys merged in. The framework's per-command affordances SHALL travel on the runtime handle: an `inject` function for mid-execution event injection, a `start_poller` function for background resource polling, and a `stutter` field that is populated only on stutter/idempotency retries (and `nil` on the first execution).

#### Scenario: user_context is exactly the setup return
- **WHEN** the adapter receives its arguments in `execute/3`
- **THEN** the second argument SHALL equal the value returned by `setup/1`
- **AND** it SHALL NOT contain framework keys such as `:inject`, `:start_poller`, or `:stutter`

#### Scenario: Inject available on the runtime
- **WHEN** the adapter receives the runtime in `execute/3`
- **THEN** `runtime.inject` SHALL be a callable 1-arity function
- **AND** calling it with an event struct SHALL immediately update projections

#### Scenario: Start poller available on the runtime
- **WHEN** the adapter receives the runtime in `execute/3`
- **THEN** `runtime.start_poller` SHALL be a callable 1-arity function
- **AND** calling it with poller options SHALL spawn a background resource poller

#### Scenario: Stutter populated on retries only
- **WHEN** stutter testing is enabled and a command is retried
- **THEN** `runtime.stutter` SHALL be a map with attempt number, is_retry flag, and idempotency key, and `PropertyDamage.Runtime.stuttering?/1` SHALL return `true`
- **AND** on the first execution (attempt 1) `runtime.stutter` SHALL be `nil` and `stuttering?/1` SHALL return `false`

### Requirement: Injector Adapter for External Events

The system SHALL support injector adapters that receive events from external sources (webhooks, callbacks, message queues) and push them to a shared event queue for the executor to process.

#### Scenario: Injector adapter lifecycle
- **WHEN** injector adapters are configured
- **THEN** each injector adapter SHALL have its `setup/1` called to start listening
- **AND** incoming payloads SHALL be transformed via `to_event/1` and pushed to the event queue
- **AND** `teardown/1` SHALL be called to stop listening after the run completes

#### Scenario: Emits declaration for validation
- **WHEN** an injector adapter declares event types via `@emits`
- **THEN** the framework SHALL validate that the model's injectable events cover all declared types

### Requirement: Command Delegation to Sub-Adapters

The system SHALL support a delegation macro that routes specific command types to dedicated sub-adapter modules, enabling modular organization of complex adapters.

#### Scenario: Delegated command execution
- **WHEN** an adapter defines `delegate_execution for: [CommandA, CommandB], to: SubAdapter`
- **THEN** executing `CommandA` or `CommandB` SHALL invoke `SubAdapter.execute/3`
- **AND** the sub-adapter SHALL receive the same `user_context` and `runtime` as the parent adapter

#### Scenario: Multiple delegation targets
- **WHEN** an adapter delegates different commands to different sub-adapters
- **THEN** each command SHALL be routed to the correct sub-adapter based on its type

### Requirement: External Field Markers

The system SHALL support `external()` markers in event struct definitions to identify fields whose values are generated by the SUT. External fields SHALL be automatically detected, captured from the producing command's events during concrete execution, and used to resolve placeholders held by downstream commands.

#### Scenario: Single external field
- **WHEN** an event struct defines a field with `external()` as its default value
- **THEN** the framework SHALL recognize that field as server-generated
- **AND** the concrete value SHALL be captured from the adapter's returned (or injected) event

#### Scenario: Multiple and nested external fields
- **WHEN** an event struct defines multiple external fields or external fields nested in maps
- **THEN** all external field paths SHALL be tracked (e.g., `[:ids, :transaction]`)
- **AND** each SHALL be resolved independently during execution

#### Scenario: Downstream resolution
- **WHEN** a later command field holds a placeholder for an external value produced earlier
- **THEN** the framework SHALL replace the placeholder with the captured concrete value before executing that command
- **AND** if the placeholder has not been resolved (its producer has not run), execution SHALL fail

#### Scenario: Placeholder identity
- **WHEN** placeholders are compared
- **THEN** identity SHALL be determined by the placeholder's stable id, not by display labels

### Requirement: Shared Event Queue

The system SHALL provide a shared event queue where injector adapters push incoming events. The executor SHALL drain pending events from the queue after each command execution.

#### Scenario: Event queue lifecycle
- **WHEN** a test run begins
- **THEN** the framework SHALL start an event queue
- **AND** injector adapters SHALL receive the queue reference for pushing events
- **AND** the framework SHALL stop the queue after the run completes

#### Scenario: Draining after each command
- **WHEN** a command finishes executing
- **THEN** the executor SHALL drain all pending events from the queue
- **AND** drained events SHALL be processed through projections
- **AND** drained events SHALL be evaluated against `@trigger every:` assertions (DR-025)
- **AND** each entry SHALL record the source adapter module and timestamp

### Requirement: Mock Service Adapter

The system SHALL support mock service adapters that start controlled mock servers, allowing the SUT to call mock endpoints instead of real third-party services. Mock adapters SHALL maintain state, respond to SUT requests, and optionally inject events.

#### Scenario: Mock service intercepts SUT calls
- **WHEN** a mock service adapter is configured
- **THEN** the SUT's outbound calls to the third-party service SHALL be routed to the mock
- **AND** the mock SHALL return controlled responses based on its current state

#### Scenario: Mock state evolves with commands
- **WHEN** a command configures mock behavior (e.g., switch from success to decline)
- **THEN** the mock's internal state SHALL update
- **AND** subsequent SUT requests SHALL reflect the new mock behavior

#### Scenario: Mock injects events
- **WHEN** the SUT calls the mock and the mock handler returns events
- **THEN** those events SHALL be injected into the framework's event processing pipeline

### Requirement: Assertions on Asynchronously-Observed Events

The executor SHALL evaluate `@trigger every:` assertions on every observed event, including events observed asynchronously rather than returned by a command (DR-025): resource-poller and injector-adapter events drained from the shared event queue, mock-service events, and nemesis events, as well as events folded during the finalize-time drains (the `@poll_state` await drain and the settled-state drain). Each asynchronously-observed event SHALL be folded into projection state and then evaluated against the synchronous-assertion dispatch **incrementally** — one event at a time, on the state produced by folding that event — with the per-event counters (`:step`, `:event`, and the event module) advancing as for a command's own event. Assertion mode (DR-014) SHALL be honored, including halting mid-drain under `:halt`.

#### Scenario: Assertion fires on a poller-observed event
- **WHEN** a resource poller injects an event that matches an `@trigger every:` assertion
- **THEN** the executor SHALL evaluate that assertion on the projection state after the event is folded in
- **AND** the per-event counters SHALL advance as for a command's own event

#### Scenario: Violation reported at the observing event
- **WHEN** an `@trigger every:` assertion fails on an asynchronously-observed event
- **THEN** the failure SHALL be reported as a named assertion failure located at that event's `command_index`
- **AND** it SHALL be distinct from an `@trigger at: :teardown` settled-state failure (which has no position) and from a `@poll_state` poll timeout

#### Scenario: Halt mode stops mid-drain
- **WHEN** assertion mode is `:halt` and an `@trigger every:` assertion fails while draining asynchronously-observed events
- **THEN** the executor SHALL stop draining and fail the run at the offending event
- **AND** subsequent queued events SHALL NOT be folded or asserted

#### Scenario: Finalize-time drains are checked
- **WHEN** events are folded during the finalize-time drains (the `@poll_state` await drain or the settled-state drain)
- **THEN** those events SHALL be evaluated against `@trigger every:` assertions, and a violation SHALL surface as a run failure rather than being folded silently

### Requirement: Per-Assertion Firing and Whole-Run Coverage Accumulation (DR-026)

The executor SHALL record how many times each assertion actually fired during a run, keyed by its owning projection and name. An assertion counts as fired whenever its function is invoked, regardless of whether it passes or fails, at every evaluation site: synchronous dispatch on commands and observed events (including the asynchronous paths of DR-025), lifecycle `at:` boundaries (DR-024), and `@poll_state` poller spawn. Per-assertion firing counts SHALL merge across parallel branches the same way the existing assertion counters do. Firing counts SHALL be accumulated across all generated sequences of the run and attached to the result as `result.assertion_fires`.

#### Scenario: Firing recorded at every evaluation site
- **WHEN** an assertion is evaluated via `every:`, an `at:` boundary, an asynchronously-observed event, or a spawned `@poll_state` poller
- **THEN** the executor SHALL increment that assertion's firing count, regardless of pass or fail

#### Scenario: Poller spawn counts as firing
- **WHEN** a `@poll_state` poller is spawned because a matching `after:` event was observed
- **THEN** the executor SHALL count the assertion as having fired, even if the poller later times out or remains pending at shutdown

#### Scenario: Firing accumulates across the whole run
- **WHEN** a run executes multiple generated sequences
- **THEN** `result.assertion_fires` SHALL reflect firing counts summed across all sequences, not a single representative sequence

#### Scenario: Per-assertion firing merges across branches
- **WHEN** execution branches in parallel and assertions fire in different branches
- **THEN** the per-assertion firing counts SHALL merge by the same delta-from-prefix rule as the existing assertion counters

### Requirement: Pre-Run Validation

The system SHALL verify model and adapter configuration before beginning execution, detecting misconfigurations early rather than at runtime.

#### Scenario: Validation catches missing configuration
- **WHEN** the model or adapter is misconfigured (e.g., missing required projections or undeclared commands)
- **THEN** the framework SHALL report validation errors before any commands execute

#### Scenario: Validation passes for correct configuration
- **WHEN** the model and adapter are correctly configured
- **THEN** validation SHALL succeed and execution SHALL proceed

### Requirement: Seed Library Replay Phase

When the `seed_library:` option is enabled and the library is non-empty, the system SHALL run a replay phase before random exploration, as a sibling of the random run loop inside the same run lifecycle (DR-023). The phase SHALL reuse the existing per-sequence machinery (`setup_each` → executor → `teardown_each`, event queue, injectors) under the single `setup_once`/teardown the run already owns, and SHALL NOT invoke `PropertyDamage.run/1` recursively.

#### Scenario: Replay precedes exploration
- **WHEN** the seed library is enabled and non-empty
- **THEN** the system SHALL replay each stored seed once (most-recently-discovered first) before generating any random sequence
- **AND** each replayed seed SHALL be regenerated by run-0 derivation (the stored seed reproduces its original sequence while generators are byte-stable)

#### Scenario: Replays do not consume the exploration budget
- **WHEN** seeds are replayed
- **THEN** the replays SHALL NOT count against `max_runs`, which remains the exploration budget

#### Scenario: Halt on a still-failing replay
- **WHEN** any replayed seed still fails
- **THEN** the system SHALL replay all seeds first (so every streak updates and pruning happens), then skip random exploration and return `{:error, failure}` for a representative still-failing seed
- **AND** that representative report SHALL be produced by shrinking the failing run to a minimal `FailureReport`, consistent with the normal failure contract

#### Scenario: Proceed when all replays pass
- **WHEN** every replayed seed passes
- **THEN** random exploration SHALL proceed normally
- **AND** an explicit `seed:` SHALL still get its exploration run after the replay phase

### Requirement: Adapter Timeout

Each command execution SHALL be subject to a configurable timeout. The default timeout SHALL be 30 seconds. Adapters MAY override the timeout per command type.

#### Scenario: Default timeout applies
- **WHEN** an adapter does not override the timeout
- **THEN** each command execution SHALL time out after 30 seconds

#### Scenario: Per-command timeout override
- **WHEN** an adapter overrides the timeout for a specific command type
- **THEN** that command SHALL use the overridden timeout value
- **AND** the timeout MAY be specified as an integer (seconds) or a tuple with units (e.g., `{500, :milliseconds}`)
