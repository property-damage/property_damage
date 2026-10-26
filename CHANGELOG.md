# Changelog

All notable changes to PropertyDamage will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`PropertyDamage.Equivalence.within/3`, a tolerance (DR-051).**
  `@compare using: {PropertyDamage.Equivalence, :within, [0.01]}` agrees when
  two numbers differ by at most `0.01`, at every depth of maps, lists and
  tuples of the same shape, and compares any other values under `==`. It is
  the first relation that takes data through `{Mod, :fun, args}`.
- **A divergence records its relation (DR-051).** `Failure.Divergence` carries
  the observation's `using:` term as written in a new `using` field (`nil`
  under `==`), and the printed report shows it on a `Using:` line beside the
  two values. The persistence format stays at version 15.
- **Every observation that disagrees at the convergence bound is reported.**
  The first disagreeing `@compare` key in declaration order still names the
  `:diverged` or `:did_not_converge` failure; every further key that differed or
  was pending at that boundary is listed, in the same order, in the failure
  detail's new `other_keys` field (`Failure.Divergence` and
  `Failure.Convergence`), and the printed report shows each one, also under
  such a failure listed among the run's other failures.
- **Boundary observations: `@compare` (DR-046).** A public projection function
  `def name(state, root)` marked `@compare every: ..., using: ...` is the only
  cross-target oracle. `every:` takes the `@check` schedule vocabulary (`1`, `N`,
  `{N, Module}`, `Module`, `[Modules]`) plus `:end`; `using:` names the
  relation (`:fun`, `{Mod, :fun}` or `{Mod, :fun, args}`, DR-051; default
  `==`), whose return is a verdict (DR-052): truthy to agree, `false` or
  `nil` to disagree holding both values, `{:fail, "text"}` or
  `{:fail, exception}` to disagree with that reason. A function may return
  `{:pending, reason}` while its target is catching up; a pending side is
  never a disagreement. A raise in a `@compare` function or a `using:`
  relation is a check failure naming the key.
  A run with two or more targets and no `@compare` is an error at run start,
  before any adapter setup; with one target no `@compare` function is called.
- **The convergence loop and `compare: [converge_within: ms]` (DR-046).** At
  every scheduled boundary the framework drains and folds every variant, runs the
  async checks, re-reads a `:probe` root in every variant (the reference and the
  final boundary included) and evaluates again, until the sides agree or the
  convergence bound (default 5000 ms, measured from the last variant's arrival,
  at most one iteration of overshoot) expires. A side still pending at the bound
  is `:did_not_converge` (`Failure.Convergence`); ready sides that differ are
  `:diverged`. Both are named by the `@compare` key and report the time waited.
  An expired `@eventually` window is a check failure at once.
- **`PropertyDamage.ComparisonMismatch` and `PropertyDamage.Equivalence` (DR-046).**
  `Equivalence.normalize/1` and `drop_keys/2` normalize a value in an
  observation body, and `by_key/1` lifts a key function into a relation that
  returns `true` or `{:fail, %ComparisonMismatch{}}` holding both keys. `ComparisonMismatch` is the default mismatch detail.
  `PropertyDamage.Verdict.read/1` reads a relation's return with the grammar
  shared with `@check` and `@eventually` (DR-052).
- **Boundary counters (DR-046).** `compare_counts` on `stats` and the failure
  report holds `compared_at`, `waited_at` and `waited_ms` per `@compare` key. The
  reporter prints it, and persistence stores it.
- **`latency: true` (DR-046).** Measures each target's latency per command
  (`p50`, `p95`, `p99`, `mean`, `min`, `max`, `commands` and `by_command`).
  Requires `concurrency: :serial`. DR-047 adds `warmup:` and a budget.
- **The latency budget and failure kind `:latency_exceeded` (DR-047).**
  `latency: [warmup: n, p50 | p95 | p99 | mean: [max: {n, unit}, max_ratio: r]]`
  judges the aggregates once, after the last run: `max:` (a
  `{n, :milliseconds | :seconds | :minutes}` tuple; a bare integer is an option
  error) for every target, `max_ratio:` against the reference (two or more
  targets). A breach is a `:latency_exceeded` failure naming the target,
  statistic, value and limit. It is never shrunk, never re-executed and has no
  replay artifact; re-run the seed to reproduce it. A run that fails for another
  reason ends the campaign first and the budget is not judged. Reports carry
  `latency` and `metrics`.
- **`FailureReport.other_failures` and `Variant.retire/1` (DR-046).** An adapter
  `{:error, _}` or raise at a root is `:execution_failed` in every mode. A failure
  of a non-reference variant retires that variant at once (pollers finalized,
  `:teardown` checks and `teardown/1` run) and the other variants go on; the run
  stops when no non-reference variant remains. The report names the primary
  failure (first by root, then by target order) and lists the rest in
  `other_failures`; only the primary failure is shrunk.
- **Boundary comparison fixes (DR-046).** A function carries one `@compare`,
  written above its first clause; a second on another clause is a compile error.
  Under `check_mode: :record`, a variant whose check failed on a final re-read
  keeps re-reading with the others. Every run, with or without a retired
  variant, orders its failures by root, then target, then when it happened within
  that root and target (a check recorded under `check_mode: :record`, then the
  comparison failure at that root's boundary, then a failure found while the
  target finalized); a failure with no root found at the end of the run (an
  `@eventually` timeout, a `:teardown` check, the reference included) comes after
  every rooted failure, in target order. The first is the primary failure and
  every other one is in `other_failures`; a recorded check at the same root in
  the same or an earlier target becomes primary and the divergence is listed
  there; a finalize-time repeat is listed once and nothing is dropped. New public type
  `t:PropertyDamage.Scheduler.compare_counts/0`.
- **Stutter `using:` (DR-046).** `stutter: [using: {Mod, :fun}]`, called
  `Mod.fun(original_events, retry_events)`, decides whether a retry agrees;
  `{Mod, :fun, args}` and a 2-arity function are accepted too (DR-051), and
  equality is the default. Its return is a verdict, read like `@compare`'s
  `using:` (DR-052).
  `Stutter.compare_events/3` returns `:agree` or `{:disagree, exception}`.
  `Stutter.Violation` carries `mismatch` (an exception) in place of
  `comparison_result`.
- **One runner for one or more targets (DR-045, DR-046).** `PropertyDamage.run/1`
  takes `targets:` with several entries; the first is the reference. New run
  options: `concurrency:`, `compare: [converge_within: ms]` and `latency:`.
  `{:ok, stats}` carries `targets`, `compare_counts` and, under `latency:`,
  `metrics` keyed by target name.
- **`FailureReport` fields `kind`, `variant`, `targets`, `concurrency`,
  `compare`, `compare_counts`, `other_failures`, `stutter` and `max_commands`
  (DR-045, DR-046).**
  `kind` is `:check_failed`, `:diverged`, `:did_not_converge`, `:setup_failed`
  or `:execution_failed` or `:latency_exceeded` (DR-047),
  and always equals `kind_of(failure_reason)`.
  `variant` is `%{index, name}`. `targets` holds the run's entries, so
  `reproduction_command/1` prints the exact target list. It also prints
  `compare: [converge_within: ms]` (when not 5000), `stutter:` and
  `max_commands:` when the run used a non-default value, and `shrink_further/2`
  re-shrinks under the report's `compare` and `stutter` (it accepts `compare:`
  and rejects `equivalence:`). New helpers:
  `FailureReport.kind_of/1`, `reference_target/1` and `targets_source/1`; new
  failure types `Failure.Divergence`, `Failure.Convergence` and `Failure.Setup`.
- **A divergence is shrunk and reproduced (DR-045, DR-046).** It ends the run and
  `run/1` returns `{:error, report}` with `kind: :diverged` (or
  `:did_not_converge`). The shrinker accepts a candidate only with the same
  `{kind, name, variant_index}` at the same or an earlier root, and runs every
  attempt on every target. A divergence is identified by its `@compare` key:
  `Failure.Divergence` carries `key`, `root`, `command`, `reference_value`,
  `variant_value` and `mismatch`, and `Failure.name/1` of a divergence or a
  failure to converge is the key `{projection, function}`, so a candidate that
  diverges on another observation is rejected.
- **Command and check telemetry from the engine (DR-045).**
  `[:property_damage, :command, :start | :stop]` and
  `[:property_damage, :check, :start | :stop]` carry `variant` and `run_number`;
  `[:property_damage, :sequence, :stop]` carries `variant`. `Progress.RunResult`
  gains `kind` and `variant`.
- **`Scheduler.run/1` options `mint_epoch:` and `placeholder_registry:` (DR-045).**

- **`Executor.Stepping.drain/2` and `finalize/2` (DR-044).** `drain/2` folds the
  events waiting in the context's event queue into a stepped state, checking each
  one as it folds. `finalize/2` finishes a stepped run into the result
  `Executor.run/4` reports.
- **Pollers, injectors and mocks in multi-target runs (DR-044).**
  `runtime.start_poller` is allowed in multi-target runs (the old refusal is gone),
  and each target's `injectors:` and `mocks:` are honored. Each belongs to its own
  variant.
