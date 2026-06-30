# Changelog

All notable changes to PropertyDamage will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Nemesis generation dispatch (DR-031).** A Nemesis module listed in a Model's
  `commands/0` is now selected by weight during sequence generation and produces
  instances via its `new!/2` callback (Nemesis modules implement `new!/2`, not
  `generator/1`). Its `precondition/1` acts as a generation-time filter, the
  Nemesis analogue of a command's `when:`. Previously a weighted Nemesis would
  fall through to `generator/1` and crash; Nemesis commands only reached the
  runtime when pre-baked into a sequence. A selected Nemesis without `new!/2` now
  raises a clear error instead of an opaque `UndefinedFunctionError`.

### Changed

- **BREAKING (DR-028):** `command_spec/1` is now the single surface for a command's
  *static* metadata. The per-metadata `Command` callbacks are removed:
  `semantics/0`, `settle_config/0`, `read_only?/0`, `idempotent?/0`,
  `acceptable_retry_events/0`, and `downstream_observables/0`. Move each onto the
  spec map (authored via `use PropertyDamage.Command, <opts>` or an explicit
  `command_spec/1`):
  - `def semantics, do: :probe` → `use PropertyDamage.Command, execution: :probe`
  - `def settle_config, do: %{...}` → `use PropertyDamage.Command, settle: %{...}`
  - `def read_only?, do: true` → `use PropertyDamage.Command, shrink: :prefer_remove`
    (read-only IS the `:prefer_remove` shrink hint; there is no separate boolean)
  - `def downstream_observables, do: [...]` → `use PropertyDamage.Command, observables: [...]`
  - `def idempotent?, do: false` → `use PropertyDamage.Command, idempotent: false`
  - `def acceptable_retry_events, do: [...]` → `use PropertyDamage.Command, acceptable_retry_events: [...]`
  The per-instance callbacks `generator/1` (required), `idempotency_key/1`,
  `label/2`, and `awaits/2` are unchanged (they take the command and/or state, so
  they cannot live in a static map). `PropertyDamage.Command.build_spec_from_legacy/1`
  and the legacy branch of `Model.resolve_spec/2` are removed; a command module
  without `command_spec/1` now resolves to the framework defaults (plus any
  Model-supplied overrides). This supersedes the legacy-fallback portion of DR-019.
- **BREAKING (DR-027):** The `Adapter` callback `execute/2` is now `execute/3`:
  `execute(command, user_context, runtime)`. The `user_context` (second argument)
  is now *exactly* what your `setup/1` returned, with no framework keys merged in;
  the framework's per-command affordances move to an explicit
  `%PropertyDamage.Runtime{}` handle (third argument). Migration:
  - `def execute(cmd, ctx)` becomes `def execute(cmd, user_context, runtime)`.
  - `ctx.inject.(event)` becomes `runtime.inject.(event)`.
  - `ctx.start_poller.(opts)` becomes `runtime.start_poller.(opts)`.
  - A `%{stutter: s}` match on the context becomes `runtime.stutter` (prefer
    `PropertyDamage.Runtime.stuttering?(runtime)`); `runtime.stutter` is `nil` on
    the first execution.
  - `delegate_execution/1` now forwards three arguments to the sub-adapter, which
    must also implement `execute/3`.
  This restores the served/servant layering (your data vs. framework plumbing) and
  removes the ambient process-dictionary channels the plumbing used to ride on. As
  a direct consequence, mid-execution `inject` now works from the load-test worker's
  spawned task and from `Differential` targets, which the process dictionary did not
  reach. `teardown/1` is unchanged in arity (it already received your `setup/1`
  return) but is now best-effort: a raising teardown logs a warning instead of
  failing the run.
- **BREAKING (DR-027):** The optional `Adapter.register_handler/2` callback is
  removed. Command/event correlation moves to the semantic surface (see DR-030);
  inbound transport stays with `Adapter.Injector`.
- **(DR-030):** A `@poll_state` liveness timeout is now attributed to the command
  whose event opened the poll window: its `failed_at_index` (previously `nil`) is
  that command's index, so the shrinker keeps locality. Code that asserted poll
  timeouts report `failed_at_index: nil` must update.

### Added

