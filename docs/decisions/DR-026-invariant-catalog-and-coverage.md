# DR-026: Invariant Catalog and Anti-Vacuity Coverage (first-class invariant identity + per-assertion firing)

**Status:** Accepted
**Date:** 2026-06-24

> Recorded as a design pass, to be implemented next. It gives a model's assertions a
> first-class **invariant identity**, a single authoritative **catalog** of the properties
> a model verifies, and a trustworthy **anti-vacuity** signal: which invariants were
> actually exercised during a run and which silently never fired. Implementation is pending
> at the time of writing; the spec deltas in `openspec/specs/projection`,
> `openspec/specs/observability`, `openspec/specs/execution-engine`,
> `openspec/specs/eventual-consistency`, `openspec/specs/model`, and
> `openspec/specs/failure-analysis` describe the target behavior. This decision **completes
> and corrects** the coverage subsystem rather than adding a parallel one (see Context).

## Decision

An assertion validates a named **invariant**, which is a first-class entity with a stable
identity and an optional human description. The engine records which invariant each assertion
fired, and the framework reports invariants that were declared but never exercised.

### Invariant identity

- An invariant is represented by `%PropertyDamage.Invariants.Invariant{id, name, description}`.
  `id` is the canonical, unique identifier (the linking, uniqueness, lookup, and
  coverage-rollup key); `name` is a human-readable display label that **defaults to `id`**;
  `description` is an optional sentence. There is no `:kind` field — safety-versus-liveness is
  a property of a *check*, not of an invariant (one invariant MAY have both a synchronous and
  a polling check), and is surfaced in the catalog, not stored on the struct.
- `Invariant.new!/1` builds a struct from a keyword list, validating that `id` is an atom,
  `name` is an atom (defaulting to `id`), and `description` is a binary or `nil`; it raises
  otherwise.
- `Invariant.fetch!(id, ctx)` resolves the `%Invariant{}` for an `id`. By default it reads the
  owning projection's compile-time registry; it raises only on an unknown `id` (a condition
  compile-time validation makes unreachable post-compile, so failing fast is correct). A
  configurable resolver MAY override the **description** (and only the description) at
  report time, best-effort with fallback to the local description. Description resolution is
  **lazy** (report/catalog time only), never compile-time, never on the run hot path, and
  never feeds generation, shrinking, or assertion logic. *(The pluggable-resolver config is
  deferred; the `fetch!/2` seam is built now. See Consequences.)*

### Declaring and linking invariants (per projection)

- A projection declares invariants centrally with an accumulating module attribute whose value
  is the `new!/1` keyword list:
  ```elixir
  @invariant id: :balance_nonneg, description: "Balance never drops below zero"
  ```
  No new macro is introduced: `@invariant <keyword-list>` is the constructor's own argument
  list, reuses the projection's existing attribute DSL (`@trigger`/`@poll_state`), and `new!/1`
  enforces the required `:id`.
- An assertion links to the invariant it checks with `validates: :id` on `@trigger` or
  `@poll_state`. An assertion MAY instead declare an invariant inline with `id:` (plus optional
  `description:`), which both declares the invariant and registers that assertion as a check of
  it.
- An assertion with neither `validates:` nor `id:` validates an invariant whose `id` is the
  assertion's own (`assert_`-stripped) logical name. This makes every existing assertion own a
  same-named invariant by default, so the feature is fully backward compatible.
- **Invariant identity is scoped per projection.** `id`s are unique within a projection;
  `validates:` resolves within the same projection. The model-level catalog
  (`PropertyDamage.assertion_catalog/1`) is the union of its projections' invariants, keyed by
  `{projection, id}` so two projections MAY reuse an `id` for distinct invariants.

### Compile-time validation (structural; per projection; order-independent)

Resolved at `@before_compile` after accumulating all declarations and references:

- A duplicate `id` (across `@invariant` and inline `id:`, including a byte-identical
  redeclaration) is a **`CompileError`**.
- A `validates:` referencing an undeclared `id` is a **`CompileError`** with file/line. This
  check is pure local set-membership; it never calls `fetch!/2`, so typo-safety is independent
  of any description resolver.
- An invariant declared with zero checks is **static vacuity**: a compile-time **warning**,
  also surfaced by `mix pd.validate` (and elevated to an error under strict mode).

### Per-assertion firing (dynamic)

- The engine records, per run, how many times each assertion's function was actually invoked,
  keyed by the assertion and its owning projection. "Fired" means the assertion ran (regardless
  of pass or fail), at **every** evaluation site: synchronous `every:` (commands and observed
  events, including the asynchronous observation paths of DR-025), lifecycle `at:` boundaries
  (DR-024), and `@poll_state` — for which **spawning a poller counts as fired** (a matching
  `after:` event arrived and verification began; a timed-out or still-pending poller still
  counts as exercised).
- Firing counts accumulate **across the whole run** (all generated sequences), since "never
  fired across the run" is the meaningful unit. The aggregate is attached to every result as
  `result.assertion_fires`, and merges across parallel branches exactly as the existing
  assertion counters do.