- **`PropertyDamage.Variant` and `PropertyDamage.Scheduler` (DR-044).** A variant
  runs one target over a shared command sequence in its own process, through the
  per-command engine; the scheduler advances the variants in lockstep and compares
  them at every root. See the `BREAKING (DR-044)` entry under Changed.

- **`mix pd.validate --targets` (DR-043).** `mix pd.validate MODEL --targets
  EXPR` validates the model against every target of a `targets:` list given as
  an Elixir expression. It warns when two targets use the same adapter with an
  identical `config:`, because such targets share state; give each target its
  own `config:` (for example a tenant).
- **Structured failure vocabulary: `%PropertyDamage.Failure{}` (DR-041).** A run's
  `failure_reason` is now one nested, public type instead of a loose family of
  `{:tag, ...}` tuples. It carries a class struct under `type`
  (`Failure.Assertion` / `Failure.Execution` / `Failure.Framework`) so illegal
  class/kind combinations are unrepresentable, plus a `branch_id` on the envelope
  that absorbs the old `{:branch_failure, id, inner}` wrapper. Kinds are globally
  unique atoms; `Failure.class/1`, `kind/1`, `name/1`, `detail/1`, `branch_id/1`,
  and `partial_events/1` read a failure. See DR-041 for the full class/kind table
  and the `kind in [:poll_timeout, :settle_timeout]` "possibly tuning, not a bug"
  triage note (documented in `guides/debugging_failures.md`).

- **Per-step projection-state timeline + projection-purity check (DR-040).**
  Projection state at any command is now *derived* from the run (no snapshot is
  captured). `PropertyDamage.RunTrace.state_at/2`, `state_before/2`, and
  `state_timeline/1` re-fold the recorded fold order to give the faithful state
  the run actually had (async / injected events land where they folded);
  `canonical_state_timeline/1` is a timing-immune variant used by run comparison.
  The executor records the real fold order additively: `EventLog.Entry` gains a
  `fold_index`, and `RunTrace` gains `command_fold_ordinals` and the verified
  branch `linearization`. `PropertyDamage.FailureReport.verify_projections/1`
  (and `RunTrace.verify_projections/4`) are the projection-purity check — the
  faithful-derived state at the failing step must equal the runtime snapshot; a
  mismatch names the non-pure projection module(s). Because it replays the real
  fold order, a pure-but-async projection does not false-positive.
  `PropertyDamage.audit_projections/2` (run by `mix pd.audit`) is the
  generation-side companion: it folds each generated plan twice and names any
  projection whose `apply/2` is non-deterministic.
- **Projection-state divergence now enters `PropertyDamage.RunComparison`
  ranking (DR-040).** Each projection's canonical per-step state is flattened
  into leaf-path fields and classified alongside command/event fields, so a
  regression or flake that manifests only in derived state is localized and
  ranked. Canonical states are timing-immune, so async fold-order skew can never
  masquerade as a state finding. A new `state_warnings` field (surfaced in the
  HTML report and JSON) flags projections whose state varies within an outcome
  group — a likely non-pure `apply/2`.
- **Load testing and mutation testing are now supported features.** Both were
  previously shipped as work-in-progress modules held out of the docs front page;
  they have now been validated against live SUTs (via the openapi and cachex
  benches) and are promoted to the supported tier. Their guides
  (`guides/load_testing.md`, `guides/mutation_testing.md`) join the main Guides
  group, and `PropertyDamage.LoadTest` and the `PropertyDamage.Mutation` modules
  move out of the "Advanced (work in progress)" documentation group into
  dedicated "Load Testing" and "Mutation Testing" groups. The load-testing guide
  gains a note on writing invariants that stay valid under a shared, never-reset
  SUT.

- **Mock third-party services are now reachable through `PropertyDamage.run/1`
  (WP-C5).** A new `:mock_services` run option accepts a list of
  `PropertyDamage.MockServiceAdapter` modules (or `{module, config}` tuples). Per
  run the framework starts a `PropertyDamage.MockServiceRegistry`, registers and
  `setup/1`s each mock (passing `%{registry: pid, event_queue: pid}` merged with
  the entry's config), drives `on_command/2` before each command, folds the
  events mocks push into projections (`source: :mock`) after each command, and
  tears each mock down at run end. The registry pid is handed to the adapter on
  the `PropertyDamage.Runtime` handle as a new `runtime.mock_registry` field, so
  `execute/3` can drive the mock's `handle_request/2` for an in-process SUT (a
  real HTTP mock drives it from the listener it started in `setup/1`). The same
  registry is reused across a failure's shrink attempts and the reproduction
  re-execution, so a mock-dependent failure keeps reproducing as it minimizes.
  Previously the Executor accepted a `mock_registry` pid but `run/1` never
  threaded one and `handle_request/2` had no caller in the framework, so the
  whole mocking feature was unreachable through the public API. The
  "Mocking Third-Party Services" guide now documents the wired path end to end.

- **Live network fault injection is now reachable through the engine (DR-038).**
  The built-in network nemeses (`NetworkLatency`, `NetworkPartition`,
  `PacketLoss`) discover their Toxiproxy config from the adapter context: return
  `toxiproxy: %{proxy_name: ..., api_url: ...}` from your adapter's `setup/1` and
  the fault injects for real against that proxy. Previously the executor built
  the nemesis context with only `:adapter_context` (never a top-level
  `:toxiproxy`), so through `PropertyDamage.run` these nemeses *always* ran
  simulated no matter how the SUT was proxied; live injection was reachable only
  by hand-calling `inject/2`. Config discovery now checks `context[:toxiproxy]`
  (top-level, still honored for direct calls) then
  `context.adapter_context[:toxiproxy]`. The simulated fallback (no config found
  ⇒ `simulated: true`, no HTTP) is unchanged. The shared plumbing moved to a new
  `PropertyDamage.Nemesis.Toxiproxy` module (config discovery, `:httpc`
  post/delete, URL building, status dispatch, live-vs-simulated decision); the
  three nemeses shrank to a generator, a pure `toxics/1` toxic-spec, and event
  construction.

- **Generation determinism audit (DR-037).** `PropertyDamage.audit/2` and the
  `mix pd.audit` task prove a model's generation is a pure function of the seed:
  they realize the model's generated sequence twice at each of N seeds through
  the seeded path and assert the two are structurally equal (honest raw equality
  post-DR-036, including `external/0`- and `mint_per_run`-using models). Impurity
  in a generator, `when:`/`with:` predicate, `command_sequence_projection`, or
  simulator (reading the clock, `:rand`, `System.unique_integer/1`, or
  `UUID.uuid4/0`) is caught at dev/CI time before it breaks `seed: N`
  reproduction and `RunComparison`'s fingerprint guard. The audit is
  generation-only (no adapter/SUT, never resolves markers/placeholders), threads
  `max_commands`/`branching`, and on divergence localizes the first differing
  command position and fields; `mix pd.audit` exits non-zero so CI gates on it. A
  new `guides/deterministic_generation.md` documents the three deterministic
  seams: a seeded relative time offset reified in the adapter (for
  timeliness-dependent values), `mint_per_run/1` for client-minted uniqueness,
  and `external/0` for server-assigned output.
- **Structural failure-query interface (Phase A).** `FailureReport` gains
  `steps/1`, `event_entries_at/2`, and `failure_step/1` so callers ask the report
  about a failed run's timeline instead of re-walking `shrunk_sequence` /
  `event_log` / `failed_at_index`. `steps/1` returns first-class
  `%FailureReport.Step{position, flattened_index, command, entries, label,
  failed?}` values in flattened reading order. Each step's `entries` are the full
  `EventLog.Entry` structs attributed to the command, in log order, so per-event
  provenance (`source`, `branch_id`; the bare event is `entry.event`) is
  preserved — a nemesis / mock / stutter event stays distinguishable from SUT
  output, and the "Command → Event Timeline" (with its CMD/NEM/MOC/STU source
  badges) is served from `steps/1` rather than a private `event_log` walk. Each
  step also carries a new shared
  `%PropertyDamage.Sequence.Position{section, offset}` (reifying the executor's
  `current_position` tuple, DR-021) that identifies a command unambiguously
  across parallel branches, plus its derived flattened index. New
  `Sequence.indexed/1` owns the position ↔ flattened-index mapping and
  `Sequence.position_at/3` resolves an executor command index to a position.
  `failed?` is matched by position, not by comparing the flattened index to
  `failed_at_index` (an executor index that diverges from the flattened ordinal
  for branch failures); `failure_step/1` is `nil` for non-localized failures.
  This is additive: the materialized `command_at_failure` / `events_at_failure`
  fields and the ~20 existing callers are unchanged (their migration is Phase B).
- **Core adapter timeout (DR-032).** Each `adapter.execute/3` call in an ordinary
  `PropertyDamage.run/1` is now bounded by `adapter.timeout/1` (default 30s, per-command
  override), not just in load-test workers. A wedged `execute/3` now fails with
  `PropertyDamage.CommandTimeoutError` instead of hanging the run. Enforcing a hard
  wall-clock bound requires a separately-killable process, so `execute/3` now runs in
  a short-lived child process. Ecto `SQL.Sandbox` and Mox adapters are unaffected (they
  resolve ownership through the `$callers` chain, which is propagated), but adapters that
  stashed state in the run process's process dictionary or relied on `self()` identity must
  thread that state through `user_context` instead. See the `PropertyDamage.Adapter` module
  docs, "Execution process and the per-command timeout".
