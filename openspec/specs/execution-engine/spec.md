# Execution Engine Specification

## Purpose

Defines the two-phase execution model, adapter lifecycle, external field markers and placeholder resolution, event injection, and mock service support that together form the core runtime of the PropertyDamage SPBT framework.

Reference DRs: DR-011 (External Field Markers), DR-021 (Placeholder Resolution Identity), DR-015 (Adapter Separation), DR-016 (Injector Pattern), DR-018 (Resource Polling). DR-010 (Symbolic References) is superseded.

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

The adapter SHALL follow a strict setup/execute/teardown lifecycle: `setup/1` is called once to establish context, `execute/2` is called for each command in the sequence, and `teardown/1` is called once for cleanup.

#### Scenario: Normal adapter lifecycle
- **WHEN** a command sequence is executed
- **THEN** the framework SHALL call `setup/1` exactly once before any command execution
- **AND** the framework SHALL call `execute/2` once per command in sequence order
- **AND** the framework SHALL call `teardown/1` exactly once after all commands complete

#### Scenario: Teardown on failure
- **WHEN** a command execution fails mid-sequence
- **THEN** the framework SHALL still call `teardown/1` for cleanup
- **AND** the framework SHALL log a warning if teardown itself raises an error

#### Scenario: Shrink attempts repeat the full lifecycle
- **WHEN** the shrinker re-executes a candidate sequence
- **THEN** the framework SHALL run the full setup/execute/teardown lifecycle for each shrink attempt

### Requirement: Adapter Execute Context

The adapter context passed to `execute/2` SHALL include an `:inject` function for mid-execution event injection and a `:start_poller` function for background resource polling. When stutter testing is active, retry executions SHALL additionally receive a `:stutter` key.

#### Scenario: Inject function available in context
- **WHEN** the adapter receives the context in `execute/2`
- **THEN** the context SHALL contain an `:inject` key with a callable function
- **AND** calling that function with an event struct SHALL immediately update projections

#### Scenario: Start poller function available in context
- **WHEN** the adapter receives the context in `execute/2`
- **THEN** the context SHALL contain a `:start_poller` key with a callable function
- **AND** calling that function with poller options SHALL spawn a background resource poller

#### Scenario: Stutter context on retries only
- **WHEN** stutter testing is enabled and a command is retried
- **THEN** the context SHALL contain a `:stutter` key with attempt number, is_retry flag, and idempotency key
- **AND** the first execution (attempt 1) SHALL NOT include stutter context

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
- **THEN** executing `CommandA` or `CommandB` SHALL invoke `SubAdapter.execute/2`
- **AND** the sub-adapter SHALL receive the same context as the parent adapter

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

### Requirement: Pre-Run Validation

The system SHALL verify model and adapter configuration before beginning execution, detecting misconfigurations early rather than at runtime.

#### Scenario: Validation catches missing configuration
- **WHEN** the model or adapter is misconfigured (e.g., missing required projections or undeclared commands)
- **THEN** the framework SHALL report validation errors before any commands execute

#### Scenario: Validation passes for correct configuration
- **WHEN** the model and adapter are correctly configured
- **THEN** validation SHALL succeed and execution SHALL proceed

### Requirement: Adapter Timeout

Each command execution SHALL be subject to a configurable timeout. The default timeout SHALL be 30 seconds. Adapters MAY override the timeout per command type.

#### Scenario: Default timeout applies
- **WHEN** an adapter does not override the timeout
- **THEN** each command execution SHALL time out after 30 seconds

#### Scenario: Per-command timeout override
- **WHEN** an adapter overrides the timeout for a specific command type
- **THEN** that command SHALL use the overridden timeout value
- **AND** the timeout MAY be specified as an integer (seconds) or a tuple with units (e.g., `{500, :milliseconds}`)
