# Differential Testing Specification

## Purpose

Define the differential testing and mutation testing subsystems that allow PropertyDamage to compare multiple implementations against the same command sequences and to measure test suite quality by injecting faults into adapter responses. A multi-target run is `PropertyDamage.run/1` with several `targets:` entries (DR-045): each target runs as a variant in its own process and the variants advance in lockstep (DR-044). The targets are compared only through the `@compare` boundary observations of the model's projections (DR-046). A divergence is a failure: it ends the run, is shrunk and reproduced, and is reported as a failure report (DR-045). This domain also defines run comparison (DR-035): the post-hoc comparison of two or more full run traces of the same plan, used to localize regressions and flakiness.

## Requirements

### Requirement: Multi-Target Execution

`PropertyDamage.run/1` SHALL run the same command sequences against every entry of `targets:` and compare their results (DR-045). One entry is a run without comparison; two or more entries compare every non-reference target with the first.

#### Scenario: Oracle testing

- **WHEN** `PropertyDamage.run/1` is called with a `targets:` list of two or more entries
- **THEN** the framework SHALL execute the same command sequences against all targets
- **AND** SHALL compare the `@compare` observations of every other target against the first target's (DR-043, DR-046)

#### Scenario: Removed entry point

- **WHEN** a caller looks for a separate differential entry point module
- **THEN** none SHALL exist; the multi-target entry point is `PropertyDamage.run/1` (DR-045)
- **AND** the helpers for comparing values SHALL live in `PropertyDamage.Equivalence` (DR-046)

#### Scenario: Same adapter with different configurations

- **WHEN** multiple targets use the same adapter module with different `name:` and `config:` values
- **THEN** the framework SHALL treat them as distinct targets
- **AND** SHALL execute commands against each target's configured endpoint independently, passing each target's `config:` to its own `setup/1`

### Requirement: Comparison Through `@compare` Observations Only (DR-046)

The framework SHALL compare the targets of a run only through the boundary observations that the model's projections declare with `@compare`. It MUST NOT compare the events of a root across variants, there SHALL be no default observation, and no option SHALL switch comparison between modes. The options `equivalence:`, `compare: :correctness`, `compare: :performance`, `compare: :both` and `compare: [settle: _]` SHALL be removed and rejected.

#### Scenario: Events that differ are not a divergence

- **GIVEN** two targets whose adapters return different events for a root
- **AND** a model whose `@compare` observations agree on both targets
- **WHEN** the run executes
- **THEN** it SHALL pass

#### Scenario: A removed option is rejected