- **Nemesis generation dispatch (DR-031).** A Nemesis module listed in a Model's
  `commands/0` is now selected by weight during sequence generation and produces
  instances via its `new!/2` callback (Nemesis modules implement `new!/2`, not
  `generator/1`). Its `precondition/1` acts as a generation-time filter, the
  Nemesis analogue of a command's `when:`. Previously a weighted Nemesis would
  fall through to `generator/1` and crash; Nemesis commands only reached the
  runtime when pre-baked into a sequence. A selected Nemesis without `new!/2` now
  raises a clear error instead of an opaque `UndefinedFunctionError`.
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

- **Setup and teardown commands: `setup_each/0` and `teardown_each/0` (DR-048).**
  A model declares fixtures as commands. Both callbacks are optional and default
  to `[]`; each returns command specs in the grammar of `commands/0` (typed
  `PropertyDamage.Model.sequence`). Setup commands run in every target after
  `Adapter.setup/1` and before the first root, in every run and shrink attempt;
  teardown commands run after the last root and the final checks, whatever the
  outcome, before `Adapter.teardown/1`. A list is a sequence: every entry runs in
  order, and `when:` or `weight:` on an entry draws a `mix pd.validate` warning.
  The generator draws and simulates setup commands before the roots, so
  `overrides:` and `external()` ids flow into later commands, and adding a setup
  command re-draws the roots for a given seed. Setup commands are never compared,
  expanded or shrunk; stutter and nemesis faults are off (a nemesis module in
  either callback is a validation error); teardown commands are best effort.
- **`:setup_failed` carries a cause (DR-048).** `PropertyDamage.Failure.Setup`
  gains `cause` (`:adapter_setup`, `:command`, `:check` or
  `:unresolved_placeholder`), `command`, `setup_index`, `field` and `detail`.
  An `external()` a setup command produced that is still unresolved after the last
  setup command is a setup failure that names the command, the field and the
  target. A setup failure in the reference ends the run before any root; in
  another target, detected before the first root, it retires that target alone
  (a setup-opened `@eventually` window that times out after the first root ends
  the run). It is never shrunk, and a shrink attempt in which setup failed is
  not a reproduction.
- **Setup and teardown commands in reports (DR-048).** `FailureReport` gains
  `setup_commands` and `teardown_commands`, so a report reproduces without
  re-drawing; `stats` and the report count them apart from `total_commands`,
  which counts roots. `PropertyDamage.replay/2`, `RunTrace` and
  `Analysis.isolate_trigger/2` execute them; a branching run executes the setup
  commands before its own prefix segment; exported scripts list the setup steps
  first. Telemetry command events carry `phase: :setup | :root | :teardown`, and
  the coverage summary reports setup commands under a `setup` key.
- **Persistence version 11 (DR-048).** Failure reports and traces store the setup
  and teardown commands; loaders refuse older files.
- **`expansions/0`, roots that run as several commands (DR-049).** The optional
  `PropertyDamage.Model` callback returns `[{Root, fun}]`. `fun` takes the root
  as generated and the target's simulated state, and returns a plain list of
  entries: a sequence of command specs, or `{sequence, weight: n}`. The identity
  is the received struct alone (`[root]`). Every expansion of a root means the
  same as the root once it is done, under every `@compare` value of the model.
  New types `command_spec`, `sequence`, `identity` and `choices(item)`. An
  `overrides:` function of arity 2 (`fn state, prior_leaves -> map end`) reads
  the earlier leaves of the same sequence with their simulated events. A root
  placeholder is aliased to the one leaf that holds the same event module at
  the same field; zero or several matches fail generation. A root with no
  listed entry that fits runs as itself and is counted `:forced`.
- **The `expansion:` target option (DR-049).** `:random` (default) picks an
  entry per root by weight from a seed keyed on the run seed, the target's name
  and the root; `:identity` runs the roots; `:reference` copies the first
  target leaf for leaf. `:reference` on the first or the sole target is an
  option error. Leaves are executed commands for checks, latency and coverage;
  `@compare` schedules, `max_commands` and `total_commands` count roots.
- **`mix pd.validate --seeds N` and `--seed S` (DR-049).** For a model with
  `expansions/0`, the task samples N root sequences (default 100), realizes
  every target's expansions and lists the leaf modules, each entry key with its
  count, the entries never realized and the roots forced to the identity in
  every sampled state. `--seed S --seeds 1` samples what `seed: S, max_runs: 1`
  runs.
- **Report fields `expansions` and `expansion_counts` (DR-049).**
  `FailureReport.expansions` gives, per target name, the entry and leaf modules
  of every executed root up to the failing root, and the reporter prints each
  target's entry at the failing root. `expansion_counts` (also on `stats`)
  counts entries per target and root module, and `:forced`. Coverage derives its
  command universe from generation and counts expanded roots by entry.
- **Telemetry for leaves (DR-049).** `[:property_damage, :command, :start | :stop]`
  metadata carries `root_index` and `leaf_index`, and
  `[:property_damage, :expansion, :leaf_validated]` reports each first
  validation of a leaf module.
- **The shrinker shrinks along the expansion axis (DR-050).** When a run with
  several targets fails, each shrink cycle runs four phases in order: drop root
  subtrees; collapse the reference target's expansion toward the identity at each
  surviving root; collapse each `:random` target onto the reference's choice;
  simplify arguments (generator-chosen fields only, never an `overrides:` value
  or a placeholder). A cycle that makes no progress ends the shrink. A shrunk
  root that runs as itself without being listed is recorded as `:identity` and
  printed "identity, by shrinking". Failure identity is `{kind, name, variant}`
  at the same or an earlier root. A candidate is invalid and never runs when an
  entry is no longer offered for its state, or when its replay artifact could not
  run it again (a placeholder its commands hold that the shrunk roots do not
  mint).
- **`PropertyDamage.Expansion.for/5`.** `for(model, seed, run, name, opts)`
  regenerates the concrete sequence a target ran, without running a target or an
  adapter. `run` is 1-based, and `Expansion.for(Model, report.seed, 1, name)`
  regenerates the failing run as it ran before shrinking.
- **`only:` run option.** `only: [run: n, variants: names, with_reference: bool]`
  runs one run and a subset of targets; `only: [replay: path]` runs a replay
  artifact. Option errors name the rule that failed.
- **`replay_dir:` run option.** Names the directory for replay artifacts
  (default `"property_damage_replays"`); `false` writes nothing.
- **Replay artifact.** Every failure writes
  `<model last segment>_seed<seed>.replay.exs`: one human-readable Elixir literal
  term with a version header. The loader parses it without evaluating code and
  refuses calls, functions, sigils and a second term. Generation refuses a command
  field that holds a function, pid, reference, port, improper list or non-binary
  bitstring, map keys included; the report then says where.
- **`FailureReport` fields and footer.** `run`, `replay_path`, `replay` (the term,
  `{:refused, where}` or nil) and `replay_status`, plus `replay_command/1` and
  `expansion_command/1`. The printed report ends with the reproduction command,
  "Regenerate the failing variant:" and "Replay the shrunk failure:", whose
  `only: [replay: path]` call is the last line.

### Changed

- **BREAKING (DR-051): `using:` names the relation, and `@compare` is a plain
  attribute.** `use PropertyDamage.Model.Projection` no longer replaces
  `Kernel.@/1`: `@compare` is read like `@check` and `@eventually`, so a
  projection module may import its own attribute macros, and
  `PropertyDamage.Model.Projection.CompareAttribute` is removed. `using:` no
  longer takes an expression; it names the relation in one of three forms:

  | Form | Calls |
  |------|-------|
  | `:fun` | `fun(reference_value, variant_value)` in the projection, public or private |
  | `{Mod, :fun}` | `Mod.fun(reference_value, variant_value)`, public |
  | `{Mod, :fun, args}` | `Mod.fun(reference_value, variant_value, arg1, ..., argN)`, public |

  `Mod` may be `__MODULE__`, and then the function may be private; `args` are
  literals. An unknown form, a function value, a missing function and a wrong
  arity are each a `CompileError` naming the observation, the `using:` term
  and the expected arity; a remote relation adds a compile-time dependency on
  its module. Migrate each `using:` as follows:

  | Before | After |
  |--------|-------|
  | `using: &local/2` | `using: :local` |
  | `using: &Mod.fun/2` | `using: {Mod, :fun}` |
  | `using: fn a, b -> ... end` | `using: :name`, with `defp name(a, b), do: ...` |
  | `using: by_key(fn v -> v \|> normalize() \|> drop_keys(keys) end)` | no `using:`; return `value \|> normalize() \|> drop_keys(keys)` from the observation |
  | `using: fn a, b -> abs(a - b) <= 0.01 end` | `using: {PropertyDamage.Equivalence, :within, [0.01]}` |

  `stutter: [using:]` accepts `{Mod, :fun}` and `{Mod, :fun, args}` beside a
  2-arity function, and its default is `{Kernel, :==}`.
