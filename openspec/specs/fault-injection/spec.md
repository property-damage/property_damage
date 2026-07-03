# Fault Injection Specification

## Purpose

Define the Nemesis behaviour and built-in fault types that allow PropertyDamage to inject controlled faults into the test environment, verify system resilience, and shrink fault scenarios to minimal reproductions.

## Requirements

### Requirement: Nemesis Behaviour Callbacks

The Nemesis behaviour SHALL define three required callbacks: `inject/2`, `restore/2`, and `precondition/1`. It MAY define optional callbacks `new!/2`, `auto_restore?/0`, and `duration_ms/1`.

#### Scenario: Injecting a fault

- **WHEN** a Nemesis command is executed during a command sequence
- **THEN** the framework SHALL call `inject/2` with the command struct and execution context
- **AND** `inject/2` SHALL return `{:ok, events}` describing the fault activation or `{:error, reason}` on failure

#### Scenario: Restoring after a fault

- **WHEN** a fault's duration expires, a RestoreFault command is executed, or the test sequence ends
- **THEN** the framework SHALL call `restore/2` with the original command struct and execution context
- **AND** `restore/2` SHALL return `{:ok, events}` describing the restoration or `{:error, reason}` on failure

#### Scenario: Checking preconditions

- **WHEN** the framework considers generating a Nemesis command
- **THEN** it SHALL call `precondition/1` with the current model state
- **AND** the command SHALL only be generated if `precondition/1` returns `true`

### Requirement: Auto-Restoration

Nemesis commands SHALL auto-restore by default. Implementations MAY override this by implementing the `auto_restore?/0` callback.

#### Scenario: Default auto-restore behaviour

- **WHEN** a Nemesis command does not implement `auto_restore?/0`
- **THEN** the framework SHALL treat the command as auto-restoring (default `true`)
- **AND** SHALL call `restore/2` after the duration returned by `duration_ms/1` expires

#### Scenario: Explicit restoration

- **WHEN** a Nemesis command implements `auto_restore?/0` returning `false`
- **THEN** the framework SHALL NOT automatically call `restore/2`
- **AND** restoration MUST be triggered by an explicit RestoreFault command in the sequence

### Requirement: Duration Resolution

The framework SHALL resolve a Nemesis command's duration by checking `duration_ms/1` callback first, then the `:duration_ms` field on the command struct.

#### Scenario: Duration from callback

- **WHEN** the Nemesis module exports `duration_ms/1`
- **THEN** the framework SHALL use the callback's return value as the fault duration

#### Scenario: Duration from struct field

- **WHEN** the Nemesis module does not export `duration_ms/1`
- **AND** the command struct has a `:duration_ms` field
- **THEN** the framework SHALL use that field value as the fault duration

#### Scenario: No duration specified

- **WHEN** neither `duration_ms/1` nor a `:duration_ms` struct field is available
- **THEN** the framework SHALL return `nil` for the duration

### Requirement: Event Logging

Nemesis events SHALL be recorded in the event log with `source: :nemesis` and the originating module identified.

#### Scenario: Recording injection events

- **WHEN** `inject/2` returns `{:ok, events}`
- **THEN** each event SHALL be recorded in the event log as an `EventLog.Entry`
- **AND** the entry SHALL have `source: :nemesis`
- **AND** the entry SHALL have `nemesis_module` set to the implementing module

#### Scenario: Recording restoration events

- **WHEN** `restore/2` returns `{:ok, events}`
- **THEN** each event SHALL be recorded in the event log with `source: :nemesis`

### Requirement: Model Integration

Nemesis commands SHALL participate in the normal command sequence as defined by the Model's `commands/0` callback, typically with lower weights than regular commands.

#### Scenario: Including Nemesis commands in model

- **WHEN** a Model lists Nemesis commands in `commands/0` with weight tuples
- **THEN** the framework SHALL select Nemesis commands according to their weights during sequence generation
- **AND** Nemesis commands SHALL be subject to the same `when:` predicates as regular commands

#### Scenario: Generating a selected Nemesis command (DR-031)

- **WHEN** the generator selects a Nemesis module during sequence generation
- **THEN** it SHALL produce a command instance via the Nemesis module's `new!/2` callback (passing the current generation state and any `with:` overrides), since Nemesis modules implement `new!/2` rather than `generator/1`
- **AND** the Nemesis module's `precondition/1` SHALL act as a generation-time filter: a Nemesis whose precondition is unmet for the current state SHALL NOT be selected
- **AND** if a selected Nemesis module does not implement `new!/2`, the framework SHALL raise a clear error rather than fall through to `generator/1`

#### Scenario: Adjusting assertions during active faults