- **WHEN** `run/1` is called with `equivalence:`, with `compare: :correctness`, `:performance` or `:both`, or with `compare: [settle: _]`
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError` whose message names the replacement (`@compare` with `using:`, `latency: true`, or `compare: [converge_within: ms]`)
- **AND** no command SHALL execute

#### Scenario: Agreement is judged by using:

- **WHEN** a boundary observation's reference value and variant value are judged
- **THEN** the framework SHALL call the observation's `using:` predicate with the reference value first
- **AND** SHALL treat `:match` and `true` as agreement
- **AND** SHALL treat `false` and `{:mismatch, detail}` as a difference, whose detail is a `PropertyDamage.ComparisonMismatch` (holding both values or the given text) or the exception given

#### Scenario: A raise is a check failure

- **WHEN** a `@compare` function or a `using:` predicate raises
- **THEN** the framework SHALL report a failure of kind `:check_failed` in the variant where it ran, naming the observation's key
- **AND** SHALL NOT report a divergence

### Requirement: The No-Observation Guard (DR-046)

A run with two or more targets whose model declares no `@compare` function on any projection of `command_sequence_projection/0` and `check_projections/0` SHALL be an error at run start, before any adapter setup, because the variants would never be compared and the run would pass vacuously. A run with one target SHALL NOT call any `@compare` function.

#### Scenario: Two targets and no observation

- **WHEN** `run/1` is given two targets and a model that declares no `@compare`
- **THEN** it SHALL raise `ArgumentError` naming `@compare`
- **AND** no adapter `setup/1` SHALL be called

#### Scenario: One target

- **WHEN** `run/1` is given one target and the model declares `@compare` functions
- **THEN** no `@compare` function SHALL be called

### Requirement: The Convergence Loop (DR-046)

At every boundary at which an observation is scheduled, the framework SHALL run the convergence loop: it SHALL evaluate every scheduled observation in every variant, and while a side is pending or ready sides differ, SHALL drain and fold every variant's event queue, run the async checks, re-read the root in every variant when it is a `:probe` command (the reference and the final boundary included), and evaluate again, until every side is ready and in agreement or the convergence bound expires. No boundary SHALL be skipped. The final boundary SHALL be compared after every variant finalized its run.

The bound is `compare: [converge_within: ms]`, an integer of milliseconds with default `5_000`. It SHALL be measured from the arrival of the last variant at the boundary and checked between iterations, so the loop MAY overshoot the bound by at most one iteration. The loop SHALL evaluate again at most 50 ms after the last evaluation, and sooner when a drain delivered an event, and SHALL re-read a probe root at most once per 50 ms.

Vocabulary: *settle* is one system catching up with itself per adapter call (the per-command `settle:` map); *convergence* is the variants reaching agreement at a boundary; *time to converge* is the measured duration; *did not converge* is a side still pending at the bound; *diverged* is ready sides that differ at the bound.

#### Scenario: A pending side is waited for

- **GIVEN** an observation that returns `{:pending, reason}` in one variant until its asynchronous events arrive
- **WHEN** the events arrive before the bound
- **THEN** the loop SHALL end in agreement and the run SHALL continue
- **AND** the key's `waited_at` SHALL count the boundary

#### Scenario: A side still pending at the bound did not converge

- **WHEN** a side is still `{:pending, reason}` when the bound expires
- **THEN** the framework SHALL report a failure of kind `:did_not_converge` naming the key, the root, the variant and the reason
- **AND** the report SHALL state the time waited and the bound

#### Scenario: Ready sides that differ at the bound diverged

- **WHEN** no side is pending and the sides still differ when the bound expires
- **THEN** the framework SHALL report a failure of kind `:diverged` carrying the key, the root, the reference value, the variant value and the mismatch

#### Scenario: A probe root is re-read

- **GIVEN** a `:probe` root whose first read is stale
- **WHEN** the loop iterates
- **THEN** the framework SHALL execute the root again in every variant, including the reference, under that root's per-command settle
- **AND** the final boundary SHALL be re-read the same way

#### Scenario: The bound overshoots by at most one iteration

- **WHEN** a probe re-read that started before the bound outlasts it
- **THEN** the loop SHALL report after that re-read ends, not earlier and not after a further iteration
- **AND** the time waited in the report SHALL include the overshoot

#### Scenario: A check failure recorded on a final re-read does not stop the re-reads
- **GIVEN** `check_mode: :record` and a variant whose check fails on a final re-read
- **THEN** that variant SHALL keep re-reading with the others

#### Scenario: Convergence bound validation

- **WHEN** `converge_within:` is not a positive integer
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError` naming `converge_within:`

#### Scenario: Expired eventually windows have precedence

- **WHEN** an `@eventually` window expires while the loop runs
- **THEN** the framework SHALL report a failure of kind `:check_failed` at once, without waiting for the bound
- **AND** a polling `@eventually` window that has not expired SHALL NOT keep the boundary from agreeing

### Requirement: Boundary Counters (DR-046)

For every `@compare` key the framework SHALL count `compared_at` (the boundaries at which the key was compared), `waited_at` (the boundaries at which it did not agree at some evaluation) and `waited_ms` (the time spent waiting there). `{:ok, stats}` and a failure report SHALL carry them as `compare_counts`, keyed by `{projection, function}`, and the reporter SHALL print them.

#### Scenario: Counters of a passing run

- **WHEN** a run with two targets passes
- **THEN** `stats.compare_counts` SHALL hold an entry for every declared key, with `compared_at` equal to the number of boundaries at which the key was scheduled

#### Scenario: Counters of one target

- **WHEN** a run has one target
- **THEN** every declared key SHALL be present with zero counts