- **BREAKING (DR-052): a check's verdict is its return value.**
  `PropertyDamage.Verdict.read/1` reads a `@check`'s return and an
  `@eventually` predicate's return with one grammar: a truthy return passes
  (is satisfied), `nil` or `false` fails (is not yet), `{:fail, "text"}` or
  `{:fail, %Exception{}}` fails with that reason, and a bare exception struct,
  an `{:error, _}` tuple or the retired `{:mismatch, _}` fails with the
  sentence "a verdict is truthy,
  `nil`/`false`, or `{:fail, reason}`". A raise is a failure in both.
  - A `@check` that returned `nil` or `false` used to pass; it now fails, in the
    executor, forensics, the load-test worker and the linearization checker,
    for `every:` and `at:` checks, with a message that names the check, shows
    the value and gives the three accepted forms: a predicate
    (`state.net >= state.fees`), `condition or fail!("...", ...)`, or a body
    that ends with a truthy value such as `:ok`. The failure is an ordinary
    check failure; no new failure kind.
    `{:fail, "text"}` is the returned form of `fail!/2` and carries the same
    `CheckFailed`.
  - The `if condition, do: fail!(...)` idiom is retired: a `@check` clause
    whose last expression is an `if` or `unless` without `else` is a
    `CompileError` naming the clause and the rewrite. Every check in the
    library, the `mix pd.gen.projection` template, the guides and the benches
    is rewritten.
  - An `@eventually` predicate's `{:fail, reason}` means "never": the window
    ends at once as a check failure with that reason instead of waiting out
    the `timeout:`. A raise, exit or throw inside the predicate is a check
    failure at once that keeps the raised exception and names the check and
    the poll count (a new `context` field on `Failure.Check` holds the poll
    count and elapsed time); it no longer means "not yet", and `last_predicate_error` is
    gone from the poll-timeout info. Rewrite a predicate that raised before the
    state caught up as a total one (`get_in/2`, `match?/2`, a `case` with a
    fallback).
  - A `using:` relation that still returns the retired `{:mismatch, detail}`
    (DR-046) used to agree, because the tuple is truthy; it now disagrees with
    the same sentence, carrying the value. The reader fails a `@check` or an
    `@eventually` predicate that returns it the same way. `:match` still agrees.
- **`latency:` and a non-default `check_mode:` are refused beside `branching:`.**
  A branching run executes one branch at a time on one target through the
  linear engine: it records no latency samples (`latency:` returned
  `%{error: :no_data}`) and halts at the first failing check whatever
  `check_mode:` said. Both combinations are option errors at run start. The
  guides, the README, the option documentation and the concurrency
  specification now say what the path does: branches run one after another,
  the checker models the interleavings afterward, and no race is detected
  (DR-053).
- **BREAKING: persistence format version 14 becomes 15.** A report records the
  run's `check_mode`, the `campaign` a latency budget was judged over
  (`%{seed:, max_runs:}`, `nil` for every other kind),
  `original_failed_at_index` and `run_check_fires` (the check firings of the
  run the report describes). A `.pd` or `.pdtrace` file of version 14 or older
  is refused with `{:unsupported_format_version, version, 15}`, and a version-15
  report lacking `run`, `replay`, `replay_path` or `check_mode` is refused with
  `{:missing_field, field}` instead of loading with a drift warning.
- **BREAKING: `shrink_further/2` and `Analysis.isolate_trigger/2` return
  `{:error, :missing_model_or_target}`** (was `:missing_model_or_adapter`) for a
  report that records no model or no target, and `mix pd.reshrink` says the file
  "does not record a model and a target".
- **BREAKING: the replay artifact loader trusts nothing in the file.** It parses
  with `existing_atoms_only: true` and creates no atom: an artifact naming an atom
  the running system does not know is refused, naming it. It loads struct values
  whose modules are already loaded and never loads a module: a command's fields
  may hold any struct of a loaded module (a `%Date{}`, for example), while a
  command itself must be a loaded command module (or a placeholder or
  position). Any other struct is refused before any run starts with
  `{:error, {:unknown_struct_module, module}}` from the loader, an
  `ArgumentError` naming the module from `only: [replay: path]`. A replay loads the model and the commands it lists
  first; a leaf module no listed command names must be loaded by the caller.
- **`Analysis.isolate_trigger/2` returns `{:error, :not_applicable}` for a
  `:diverged` or `:did_not_converge` report.** Every variation runs one target
  alone, so none could show a comparison failing; the analysis was vacuous.
- **A replay artifact never replaces another failure's file.** When
  `<Model>_seed<n>.replay.exs` holds another failure or other targets, the run
  writes `<Model>_seed<n>_2.replay.exs` (the smallest free suffix from 2) and the
  report's `replay_path` and footer name it. A re-shrink of the same failure
  still replaces its own file.
- **BREAKING: `shrink_further/2` refuses `targets:` that moved the failing
  target.** When the `targets:` option does not hold the target the report
  failed in at the index it failed at (renamed, dropped or reordered), it
  returns `{:error, {:variant_not_in_targets, name}}` and runs nothing, where it
  returned the report unchanged. An unchanged report now means only that no
  smaller sequence reproduced the failure.
- **A shrunk report's counts describe its reproduction.** `compare_counts` are
  the counts of the reproduction of the shrunk sequence, from `run/1` and from
  `shrink_further/2`, not the failing run's. From `run/1`, `check_fires` count
  the runs before the failing one plus the reproduction, and the new
  `run_check_fires` field holds the reproduction's share; `shrink_further/2`
  replaces the incoming `run_check_fires` share of `check_fires` with its own
  reproduction's, where it dropped `check_fires`.