- **`Command.awaits/2` (DR-030):** a new optional, per-instance callback that
  correlates inbound injector events back to the command that owns them. It
  returns `[%PropertyDamage.Await{match}]`, where `match` is a predicate
  `(event -> boolean)` built from the command's resolved fields and captured
  response. A matching injector event is attributed to the declaring command's
  `command_index` (instead of the ambient `nil`), persistently for the rest of
  the run; overlapping matchers resolve to the first-registered with a logged
  diagnostic. This is **pure correlation**: judgment over a command's correlated
  set is expressed in projections (a `@poll_state` for liveness, a
  `@trigger`/`@invariant` for safety/cardinality), reusing the existing assertion
  machinery rather than a separate await loop. This implements, on the correct
  (semantic) surface, the capability the removed `Adapter.register_handler/2`
  advertised.
- **`Command.label/2` rendering (DR-028 amendment):** the optional per-instance
  `label/2` callback, previously declared but consumed nowhere, is now wired into
  failure reporting. When a `FailureReport` is built, each command's label is
  computed lazily (zero cost on passing/generation runs) against its
  `command_sequence_projection` pre-state, reconstructed by folding the shrunk
  sequence in flattened order with the same recipe generation uses. Non-nil
  labels render next to their command in the failure report (terminal, markdown,
  JSON) and as comments in every exported reproduction (ExUnit, curl/bash,
  Python, Elixir, Livebook). Labels are stored in a new `FailureReport`
  `command_labels` field keyed by the flattened (`Sequence.to_list/1`) command
  index. Best-effort: a raising `label/2` degrades to no annotation rather than
  failing the report.

## [0.2.0] - 2026-06-25

This cycle made the headline features that 0.1.0 advertised actually work end to
end, and trimmed the documented surface to what has been validated.

### Added