### Requirement: Latency Measurement (DR-046)

`latency: true` SHALL measure each target's latency per command and put the metrics in `stats.metrics`, keyed by target name, together with `metrics:`, `percentiles:` and `warmup_runs:`. `latency:` defaults to `false`. `latency: true` with `concurrency: :parallel` SHALL be an option error. A run SHALL NOT measure latency unless `latency: true` is given.

#### Scenario: Latency requires serial concurrency

- **WHEN** `latency: true` is configured together with `concurrency: :parallel`
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError` naming `:concurrency` and stating that latency measurement requires `concurrency: :serial`
- **AND** no command SHALL execute

#### Scenario: Metrics under latency: true

- **WHEN** a run with `latency: true` passes
- **THEN** `stats.metrics` SHALL map each target name to its latency metrics, excluding the warm-up runs

### Requirement: Lockstep Concurrency (DR-044)

`PropertyDamage.run/1` SHALL run each generated linear command sequence against every target in lockstep, through `PropertyDamage.Scheduler` (DR-045). Every command of the sequence is a root. For each root `r`, in order, every variant SHALL execute root `r` and stop at boundary `r`; only then SHALL the comparison run, and only after it SHALL any variant start root `r + 1`. The `concurrency:` option SHALL decide how the variants reach a boundary: `:serial` (the default) advances one variant at a time in target order, and `:parallel` advances all variants at the same time. Targets that share one system under `:parallel` MUST isolate their slices of it through `config:`. The option `execution:` MUST be rejected.

#### Scenario: Serial concurrency is the default

- **WHEN** `concurrency:` is not given
- **THEN** the framework SHALL advance the variants one at a time in target order for each root
- **AND** `report.concurrency` SHALL be `:serial` in a failure report

#### Scenario: Parallel concurrency

- **WHEN** `concurrency: :parallel` is configured
- **THEN** the framework SHALL execute root `r` in every variant at the same time
- **AND** SHALL start no variant on root `r + 1` before every variant has reached boundary `r` and the comparison has run
- **AND** `report.concurrency` SHALL be `:parallel` in a failure report

#### Scenario: Unknown concurrency value

- **WHEN** `concurrency:` is any value other than `:serial` or `:parallel`
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError` naming `:concurrency`

#### Scenario: Execution option is rejected

- **WHEN** `PropertyDamage.run/1` is called with `execution:`
- **THEN** the framework SHALL raise `NimbleOptions.ValidationError` with the message "`execution:` was removed; every target runs in lockstep, use `concurrency:` (`:serial`, the default, or `:parallel`)"
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