- **An entry whose one leaf equals its root runs the root itself.** A run
  records it as `:identity` (no leaves, no alias, at the root's own position),
  as a replay of the artifact runs it; `expansion_counts` count it under
  `:identity`, and `mix pd.validate --seeds` prints it as identity, not under
  the entry's key.
- **Shrinking budget and candidate validity.** `max_iterations: 0` tries no
  candidate and reports 0 iterations (the check of the sequence cut after the
  failing root counted 1). A branching candidate the model rejects is never
  run, as on the linear path. A candidate whose expansions cannot be realized
  is realized and counted once, not again under the listed entry it equals.

- **BREAKING (DR-047): `latency:` takes its options inside the keyword list, and
  the metrics are renamed, with no compatibility layer.**
  - Removed run options: `metrics:` and `percentiles:` (accepted but never
    applied; the statistics are fixed at `p50`, `p95`, `p99` and `mean`) and
    `warmup_runs:` (now `latency: [warmup: n]`).
  - Removed metrics: `error_count` and `error_rate` (always zero, because an
    adapter error fails the run in every mode). The `latency_` prefix is
    dropped (`latency_p95` is `p95`, and likewise `p50`, `p99`, `mean`, `min`,
    `max`). A target's `total_commands` is `commands`.
  - A new failure kind, `:latency_exceeded`, ends a campaign whose budget is
    breached; code that matches on `kind` should handle it.
  - Persistence format version 11 becomes 12: reports carry `latency` and
    `metrics`. Loaders refuse version 11 and older.
- **BREAKING (DR-046): targets are compared through `@compare` observations only, with no compatibility layer.**
  - Events are never compared across variants, and there is no default
    observation. A run with two or more targets whose model declares no
    `@compare` is an error at run start.
  - Removed run options: `equivalence:` (`:exact`, `:structural`, a function) and
    `compare: :correctness | :performance | :both`. Declare the observation with
    `@compare ... using:`; `compare: :performance | :both` becomes `latency: true`.
    `compare:` is now a keyword list with `converge_within:` (integer
    milliseconds, default 5000); `compare: [settle: _]` and unknown keys are
    option errors that name `converge_within:`. `shrink_further/2` rejects
    `equivalence:` and accepts `compare:`.
  - Removed: `PropertyDamage.Comparison.equivalent?/3`, `normalize/1`,
    `ignore_fields/1` and `only_fields/1` (use `PropertyDamage.Equivalence`),
    `FailureReport.equivalence` (replaced by `compare`), the `reference_result`
    and `divergent_result` fields of `Failure.Divergence` (replaced by
    `reference_value`, `variant_value`, `key` and `mismatch`), `results` on a
    divergence, and `Failure.diverged/5` (now `Failure.diverged/1`, taking a map
    of fields; `Failure.did_not_converge/1` is new).
  - Removed stutter configuration: `comparison:` with `:strict`,
    `{:structural, _}`, `{:custom, _}` and `:acceptable`, and the command key
    `acceptable_retry_events:` (in `use PropertyDamage.Command`, `command_spec/1`
    and a `commands/0` entry). Use the `using:` relation of `stutter:`.
    `Stutter.Violation.comparison_result` is renamed `mismatch`.
  - An adapter `{:error, _}` answer is no longer an observation: with several
    targets, an agreed error used to pass and the variants continued. It is now
    `:execution_failed` (see `other_failures` above), and the internal agreed-error
    continuation (`on_adapter_error: :continue` on `Variant`) is removed. A
    placeholder consumer whose producer failed is never observed as
    `{:error, {:placeholder_resolution_failed, _}}`.
  - The failure `name` of a divergence is the `@compare` key, not the root
    command's module.
  - Persistence format version 9 becomes 10: reports carry `compare`,
    `compare_counts` and `other_failures`. Loaders refuse every version before 10.

- **BREAKING (DR-045): one runner for one or more targets, with no compatibility layer.**
  - `PropertyDamage.Differential` and `Differential.run/1` are removed. Call
    `PropertyDamage.run/1` with several `targets:`. `Differential.Result` is
    removed: `run/1` returns `{:ok, stats}` or `{:error, %FailureReport{}}`, and a
    divergence is a report with `kind: :diverged`. There is no `divergences` list
    and no run after a divergence.
  - `Differential.Equivalence` is renamed PropertyDamage.Comparison (an internal module)
    (`equivalent?/3`, `normalize/1`, `ignore_fields/1`, `only_fields/1`); DR-046
    removes those functions (see its entry above).
  - `Progress.DifferentialUpdate`, `Progress.DifferentialResult`, the
    `:differential` progress operation, the
    `[:property_damage, :differential, :progress | :result]` telemetry events and
    `Options.validate_differential!/1` are removed. Run telemetry metadata carries
    `targets: [%{index, name, adapter}]` instead of `adapter:`.
    `Progress.Printer.consumer/3` and `print_header/3` take the target list instead
    of an adapter.
  - `FailureReport.adapter` (the field and the `new/1` option) is removed; use
    `targets`, `variant` and `FailureReport.reference_target/1`. `export_json/1`
    writes `kind`, `variant` and `targets` instead of `adapter`.
  - The `{:error, %{adapter_setup_failed: _}}` map and every
    `{:adapter_setup_failed, reason}` tuple are removed. `run/1` returns a report
    with `kind: :setup_failed`; `execute/2`, `Replay.start/2` and `shrink_further/2`
    return `{:error, %Failure{type: %Failure.Setup{}}}`; `mix pd.replay` prints it.
    The `setup_once_failed` and `setup_each_failed` shapes are unchanged.
  - `Shrinker.failure_signature/1` (a 2-tuple) is replaced by
    `Shrinker.failure_signature/2`, which returns `{kind, name, variant_index}`.
    `equivalent_failures?/2` takes `{reason, variant_index}` pairs.
    `Shrinker.shrink/2` takes `targets:`, `variant_index:`, `concurrency:`,
    `compare:` (`[converge_within: ms]`) and `check_mode:` in place of
    `target:`, `event_queue:` and `mock_registry:`.
  - `Scheduler.run/1` has no `divergence` key. Its `failure` is `nil` or
    `%{kind, variant, run, root, reason}`, with `kind` one of `:check_failed`,
    `:diverged`, `:did_not_converge`, `:setup_failed` and `:execution_failed`, and
    `reason` always a `%Failure{}`.
  - Persistence format version 8 becomes 9 for `.pd` reports and `.pdtrace`
    traces (version 10 under DR-046, version 11 under DR-048, version 12 under DR-047, version 13 under DR-049). Loaders refuse version 8 files.
  - `branching:` with two or more targets is an option error. Branching sequences,
    `PropertyDamage.replay/2`, `Analysis.isolate_trigger/2` and `RunTrace` stay
    one-target.
  - `check_mode:` now reaches the engine (it was accepted without effect).
    `teardown_each/1` runs at the end of each run, not after the last run. An
    injector or mock setup that raises inside a target is a `:setup_failed` report.
    `setup_once/1`, `setup_each/1` and their teardowns receive the reference
    target's config.


- **BREAKING (DR-044): `Differential.run/1` runs every target as a variant in lockstep.** (`Differential.run/1` itself is removed by DR-045, above.)
  - `execution:` is removed with no mapping (it took `:interleaved` or
    `:sequential`). Use `concurrency:`: `:serial` (the default, one target at a
    time) or `:parallel` (all targets at once; targets that share a system must
    isolate their slices through `config:`). Passing `execution:` is an option error
    that names `concurrency:`. `compare: :performance` and `:both` (now
    `latency: true`, DR-046) require `concurrency: :serial`.
  - `Differential.Result`: the `execution` field is replaced by `concurrency`;
    there is a new `failure` field; `status` may be `:failed`; `divergences` are
    listed oldest first. A divergence now has the keys `seed`, `run`, `root`,
    `command`, `variant` (`%{index, name}`), `reference_result`, `divergent_result`
    and `results`; `divergent_target` and `step` are gone. A failure is
    `%{kind, variant, run, root, reason}` with `kind` one of `:check_failed`,
    `:setup_failed` and `:execution_failed`, and it ends the campaign.
  - `Executor.Stepping.step/4` returns the raw outcome of the command:
    `{:ok, state, outcome}` or `{:error, failure, state, outcome}`, where it
    returned `{:ok, state}` or `{:error, failure, state}` before.
  - `Differential.run/1` calls `Adapter.setup/1` once per run per target, not once
    per campaign, and tears every target down at the end of each run. `setup/1`
    must be idempotent. Code that looped over `max_runs: 1` to force a fresh setup
    no longer needs the loop.

- **BREAKING (DR-043): targets carry every per-target resource, with no compatibility layer.**
    - The run-level options `adapter:`, `adapter_config:`, `injector_adapters:`
      and `mock_services:` are removed. Describe the target in `targets:`
      instead: `targets: [{MyAdapter, config: %{...}, injectors: [...],
      mocks: [...]}]`. Each removed key raises an error that names `targets:` and
      the entry key that replaces it.
    - The per-target `role:` is removed: the first `targets:` entry is the
      reference. The per-target `opts:` is renamed `config:` and is a map that
      reaches `Adapter.setup/1` unchanged, with no conversion from a keyword
      list.
    - `{Module}` 1-tuples are no longer accepted; write `Module` or
      `{Module, keyword}`.
    - A target without `name:` is named after the last segment of its adapter
      module, with no index suffix, so reordering `targets:` never renames a
      target. Two entries that resolve to the same name are an error that asks
      for a distinct `name:`.
    - Every entry point other than `PropertyDamage.Differential.run/1` takes
      exactly one `targets:` entry. An engine that cannot honor a target's
      `injectors:` or `mocks:` raises instead of ignoring the key.
    - `PropertyDamage.Differential.Target` is replaced by
      `PropertyDamage.Target`, with the fields `adapter`, `name`, `index`,
      `config`, `injectors` and `mocks`.
    - `PropertyDamage.Differential.Result` fields `reference` and `targets`
      hold `%{index, name}` maps.
    - The `Executor.run/4` option for the adapter's setup configuration is
      `config:`.

- **BREAKING (DR-042): vocabulary renames, with no compatibility layer.** The
  old names are not recognized.
    - The "assertion" identifier family becomes "check": the model callback
      `assertion_projections/0` is `check_projections/0`; the exception
      `PropertyDamage.AssertionFailed` is `PropertyDamage.CheckFailed` (still
      raised by `PropertyDamage.fail!/2`); the run option `assertion_mode:` is
      `check_mode:`; `%Failure.Assertion{}` is `%Failure.Check{}` (class `:check`,
      kind `:check_failed`); `assertion_coverage/2` is `check_coverage/2`;
      `assertion_catalog/1` is `check_catalog/1` (report kinds `:synchronous`,
      `:lifecycle`, `:eventual`); `assertion_fires` is `check_fires`;
      `Projection.__assertions__/0` is `Projection.__checks__/0`; the LoadTest
      failure metrics are now `check_failures` and `check_failure_rate`; the `Statistics` option
      `assertions:` is `checks:`.
    - The projection attributes `@trigger` and `@poll_state` become `@check` and
      `@eventually`, with the same `every:`, `at:`, `after:`, `timeout:` and
      `interval:` options.
    - The model callback `terminate?/3` is `terminate_early?/3`.
    - The command-spec option `with:` is `overrides:`.
    - A retired key raises an error that names its replacement. The messages are:
      "`assertion_mode:` was renamed `check_mode:`", "`assertions:` was renamed
      `checks:`" and "Invalid `with:` for command M: `with:` was renamed
      `overrides:`."
    - The persisted `.pd` format moves to version `8`; older files are refused
      with `{:error, {:unsupported_format_version, version, 8}}`.
    - `mix pd.gen.model` now takes `--check-projections`.

- **`failure_reason` is a `%PropertyDamage.Failure{}` everywhere it flowed as a
  raw tuple (BREAKING, DR-041).** Every producer (the executor, branching,
  nemesis, finalization, linearization) now constructs a `%Failure{}`, and every
  consumer reads one: `Shrinker.failure_signature/1` returns a `{kind, name}`
  tuple (was a `%{type:, check_name:}` map) and accepts only a `%Failure{}`;
  `FailureReport.classify_reason/1`, `ErrorOrigin.classify/2`, `Error.format/2`,
  the formatter titles, and `FailureIntelligence` fingerprinting all key on the
  kind. Two renames of note: `:ref_resolution_error` → `:placeholder_resolution`
  (the old name referred to the long-deleted `%Ref{}` system), and the
  trigger/check failures unify under `:assertion_failed` (so
  `FailureReport.failure_type/1` returns `:assertion_failed`, not `:check_failed`,
  and linearization failures report `:linearization`, not `:linearization_failed`).
  The shrinker's failure-equivalence granularity is unchanged — the `{kind, name}`
  signature keeps a `:poll_timeout` of `:x` distinct from an `:assertion_failed`
  of `:x` (a class-based signature would have merged them).

- **Persisted-file format bumps to version `7`; pre-v7 files are refused
  (BREAKING, DR-041).** A report's persisted shape changed (its `failure_reason`
  is a nested `%Failure{}` and the six denormalized failure fields are gone), so
  `@version` goes 6 → 7. A `.pd` / `.pdtrace` file written under format version
  `1`–`6` now returns `{:error, {:unsupported_format_version, version, 7}}`; there
  is no honest in-place upgrade. Re-capture the failure under the current version
  (the framework is unpublished; no persisted artifacts exist outside test
  fixtures).

