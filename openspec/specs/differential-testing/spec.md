# Differential Testing Specification

## Purpose

Define the differential testing and mutation testing subsystems that allow PropertyDamage to compare multiple implementations against the same command sequences and to measure test suite quality by injecting faults into adapter responses. Multi-target runs execute each target as a variant in its own process and advance the variants in lockstep (DR-044). This domain also defines run comparison (DR-035): the post-hoc comparison of two or more full run traces of the same plan, used to localize regressions and flakiness.

## Requirements

### Requirement: Multi-Target Execution

The framework SHALL run the same command sequences against multiple adapter targets and compare their results.

#### Scenario: Oracle testing

- **WHEN** differential testing is configured with a `targets:` list of two or more entries
- **THEN** the framework SHALL execute the same command sequences against all targets
- **AND** SHALL compare the results of every other target against the first target's results (DR-043)

#### Scenario: Same adapter with different configurations

- **WHEN** multiple targets use the same adapter module with different `name:` and `config:` values
- **THEN** the framework SHALL treat them as distinct targets
- **AND** SHALL execute commands against each target's configured endpoint independently, passing each target's `config:` to its own `setup/1`

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

#### Scenario: Timed comparison requires serial concurrency (DR-044)

- **WHEN** `compare: :performance` or `compare: :both` is configured together with `concurrency: :parallel`
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError` naming `:concurrency` and stating that the comparison requires `concurrency: :serial`
- **AND** no command SHALL execute

### Requirement: Lockstep Concurrency (DR-044)

`PropertyDamage.Differential.run/1` SHALL run each generated command sequence against every target in lockstep. Every command of the sequence is a root. For each root `r`, in order, every variant SHALL execute root `r` and stop at boundary `r`; only then SHALL the comparison run, and only after it SHALL any variant start root `r + 1`. The `concurrency:` option SHALL decide how the variants reach a boundary: `:serial` (the default) advances one variant at a time in target order, and `:parallel` advances all variants at the same time. Targets that share one system under `:parallel` MUST isolate their slices of it through `config:`. The option `execution:` MUST be rejected.

#### Scenario: Serial concurrency is the default

- **WHEN** `concurrency:` is not given
- **THEN** the framework SHALL advance the variants one at a time in target order for each root
- **AND** `result.concurrency` SHALL be `:serial`

#### Scenario: Parallel concurrency

- **WHEN** `concurrency: :parallel` is configured
- **THEN** the framework SHALL execute root `r` in every variant at the same time
- **AND** SHALL start no variant on root `r + 1` before every variant has reached boundary `r` and the comparison has run
- **AND** `result.concurrency` SHALL be `:parallel`

#### Scenario: Unknown concurrency value

- **WHEN** `concurrency:` is any value other than `:serial` or `:parallel`
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError` naming `:concurrency`

#### Scenario: Execution option is rejected

