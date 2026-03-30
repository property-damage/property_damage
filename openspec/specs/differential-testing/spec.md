# Differential Testing Specification

## Purpose

Define the differential testing and mutation testing subsystems that allow PropertyDamage to compare multiple implementations against the same command sequences and to measure test suite quality by injecting faults into adapter responses.

## Requirements

### Requirement: Multi-Target Execution

The framework SHALL run the same command sequences against multiple adapter targets and compare their results.

#### Scenario: Oracle testing

- **WHEN** differential testing is configured with a reference target (`role: :reference`) and one or more SUT targets
- **THEN** the framework SHALL execute the same command sequences against all targets
- **AND** SHALL compare SUT results against the reference target's results

#### Scenario: Same adapter with different configurations

- **WHEN** multiple targets use the same adapter module with different `opts:`
- **THEN** the framework SHALL treat them as distinct targets
- **AND** SHALL execute commands against each target's configured endpoint independently

### Requirement: Comparison Modes

The framework SHALL support three comparison modes: `:correctness`, `:performance`, and `:both`.

#### Scenario: Correctness comparison

- **WHEN** `compare: :correctness` is configured
- **THEN** the framework SHALL compare the events returned by each target for equivalence
- **AND** SHALL record divergences where results differ

#### Scenario: Performance comparison

- **WHEN** `compare: :performance` is configured
- **THEN** the framework SHALL compare latency and throughput metrics across targets
- **AND** SHALL NOT check event equivalence

#### Scenario: Combined comparison

- **WHEN** `compare: :both` is configured
- **THEN** the framework SHALL perform both correctness and performance comparison

### Requirement: Execution Modes

The framework SHALL support interleaved and sequential execution modes.

#### Scenario: Interleaved execution

- **WHEN** execution mode is `:interleaved` (default for correctness comparison)
- **THEN** the framework SHALL execute each command round-robin across all targets before proceeding to the next command
- **AND** this SHALL minimize environmental timing differences between targets

#### Scenario: Sequential execution

- **WHEN** execution mode is `:sequential` (default for performance comparison)
- **THEN** the framework SHALL execute the full command sequence on each target independently

#### Scenario: Baseline implies sequential

- **WHEN** a `baseline:` file is provided for comparison
- **THEN** execution SHALL be implicitly sequential since the baseline was recorded in a prior run

### Requirement: Equivalence Strategies

The framework SHALL support multiple strategies for comparing results between targets: exact, structural, and custom function.

#### Scenario: Exact equivalence

- **WHEN** the equivalence strategy is `:exact`
- **THEN** results from all targets MUST be strictly equal for the command to be considered equivalent

#### Scenario: Structural equivalence

- **WHEN** the equivalence strategy is `:structural`
- **THEN** the framework SHALL normalize results by removing common non-deterministic fields (id, inserted_at, updated_at, created_at, timestamp, uuid, request_id, correlation_id)
- **AND** SHALL compare the normalized results for equality

#### Scenario: Custom equivalence function

- **WHEN** the equivalence strategy is a custom function `fn ref_result, target_result -> boolean end`
- **THEN** the framework SHALL call the function with the reference result and target result
- **AND** SHALL treat the command as equivalent if the function returns `true`

### Requirement: Divergence Recording

The framework SHALL record which commands produced different results across targets, including the specific divergence details.

#### Scenario: Recording a divergence

- **WHEN** a command produces non-equivalent results across targets
- **THEN** the framework SHALL record the command, its index in the sequence, the results from each target, and the target names involved

#### Scenario: Shrinking divergences

- **WHEN** divergences are detected in a command sequence
- **THEN** standard PropertyDamage shrinking SHALL apply to find the minimal command sequence that still produces the divergence

### Requirement: Time-Separated Baselines

The framework SHALL support saving test results to baseline files for later comparison against different implementations or versions.

#### Scenario: Exporting a baseline

- **WHEN** `export_to: "baselines/v2.3.json"` is configured
- **THEN** the framework SHALL save command sequences, results, timing data, event logs, and aggregate metrics to the specified JSON file
- **AND** the baseline SHALL include metadata: creation time, model name, model version, target name, and seed

#### Scenario: Comparing against a baseline

- **WHEN** `baseline: "baselines/v2.3.json"` is configured with a live target
- **THEN** the framework SHALL load the baseline results
- **AND** SHALL compare the live target's results against the stored baseline results using the configured equivalence strategy

### Requirement: Target Specification

Each target SHALL be specified as a tuple of `{AdapterModule}` or `{AdapterModule, opts}` with optional `name:`, `role:`, and `opts:` keywords.