- **WHEN** the same `seed:` is run twice and an adapter draws random values in `setup/1` (the adapter's `execute/3` runs in a per-attempt Task with its own entropy and is not covered)
- **THEN** each variant SHALL draw the same values in both runs
- **AND** two variants of one run SHALL draw different values, because each variant seeds its process with `:rand.seed(:exsss, :erlang.phash2({Generator.run_seed(seed, run_number), target.index}, 4_294_967_296))`

### Requirement: External Value Capture Per Target

The framework SHALL capture `external()` server-generated values and resolve them into downstream commands during a multi-target run (DR-021), maintaining a separate placeholder registry per target so that the same consumer placeholder resolves to the value each target actually produced.

#### Scenario: Consumer resolved to its target's captured value

- **WHEN** a command produces a value marked `external()` and a later command in the sequence consumes it
- **THEN** the framework SHALL resolve the consumer to the concrete value captured from that target's events before executing it, under both `concurrency: :serial` and `concurrency: :parallel`
- **AND** each target SHALL resolve the consumer to its own captured value, independent of the other targets

#### Scenario: Producer that failed before capture

- **WHEN** a target's producer command errors before its external value is captured, and a later command consumes that value
- **THEN** the framework SHALL NOT call the adapter for the consumer in that target
- **AND** the producer's own adapter error SHALL already have ended the run as a failure of kind `:execution_failed` (see Failures Name the Variant), so no consumer runs after it

### Requirement: Equivalence Helpers (DR-046)

`PropertyDamage.Equivalence` SHALL offer helpers for `using:` predicates: `by_key/1` lifts a 1-arity key function into a predicate comparing the two keys under `==/2` and keeping both keys in the mismatch; `normalize/1` strips the identifier and timestamp keys (`id`, `inserted_at`, `updated_at`, `created_at`, `timestamp`, `uuid`, `request_id`, `correlation_id`) at every depth and unwraps a top-level `{:ok, _}` or `{:error, _}`; `drop_keys/2` removes the given keys at every depth. The framework MUST NOT sort or normalize a value silently.

#### Scenario: by_key compares keys

- **WHEN** `using: by_key(&normalize/1)` judges two values that differ only in an `id`
- **THEN** it SHALL return `:match`
- **AND** WHEN they differ in another field, it SHALL return `{:mismatch, %ComparisonMismatch{}}` holding the two normalized values

#### Scenario: drop_keys keeps struct types

- **WHEN** `drop_keys/2` removes a field from a struct
- **THEN** the result SHALL be a struct of the same type with that field set to `nil`

### Requirement: A Divergence Is a Failure (DR-045, DR-046)

The framework SHALL treat a boundary at which no side is pending and ready sides still differ when the convergence bound expires as a failure of kind `:diverged`, and a boundary at which a side is still pending when it expires as a failure of kind `:did_not_converge`. With several keys failing at one boundary, the framework SHALL report the first in declaration order, and within that key a pending side before a difference. The failure SHALL end the run at that boundary and the campaign: no later run starts. The framework SHALL shrink the command sequence, reproduce the shrunk sequence, and return `{:error, %PropertyDamage.FailureReport{}}` from `run/1`. There SHALL be no list of divergences and no run after a divergence. `{:ok, stats}` SHALL mean that no run failed in any kind.

#### Scenario: Reporting a divergence

- **WHEN** a boundary observation differs across ready sides at the bound
- **THEN** `run/1` SHALL return `{:error, report}` with `report.kind == :diverged`
- **AND** `report.variant` SHALL be `%{index, name}` of the first differing variant in target order
- **AND** `report.failed_at_index` SHALL be the 0-based index of the root
- **AND** the failure reason SHALL be a `%PropertyDamage.Failure{}` of type `Failure.Divergence` carrying `key`, `root`, `command` (the root command), `reference_value`, `variant_value` and `mismatch`
- **AND** `Failure.name/1` of the failure reason SHALL be the `@compare` key `{projection, function}`

#### Scenario: Reporting a failure to converge

- **WHEN** a side is still pending at the bound
- **THEN** `run/1` SHALL return `{:error, report}` with `report.kind == :did_not_converge`
- **AND** the failure reason SHALL be of type `Failure.Convergence` carrying `key`, `root`, `command`, `reason`, the time waited and the bound
- **AND** `Failure.name/1` SHALL be the `@compare` key

#### Scenario: A divergence is shrunk and reproduced

- **WHEN** a divergence or a failure to converge is found in a run
- **THEN** the framework SHALL shrink the sequence with the reference's sequence as the shrink target, running every attempt through every target
- **AND** SHALL accept a candidate only if it fails with the same kind, in the same variant, on the same `@compare` key, at the same or an earlier root
- **AND** `FailureReport.shrunk_sequence/1` SHALL return the shrunk sequence
- **AND** `FailureReport.reproduction_command/1` SHALL print the exact `targets:` entries and `compare: [converge_within: ms]` when the bound is not the default

#### Scenario: Record mode reports an earlier check failure

- **WHEN** `check_mode: :record` is configured and a check failure is recorded at an earlier root, or at the same root in the same or an earlier target
- **THEN** the report SHALL describe the check failure (`kind: :check_failed`) as the primary failure
- **AND** the divergence SHALL be listed in `other_failures`, not replaced

### Requirement: Per-Run Setup and Teardown (DR-044)

`PropertyDamage.run/1` SHALL call `Adapter.setup/1` once per run for every target, in the variant's own process, one variant after another in target order. No variant SHALL execute root 0 before every setup has returned and every `@check at: :startup` check has passed. At the end of the run, whether it passed or failed, every variant that was set up SHALL finalize its run and tear its adapter down. An adapter's `setup/1` MUST be idempotent, because it can find state that an earlier run or a crashed run left behind.

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
- **AND** `run/1` SHALL return `{:error, report}` with `report.kind == :setup_failed`, `report.variant` naming that variant and `report.failed_at_index` equal to `nil`
- **AND** SHALL tear down the variants that were already set up
- **AND** SHALL NOT call `teardown/1` of the variant whose setup failed
- **AND** no command SHALL execute
- **AND** an injector or mock setup that raises inside a target SHALL be a `:setup_failed` failure too
- **AND** the setup failure SHALL go through `on_failure`, the regression handler and the seed-library append like any other failure
- **AND** a setup failure SHALL NOT be shrunk

### Requirement: Failures Name the Variant (DR-044, DR-045, DR-046)

A failure SHALL name the variant `%{index, name}` that failed and the root where one exists. The scheduler's failure SHALL be `%{kind, variant, run, root, reason}`, where `run` is the 0-based run, `root` is the 0-based command index or `nil` when the failure belongs to no command, and `reason` is always a `%PropertyDamage.Failure{}`. `kind` SHALL be one of `:check_failed`, `:diverged`, `:did_not_converge`, `:setup_failed` and `:execution_failed`. The failure report SHALL carry the same `kind` and `variant`, with `failed_at_index` as the root. The `kind` SHALL be derived from the failure reason by `FailureReport.kind_of/1`, so a failure found while the run finalizes is `:execution_failed` when its reason is of the execution class. A failure SHALL end the run at that boundary and the campaign. A failure of kind `:check_failed`, `:setup_failed` or `:execution_failed` SHALL NOT be compared.

An adapter that raises or answers `{:error, _}` at a root SHALL be an `:execution_failed` failure in every mode and SHALL NOT be an observation. A failure of the reference SHALL stop the run. A failure of a non-reference variant at a root SHALL retire that variant at once: the framework SHALL finalize its pollers and run its `:teardown` checks and `Adapter.teardown/1` before the next root starts anywhere, and the other variants SHALL continue and be compared among themselves. The run SHALL stop when no non-reference variant remains. The report SHALL carry as the primary failure the first failure in root order and then target order, and SHALL list the other failures found in the run in `other_failures` (each with the variant, the root and the failure). The primary failure SHALL be the only shrink target. In every run, with or without a retired variant, failures SHALL be ordered by root, then target, then by when they happened within that root and target (a check recorded under `check_mode: :record` while the root was stepped, then the comparison failure at that root's boundary, then a failure found while the target finalized). A failure with no root found at the end of the run SHALL come after every rooted failure, in target order. The first SHALL be the primary failure and every other one SHALL be in `other_failures`. A finalize-time repeat of a failure already found SHALL be listed once, and no failure SHALL be dropped.

#### Scenario: Check failure

- **WHEN** a check fails in one variant, at a command, at the `:startup` phase, or while the run finalizes (an `@eventually` timeout or an `@check at: :teardown` check)
- **THEN** the failure kind SHALL be `:check_failed`
- **AND** `root` SHALL be `nil` for a `:startup` check

#### Scenario: Execution failure

- **WHEN** a variant's adapter raises in `execute/3`, answers `{:error, _}`, a command cannot be executed, or the variant process crashes
- **THEN** the failure kind SHALL be `:execution_failed`, with one target or several
- **AND** the answer SHALL NOT be compared

#### Scenario: Reference failure stops the run

- **WHEN** the reference's adapter fails at root `r`
- **THEN** the run SHALL end with that failure as primary
- **AND** no variant SHALL start root `r + 1`

#### Scenario: A non-reference failure retires the variant

- **GIVEN** three targets a, b and c, where c's adapter answers `{:error, _}` at root `r`
- **WHEN** root `r` completes
- **THEN** c's pollers SHALL be finalized, its `:teardown` checks and its `teardown/1` SHALL run, and c SHALL start no later root
- **AND** a and b SHALL execute root `r + 1` and be compared
- **AND** the report SHALL name c as the primary failure unless an earlier failure exists

#### Scenario: The run stops with no non-reference variant left

- **WHEN** every non-reference variant has failed
- **THEN** the run SHALL end with the primary failure
- **AND** the failures other than the primary SHALL be in `report.other_failures`

#### Scenario: No next root after a failure under serial concurrency

- **WHEN** the reference fails at root `r` under `concurrency: :serial`
- **THEN** no variant after it in target order SHALL execute root `r`

### Requirement: Failure Report Is the Result (DR-045, DR-046)

`PropertyDamage.run/1` SHALL return `{:ok, stats}` or `{:error, %PropertyDamage.FailureReport{}}`. `stats` SHALL carry `runs`, `total_commands`, `seed`, `targets` (a list of `%{index, name}`), `check_fires`, `compare_counts`, `coverage` when requested, and `metrics` keyed by target name under `latency: true`. The failure report SHALL carry `kind`, `variant`, `targets` (the run's entries as `PropertyDamage.Target.to_entry/1` gives them), `concurrency`, `compare` (`[converge_within: ms]`), `compare_counts`, `other_failures`, `stutter` and `max_commands`, and SHALL NOT carry `adapter` or `equivalence`. A setup failure (the adapter's `setup/1`, a setup command, or an unresolved `external()`) SHALL return a `:setup_failed` report whose `failed_at_index` is `nil` (DR-048). The report SHALL also carry `setup_commands` and `teardown_commands`, and `stats` SHALL count setup and teardown commands separately from `total_commands`. There SHALL be no `Differential.Result`.

#### Scenario: Passing multi-target run

- **GIVEN** a `targets:` list of `[{ImplA, name: "a"}, {ImplB, name: "b"}]`
- **WHEN** no run fails
- **THEN** `run/1` SHALL return `{:ok, stats}` with `stats.targets == [%{index: 0, name: "a"}, %{index: 1, name: "b"}]`

#### Scenario: Reproduction names the targets

- **WHEN** a failure report comes from a run with non-default target names, configs or `concurrency:`
- **THEN** `FailureReport.reproduction_command/1` SHALL print the exact `targets:` entries (non-default `name:` and `config:`) and the non-default `concurrency:`

#### Scenario: Reproduction names the run options that decide the outcome
- **WHEN** a failure report comes from a run with a non-default convergence bound, `max_commands:` or with `stutter:`
- **THEN** the report SHALL record `compare`, `stutter` and `max_commands`
- **AND** `FailureReport.reproduction_command/1` SHALL print `compare: [converge_within: ms]`, `stutter:` and `max_commands:`

#### Scenario: Other failures are listed

- **WHEN** a run ends with failures in more than one variant
- **THEN** `report.other_failures` SHALL list each failure other than the primary with its variant, its root and its `%Failure{}`
- **AND** the terminal, markdown and JSON formats SHALL show them

### Requirement: Per-Target Injectors, Mocks and Pollers in Multi-Target Runs (DR-044)

`PropertyDamage.run/1` SHALL honor each target's `injectors:` and `mocks:` in every run, one target or several: the framework SHALL set them up per run for that variant only, and their events SHALL reach only that variant's event queue. `runtime.start_poller` SHALL be allowed in multi-target runs, and a poller's events SHALL reach only the variant that started it.

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

The first entry of the `targets:` list SHALL be the reference target. The framework MUST NOT accept a per-target `role:` option, so a list has exactly one reference by construction. The failure report's `variant` and `targets` and the stats' `targets` SHALL identify targets by `%{index, name}`; the reference has index 0. The model's setup and teardown commands SHALL run in every target, and each target's adapter SHALL realize them with that target's own `config:` (DR-048).

#### Scenario: Reference by position

- **GIVEN** a `targets:` list of `[{ImplA, name: "a"}, {ImplB, name: "b"}]`
- **WHEN** a run of the list diverges in the second target
- **THEN** `report.variant` SHALL be `%{index: 1, name: "b"}`
- **AND** the reference SHALL be the target named "a", at index 0

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