- **WHEN** `PropertyDamage.Differential.run/1` is called with `execution:`
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError` with the message "`execution:` was removed; Differential runs every target in lockstep, use `concurrency:` (`:serial`, the default, or `:parallel`)"
- **AND** no command SHALL execute

### Requirement: Variant Isolation (DR-044)

Each target of a multi-target run SHALL run as a variant: one target over the shared concrete sequence, in its own process, through the per-command engine (`PropertyDamage.Executor.Stepping`). A variant SHALL own its projections, event log, copy of the placeholder registry, event queue, injectors, mocks and pollers. Checks, settle, stutter and nemesis SHALL work in every variant as they do in `PropertyDamage.run/1`.

#### Scenario: Variants do not share state

- **GIVEN** two targets that run the same sequence
- **WHEN** one variant's command changes its projections or its event queue
- **THEN** the other variant's projections and event queue SHALL NOT change

#### Scenario: Checks run in every variant

- **WHEN** a model's check fails on a command in one variant
- **THEN** the framework SHALL report a failure of kind `:check_failed` that names that variant

#### Scenario: Pollers die with their variant

- **WHEN** a variant process exits for any reason, including being killed
- **THEN** every `@eventually` state poller and every resource poller that the variant started SHALL stop

#### Scenario: Same seed, same adapter randomness

- **WHEN** the same `seed:` is run twice and an adapter draws random values in `setup/1` or `execute/3`
- **THEN** each variant SHALL draw the same values in both runs
- **AND** two variants of one run SHALL draw different values, because each variant seeds its process with `:rand.seed(:exsss, :erlang.phash2({Generator.run_seed(seed, run_number), target.index}, 4_294_967_296))`

### Requirement: External Value Capture Per Target

The framework SHALL capture `external()` server-generated values and resolve them into downstream commands during differential execution (DR-021), maintaining a separate placeholder registry per target so that the same consumer placeholder resolves to the value each target actually produced.

#### Scenario: Consumer resolved to its target's captured value

- **WHEN** a command produces a value marked `external()` and a later command in the sequence consumes it
- **THEN** the framework SHALL resolve the consumer to the concrete value captured from that target's events before executing it, under both `concurrency: :serial` and `concurrency: :parallel`
- **AND** each target SHALL resolve the consumer to its own captured value, independent of the other targets

#### Scenario: Producer that failed before capture

- **WHEN** a target's producer command errors before its external value is captured, and a later command consumes that value
- **THEN** the framework SHALL NOT call the adapter for the consumer in that target
- **AND** SHALL observe the consumer as `{:error, {:placeholder_resolution_failed, reason}}` for that target, compare it like any other observation, and continue the run

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

### Requirement: Root Observation and Comparison (DR-044)

A variant SHALL observe a root as `{:ok, events}`, the events the command injected followed by the events it returned (for a `:probe` or `:async` root, the events it settled to), or as `{:error, reason}`, the adapter's own error term. At each boundary the framework SHALL compare the observation of every non-reference variant with the reference variant's observation through the configured equivalence strategy, in one comparison function. With two or more variants, an adapter `{:error, _}` SHALL be an observation: the variant continues from the failed command's state. With one variant, an adapter `{:error, _}` SHALL end the run, as it does in `PropertyDamage.run/1`.

#### Scenario: Observation of a command that injects events

- **WHEN** a root's command returns events and an injector delivers events attributed to it
- **THEN** its observation SHALL be `{:ok, events}` with the injected events first, then the returned events

#### Scenario: Probe root

- **WHEN** a root's command has `:probe` or `:async` semantics
- **THEN** its observation SHALL be taken after the command settles

#### Scenario: Adapter error with two variants

- **WHEN** one of two variants answers `{:error, reason}` for a root
- **THEN** the framework SHALL compare that observation with the other variant's observation
- **AND** SHALL NOT end the run unless the observations are not equivalent

### Requirement: Divergence Recording

The framework SHALL record the first root at which a non-reference variant's observation is not equivalent to the reference's observation, and SHALL end that run at the boundary. The next run SHALL start. `Result.divergences` SHALL list the divergences oldest first.

#### Scenario: Recording a divergence

- **WHEN** a root produces non-equivalent observations across variants
- **THEN** the divergence SHALL be a map with the keys `seed`, `run` (0-based), `root` (0-based command index), `command`, `variant` (`%{index, name}` of the first non-equivalent variant in target order), `reference_result`, `divergent_result` and `results` (every variant's observation, keyed by target name)
- **AND** the map SHALL NOT carry the keys `divergent_target` or `step`

#### Scenario: Oldest first

- **WHEN** two runs of one campaign diverge
- **THEN** `Result.divergences` SHALL list the divergence of the earlier run first

#### Scenario: Divergences are not shrunk

- **WHEN** a divergence is recorded
- **THEN** the framework SHALL NOT shrink the command sequence

### Requirement: Per-Run Setup and Teardown (DR-044)

`PropertyDamage.Differential.run/1` SHALL call `Adapter.setup/1` once per run for every target, in the variant's own process, one variant after another in target order. No variant SHALL execute root 0 before every setup has returned and every `@check at: :startup` check has passed. At the end of the run, whether it passed or failed, every variant that was set up SHALL finalize its run and tear its adapter down. An adapter's `setup/1` MUST be idempotent, because it can find state that an earlier run or a crashed run left behind.

#### Scenario: Setup once per run

- **WHEN** a campaign runs `max_runs: 3` against two targets
- **THEN** each target's `setup/1` SHALL be called three times, once per run
- **AND** each target's `teardown/1` SHALL be called three times

#### Scenario: Barrier before root 0

- **WHEN** the second variant's `setup/1` is slow
- **THEN** the first variant SHALL NOT execute root 0 before the second variant's `setup/1` has returned

#### Scenario: Setup failure

- **WHEN** a target's `setup/1` returns `{:error, reason}` or raises
- **THEN** the framework SHALL end the run with a failure of kind `:setup_failed` that names that variant
- **AND** SHALL tear down the variants that were already set up
- **AND** SHALL NOT call `teardown/1` of the variant whose setup failed
- **AND** no command SHALL execute

### Requirement: Failures Name the Variant (DR-044)

A failure SHALL be a map `%{kind, variant, run, root, reason}`, where `variant` is `%{index, name}`, `run` is the 0-based run, `root` is the 0-based command index or `nil` when the failure belongs to no command, and `reason` is the `%PropertyDamage.Failure{}`, the exception the adapter raised, or the term `setup/1` returned. `kind` SHALL be one of `:check_failed`, `:setup_failed` and `:execution_failed`. A failure SHALL end the run at that boundary and SHALL end the `Differential.run/1` campaign: no later run starts, `Result.status` is `:failed`, `Result.failure` holds the failure, and divergences of earlier runs stay in `Result.divergences`. A failure SHALL NOT be compared.

#### Scenario: Check failure

- **WHEN** a check fails in one variant, at a command, at the `:startup` phase, or while the run finalizes (an `@eventually` timeout or an `@check at: :teardown` check)
- **THEN** the failure kind SHALL be `:check_failed`
- **AND** `root` SHALL be `nil` for a `:startup` check

#### Scenario: Execution failure

- **WHEN** a variant's adapter raises in `execute/3`, a command cannot be executed, or the variant process crashes
- **THEN** the failure kind SHALL be `:execution_failed`
- **AND** `reason` SHALL be the exception the adapter raised, where it raised

#### Scenario: No next root after a failure

- **WHEN** a failure occurs at root `r` under `concurrency: :serial`
- **THEN** no variant after the failing one in target order SHALL execute root `r`
- **AND** no variant SHALL start root `r + 1`

### Requirement: Per-Target Injectors, Mocks and Pollers in Multi-Target Runs (DR-044)

`PropertyDamage.Differential.run/1` SHALL honor each target's `injectors:` and `mocks:`: the framework SHALL set them up per run for that variant only, and their events SHALL reach only that variant's event queue. `runtime.start_poller` SHALL be allowed in multi-target runs, and a poller's events SHALL reach only the variant that started it.

#### Scenario: Injector events stay in their variant

- **GIVEN** two targets, only one of which declares an injector
- **WHEN** the injector delivers an event during a run
- **THEN** the event SHALL fold into the declaring variant's projections
- **AND** SHALL NOT reach the other variant

#### Scenario: Resource poller in a multi-target run

- **WHEN** an adapter calls `runtime.start_poller` in one variant of a multi-target run
- **THEN** the framework SHALL start the poller
- **AND** the events it pushes SHALL fold into that variant only

### Requirement: Target Specification (DR-043)

Each target SHALL be an entry of the `targets:` option: either an adapter module or `{AdapterModule, keyword}`, the same idiom the model's `commands/0` uses. The keyword MAY carry `name:`, `config:`, `injectors:` and `mocks:`; any other key, including `expansion:` until a decision record introduces expansions, MUST be rejected as an unknown option. The framework SHALL normalize every entry to a `%PropertyDamage.Target{}` with the fields `adapter`, `name`, `index`, `config`, `injectors` and `mocks`, where `index` is the zero-based position of the entry in the list.

#### Scenario: Minimal target specification

- **WHEN** a target is specified as `MyAdapter` or `{MyAdapter, []}`
- **THEN** the framework SHALL name the target after the last segment of the module name, with no index suffix
- **AND** SHALL pass `%{}` to `setup/1`
- **AND** SHALL give the target no injectors and no mocks

#### Scenario: Named target with configuration

- **WHEN** a target is specified as `{MyAdapter, name: "prod", config: %{url: "http://prod"}}`
- **THEN** the framework SHALL use "prod" as the name
- **AND** SHALL pass `%{url: "http://prod"}` to the adapter's `setup/1` unchanged

#### Scenario: Keyword configuration is rejected

- **WHEN** a target's `config:` is a keyword list instead of a map
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError` naming `config:`
- **AND** SHALL NOT convert the keyword list to a map

