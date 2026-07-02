# Differential Testing Specification

## Purpose

Define the differential testing and mutation testing subsystems that allow PropertyDamage to compare multiple implementations against the same command sequences and to measure test suite quality by injecting faults into adapter responses. This domain also defines run comparison (DR-035): the post-hoc comparison of two or more full run traces of the same plan, used to localize regressions and flakiness.

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

### Requirement: External Value Capture Per Target

The framework SHALL capture `external()` server-generated values and resolve them into downstream commands during differential execution (DR-021), maintaining a separate placeholder registry per target so that the same consumer placeholder resolves to the value each target actually produced.

#### Scenario: Consumer resolved to its target's captured value

- **WHEN** a command produces a value marked `external()` and a later command in the sequence consumes it
- **THEN** the framework SHALL resolve the consumer to the concrete value captured from that target's events before executing it, on both interleaved and sequential modes
- **AND** each target SHALL resolve the consumer to its own captured value, independent of the other targets

#### Scenario: Producer that failed before capture

- **WHEN** a target's producer command errors before its external value is captured, and a later command consumes that value
- **THEN** the framework SHALL record the consumer as a failed command for that target rather than aborting the differential run

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

### Requirement: Run Comparison (DR-035)

The framework SHALL compare two or more full `RunTrace` records (DR-033) of the same plan to help a human or an LLM localize regressions and flakiness. All compared traces MUST share a plan identity (equal `original_sequence` and model); the framework SHALL refuse or clearly flag a comparison of traces that do not, treating an unequal `original_sequence` or a differing `plan-generated` value (DR-034) as the incomparability signal. Comparison SHALL operate over `PropertyDamage.RunComparison` and SHALL NOT consume shrunk failure reports, since a shrunk sequence is a different, smaller plan that cannot be aligned against a full run. Rows SHALL be commands and their events (two levels; SUT-call / request-body rows are out of scope for this requirement). Columns SHALL be runs, grouped by outcome (passing versus failing) but otherwise peers, so any run may be compared against any other.

#### Scenario: Comparability guard

- **WHEN** run comparison is asked to compare traces whose `original_sequence` differs, or where a `plan-generated` value differs between them
- **THEN** the framework SHALL treat the traces as not comparable and SHALL surface this rather than emit a misleading diff

#### Scenario: Command and event alignment

- **WHEN** traces are aligned
- **THEN** commands SHALL align by their branch-aware step position, which is identical across same-plan runs
- **AND** events within a command SHALL align by a longest-common-subsequence keyed on event struct module, so a value difference within a matched event is distinguished from an inserted or removed event
- **AND** a model MAY supply a per-event identity function to override the default module key

#### Scenario: Discriminative analysis across multiple runs

- **WHEN** more than one passing run is compared against one or more failing runs
- **THEN** the framework SHALL classify each aligned field difference by its correlation with outcome: a difference that also varies among the passing runs SHALL be ranked as incidental, and a difference that is stable within each outcome group but differs between groups SHALL be ranked as discriminating
- **AND** the framework SHALL emit a ranked list of the most discriminating differences
- **AND** with a single passing run the analysis SHALL degrade to a plain pairwise diff

#### Scenario: Provenance-aware highlighting

- **WHEN** an aligned difference is rendered
- **THEN** `run-scoped` values (DR-034) that differ SHALL be shown as correlation identifiers rather than flagged as suspicious
- **AND** `server-resolved` differences SHALL be the subject of the discriminative ranking

#### Scenario: Self-contained report artifact

- **WHEN** a comparison report is produced
- **THEN** it SHALL be a single self-contained HTML file with no external dependencies, embedding the machine-readable comparison data in one JSON block and rendering a static human-readable table that JavaScript MAY enhance with interactivity
- **AND** it SHALL carry a reproducibility header naming the model, adapter, UTC timestamp, source revision, seed, run number, and per-run `run_nonce`

#### Scenario: Semantic-difference row highlighting

- **WHEN** an aligned row (command or event) has a semantic difference across runs
- **THEN** the row SHALL be highlighted in a color distinct from the pass/fail green and red (for example, amber)
- **AND** the specific differing attributes within the row SHALL be highlighted per diff convention (added, removed, changed)