- **Persisted-file format bumps to version `6`; pre-v6 files are refused
  (BREAKING, DR-040).** V6 records the per-run fold order (`EventLog.Entry`
  `fold_index` + `RunTrace` `command_fold_ordinals` + verified `linearization`)
  so the per-step state timeline and the projection-purity check can be derived.
  A `.pd` / `.pdtrace` file written under format version `1`–`5` now returns
  `{:error, {:unsupported_format_version, version, 6}}`; a pre-v6 file carries no
  fold-order record, so no honest in-place upgrade exists. Re-capture the failure
  under the current version (the framework is unpublished; no persisted artifacts
  exist outside test fixtures).

- **Command positions are now `%PropertyDamage.Sequence.Position{}` everywhere
  (BREAKING, DR-039).** The raw position tuples `{:prefix, i}` / `{:branch, b,
  i}` / `{:suffix, i}` are gone; the whole pipeline (generator minting, executor
  `current_position`, placeholder registry keys, shrinker remap, mint markers,
  the determinism audit, and the export step plan) speaks the struct. This
  finishes the single-position-vocabulary intent of DR-021. Placeholder ids stay
  deterministic and opaque, and the plan fingerprint is still
  `sha256(term_to_binary(canonical, minor_version: 2))`; DR-036's determinism,
  id-opacity, and plan-identity guarantees are unchanged (only the encoding
  changes). Impact:
    - **Persisted-file format bumps to version `5`; pre-v5 files are refused.** A
      `.pd`/`.pdtrace` file written under format version `1`–`4` now returns
      `{:error, {:unsupported_format_version, version, 5}}`; re-capture the
      failure under the current version. There is no deep-converting loader (it
      would resurrect exactly the tuple-encoding interpretation this change
      deletes), and the pre-v4 `RunTrace` synthesis path is removed.
    - **Plan fingerprints and client-minted (`mint_per_run`) values differ
      across this boundary.** Both are pure functions of the position, which is
      now a struct, so their bytes change. This has no runtime consumers today
      (fingerprint continuity and minted-value stability had no dependents).
    - If you construct placeholders or mint markers by hand (e.g. in a static
      regression test), use the new `Position.prefix/1`, `Position.branch/2`, and
      `Position.suffix/1` constructors instead of raw tuples.

- **`PropertyDamage.Validator` renamed to `Sequence.Validator`.**
  The sequence-data validity check (`valid_sequence?/2`, run by the shrinker and
  by `Analysis`) now lives under the `Sequence` namespace, next to
  `Sequence.Position`, resolving the collision with `Validation`
  (config/model-adapter setup validation, unchanged). Both were `@moduledoc
  false` internals; clean break, no forwarding module.

- **Stricter option validation on more entry points (BREAKING-ish).** The
  up-front NimbleOptions validation convention now covers every public
  option-taking entry point: `Integration.run/1`, `hunt_bugs/1`,
  `health_check/1`; `Flakiness.check/4`, `check_batch/4`, `discover_flaky/3`;
  `Audit.run/2` (DR-037); `RunComparison.compare/2` and `investigate/1`
  (DR-035); and the `Regression` handler factories. Unknown or mistyped options
  that were previously ignored (or deferred until a handler fired) now raise
  `NimbleOptions.ValidationError` immediately. In particular:
    - **`Regression` factories validate at factory time.** `generate_test/2`,
      `save_failure/2`, `add_to_library/2` (and `handler/1`, `handle_failure/2`,
      `check_duplicate/2`, `process_batch/2`) validate their options when built,
      not when the failure handler later fires. Previously a typo'd option was
      swallowed by `compose/1`'s per-handler rescue and the regression artifact
      was silently lost. `:base_url` is no longer accepted in the regression
      surface (it never applied to the `:exunit`-only generated tests).
    - **`RunComparison.investigate/1` takes `capture:` as a sub-keyword.**
      `RunTrace.capture/1` options are now nested under `:capture` (e.g.
      `investigate(runs: 5, capture: [model: M, adapter: A, seed: 3])`) rather
      than passed flat, so `RunTrace`'s option surface stays single-sourced.
    - **`Analysis.generate_test/2` now validates its options** (the previously
      orphaned `format`/`module_name` schema is wired in); the dead
      `:include_setup` option was removed.

- **`NetworkPartition` `:full` now cuts both directions (DR-038).** A full
  partition installs two `bandwidth` toxics at rate `0` (`pd_partition_up` on the
  upstream, `pd_partition_down` on the downstream); restore removes both.
  Previously it sent one unqualified `bandwidth` toxic, which Toxiproxy defaults
  to downstream only, so requests still flowed and only responses were blocked.

- **Structural failure-query interface (Phase B): callers migrated.** Every
  renderer, exporter, and forensic analyzer that previously re-walked
  `shrunk_sequence` / `event_log` / `failed_at_index` to reconstruct "the command
  and events at the failure" now goes through `FailureReport.steps/1` /
  `failure_step/1`: the terminal/markdown formatters and timeline, the ExUnit /
  script (curl/python/elixir) / Livebook exporters, `FailureIntelligence.Fingerprint`,
  and `Analysis.explain/1` / `isolate_trigger/2`. This fixes latent branch bugs
  where a flattened ordinal was compared to the executor `failed_at_index` (they
  diverge for parallel-branch failures), so the failure marker, per-command event
  grouping, and dependency-graph trigger now land on the correct command;
  reader-facing "Command Index" text now shows the flattened (reading-order)
  ordinal. `Fingerprint` also now reports a correct `sequence_length` /
  `sequence_shape` for real reports (it silently returned 0/`[]` before because it
  only matched a `%{commands: ...}` map, not a `%Sequence{}`); this changes the
  computed `Fingerprint.hash/1` for such reports, so similarity clustering should
  be recomputed rather than compared against values cached under the old bug.
- **Persistence format 2 → 3.** `.pd` files now stamp format version `3`, which
  tracks the `FailureReport` struct shape. Version 1 and 2 files still load. A
  file written before the field removal below deserializes losslessly: the two
  removed keys are recognized (not reported as struct-shape drift), and the
  failing command/events remain recoverable via `failure_step/1`, recomputed from
  the untouched `event_log` + `shrunk_sequence`.

- **BREAKING (DR-032):** `external_markers` is now an explicit run option only;
  the `config :property_damage, external_markers: [...]` app-config channel is no
  longer consulted. `PropertyDamage.External.external?/1` no longer recognizes
  configured atom markers (only the `%External{}` struct and `ExternalMarker`
  protocol implementers are intrinsic); `external?/2` and `external_paths/2` use
  the explicit list as their sole source. Pass markers via
  `PropertyDamage.run(..., external_markers: [:__external__])` instead of app
  config. This completes the ambient-state removal begun in DR-027 and DR-029.
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
  they cannot live in a static map). `Command.build_spec_from_legacy/1`
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

- **BREAKING (DR-048): the model's lifecycle hooks are replaced by setup and teardown commands, with no compatibility layer.**
  - Removed: the callbacks `setup_once/1`, `setup_each/1`, `teardown_each/1` and
    `teardown_once/1`, and the `lifecycle_config` type. A model that defines one
    of them, or `setup_once/0` or `teardown_once/0`, fails at run start with an
    error that names the replacement. There is no once-per-campaign callback:
    make `Adapter.setup/1` idempotent or wrap `PropertyDamage.run/1` yourself.
  - Removed: the `{:error, %{setup_once_failed: _}}` and
    `{:error, %{setup_each_failed: _}}` error maps. A failed setup is a
    `:setup_failed` report (`failed_at_index: nil`).
  - Replacement: `setup_each/0` and `teardown_each/0` return command specs that
    run in every target. Move a side effect only the adapter can do (a database
    reset, a pool) into the idempotent `Adapter.setup/1`, and move a fixture (a
    user, a login) into a setup command.
  - Persisted failure reports and traces are version 11; version 10 and older are
    refused.