#### Scenario: Default name is stable under reordering

- **WHEN** the entries of a `targets:` list are reordered
- **THEN** every target without `name:` SHALL keep the name derived from its module
- **AND** only its `index` SHALL change

### Requirement: The First Target Is the Reference (DR-043)

The first entry of the `targets:` list SHALL be the reference target. The framework MUST NOT accept a per-target `role:` option, so a list has exactly one reference by construction. `PropertyDamage.Differential.Result` SHALL report the reference and the targets as `%{index, name}` pairs.

#### Scenario: Reference by position

- **GIVEN** a `targets:` list of `[{ImplA, name: "a"}, {ImplB, name: "b"}]`
- **WHEN** a differential run completes
- **THEN** the result's `reference` SHALL be `%{index: 0, name: "a"}`
- **AND** its `targets` SHALL be `[%{index: 0, name: "a"}, %{index: 1, name: "b"}]`

#### Scenario: Role option is removed

- **WHEN** a target entry carries `role:`
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError` with the message "targets entry 0: `role:` was removed; the first `targets:` entry is the reference" (the index is that of the offending entry)

### Requirement: Target Names Are Unique (DR-043)

Two entries of one `targets:` list that resolve to the same name, whether derived or given, MUST be rejected before any command executes.

#### Scenario: Same adapter twice without names

- **WHEN** `targets:` lists `MyAdapter` twice
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError` whose message states that two `targets:` entries resolve to the name "MyAdapter" and asks for a distinct `name:` on each
- **AND** no command SHALL execute