- Lifecycle-boundary assertions via a new `at:` timing on `@trigger` (DR-024).
  `@trigger at: :teardown` evaluates a synchronous assertion exactly once on the
  fully-settled final projection state (after both `@poll_state` and resource
  pollers have finalized, before `Adapter.teardown/1`); `@trigger at: :startup`
  evaluates it once on the initial `init/0` state before the first command. This
  gives a declarative *safety* primitive ("never exceeds N", "applied at most
  once") to complement `@poll_state`'s *liveness*: a `@poll_state` predicate
  resolves on the transient pass through the expected value and stops watching,
  so it cannot express a bound that is only violated later, whereas the settled
  checkpoint sees the persistent overshoot. Detection rests on the projection
  *accumulating* evidence (a maximum, a sticky flag, a count) rather than
  snapshotting the latest value (the "accumulator contract", documented in the
  projection moduledoc and the eventual-consistency guide). An assertion carries
  exactly one timing (`every:` xor `at:`, enforced at compile time); a failing
  `:startup` check halts before command 1; a `@poll_state` liveness timeout
  preempts the `:teardown` checkpoint; and `Adapter.teardown/1` always runs so a
  failing safety check never leaks SUT resources. Violations report as the
  assertion's named synchronous failure, distinct from a poll timeout.
- Continuous async-observation checking (DR-025). A `@trigger every:` assertion
  now fires on **every observed event**, including events observed
  asynchronously rather than returned by a command: resource-poller and
  injector-adapter events, mock-service events, and nemesis (command-injected)
  events, plus events folded during the finalize-time drains. This makes the
  documented `@trigger every: :event` ("after any event") contract true; until
  now those asynchronous observations were silently skipped. A violation is
  reported **at the offending event**, carrying that event's `command_index`, so
  the shrinker converges to a tight reproduction instead of only surfacing the
  failure at the `at: :teardown` settled checkpoint. There is no new trigger
  surface and no opt-in flag; `@trigger every: :command` remains the opt-out for
  assertions that should fire only after commands. **Behavior change:** a
  `@trigger every:` assertion that previously ran only on a command's own events
  now also runs on asynchronously-observed events of a matching kind. The
  shrinker's failure signature now distinguishes assertion failures by name, so
  distinct assertions are no longer conflated during shrinking (an async-observed
  failure stays equivalent to a `:teardown` failure of the same assertion).
- Invariant catalog and anti-vacuity coverage (DR-026). Assertions now validate
  first-class **invariants** with a stable identity
  (`%PropertyDamage.Invariants.Invariant{id, name, description}`). A projection
  declares invariants centrally with an accumulating `@invariant id: …,
  description: …` attribute, or inline on an assertion with `id:`; other
  assertions link to one with `validates: :id`. An assertion with neither owns a
  same-named invariant by default, so existing models gain a populated catalog
  with no changes. Identity is per projection: ids are unique within a
  projection and `validates:` resolves locally, checked at compile time
  (duplicate id and dangling `validates:` are `CompileError`s; an invariant with
  no check warns as statically vacuous). `PropertyDamage.Model.assertion_catalog/1`
  returns the model-wide catalog keyed `{projection, id}` with each invariant's
  checks and per-check kind (`:synchronous` / `:lifecycle` / `:polling`). The
  engine records **per-assertion firing** across the whole run at every
  evaluation site (synchronous `every:`, lifecycle `at:`, async observations,
  and `@poll_state` spawn, where spawning counts as firing), exposed on the
  result as `assertion_fires`. `PropertyDamage.assertion_coverage(result, model)`
  joins those firings against the catalog with no re-execution, reporting which
  invariants were actually exercised: an `@trigger every: RareEvent` that never
  triggers was a silent vacuous pass and is now visibly uncovered. A verbose run
  prints a terse `Invariants: N/M exercised` footer;
  `Coverage.meets_threshold?(tracker, assertion_coverage: 100)` fails CI on any
  uncovered invariant; failure reports headline the invariant's name and
  description with the failing check as secondary detail. This also completes the
  previously-stubbed `Coverage` "check coverage" (per-assertion fire counts now
  populate `check_hits`) and makes the long-documented `coverage: true` run
  option real: it accumulates the heavier command/transition/state dimensions
  across **all** generated sequences (attached to the success stats as
  `:coverage`), where before they silently reflected a single representative
  sequence. The additive surface (`@invariant`, `validates:`, inline
  `id:`/`description:`, `assertion_fires`, `coverage: true`) is backward
  compatible.
- `mix pd.replay <failure-file> [--verbose]` replays a saved `.pd` failure
  against the SUT. It loads the failing run (model and adapter are read from the
  file itself, so no flags are needed), re-executes the shrunk sequence through
  the real engine, prints each step and a verdict, and reports the outcome as an
  exit code: `0` when the bug is fixed (good), `1` when it reproduces (bad), and
  `125` when the replay could not run at all (the project does not compile, the
  file fails to load, it records no model/adapter, or the sequence is branching).
  The `125` case is indeterminate rather than a reproduction, which is exactly
  the "skip" signal `git bisect run` needs, so the task drops into a CI gate or
  `git bisect` directly. A thin shell over `PropertyDamage.load_failure/1` and
  `PropertyDamage.replay/2`; use those for custom adapter config or stutter.
- `mix pd.bisect <failure-file> --good <ref> [--bad <ref>] [--verbose]` finds the
  first commit where a saved failure starts reproducing, by driving `git bisect`
  and replaying the failure at each candidate commit (classified via
  `mix pd.replay`'s `0`/`1`/`125` exit code, so un-runnable commits are skipped,
  not blamed). It validates a clean working tree up front, copies the `.pd` file
  outside the tree so it survives checkouts, and always runs `git bisect reset`
  at the end. It replays the saved concrete shrunk sequence (not a re-generation
  from the seed), so the search is robust across commits that changed generators,
  weights, or `when:` predicates (DR-023).
- `mix pd.reshrink <failure-file> [--strategy quick|thorough|exhaustive]
  [--max-iterations N] [--max-time-ms N] [--output PATH | --overwrite]` re-runs
  the shrinker over a saved `.pd` failure with a larger budget, to squeeze out
  reductions the original run missed. It prints the before/after command counts
  and, by default, writes nothing; `--output`/`--overwrite` persist the smaller
  report to an explicit location. Re-shrink is not a pass/fail gate, so it exits
  zero on any successful run (reduced or already minimal) and non-zero only on a
  real error. A thin shell over `PropertyDamage.load_failure/1` and
  `PropertyDamage.shrink_further/2`; use the latter for a custom adapter config.
- Unified progress reporting (DR-022): all long-running operations
  (`PropertyDamage.run/1`, `PropertyDamage.Mutation.run/1`,
  `PropertyDamage.Differential.run/1`, and load tests) now report through a single
  derived projection, a `%PropertyDamage.Progress{}` value fanned out to zero or
  more consumers. Each operation accepts an `on_progress:` consumer and emits
  coarse `[:property_damage, <operation>, :progress | :result]` telemetry events
  (`<operation>` is `:test_run`, `:load_test`, `:mutation`, or `:differential`),
  additional to and distinct from the existing fine-grained `run/1` spans. With no
  consumers attached (verbose off, no `on_progress:`, no telemetry handler), no
  `%Progress{}` is built (zero cost on the hot path). `Differential.run/1` gained
  an `on_progress:` option.
- `external()` server-generated field markers now work end to end (DR-021):
  placeholders are created during generation, transported to execution via the
  `Sequence` registry, captured by the producing command's structured position,
  and remapped through shrinking. New consumer-routing helpers
  `PropertyDamage.Generator.available_externals/2` and `external_from/2`.
- `external()` values are now captured from events emitted mid-execution via
  `ctx.inject` (not just events returned from `execute/2`), so a producer can
  inject its server-generated id and downstream commands resolve it.
- The model-free `PropertyDamage.execute/2` path now resolves `external()` values
  across commands: a consumer carrying a `%Placeholder{}` for an earlier
  producer's field receives the captured concrete value.
- `PropertyDamage.Differential.run/1` and load tests now capture and resolve
  `external()` values across commands too (DR-021), so command sequences that
  chain a server-generated id work on every execution path. Differential keeps a
  per-target registry, so the same consumer resolves to each adapter's own value;
  the load test worker resolves per worker. Previously differential passed
  unresolved placeholders straight through and the load test worker raised on the
  first one.
- Decision Records under `docs/decisions/` (DR-001–DR-026).
- `credo` as a dev/test lint (non-blocking in CI); `PlaceholderRegistry.resolve/3`.
- Documentation of the command sequence generation loop in the
  `PropertyDamage.Model` moduledoc.
- New guide: "Building Reusable Components" (`guides/reusable_components.md`).
- New guide: "Mutation Testing" (`guides/mutation_testing.md`).
- Seed library replay (DR-023): `PropertyDamage.run/1` gained a top-level
  `seed_library:` option (`false` (default) / `true` / path) and
  `seed_library_prune_after:` (default 3). When enabled, previously-failing seeds
  are replayed before random exploration; a still-failing replay halts the run
  with a shrunk report and a summary, all-passing replays proceed to exploration,
  and a new exploration failure's seed is appended (deduplicated). The library is
  an ephemeral, self-pruning working set (a `consecutive_passes` streak per
  entry, pruned after `K` passes), not a durable corpus — export to ExUnit for
  durable regressions. The replay phase reports through the unified progress
  projection via a new `ReplayUpdate` payload and prints an unconditional banner
  (and a halt summary) to stdout.

### Changed

- **BREAKING**: The load test's `on_metrics:` and `on_complete:` options are
  removed in favor of `on_progress:`, which receives `%PropertyDamage.Progress{}`
  values (periodic `LoadUpdate` snapshots and a terminal `LoadResult`).
  `metrics_interval:` is retained as the snapshot cadence.
- **BREAKING**: `PropertyDamage.Mutation.run/1`'s `on_progress:` now receives a
  `%PropertyDamage.Progress{}` (a `MutationUpdate` per mutation, then a terminal
  `MutationResult`) instead of a raw result map.
- `verbose:` output for `run/1`, `Mutation.run/1`, and `Differential.run/1` is now
  produced by a built-in progress consumer rather than inline printing; the
  printed output is unchanged.
- A command spec's `with:` override that targets a field the command does not
  define now raises a clear `ArgumentError` naming the command and the offending
  field(s), instead of an opaque `KeyError` deep inside generation. Such an
  override never took effect (the generated map is built into the command struct,
  which rejects unknown keys), so this surfaces a silent misconfiguration early.
- **BREAKING**: Renamed `state_projection/0` to `command_sequence_projection/0`
  (clearer name: returns the projection used for command sequence generation).
- **BREAKING**: Renamed `extra_projections/0` to `assertion_projections/0`
  (clearer name: these projections verify invariants).
- **BREAKING**: Removed the weight-first `{weight, Module}` command-spec form.
  It was undocumented, absent from the `command_spec` typespec, and inconsistent
  with every other (module-first) form. Use `{Module, weight: n}` (or
  `{Module, weight}`). `mix pd.scaffold` / `mix pd.gen.model` now emit the
  keyword form, and all moduledoc examples were updated.
- Sequence generation is now a pure function of the run seed (seeded
  `StreamData`), so a reported seed reproduces the failing sequence exactly.
- Probe/async settle behaviour is sourced from the command spec (DR-019) at
  execution time.
- Trimmed the README, feature list, and docs to the validated surface. Several
  modules (load testing, mutation testing, invariant suggestions, failure
  intelligence clustering/verification, production forensics, flakiness
  detection, and the telemetry dashboard) are documented
  as work in progress and grouped separately; the inaccurate "AI-powered"
  framing of `Suggestions` was removed and a chaos/Toxiproxy caveat added to the
  nemesis docs. ex_doc modules are now grouped by tier and all guides are
  surfaced.
- Guides use seeded selection (`StreamData.member_of`) instead of `Enum.random`,
  and valid `external()` struct syntax.
- **BREAKING**: `PropertyDamage.SeedLibrary` is reframed as an ephemeral replay
  working set (DR-023). The per-entry `run_count`/`fail_count`/`status`
  (`:failing`/`:fixed`/`:flaky`) tri-state is replaced by a single
  `consecutive_passes` streak, and `record_run/3` now uses streak semantics plus
  a `prune/2` step. The library file version is bumped to 2; `load/1` tolerates
  older files. `save/2` is now atomic (temp file + rename). `stats/1`/`format/1`
  reflect the new schema. `get_seeds/2` and `seed_values/2` are removed (they
  filtered on the now-gone status field).
- **BREAKING**: `PropertyDamage.Regression`'s `dedup_source` collapses to
  `:failures` only (default `:failures`); the `:library` and `:both` values are
  removed. The library branch always returned no comparable failures, so dedup
  behavior is unchanged.

### Removed

- Removed the unvalidated genetic-algorithm guided generation (`GuidedRunner`
  and the `TargetedGeneration` behaviour). The search was never shown to
  outperform random generation and had no test coverage. This is not planned for
  re-implementation: command weighting (`weight:`), `when:`/`with:` shaping, and
  longer sequences already cover reaching deep states, and the narrow target
  class where an evolutionary search would add value did not justify the
  machinery.
- Removed the interactive Livebook visualization (`PropertyDamage.Livebook` and
  `PropertyDamage.Livebook.Charts`). The widgets read a run-result shape the
  engine does not emit, so they could not work as shipped. Failure-to-notebook
  export (`PropertyDamage.Export` Livebook output) is unaffected. This is not
  planned for re-implementation: it was packaging over capability that already
  exists or never did. Failure exploration is covered by the `FailureReport`
  formatter, its `Inspect` impl, and `Export.LiveBook.generate/1` (a real,
  executable per-step notebook); live monitoring is a few cells over the live
  `Telemetry.Collector`; and the run-history charts depended on per-command
  trace data the engine has never captured.
- **BREAKING**: Removed the deprecated symbolic-reference mechanism, fully
  superseded by `external()` markers (DR-011/DR-021): the `PropertyDamage.Ref`
  module, the `%Ref{}` struct and `Ref.symbolic/1`, the `creates_ref/0` command
  callback (and its `--creates-ref` generator option), and the now-dead `:refs`
  option on `PropertyDamage.execute/2`. Declare server-generated values with
  `external()` on event structs instead. DR-010 is marked superseded.
- **BREAKING**: Removed `PropertyDamage.SeedLibrary`'s `export`/`import` functions
  and all "share across a team / build a regression suite" framing (DR-023). The seed
  library is a local, ephemeral working set; `save`/`load` are the only
  persistence. Durable, shareable regressions belong to the Export subsystem
  (ExUnit), which freezes the concrete shrunk sequence.

### Fixed

- Converted-branching shrinks now truncate at the linear failure index. When a
  branching sequence converted to linear during shrinking, the linear phase
  received the original *branch-relative* failure index, which for a failure in
  the second or later branch is smaller than the command's position in the
  flattened sequence; truncation cut too short, was rejected by the still-fails
  guard, and left the full sequence to the budget-bounded one-by-one fixpoint,
  which on long sequences could exhaust its budget and return a non-minimal
  reproduction. The convert step now derives the failure index from its own
  linear re-run, so truncation targets the real failure point.
- The settled final state now folds in late resource-poller events even when no
  `@poll_state` poller is active. Previously the finalize-time drain only ran to
  feed `@poll_state` predicates, so a run with resource pollers but no
  `@poll_state` left events that arrived after the last command unfolded. A final
  event-queue drain in result finalization makes the settled state (used by
  `@trigger at: :teardown` and the reported projections) reflect every observed
  event.
- `PropertyDamage.shrink_further/2`'s documented option defaults no longer drift
  from the code: it listed a phantom `:max_iterations` default of 5000, but the
  defaults are strategy-derived (`:thorough` is 2000 iterations / 60_000 ms). The
  docs now describe the per-strategy budget table.
- Standalone reproduction scripts (curl/python/elixir/livebook) now wire
  server-generated `external()` values (DR-021): the producing command's response
  field is extracted (by the `%Placeholder{}`'s path) and referenced by downstream
  consumers, instead of being rendered as an inert `<Placeholder:...>` literal. The
  deprecated name-guessing ref extraction (which never matched what consumers
  referenced) is removed from the script generators.
- `PropertyDamage.Mutation.run/1` could not execute end to end: the runner passed
  the `MutatingAdapter` struct as the `:adapter` option, which option validation
  rejects and the executor cannot dispatch on. It now passes `MutatingAdapter` as
  the adapter module with the struct threaded through `adapter_config`, matching
  the adapter's design.
- `PropertyDamage.Integration.health_check/1` crashed instead of returning
  `{:error, _}` when no usable HTTP client was available: the `httpc` fallback
  called `:inets.start()`/`:ssl.start()` unconditionally and `:ssl.start/0` raises
  when `:ssl` is not loadable. The fallback is now guarded and degrades to an
  error result, honouring the documented `:ok | {:error, term()}` contract.
- `Coverage.new/1` mis-parsed command specs: it read the raw command list with a
  weight-first `{_weight, cmd}` pattern, so the documented `{Module, weight: n}`
  keyword form bound the options list as the "command". It now routes through
  `Model.normalize_commands/1` and handles every spec form.
- Configuration validation, the `pd.validate`/`iex` helpers, and the
  no-valid-commands error formatter iterated `normalize_commands/1`'s
  `{weight, module, spec}` output with a stale two-element `{_weight, cmd}`
  pattern, so most of `Validation` was a silent no-op (command-existence,
  `downstream_observables`, and orphan-event checks never ran) and the error
  formatter raised. Corrected to the three-element form. `mix pd.validate` and
  `PropertyDamage.IEx.check_preconditions/2` also checked the obsolete
  `new!/2`/`precondition/1` API; they now check `generator/1` and evaluate the
  spec's `:when` predicate.
- Step-by-step `Replay` rebuilt as a stepping shell over the executor (it
  previously could not execute a single step against any model).
- Eventual-consistency pipeline rebuilt: probe/async settle and `@poll_state`
  polling now function (the latter previously crashed the run on the first
  command).
- Branching/parallel execution, linearization checking, and branch-aware
  shrinking rebuilt.
- Hierarchical shrinking index handling; placeholder resolution is preserved
  through shrinking.
- Failure output made crash-proof (JSON serialization, error classification,
  formatter). Malformed adapter returns, raising adapters, and raising
  projections now produce graceful failure reports instead of crashing the run.
- Nemesis auto-restore now actually runs: faults whose `duration_ms` elapses are
  lifted between commands, and any still-active faults are restored at sequence
  end (`restore/2` previously had no call sites despite the behaviour promise).
- Nemesis silent no-ops are gone: the Toxiproxy-backed network nemeses
  (`NetworkLatency`, `NetworkPartition`, `PacketLoss`) tag their events with
  `simulated: true` when Toxiproxy is not configured, so a fault that injected
  nothing can no longer be mistaken for a real one (`Nemesis.simulated_event?/1`
  reads the marker). All 10 nemesis implementations are now audited (real
  injection or honest simulation) against a live Redis + Toxiproxy bench.
- `mix pd.scaffold` now emits a suite that actually compiles and runs against a
  live HTTP API (validated end to end against a real OpenAPI spec). The
  generated adapter previously returned `{:ok, response}` (the raw body), which
  the executor rejects as a malformed return, and collapsed every non-2xx to an
  `{:error, _}` the run halts on. It now maps each completed HTTP response
  through the command's `events/3` (status-aware, so a `404`/`409` can be an
  observation) and returns `{:ok, events}`; transport failures stay
  `{:error, _}`. Also fixed: missing `@impl true` on generated `read_only?/0`,
  the adapter missing the required `timeout/1` callback (now `use
  PropertyDamage.Adapter`), an undefined-`Req` warning under
  `--warnings-as-errors`, non-`mix format`-clean output, and a moduledoc that
  taught a nonexistent `new!/2`/`Faker`/`Req.post!` API.

## [0.1.0] - 2024-12-27

### Added

#### Core Framework
- Stateful property-based testing with commands, events, and projections
- Two-phase execution (symbolic and concrete)
- Symbolic references for entity IDs
- Automatic shrinking of failing sequences
- Seed-based reproducibility

#### Command System
- `PropertyDamage.Command` behaviour for defining operations
- Two-layer generator architecture (`generator/1` and `new!/2`)
- Command preconditions for state-aware generation
- Ref extraction for entity relationships

#### Projections
- `PropertyDamage.Projection` behaviour for state tracking
- State projections for model state
- Assertion projections for invariant checking
- Configurable check triggers (`:always`, `:end_of_sequence`)
- Sampling support for expensive checks

#### Model System
- `PropertyDamage.Model` behaviour for test configuration
- Weighted command selection
- Lifecycle hooks (`setup_each/1`, `teardown_each/1`)

#### Adapter System
- `PropertyDamage.Adapter` behaviour for SUT integration
- Setup and teardown lifecycle
- Context passing between executions

#### Parallel Execution
- Branching sequences for race condition testing
- Linearization checking for parallel results
- Parallel shrinking support

#### Shrinking
- Automatic sequence minimization
- Command removal strategies
- Value simplification
- Ref dependency analysis
- Exhaustive shrinking option

#### Analysis & Debugging
- Causal explanation of failures
- Trigger isolation
- Step-by-step replay
- State diff comparison
- Sequence diagrams (Mermaid, PlantUML, WebSequenceDiagrams)
- Diff-based trace comparison

#### Failure Management
- Failure persistence (save/load)
- Seed library for regression testing
- Automatic regression test management
- Failure fingerprinting and clustering
- Similar failure detection
- Fix verification

#### Coverage
- Command coverage metrics
- Transition coverage
- State class coverage
- Multiple output formats (terminal, markdown, JSON)

#### Flakiness Detection
- Non-deterministic behavior detection
- Pass rate analysis
- Likely cause identification

#### Load Testing
- SPBT-based load generation
- Configurable ramp strategies (linear, step, spike, wave)
- Real-time metrics collection
- Report generation

#### Export
- ExUnit test generation
- Script generation (curl, Elixir, Python)
- Livebook notebook generation
- Markdown reports

#### Mutation Testing
- Adapter response mutation
- Multiple operators (value, omission, status, event, boundary)
- Mutation score calculation
- Weakness analysis
- Actionable suggestions

#### Property & Invariant Suggestions
- Model analysis for missing checks
- Pattern detection
- Priority-based recommendations

#### Failure Intelligence
- Pattern detection across failures
- Similarity scoring
- Fix verification with seed variations

#### Chaos Engineering (Nemesis)
- `PropertyDamage.Nemesis` behaviour for fault injection
- Network operations:
  - `NetworkLatency` - Add latency with jitter
  - `NetworkPartition` - Full/asymmetric partitions
  - `PacketLoss` - Simulate packet loss
- Resource operations:
  - `MemoryPressure` - Memory allocation stress
  - `CPUStress` - Scheduler stress
  - `ResourceExhaustion` - File descriptors, ports, ETS, processes
- Time operations:
  - `ClockSkew` - Clock drift and jumps
- Process operations:
  - `ProcessKill` - Kill by name, pattern, supervisor
  - `SlowIO` - Artificial I/O delay
- Security operations:
  - `CertificateExpiry` - TLS certificate failures
- Auto-restore support
- Toxiproxy integration

#### Telemetry
- Comprehensive telemetry events
- Event collector for dashboards
- HTML dashboard rendering

#### Livebook Integration
- Interactive visualization dashboard
- Results tables and command statistics
- Charts (bar, histogram, pie, heatmap, timeline)
- Live monitoring
- Command stepper
- Failure exploration

#### OpenAPI Scaffolding
- Generate command modules from OpenAPI specs

### Documentation
- Comprehensive README with all features
- Example projects (Counter, ToyBank, TravelBooking)
- User guides:
  - Getting Started
  - Writing Effective Invariants
  - Debugging Failures
  - Chaos Engineering with Nemesis
- Interactive Livebook demo notebook
- ExDoc configuration with module groups

[0.2.0]: https://github.com/property-damage/property_damage/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/property-damage/property_damage/releases/tag/v0.1.0
