# DR-023: Seed Library as an Ephemeral Replay Working Set

**Status:** Accepted
**Date:** 2026-06-18

> Recorded as a design pass, then implemented. It supersedes the seed-library
> portions of DR-020 (export/import for sharing,
> the `:failing`/`:fixed`/`:flaky` status machine) and specifies the
> `seed_library:` run integration that DR-020 claimed but which was never wired.
> The failure-file (`.pd`) version-aware portions of DR-020 are unaffected.

## Decision

The seed library is an **ephemeral, self-pruning working set of recently-failing
seeds that `run/1` replays before random exploration** — not a durable regression
corpus. Its sole job is to address the probabilistic nature of property-based
testing: a path that already produced a failure is replayed deterministically at
the start of a run, so the user does not have to wait for random generation to
rediscover it while fixing the bug.

**The load-bearing constraint.** A seed reproduces its command sequence *only
while the model's generators are byte-stable*. Changing a generator, weight,
`when:` predicate, or the command set makes seed *N* replay a *different*
sequence. A stored seed is therefore a fragile, version-local pointer, not a
durable test of a behavior. Two consequences follow and shape everything below:

1. **Durable regressions are the Export subsystem's responsibility.** Exporting a
   failure to an ExUnit test freezes the concrete shrunk sequence, which survives
   generator changes. The seed library must not duplicate that role.
2. **The seed library is a transient working set that self-cleans**, so it never
   accumulates into a stale corpus that the user must maintain.

### Surface and default

- A **top-level `seed_library:` option on `PropertyDamage.run/1`**, typed
  `{:or, [:boolean, :string]}`, **default `false`**:
  - `false` (default) — disabled; `run/1` neither reads nor writes any file.
  - `true` — use the default file `property_damage_seeds.json`.
  - `"path"` — use an explicit file.
- **Off by default.** Enabling is an explicit, one-option opt-in. This avoids
  writing files as a surprise side effect of an ordinary test run and confines
  the concurrency exposure (below) to runs the user has deliberately enabled.

### Replay lifecycle inside `run/1`

When enabled and the library is non-empty, a **replay phase runs before random
exploration**, as a sibling of the random run loop *inside the same `do_run`*:

1. It reuses the existing per-sequence machinery (`setup_each` → `Executor.run`
   → `teardown_each`, event queue, injectors) under the single `setup_once`/
   teardown that `do_run` already owns. It does **not** call `PropertyDamage.run/1`
   recursively. (The prior, dead library-replay path did exactly that and is
   removed; see Consequences.)
2. Every library seed is replayed once. The verdict is **binary — pass or fail**;
   failure *signatures are not compared*.
   - **pass** (no failure): increment the entry's consecutive-pass streak.
   - **fail** (any failure): reset the streak to 0, and **refresh** the entry's
     descriptive `failure_type`/`check_name` from the new failure report so the
     description never goes stale.
3. **Pruning:** an entry whose streak reaches **K consecutive passes is removed**
   (default `K = 3`, configurable). Flaky seeds keep failing intermittently, so
   their streak keeps resetting and they self-retain; genuinely-fixed seeds pass
   K times and self-prune. The same rule transparently absorbs generator drift: a
   seed that no longer reproduces anything simply ages out.
4. **On still-failing replays — replay all, then halt with a summary.** All
   library seeds are replayed (so statuses update and pruning happens) even if an
   early one fails; then, if *any* still failed, `run/1` **halts before random
   exploration** and returns `{:error, failure}` for a representative
   still-failing seed plus a gating summary of the rest. If all pass, exploration
   proceeds normally. Red stays red; the user sees every still-broken seed.
5. **Budget:** replays do **not** consume `max_runs`. `max_runs` remains the
   exploration budget; replay counts are reported separately.
6. **Auto-append:** when `seed_library:` is enabled and a *new* failure is found
   during exploration, its seed is appended to the same file (deduplicated by
   seed). The file is thus both the replay source and the sink, which closes the
   edit-rerun fix cycle without the user wiring a separate handler.

### Observability (mandatory, not behind `verbose:`)

Because enabling the library changes behavior and writes a file, the replay phase
**announces itself**:

- A **start banner** and a **halt summary** print **unconditionally when the
  library is enabled** (and non-empty / halting, respectively). The banner states
  *what* is happening (N seeds being replayed, from which file), *why* (they
  previously failed), *when it stops* (auto-drop after K consecutive passes), and
  *how to disable it* (`seed_library: false`). The summary reports
  replayed / passed / pruned / still-failing counts and the halt reason.
- **Per-seed** pass/fail/prune lines print only under `verbose:`.
- All of the above are emitted as structured progress updates through the unified
  reporter (DR-022), so telemetry and `on_progress:` consumers observe them too.

### Status model and schema

The previous lifetime-counter status machine
(`run_count`/`fail_count`/`:failing`/`:fixed`/`:flaky`, with a hard threshold of
3) is **replaced** by a single **`consecutive_passes`** streak field. The old
machine was both dead (no caller in any run loop) and unsound: once `fail_count`
exceeded 0, a genuinely-fixed seed could never return to `:fixed` and was pinned
to `:flaky` forever. `failure_type`/`check_name`/`dependency_versions` are
retained as **inert descriptive metadata** (useful in the console banner and in
`stats`/`format`); they participate in no verdict logic.

### Persistence and concurrency

- Persistence stays a plain JSON file via `save`/`load`, so the working set
  survives across `run/1` invocations (the fix cycle spans fresh BEAM processes).
  There is **no session TTL**; per-entry pruning is the only lifetime mechanism.