#### Scenario: Same adapter twice with distinct names

- **WHEN** `targets:` lists `{MyAdapter, name: "a"}` and `{MyAdapter, name: "b"}`
- **THEN** the framework SHALL accept the list and treat the entries as distinct targets

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

The framework SHALL compare two or more full `RunTrace` records (DR-033) of the same plan to help a human or an LLM localize regressions and flakiness. All compared traces MUST share a plan identity: equal `plan_fingerprint` (DR-036) and equal model — raw sequence equality is explicitly NOT the oracle, since the fingerprint is the canonical identity and excludes derived registry state. The framework SHALL refuse or clearly flag a comparison of traces that do not share plan identity, treating an unequal fingerprint or a differing `plan-generated` command-field value (DR-034) as the incomparability signal. Trace capture SHALL be provided by `RunTrace.capture/1` (run one full, unshrunk plan, pass or fail); comparison SHALL operate over `PropertyDamage.RunComparison`, which consumes traces and never runs a SUT. Comparison SHALL NOT consume shrunk failure reports: a shrunk sequence is a different, smaller plan that cannot be aligned against a full run (a `plan_source: :shrunk` trace is comparable only against traces of the same shrunk plan). Run comparison SHALL be the framework's flakiness facility: `RunComparison.investigate/1` SHALL provide single-seed flakiness sugar (same plan, N captures, a fresh recorded `run_nonce` per capture), and `RunComparison.scan/1` SHALL provide the corpus counterpart — for each of a list of seeds it captures N traces, reduces them to a per-seed verdict (flaky?, outcome partition, distinct failure signatures), and SHALL keep memory bounded by discarding a seed's traces before capturing the next, retaining the full comparison only for flaky seeds. A seed SHALL be judged flaky when its runs disagree on pass/fail or its failing runs carry distinct failure signatures. Rows SHALL be commands and their events (two levels; SUT-call / request-body rows are out of scope for this requirement); event-log entries carrying no command index (injector, telemetry) belong to no step and are excluded from comparison in this version — a stated limit, while nemesis and injected events attributed to commands (DR-030) do participate. Columns SHALL be runs, grouped by outcome (passing versus failing) but otherwise peers, so any run may be compared against any other. In addition to command and event rows, the comparison SHALL include per-command projection-**state** rows (DR-040): each projection's canonical (fold-order-independent) per-step state SHALL be flattened into leaf-path fields and classified by the same discriminative machinery, so a regression or flake visible only in derived state is localized and ranked. Because canonical state ignores async fold timing, an async fold-order difference between two runs SHALL NOT be able to manifest as a state divergence. A projection whose derived state varies WITHIN an outcome group (same plan, same outcome, different state) SHALL be surfaced as a possible non-pure-projection warning, distinct from the comparability guard.