#### Scenario: Minimal target specification

- **WHEN** a target is specified as `{MyAdapter}`
- **THEN** the framework SHALL derive a display name from the module name
- **AND** SHALL pass no additional options to `setup/1`

#### Scenario: Named target with role

- **WHEN** a target is specified as `{MyAdapter, role: :reference, name: "prod", opts: [url: "http://prod"]}`
- **THEN** the framework SHALL use "prod" as the display name
- **AND** SHALL designate this target as the reference for oracle testing
- **AND** SHALL pass `[url: "http://prod"]` to the adapter's `setup/1`

### Requirement: Mutation Testing Execution

The mutation testing subsystem SHALL inject faults into adapter responses by wrapping the real adapter with mutation operators, then run full command sequences to determine if tests detect the mutations.

#### Scenario: Running mutation testing

- **WHEN** `PropertyDamage.Mutation.run/1` is called with model, adapter, and configuration
- **THEN** the framework SHALL generate mutations using the configured operators
- **AND** SHALL execute full command sequences against each mutated adapter
- **AND** SHALL classify each mutation as killed (detected) or survived (undetected)

#### Scenario: Mutation score calculation

- **WHEN** mutation testing completes
- **THEN** the framework SHALL calculate the mutation score as `killed_mutations / total_mutations`
- **AND** SHALL compare against the configured `target_score` (default 0.80)

### Requirement: Mutation Operators

The framework SHALL provide five built-in mutation operators: value, omission, status, event, and boundary.

#### Scenario: Value operator

- **WHEN** the `:value` operator is applied
- **THEN** it SHALL mutate numeric and string values in adapter responses (zero, negate, off-by-one)

#### Scenario: Omission operator

- **WHEN** the `:omission` operator is applied
- **THEN** it SHALL remove fields from events returned by the adapter

#### Scenario: Status operator

- **WHEN** the `:status` operator is applied
- **THEN** it SHALL change success/error outcomes in adapter responses

#### Scenario: Event operator

- **WHEN** the `:event` operator is applied
- **THEN** it SHALL modify event contents and structure in adapter responses

#### Scenario: Boundary operator

- **WHEN** the `:boundary` operator is applied
- **THEN** it SHALL push values to edge cases (0, -1, max integer, nil)

### Requirement: Mutation Operator Behaviour

Each mutation operator SHALL implement the `PropertyDamage.Mutation.Operator` behaviour with callbacks for identification, mutation generation, mutation application, and description.

#### Scenario: Operator callbacks

- **WHEN** a module implements the `Operator` behaviour
- **THEN** it SHALL implement `name/0` returning an atom identifier
- **AND** `description/0` returning a human-readable string
- **AND** `generate_mutations/2` returning a list of mutation specifications
- **AND** `apply_mutation/2` returning the mutated events
- **AND** `describe_mutation/1` returning a human-readable description of a specific mutation

### Requirement: Mutation Configuration

The mutation testing subsystem SHALL support configuration for operator selection, mutations per command, runs per mutation, target score, and timeout.

#### Scenario: Selective operators

- **WHEN** `operators: [:value, :omission]` is configured
- **THEN** the framework SHALL only apply the specified operators, not all available operators

#### Scenario: Mutations per command limit

- **WHEN** `mutations_per_command: 5` is configured
- **THEN** the framework SHALL generate at most 5 mutations for each command type

#### Scenario: Target score threshold

- **WHEN** `target_score: 0.80` is configured
- **THEN** `PropertyDamage.Mutation.passes?/1` SHALL return `true` only if the mutation score meets or exceeds 0.80

### Requirement: Mutation Analysis

The framework SHALL provide analysis of mutation testing results identifying test suite weaknesses.

#### Scenario: Weakness identification

- **WHEN** `PropertyDamage.Mutation.analyze/1` is called with a report
- **THEN** the analysis SHALL identify weak commands (low kill rates), weak operators (mutation types that frequently survive), unchecked fields, and actionable suggestions for improving test coverage

### Requirement: Mutation Report Formatting

The framework SHALL support multiple output formats for mutation testing reports.

#### Scenario: Terminal format

- **WHEN** a mutation report is formatted with `:terminal`
- **THEN** the framework SHALL produce ASCII-formatted output suitable for console display

#### Scenario: Markdown format

- **WHEN** a mutation report is formatted with `:markdown`
- **THEN** the framework SHALL produce markdown tables suitable for documentation

#### Scenario: JSON format

- **WHEN** a mutation report is formatted with `:json`
- **THEN** the framework SHALL produce JSON output suitable for programmatic analysis