- Writes are **atomic** (write to a temporary file, then rename) so a reader never
  observes a partially-written file.
- The working set is **best-effort and non-authoritative** (the durable artifact
  is the Export'd test). Concurrent writers — e.g. several `async` ExUnit tests
  each calling `run/1` against the same enabled file — are therefore
  **last-writer-wins**: a lost append is harmless (that seed merely isn't replayed
  next time), and atomic writes keep the file always-parseable.

## Context

`PropertyDamage.SeedLibrary`'s moduledoc advertised three things — "run failing
seeds first, then random exploration," automatic status tracking, and a shareable
regression corpus — none of which were wired. There was no top-level
`seed_library:` option on `run/1`; `record_run/3` had no caller in any run path;
and the only library-aware code in the failure pipeline
(`Regression.load_failures_from_library/2`) reached for the SUT by calling
`PropertyDamage.run/1` recursively from inside a failure handler, gated on a
`model:` option that was never part of `regression_opts` — so it was both unsound
in shape and unreachable in practice.

Rather than build the advertised durable corpus, the decisive reframing was to ask
what a seed can honestly promise. Because a seed is only meaningful against frozen
generators, a *persistent* seed corpus is intrinsically fragile and imposes
exactly the maintenance burden it purports to save. The durable-regression role
already has a correct home (Export → ExUnit, which stores the concrete sequence).
That leaves the seed library a narrower, honest job: a short-lived replay working
set that self-prunes, so known-failing paths are re-checked first during a fix
cycle without the user curating anything.

Two alternatives were considered and rejected. **Exploration-seeding** (fold
"interesting" seeds into the random stream to find new bugs faster) collapses into
regression-gating here: a deterministic seed has zero exploratory variance, and
the library only ever holds previously-failing seeds, so there is no distinct
"interesting" population to seed. **A persistent, version-fingerprinted corpus**
(invalidate entries when a model/generator fingerprint changes) was rejected as
re-introducing the staleness burden; consecutive-pass pruning already absorbs both
"bug fixed" and "generator drifted" with one rule and no fingerprint machinery.

Making the library **on by default** was considered (zero-config value) and
rejected: it would write a mutable file into every project on every run and expose
a shared file to corruption under `async` test concurrency. Default-off with a
trivial opt-in keeps the surprise and the concurrency exposure out of the common
path while still closing the fix-cycle loop for users who ask for it.

## Consequences

- `PropertyDamage.run/1` gains a top-level `seed_library:` option
  (`{:or, [:boolean, :string]}`, default `false`) and a pre-exploration replay
  phase in `do_run`, sharing the existing setup/execute/teardown machinery. The
  phase emits progress updates through the DR-022 reporter.
- `PropertyDamage.SeedLibrary`:
  - `record_run/3` is rewritten to streak semantics and gains a prune step; the
    `run_count`/`fail_count`/`status` tri-state is replaced by `consecutive_passes`.
  - The library `version` is bumped; `load/1` tolerates pre-existing files (it
    already no-ops missing fields).
  - `export/2` and `import/2` are **removed**, along with all "share across team /
    build a regression suite" framing; `save`/`load` are the only persistence, and
    writes become atomic. `add_seed/3`, `stats/1`, and `format/1` are retained,
    adjusted to the new schema.
  - The moduledoc is rewritten to the ephemeral working-set model and points
    durable/shareable regressions at the Export subsystem.
- `PropertyDamage.Regression`:
  - `load_failures_from_library/2` is **removed**; `dedup_source` collapses to
    `:failures` only (the `:library` and `:both` values are dropped, default
    becomes `:failures`). Observable dedup behavior is unchanged because the
    library branch always returned an empty list. `model:` is never added to
    `regression_opts`.
- Specs: the `persistence` spec's "Seed Library" requirement (export/import,
  tri-state status updates) and any "runs failing seeds first" claim are rewritten
  around this model; the `execution-engine`/`observability` specs gain the replay
  phase and its reporting. (Spec sync accompanies implementation.)
- DR-020 is **partially superseded**: its seed-library export/import-for-sharing
  and status-machine claims are reversed here; its `.pd` failure-file
  version-aware format is unaffected.

## Implementation notes

- **No recursion.** The replay phase must drive `Executor.run` directly within the
  existing `do_run` lifecycle, never `PropertyDamage.run/1`. One `setup_once`,
  one teardown, one event-queue/injector lifecycle per replayed sequence as for a
  normal run.
- **Halt-report fidelity.** A library entry stores only the seed, so a
  representative still-failing seed is re-derived (run-0 derivation) and **shrunk**
  to produce a proper minimal `FailureReport`, consistent with `run/1`'s normal
  failure contract. This costs one shrink on a red run.
- **Replay order.** Replay most-recently-discovered first.
- **Atomic writes.** Write to a temp file in the same directory, then rename;
  never write the destination in place.
- **K is configurable** via a run option; its value feeds the "when will it stop"
  line in the start banner, so the two must stay in sync.
- **Interaction with explicit `seed:`.** An explicit `seed:` still gets its
  exploration run after the replay phase completes (and only if replays pass).

## References

- DR-020 (Composable, Version-Aware Libraries) — partially superseded by this
  record for the seed-library surface.
- DR-022 (Unified Progress Projection) — the reporter the replay phase emits
  through.
- DR-017 (Hierarchical Delta Debugging) — the shrinking used for halt-report
  fidelity.
- `openspec/specs/persistence/spec.md` (Seed Library), `execution-engine` and
  `observability` specs — updated alongside implementation.