#### Scenario: Comparability guard

- **WHEN** run comparison is asked to compare traces whose plan fingerprints differ, or where a `plan-generated` command field differs between them
- **THEN** the framework SHALL treat the traces as not comparable and SHALL surface this rather than emit a misleading diff

#### Scenario: Command and event alignment

- **WHEN** traces are aligned
- **THEN** commands SHALL align by their branch-aware step position, which is identical across same-plan runs
- **AND** events within a command SHALL align by a longest-common-subsequence keyed on event struct module, so a value difference within a matched event is distinguished from an inserted or removed event
- **AND** a model MAY supply a per-event identity function to override the default module key

#### Scenario: Discriminative analysis across multiple runs

- **WHEN** more than one passing run is compared against one or more failing runs
- **THEN** the framework SHALL classify each aligned field difference by its correlation with outcome: a difference that also varies among the passing runs SHALL be ranked as incidental, a difference that is stable within each outcome group but differs between groups SHALL be ranked as discriminating, and any other pattern SHALL be ranked as weak
- **AND** the framework SHALL emit a ranked list of the most discriminating differences
- **AND** with a single passing run the analysis SHALL degrade to a plain pairwise diff

#### Scenario: Corpus flakiness scan with bounded memory

- **WHEN** `RunComparison.scan/1` is asked to scan a list of seeds, capturing N runs of each
- **THEN** the framework SHALL return a verdict per seed carrying whether it is flaky, the passing/failing outcome partition, and the distinct failure signatures observed
- **AND** a seed whose N runs all share one outcome (all passing, or all failing with one signature) SHALL be reported not flaky and SHALL NOT retain its traces, while a flaky seed MAY retain its full comparison so the divergence is available without a re-run

#### Scenario: Mixed failure signatures are surfaced

- **WHEN** the failing group contains traces with distinct failure signatures (different failure type or check)
- **THEN** the framework SHALL surface the heterogeneity rather than silently pool unlike failures into one group, since pooling would corrupt the within-group stability measure

#### Scenario: Timing-dependent repetition is not noise-ranked

- **WHEN** aligned commands differ only in the repetition count of consecutive same-module events (for example settle/probe polling, whose count is timing-dependent)
- **THEN** the framework SHALL rank that difference as incidental rather than reporting a cascade of inserted-event differences

#### Scenario: Provenance-aware highlighting

- **WHEN** an aligned difference is rendered
- **THEN** `run-scoped` values (DR-034) that differ SHALL be shown as correlation identifiers rather than flagged as suspicious
- **AND** `server-resolved` differences SHALL be the subject of the discriminative ranking

#### Scenario: Projection-state divergence is ranked (DR-040)

- **WHEN** two runs of the same plan derive different canonical projection state at some step (for example a passing run and a failing run whose difference is cleanest in derived state)
- **THEN** the framework SHALL emit a `{:state, position, projection, path}` field carrying each run's value at that leaf, classified by the same discriminating/incidental/weak machinery
- **AND** the difference SHALL be attributable, never a product of async fold-order skew, because the compared state is canonical (fold-order-independent)

#### Scenario: Non-pure projection advisory

- **WHEN** a projection's derived state varies within a single outcome group across runs of the same plan
- **THEN** the framework SHALL surface that projection as a possible non-pure-projection warning (its `apply/2` likely read a clock, counter, or environment), separately from the incomparability guard

#### Scenario: Self-contained report artifact

- **WHEN** a comparison report is produced
- **THEN** it SHALL be a single self-contained HTML file with no external dependencies, embedding the machine-readable comparison data in one JSON block and rendering a static human-readable table that JavaScript MAY enhance with interactivity
- **AND** the embedded JSON SHALL follow a defined, versioned schema (positions, struct values, and non-JSON scalars have specified encodings; the blob carries a `schema_version`)
- **AND** it SHALL carry a reproducibility header naming the model, adapter, UTC timestamp, source revision, seed, run number, and per-run `run_nonce` and `mint_epoch`

#### Scenario: Semantic-difference row highlighting

- **WHEN** an aligned row (command or event) has a semantic difference across runs
- **THEN** the row SHALL be highlighted in a color distinct from the pass/fail green and red (for example, amber)
- **AND** the specific differing attributes within the row SHALL be highlighted per diff convention (added, removed, changed)