- **BREAKING (DR-049): the `{Module, n}` weight shorthand is retired, expansions add load rules, and persistence moves to version 13, with no compatibility layer.**
  - Removed: `{Module, 3}` as a command spec in `commands/0`, `setup_each/0`,
    `teardown_each/0` and expansion sequences. It raises an error that names the
    module and `weight:` before any adapter setup. Write `{Module, weight: 3}`.
  - An `overrides:` function of arity 2 outside an expansion sequence (in
    `commands/0`, `setup_each/0` or `teardown_each/0`) is a load error.
  - New load errors, raised before any `Adapter.setup/1`: a model with
    `expansions/0` and no `@compare` whose schedule reaches the end of the run
    (`every: 1` or `:end`, one target included); a module in `expansions/0` that
    is not in `commands/0`, is listed twice, or is an `execution: :probe` root;
    `branching:` together with a model that defines `expansions/0`.
  - `Analysis.isolate_trigger/2` raises for a target that ran any root as
    leaves. `shrink_further/2` and `Replay` raise for a target whose choices the
    report does not record.
  - `%PropertyDamage.Target{}` gains the `expansion` field.
  - Persisted failure reports and traces are version 13 (the `expansions` and
    `expansion_counts` fields and the trace's concrete leaves); version 12 and
    older are refused.
- **BREAKING: persistence format is version 14.** The report envelope gains the
  replay term, its path and the run. Loaders refuse version 13 and older;
  `.pdtrace` files share the version.
- **Paths that run a failure again no longer raise for a target that ran
  leaves.** `shrink_further/2`, `Replay.run/2`, `Replay.start/2`,
  `Analysis.isolate_trigger/2` on the reference and export read the recorded
  commands instead. `shrink_further/2` writes its smaller artifact over the
  incoming report's file and raises, naming `replay_dir:`, only when the report
  holds neither a term nor choices.
- **BREAKING: `Generator.merge_overrides/2` returns `{field, generator}` pairs
  sorted by field instead of a map.** A map's iteration order depends on the VM,
  so `StreamData.fixed_map/1` on a map could draw other field values for the same
  seed in another VM; it now draws the fields in field order in every VM. A
  command with more than one field draws different values for a given seed than
  before. Code that used the result as a map (`Map.put/3`, `Map.merge/2`, a `%{}`
  pattern) must change; piping it into `StreamData.fixed_map/1` works as before.

### Removed

- **`observations` in the result of `PropertyDamage.Scheduler.run/1`.** Nothing
  read it; boundary observations reach a run through `@compare` alone.
- **BREAKING (DR-042)**: Removed Differential baseline comparison: the `baseline:`
  and `export_to:` options, `PropertyDamage.Differential.Baseline` and its JSON
  file format, and the `:baseline` field of `PropertyDamage.Differential.Result`.
  Passing either option now raises the unknown-option validation error. Recorded
  runs can return, designed against the replay artifact format.

- **BREAKING:** removed `PropertyDamage.Flakiness` and its facade delegates
  `check_determinism/4` and `discover_flaky_seeds/3`.
  Flakiness detection is now part of run comparison (DR-035): a flaky run is
  defined by multiple runs of one plan disagreeing, which is exactly what
  `RunComparison` captures and localizes. Use `RunComparison.investigate/1` for a
  single suspect seed (it also ranks *where* the passing and failing runs
  diverge, which the old outcome-only detector could not), the new
  `RunComparison.scan/1` for a corpus of seeds (the `discover_flaky` replacement:
  per-seed `%RunComparison.Verdict{}` with bounded memory — a seed's traces are
  discarded before the next, and only flaky seeds keep their full comparison), and
  `RunComparison.outcome_summary/1` for the cheap pass/fail + failure-signature
  view. The three `Options.validate_flakiness_*!` schemas are removed in favor of
  `Options.validate_run_comparison_scan!/1`.

- **BREAKING:** removed `PropertyDamage.Telemetry.Dashboard`. It was a LiveView
  renderer sketched inside a library with no Phoenix dependency (it could not
  actually render — the HEEx template was a placeholder string) and had no real
  tests. The integration surface is unchanged and complete without it: attach to
  the `[:property_damage, ...]` telemetry events directly, or subscribe
  `PropertyDamage.Telemetry.Collector` for a live in-memory run/command/check
  rollup, and render it with your own dashboard (Phoenix LiveView, an IEx loop, an
  exporter, etc.).

- **BREAKING (DR-038):** removed `NetworkPartition`'s `:asymmetric`
  `partition_type`. Its documentation ("requests go through, responses blocked")
  and its implementation were both exactly `:downstream` — duplicate vocabulary
  for one behavior. Models overriding `partition_type: :asymmetric` must switch
  to `:downstream`.

- **BREAKING (DR-041):** `FailureReport` no longer carries the six denormalized
  failure fields `failure_type`, `check_name`, `failure_message`,
  `invariant_name`, `idempotency_violation`, and `poll_timeout_info`. They were
  projections of `failure_reason`; use the accessor functions of the same names
  (`FailureReport.failure_type/1`, `check_name/1`, `failure_message/1`,
  `invariant_name/1`, `idempotency_violation/1`, `poll_timeout_info/1`), all
  derived from the `%Failure{}` reason. (Downstream structs that keep their own
  descriptive `failure_type` / `check_name` — `FailureIntelligence.Fingerprint`,
  `SeedLibrary` entries, persistence metadata — are unchanged; they now populate
  those from the accessors.)

- **BREAKING (Phase B):** `FailureReport` no longer carries the materialized
  `command_at_failure` / `events_at_failure` fields. They were redundant with the
  structural step interface added in Phase A; use
  `FailureReport.failure_step(report).command` and `.entries` instead (both
  recomputed branch-aware from `event_log` + `shrunk_sequence`, `nil` for a
  non-localized failure; the bare event of an entry is `entry.event`). Existing
  `.pd` files remain loadable (see the persistence 2 → 3 note above).

- **BREAKING (DR-032):** removed 7 of the 10 built-in nemeses, keeping only the
  three that fault the SUT's network path: `NetworkPartition`, `NetworkLatency`,
  `PacketLoss`. Removed `ClockSkew`, `SlowIO`, `CertificateExpiry` (cooperative:
  a virtual clock / flags the adapter reads via a global no-arg API),
  `CPUStress`, `MemoryPressure`, `ResourceExhaustion` (host-effect: stress the
  *local* BEAM/host), and `ProcessKill` (kills a *local* process). These only
  affected the test harness's own VM, not an external System Under Test driven
  through an adapter, so they tested the wrong thing; the host-stress ones could
  also destabilize the run (and, under the new core timeout, manufacture false
  `CommandTimeoutError`s). To fault an in-process collaborator, do it in your own
  adapter/command code. This also removes the last shared-global process-dict
  fault state (the original "per-instance handle" plan is superseded by removal).

### Fixed

- **An `@eventually` function that returns no predicate fails at its step.**
  The poller took the function's return as its predicate without checking it,
  so a function that answered the question itself (a boolean) raised
  `BadFunctionError` on every poll behind a warning and the window timed out
  as "never became true". The return is now checked when the poller would be
  spawned: anything but a 1-arity function is a check failure at that step,
  naming the check and the value, handled under `check_mode:` like a
  synchronous check.
- **A trace capture reports a failed injector setup.** `RunTrace.capture/1` of
  a model without expansions raised `MatchError` when an injector's `setup/1`
  returned `{:error, _}`, so `mix pd.audit` and `RunComparison` crashed instead
  of reporting. The trace now carries a `:setup_failed` outcome and an empty
  event log, as a capture through the scheduler already did.
- **An injector setup that raises tears down the injectors set up before it.**
  On every path that brings a target's injectors up (a run, a shrink attempt,
  a trace capture, `PropertyDamage.execute/2`), a `setup/1` that raised left
  the earlier injectors' `teardown/1` uncalled, and a mock `setup/1` that
  raised left every injector up, on the per-run wiring and on the variant
  path alike. The raise is now a `:setup_failed` failure whose detail is the
  exception, as a raising adapter `setup/1` already was, the injectors set up
  before it are torn down, and `execute/2` returns it instead of raising.
- **A placeholder argument prints whole in the terminal report.** The
  failing command's arguments were cut at a fixed width with no marker, so a
  placeholder lost its closing bracket and two distinct ids could print alike.
  A placeholder is never cut; any other value that is cut ends with `...`.
- **The timeline honors `color: false`.** `FailureReport.Timeline` reset its
  colors with an escape sequence that ignored the option, so plain output
  carried `\e[0m` after every colored span.
- **The printed Event Log names every event source.** An event a resource
  poller delivered, a telemetry receiver derived or an adapter injected
  mid-execution printed with a `???` badge in the terminal report and the
  timeline. They print as `POL`, `TEL` and `EMT`, from one badge table both
  printers share.
- **`mix pd.replay` and `mix pd.reshrink` print a divergence's check name.**
  Both tasks interpolated the `@compare` key tuple into their summary line, so
  a `:diverged` or `:did_not_converge` report raised `Protocol.UndefinedError`
  before either task did any work. The key now prints as `Projection.name`,
  as the exporters print it.
