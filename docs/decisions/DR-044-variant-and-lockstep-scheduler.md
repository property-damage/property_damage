# DR-044: Variants and the Lockstep Scheduler

**Status:** Accepted. Amended by DR-045: `Differential.run/1` and `Differential.Result` are deleted and `PropertyDamage.run/1` takes several targets; a divergence is a shrunk failure that ends the run, with no `divergences` list; the failure kinds gain `:diverged`. Amended by DR-046: there is no default root observation (variants are compared only through `@compare`), and an adapter error is a failure, never compared and continued; `compare: :performance | :both` is `latency: true`.
**Date:** 2026-10-05

## Context

`PropertyDamage.Differential.run/1` ran its targets through its own loop, not
through the per-command engine. That loop had two scheduling modes
(`execution: :interleaved` and `:sequential`), set every target up once per
campaign, called the adapter directly, and refused `runtime.start_poller`.
Checks, settle, stutter, nemesis, injectors and mocks did not run in it.

DR-042 decided that a run is a root sequence executed by one or more variants
through the per-command engine, and DR-043 gave every target its own
injectors and mocks. This record fixes how variants run and how a
multi-target run schedules them.

## Decision

1. **A variant is one target over the shared concrete sequence, in its own
   process.** `PropertyDamage.Variant` runs the target through the
   per-command engine (`Executor.Stepping`). It owns its projections and event
   log, its copy of the placeholder registry, its event queue, its injectors
   and mocks, and every `@eventually` poller and resource poller its commands
   start. Checks, settle, stutter, nemesis, injectors and mocks therefore work
   in every variant, as they do in `PropertyDamage.run/1`. A variant's pollers
   die with it, even if the process is killed.
2. **Lockstep is the one scheduling mode.** `PropertyDamage.Scheduler` runs
   one generated sequence. Every command is a root. Every variant advances to
   boundary `r` (the point after root `r`), the comparison runs, and only then
   does any variant start root `r + 1`.
3. **`concurrency:` replaces `execution:`.** `concurrency: :serial` (default)
   advances one variant at a time, in target order. `concurrency: :parallel`
   advances all variants at once; targets that share a system must isolate
   their slices of it through `config:`. `execution:` is removed with no
   mapping. Passing it is an option error that names `concurrency:`.
4. **`compare: :performance` and `:both` require `concurrency: :serial`.**
   Under `:parallel` the targets' load would mix into each other's timings.
   The combination is an option error.
5. **Setup and teardown run per run.** Each run calls `Adapter.setup/1` once
   per variant, in the variant's own process, one variant after another in
   target order. A barrier holds root 0 back until every setup has returned
   and every `@check at: :startup` check has passed. `setup/1` must be
   idempotent, because it can find state a previous run left behind. A setup
   error names the variant, and the variants already set up are torn down.
6. **The default root observation.** A variant observes a root as its
   injected events followed by its returned events, `{:ok, events}`, or as
   the adapter's raw `{:error, reason}`. A `:probe` or `:async` root is
   observed after it settles. One function in the scheduler compares the
   observations through the existing equivalence strategies (`:exact`,
   `:structural`, a 2-arity function), so a later decision can change what is
   compared in one place.
7. **Adapter errors.** With two or more variants, an adapter `{:error, _}` is
   an observation: it is compared and the variant continues from the failed
   command's state. A later command that consumes a value the failed command
   never produced is observed as `{:error, {:placeholder_resolution_failed,
   reason}}`, and the variant continues. With one variant an adapter error
   ends the run, as it does in the single-target engine.
8. **Failures name the variant.** A failure is a map with `kind`, `variant`
   (`%{index, name}`), `run`, `root` and `reason`. There are three kinds:
   `:check_failed` (a check failed, including a startup, `@eventually` or
   teardown check), `:setup_failed` (`setup/1` returned an error or raised)
   and `:execution_failed` (the adapter raised, a command could not be
   executed, or the variant crashed; never compared). The full failure
   taxonomy arrives when the single runner replaces the separate loops.
9. **What ends what.** A failure ends the run at that boundary, and ends the
   `Differential.run/1` campaign (`status: :failed`). A divergence ends only
   its run; the next run starts. `divergences` are listed oldest first. Each
   divergence names its `run`, `root`, `command`, `variant`, the reference
   and divergent observations, and every variant's observation by name.
