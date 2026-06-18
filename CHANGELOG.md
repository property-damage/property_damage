# Changelog

All notable changes to PropertyDamage will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - TBD

This cycle made the headline features that 0.1.0 advertised actually work end to
end, and trimmed the documented surface to what has been validated.

### Added

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
- Decision Records under `docs/decisions/` (DR-001–DR-021).
- `credo` as a dev/test lint (non-blocking in CI); `PlaceholderRegistry.resolve/3`.
- Documentation of the command sequence generation loop in the
  `PropertyDamage.Model` moduledoc.
- New guide: "Building Reusable Components" (`guides/reusable_components.md`).
- New guide: "Mutation Testing" (`guides/mutation_testing.md`).

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

### Removed

- Removed the unvalidated genetic-algorithm guided generation (`GuidedRunner`
  and the `TargetedGeneration` behaviour). The search was never shown to
  outperform random generation and had no test coverage. Planned for a future
  release with a proper validation harness.
- Removed the interactive Livebook visualization (`PropertyDamage.Livebook` and
  `PropertyDamage.Livebook.Charts`). The widgets read a run-result shape the
  engine does not emit, so they could not work as shipped. Failure-to-notebook
  export (`PropertyDamage.Export` Livebook output) is unaffected. Planned for a
  future release built on a real result/telemetry source.
- **BREAKING**: Removed the deprecated symbolic-reference mechanism, fully
  superseded by `external()` markers (DR-011/DR-021): the `PropertyDamage.Ref`
  module, the `%Ref{}` struct and `Ref.symbolic/1`, the `creates_ref/0` command
  callback (and its `--creates-ref` generator option), and the now-dead `:refs`
  option on `PropertyDamage.execute/2`. Declare server-generated values with
  `external()` on event structs instead. DR-010 is marked superseded.

### Fixed

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

[0.2.0]: https://github.com/property-damage/property_damage/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/property-damage/property_damage/releases/tag/v0.1.0