- **A rewritten root's id is in the target's simulated state.** In a target
  that ran a rewrite at a root that mints an `external()` id, the simulated
  state held the leaf's placeholder, while a later root carries the root's.
  A later root's `simulate/2` that looked the id up in state missed it (a
  `KeyError`, or a predicted not-found event), and so did an expansion
  function, a leaf's `overrides:` and a leaf's `when:` reading that state. The
  state now holds the root's placeholder, as in a target that ran the root as
  itself, on every path that realizes leaves: a run, a shrink and a replay of
  recorded leaves. Execution is unchanged: each target still resolves the id
  from its own leaf's real events.
- **An injector's `setup/1` receives its target's `config:`, and its
  `teardown/1` receives its setup context.** `setup/1` was called with only
  `%{event_queue: queue}` and `teardown/1` with `%{}`, so the documented
  examples (reading `config[:port]`, matching `teardown(%{server: server})`)
  could not run and an injector on two targets of one adapter could not tell
  which system it served. `setup/1` now gets the target's `config:` merged with
  `:event_queue` (the framework key wins) and `teardown/1` the context
  `setup/1` returned, on every path: `run/1` with one target or several, its
  shrink attempts and `execute/2`. A `setup/1` that returns `{:error, reason}`
  now fails the target's setup as `:setup_failed` after tearing down the
  injectors already set up (it used to be ignored); any return other than
  `{:ok, map}` or `{:error, _}` fails with
  `{:invalid_injector_setup_return, module, returned}`.
- **A check recorded under `check_mode: :record` no longer skips the final
  boundary.** A target that recorded a failing check at an earlier root kept the
  final boundary from being compared, so a divergence there went unreported; it
  is now compared and listed among the run's failures.
- **A retired or halted target's recorded check is listed.** Under
  `check_mode: :record`, the first check a target recorded before it left the
  run (an adapter failure at a later root), or before the reference's own
  failure ended the run, was missing from the report, and a retired target
  with two recorded checks listed its last one; its first is now listed at its
  root, as a finished target's is.
- **`Scheduler.run/1` refuses targets with nothing to compare.** Called directly
  with two or more targets and a model that declares no `@compare`, it ran
  them; it now raises the same `ArgumentError` as `PropertyDamage.run/1`, before
  any target is set up.
- **A `@compare` that another `@` macro handles is a compile error.** A
  projection module that unimported the projection's own `@` and imported
  another one compiled with its `@compare` observation dropped; it now fails to
  compile with an error naming the module and `@compare`.
- **A branching run whose model has a simulator runs its `@check at:` checks.**
  Verifying an ordering passed the lifecycle-boundary checks to the step
  trigger and raised `CaseClauseError`; they now run only at their boundary.
- **A raise during finalization still runs the teardown commands.** A raise,
  throw or exit while `Executor.run/4` finalized a run skipped the teardown
  commands; they now run, then `Adapter.teardown/1`, and the raise propagates.
- **`Replay.stop/1` stops a session once.** A second call ran the teardown
  commands and `Adapter.teardown/1` again; it now returns `:ok` and runs nothing.
- **A mock event pushed between commands is folded.** An event a mock received
  after its command's own flush was lost at the end of the run and missing from
  a boundary's state; `Stepping.drain/2` and finalization now flush the mock
  registry and attribute the event to the command that ran last.
- **A timed-out attempt leaves no dead resource poller in the state.** The
  pollers an adapter started in an attempt that hit `timeout/1` stayed listed in
  `active_resource_pollers` after they died with the attempt.
- **A placeholder resolution failure's detail is its message.** The detail of a
  `:placeholder_resolution` failure held the framework's stacktrace beside the
  message, so two targets' equal failures could differ by a stack frame.
- **`@eventually` checks emit check telemetry.** `[:property_damage, :check,
  :start]` fires when the triggering event opens the window and `[:property_damage,
  :check, :stop]` when the condition holds or the window times out, with the
  metadata keys of a synchronous check.
- **A projection listed in both `command_sequence_projection/0` and
  `check_projections/0` is checked once per step.** Every consumer of a model's
  projections now reads `Model.projection_modules/1`, so the engine, the
  ordering check, the load-test worker, forensics, the trace and the audit
  initialize, check and poll such a projection once.
- **`PropertyDamage.run/1` warns about targets that share state.** Under
  `validate: true` it logs the warning `mix pd.validate` prints for two targets
  with the same adapter and an identical `config:`.
- **A missing `external()` is reported on the setup command that should have
  produced it.** When a later setup command consumed it, the run failed with
  cause `:command` on the consumer; it now fails with cause
  `:unresolved_placeholder` on the producer, as the completion rule reports it.
- **An injected event of another module never resolves a command's
  `external()`.** An event injected through `runtime.inject` before a command
  answered could be read as that command's own event and give the external a
  wrong value; capture now reads only events of the external's event module.
- **A throw or an exit in an expansion is the generation error a raise is.** A
  throw or an exit from an expansion function, a leaf's `overrides:` function or
  a leaf's generator escaped `PropertyDamage.run/1` and lost the report during
  shrinking; it is now the same `ArgumentError`, naming `{:throw, value}` or
  `{:exit, reason}`, and a shrink candidate that hits it is dropped.
- **A `check_mode: :record` failure is reproduced under `:record`.** The report
  records the run's `check_mode`; `reproduction_command/1` and `replay_command/1`
  print it when it is not `:halt`, `shrink_further/2` and `mix pd.reshrink`
  re-shrink under it, and `PropertyDamage.Replay` replays under it (a failing
  check is the step's result and stepping goes on).
- **A latency budget's reproduction runs the whole campaign.**
  `reproduction_command/1` of a `:latency_exceeded` report names the campaign's
  seed and `max_runs:` (and `latency:` as given, `warmup:` included); every other
  kind still reproduces one run with `max_runs: 1`.
- **A report of a run without shrinking names its plan `:generated`.** With
  `shrink: false` the trace's `plan_source` was `:shrunk`.
- **The failing index of the run that found the failure is kept.**
  `failed_at_index` describes the sequence the report carries; when the
  reproduction failed at another command, `original_failed_at_index` keeps the
  index in `original_sequence`.
- **A failed `:startup` check lists and counts no root.** The report's
  `expansions` and `expansion_counts` listed and counted every root although none
  ran.
- **`replay_command/1` names a non-default `compare: [converge_within: ms]`**, as
  `reproduction_command/1` does, so a pasted replay waits as long as the run did.
- **Every export names a divergence by its observation.** The curl, Python and
  Elixir scripts, the ExUnit test and the Livebook notebook raised
  `Protocol.UndefinedError` on a `{projection, function}` failure name; they now
  print `Projection.function`, as the report does.
- **A shrunk export of a model without `expansions/0` binds a value after the
  step that produces it.** After shrinking dropped an earlier root, a script bound
  an `external()` value after the step at the producer's old position.

- **A module that is compiled but not loaded yet keeps its callbacks.** A command
  module lost its `:probe`, `settle:` and `idempotent:` declarations, and an
  injector was skipped by `RunTrace.capture/1`, when nothing had loaded the module
  before the run named it. Every reflection on a model, command, projection,
  adapter or injector module now loads the module first.

- **The reproduction of a found failure emits the found run's `run_number`.**
  A linear reproduction used to emit `run_number: 0` in its command and check
  telemetry while a branching one emitted the found run's number. Both now emit
  the found run's number; shrink attempts keep `0`. The telemetry docs also
  state that a root command's `index` counts across the whole run.

- **A flaky failure that does not reproduce no longer reports a blank "Unknown
  Failure".** After finding a failing run, `PropertyDamage.run/1` re-executes the
  (shrunk) sequence to gather fresh state for the report. For an intermittent
  failure that re-run can pass, leaving the fresh result with `failure_reason:
  nil`; the report then rendered `[FAIL] Unknown Failure` with `Reason: nil`,
  discarding the reason actually observed. The report now falls back to the
  original failing run's reason, index, and state when the re-execution does not
  reproduce (and keeps the shrunk sequence and fresh state on a genuine repro).
  `shrink_further/2` shared the gap and now returns the incoming report unchanged
  when its re-execution fails to reproduce.
- **`FailureReport.failed_at_index` typespec now admits `nil`.** The field is set
  `nil` for non-localized failures (teardown / whole-run / linearization safety
  checks), but the type declared `non_neg_integer()`. Corrected to
  `non_neg_integer() | nil` to match the code.
- **Injector-adapter validation no longer spuriously raises.** When an injector
  adapter is passed by module name, `PropertyDamage.run/1` now
  `Code.ensure_loaded?`s it before reflecting on its `@emits`, so an
  as-yet-unloaded injector is no longer treated as declaring zero injectable
  events. Previously a valid event could be rejected with a false "not covered by
  any InjectorAdapter `@emits`" error purely because the adapter module had not
  been loaded at reflection time.
- **A pasted reproduction command keeps each target's non-default `expansion:`.**
  `FailureReport.targets_source/1` left it out, so the pasted command re-ran a
  `:reference` or `:identity` target as `:random`, which is a different sequence.

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
  no check warns as statically vacuous). `Model.assertion_catalog/1` (since renamed
  `check_catalog/1`) returns the model-wide catalog keyed `{projection, id}` with each invariant's
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