10. **Per-variant RNG seeding.** A new process draws fresh entropy for
    `:rand`, so an adapter that draws random values in `setup/1` would break
    same-seed reproduction. Before anything runs, the variant seeds its
    process with
    `:rand.seed(:exsss, :erlang.phash2({Generator.run_seed(seed, run_number), target.index}, 4_294_967_296))`.
    The seed covers what runs in the variant process: the adapter's
    `setup/1`, `timeout/1` and `teardown/1`, injector and mock setup,
    projections and checks. Two runs of one seed draw the same values there;
    two variants of one run draw different ones. It does not cover
    `execute/3`, which the engine runs in a new Task per attempt with its own
    entropy, as `PropertyDamage.run/1` does. Stutter keeps its own generator,
    derived from the run seed (DR-029).
11. **`runtime.start_poller` and per-target resources.**
    `runtime.start_poller` is allowed in multi-target runs, and its events
    reach only the variant that started it. The old refusal in
    `Differential.run/1` is gone. `Differential.run/1` honors each target's
    `injectors:` and `mocks:`.
12. **`Executor.Stepping` changes.** `step/4` returns the raw outcome of the
    command: `{:ok, state, outcome}` or `{:error, failure, state, outcome}`,
    with `outcome` one of `{:ok, events}`, `{:error, reason}`,
    `{:raised, exception}` and `:not_called`. `drain/2` folds the events
    waiting in the queue into the state; a variant calls it at every
    boundary. `finalize/2` finishes a stepped run into the result
    `Executor.run/4` reports.

## Rationale

- One engine path for every variant removes the feature gap that DR-042
  names: a differential run gets the checks, pollers, nemesis and settle a
  property-based run has.
- Lockstep gives a comparison at every root with one rule. The two old modes
  differed in when the comparison ran and in how timings were taken, and a
  choice between them hid the question that matters: whether the targets may
  overlap in time.
- A process per variant is the only way to keep per-variant pollers, queues
  and mocks from mixing, and to remove all of them when the variant exits.
- Setup per run makes every sequence start from the state `setup/1`
  establishes. Setup once per campaign let one run's leftovers decide the
  next run's result.
- Seeding each variant makes a same-seed run reproduce the randomness drawn
  in the variant process, and the target index keeps two variants from
  drawing the same values.
- Naming the variant in every failure lets a report say which target failed
  without a second lookup.

## Alternatives considered

- **Keep both execution modes next to `concurrency:`.** Rejected: pre-v1
  clean break. A second option for the same question keeps two ways to ask it.
- **Map `execution: :interleaved` to `:serial` and `:sequential` to
  `:parallel`.** Rejected: the old names described the shape of the loop, not
  whether targets overlap, so a mapping would mislead.
- **Set targets up once per campaign and reset in the adapter.** Rejected:
  the framework cannot know what a reset must cover, and the single-target
  engine already sets up per run.
- **Let `:parallel` run with `compare: :performance`.** Rejected: overlapping
  load distorts the timings the comparison reports.
- **Share one process for all variants.** Rejected: pollers and queues would
  need per-variant tagging, and a crash in one target would take down the
  rest.

## Not decided here

- `PropertyDamage.run/1` keeps its own loop for now.
- Shrinking across variants. `Differential.run/1` does not shrink.
- A `latency:` option for the comparison.
- A settle loop at the boundary. A variant observes what its command
  returned (or settled to); it does not wait for other events before the
  comparison.

## Consequences

- `PropertyDamage.Differential.Result` has `concurrency` instead of
  `execution`, a `failure` field, and `status: :failed`. A divergence has
  `variant`, `root` and `run`; the `divergent_target` and `step` keys are
  gone.
- `PropertyDamage.Variant` and `PropertyDamage.Scheduler` are new public
  modules. `Executor.Stepping.step/4` has a new return shape, and
  `Replay` follows it.
- `Differential.run/1` calls `setup/1` once per run per target. A guide
  that told readers to loop with `max_runs: 1` to force a fresh setup no
  longer needs the loop.
- DR-042 item 1 says `Differential.run/1` and its separate loop are
  removed. The separate loop is gone, and `Differential.run/1` stays as the
  multi-target entry point on top of the scheduler until the single runner
  lands.