- **WHEN** an assertion projection fires while a Nemesis fault is active
- **THEN** the projection SHOULD be able to inspect the active faults in the model state
- **AND** MAY relax or skip invariant checks that are expected to fail during the fault

### Requirement: Shrinkability

Nemesis commands SHALL be shrinkable. The shrinker SHALL be able to remove Nemesis commands from a failing sequence to find minimal fault reproductions.

#### Scenario: Shrinking removes Nemesis commands

- **WHEN** a command sequence containing Nemesis commands fails
- **THEN** the shrinker SHALL attempt to remove Nemesis commands like any other command
- **AND** SHALL preserve the failure if the Nemesis command is necessary for reproduction

#### Scenario: Argument simplification

- **WHEN** a Nemesis command cannot be removed without losing the failure
- **THEN** the shrinker SHALL attempt to simplify the command's arguments (e.g., reducing duration, simplifying fault parameters)

### Requirement: Composability

Multiple Nemesis faults SHALL be active simultaneously. The framework MUST track all active faults in the execution context.

#### Scenario: Concurrent faults

- **WHEN** multiple Nemesis commands are injected before any are restored
- **THEN** the framework SHALL track all active faults in the `:active_faults` context
- **AND** each fault SHALL operate independently

#### Scenario: Precondition checks for conflicting faults

- **WHEN** a Nemesis command's `precondition/1` checks for conflicting active faults
- **THEN** the framework SHALL provide the current active faults in the model state
- **AND** the command MAY return `false` to prevent conflicting fault combinations

### Requirement: Cleanup on Sequence End

All active Nemesis faults SHALL be restored when a test sequence ends, regardless of test outcome.

#### Scenario: Cleanup after success

- **WHEN** a command sequence completes successfully with active faults remaining
- **THEN** the framework SHALL call `restore/2` for each active fault

#### Scenario: Cleanup after failure

- **WHEN** a command sequence fails with active faults remaining
- **THEN** the framework SHALL call `restore/2` for each active fault before reporting the failure

### Requirement: Module Introspection

The framework SHALL provide utility functions to identify Nemesis modules and commands at runtime.

#### Scenario: Checking if a module is a Nemesis

- **WHEN** `Nemesis.nemesis_module?/1` is called with a module
- **THEN** it SHALL return `true` if the module declares `@behaviour PropertyDamage.Nemesis`
- **AND** SHALL return `false` otherwise

#### Scenario: Checking if a struct is a Nemesis command

- **WHEN** `Nemesis.nemesis_command?/1` is called with a struct
- **THEN** it SHALL return `true` if the struct's module implements the Nemesis behaviour

### Requirement: Built-in Fault Types

The framework SHALL provide built-in Nemesis implementations that fault the System Under Test's network path. Built-in nemeses SHALL inject faults into the SUT's environment, not the test harness's own VM; nemeses that would only stress or observe the local BEAM/host (CPU, memory, OS resources, local process kills, a virtual clock the adapter reads) are out of scope and SHALL NOT be provided as built-ins (fault an in-process collaborator from your own adapter/command code instead).

#### Scenario: Network faults

- **WHEN** testing network resilience
- **THEN** the framework SHALL provide `NetworkPartition`, `NetworkLatency`, and `PacketLoss` Nemesis modules
- **AND** these SHALL inject through Toxiproxy when configured, tagging events `simulated: true` otherwise

#### Scenario: Toxiproxy config source (DR-038)

- **WHEN** a built-in network nemesis injects a fault
- **THEN** it SHALL discover its Toxiproxy config (`%{proxy_name: ..., api_url: ...}`) from the execution context, checking the top-level `:toxiproxy` key first and the adapter context (`context.adapter_context[:toxiproxy]`) second
- **AND** an adapter MAY supply that config by returning `toxiproxy: %{...}` from `setup/1`, which is the path that makes live injection reachable through `PropertyDamage.run`
- **AND** the framework SHALL NOT provide a separate run-level option for the config

#### Scenario: Simulated fallback (DR-038)

- **WHEN** no Toxiproxy config is discovered in either location
- **THEN** the nemesis SHALL NOT contact the SUT (no HTTP call)
- **AND** the emitted event SHALL be tagged `simulated: true` so a no-op fault cannot masquerade as a real one

#### Scenario: Full bidirectional partition (DR-038)

- **WHEN** `NetworkPartition` injects a `:full` partition against a configured Toxiproxy
- **THEN** it SHALL install two `bandwidth` toxics at rate `0`, one on the upstream and one on the downstream, so traffic is blocked in both directions
- **AND** restoration SHALL remove both toxics
- **AND** the framework SHALL support `partition_type` values `:full`, `:upstream`, and `:downstream` only (`:asymmetric` was a duplicate of `:downstream` and is removed)