### Coverage, reporting, severity (anti-vacuity)

- Invariant coverage is the join of `result.assertion_fires` against the catalog. An invariant
  is **covered** when **any** of its checks fired; an invariant that never fired is **uncovered
  (dynamic vacuity)**.
- This completes `PropertyDamage.Coverage`'s previously-stubbed "check coverage": per-assertion
  fire counts populate the (renamed) assertion-coverage data, and `Coverage.meets_threshold?/2`
  gains an `assertion_coverage:` key. `PropertyDamage.assertion_coverage(result, model)` returns
  the per-invariant breakdown from a single result with **no re-execution**.
- Fire counting is **always on** (it is an O(1) counter increment). By default a run emits a
  **terse footer** (through the existing verbose reporter, never unconditional stdout) of the
  form `invariants: N/M exercised`, counting invariants, suppressed on failing runs. A
  0-firing invariant **warns** by default; failing a run on uncovered invariants is opt-in via
  `Coverage.meets_threshold?(tracker, assertion_coverage: 100)`, not a new run option.
- A new `coverage: true` run option enables the heavier whole-run coverage dimensions
  (command/transition/state), which are accumulated across all sequences for the first time
  (see Context); the assertion-coverage footer does not require it.

## Context

**Why this completes-and-corrects rather than adds.** `PropertyDamage.Coverage` already
declares a `check_hits` field, wires it through `new`/`record`/`merge`/`to_json`/`format`/
`meets_threshold?`, and its moduledoc advertises both a `coverage: true` run option and
"check coverage: which checks have been exercised." None of that is real: `count_check_hits/2`
is a stub that returns its accumulator unchanged (with the comment *"ideally we'd track which
checks ran"*), the `coverage: true` option does not exist, and nothing accumulates coverage
across the generated sequences of a run — `from_result/2` sees a single result (the summary's
representative sequence, or a failure's shrunk one). So command/transition/state coverage,
though genuinely computed, silently report one sequence as if it were the whole run, and check
coverage reports nothing at all. This decision finishes the reserved slot: it adds the
per-assertion fire data the engine never produced, threads a genuine whole-run accumulator
through the run loop, gates the heavy dimensions behind a `coverage: true` option that now
exists, and corrects the moduledoc. The prior observability "Check coverage" requirement was
therefore aspirational; it is now realized and renamed to assertion/invariant coverage.

**Why invariant identity is separate from description lookup.** Two concerns hide under
"invariant" and have opposite requirements. The *structural* concern — which checks validate
which invariant, reference resolution, uniqueness — must be compile-time and per-projection, so
a typo in `validates:` fails the build and the structural graph travels with the reusable
projection. The *descriptive* concern — the human sentence — can be resolved lazily at report
time and MAY come from an external source. Fusing them would destroy typo-safety (a runtime
resolver cannot reject a misspelled `validates:` at compile time) and reintroduce the
compile-order and dependency-inversion problems that per-projection scope avoids. The design
keeps them apart: the description resolver enriches descriptions for already-known invariants;
it never defines the namespace or resolves references.

**Why anti-vacuity is the headline, not naming.** Naming and enumeration make the catalog
*prettier*; coverage makes it *trustworthy*. An `@trigger every: RareEvent` assertion that never
triggers reports green while never exercising the guarantee it claims to check — a vacuous pass.
Static vacuity (an invariant with no check) and dynamic vacuity (a checked invariant that never
fired) are the same failure — "a guarantee not actually verified" — caught at compile time and
at run time respectively.

**Why "fired" for a poller is spawn, not resolution.** Anti-vacuity asks whether a liveness
invariant was *engaged*. A poller spawns exactly when a matching `after:` event is observed, so
zero spawns means the triggering event never occurred — precisely the vacuous case. Counting
resolution instead would undercount pollers still pending at shutdown and would conflate
"exercised" with "passed," so a timed-out liveness check would look uncovered. Spawn is also
synchronous in the executor, so the count rides the existing counter thread with no asynchronous
plumbing.

**Compatibility.** Every existing assertion gains a default invariant whose `id` is its own
name, with no description; the catalog and coverage are therefore populated for existing models
without any change to them. The new keywords (`@invariant`, `validates:`, inline `id:`/
`description:`) are additive and optional. `result.assertion_fires` and the terse footer are
new outputs; the footer routes through the existing reporter and is silent without a verbose
consumer. The widened `check_hits` key space is invisible externally (the field was always
empty). The framework is pre-1.0; the additive surface is recorded in the changelog.

## Consequences

- `lib/property_damage/model/projection.ex`: `__on_definition__` records `validates:` and inline
  `id:`/`description:` into each assertion's metadata (a new `:invariant_id` and the description),
  extracting them before trigger-timing normalization so the existing `every:`/`at:` validation
  is untouched. `__using__` registers an accumulating `@invariant` attribute; a new
  `@before_compile` step builds `%Invariant{}` structs via `new!/1`, enforces id-uniqueness and
  `validates:` resolution (raising `CompileError`), warns on declared-but-unchecked invariants,
  and generates `__invariants__/0 ⇒ %{id => %Invariant{}}`. The default `invariant_id` is the
  `assert_`-stripped logical name. A new `PropertyDamage.Invariants.Invariant` module carries the
  struct, `new!/1`, and `fetch!/2`.
- `lib/property_damage/executor.ex`: per-assertion fire counts are recorded as
  `{:fired, projection, name}` keys **inside** the existing `assertion_counters` map — proven
  inert to `should_run?/4` (which does only point lookups and never iterates the map) and to the
  branch merge (the delta-from-prefix formula in `merge_branch_states` is exactly correct for
  additive counts), so no new threading or merge code is required. Increments are added at the
  `should_run?` true branch (`run_projection_assertions`), the lifecycle dispatch
  (`run_phase_projection_assertions`), the asynchronous dispatch (`check_async`/
  `check_async_event`), and the synchronous poller-spawn site (`maybe_spawn_pollers`).
- `lib/property_damage.ex`: `do_run/…` threads a whole-run coverage accumulator through its
  existing recursion, projecting the `{:fired, …}` keys out of each sequence's counters and
  folding them into `result.assertion_fires` on every result. A new `coverage: true` option
  (added to `options.ex`) additionally accumulates the command/transition/state dimensions
  across all sequences. `PropertyDamage.assertion_coverage(result, model)` joins
  `result.assertion_fires` against `assertion_catalog(model)`.
- `lib/property_damage/coverage.ex`: `count_check_hits/2` is replaced by lifting
  `result.assertion_fires` into `check_hits` (widened key `{module, atom}`); `record_from_data`
  reads the field; `meets_threshold?/2` gains `assertion_coverage:`; `format/2` gains an
  assertion-coverage section listing each invariant's fire count and an explicit uncovered block;
  the moduledoc's fictional `coverage: true` example and whole-run claim are corrected.
- `lib/property_damage/model.ex`: `assertion_catalog/1` enumerates the model's projections (the
  command-sequence projection plus assertion projections, deduplicated), unions their
  `__invariants__/0` keyed `{projection, id}`, and attaches each invariant's checks and per-check
  kind.
- `lib/property_damage/failure_report/formatter.ex`: a failure headlines the invariant (`name` +
  `description`, resolved via `fetch!` and stamped onto the failure at capture so the formatter
  stays pure), with the specific failing assertion as secondary detail.
- `lib/mix/tasks/pd.validate.ex`: prints the static catalog (every invariant per projection with
  its description and checks) and reports static-vacuity (declared-but-unchecked) entries.
- `openspec/specs/projection/spec.md`: invariant declaration (`@invariant`), linking
  (`validates:`), inline declaration, default-id, the `%Invariant{}`/`new!`/`fetch!` contract,
  and the compile-time validations.
- `openspec/specs/observability/spec.md`: the "Check coverage" requirement is corrected to real
  per-assertion fire recording; anti-vacuity reporting, the `coverage: true` whole-run
  accumulation, the `assertion_coverage:` threshold, the catalog enumeration, and the terse
  footer are added.
- `openspec/specs/execution-engine/spec.md`: per-assertion fire counting at the synchronous
  sites, whole-run accumulation, and `result.assertion_fires`.
- `openspec/specs/eventual-consistency/spec.md`: poller-spawn counts as fired; the asynchronous
  observation paths record firing.
- `openspec/specs/model/spec.md`: `assertion_catalog/1` enumeration across projections.
- `openspec/specs/failure-analysis/spec.md`: failure reports name the invariant and its
  description.
- Acceptance (failing-first): a model declares `@trigger every: NeverEmitted` alongside a
  normally-firing assertion; after a run the never-emitted invariant is reported uncovered
  (0 firings) and the other covered (>0) — red against the pre-change engine (no per-assertion
  data exists), green after. Companion tests: a description flows into the failure report in
  place of the bare name; the catalog enumerates across multiple projections and dedups a
  doubly-listed one; firing is counted from the async (DR-025), `at:` (DR-024), and poll-spawn
  paths, not only `every:` on own events; per-assertion counts merge across parallel branches;
  duplicate `id` and dangling `validates:` raise `CompileError`; a rare invariant that fires in
  an early sequence but not the representative one is reported covered (guarding the
  single-result bug).

## References

- `openspec/specs/projection/spec.md`
- `openspec/specs/observability/spec.md`
- `openspec/specs/execution-engine/spec.md`
- `openspec/specs/eventual-consistency/spec.md`
- `openspec/specs/model/spec.md`
- `openspec/specs/failure-analysis/spec.md`
- Related: DR-012 (Trigger-Based Assertions — the `every:` axis the invariant id rides),
  DR-024 (Lifecycle-Boundary Assertions — the `at:` firing paths coverage counts),
  DR-025 (Continuous Async-Observation Checking — the async firing paths coverage counts),
  DR-014 (Assertion Modes), DR-009 (Projections See Commands and Events), DR-022 (Unified
  Progress Projection — the reporter the footer routes through), DR-017 (Hierarchical Delta
  Debugging — failure reporting the invariant name feeds)
