# DR-065: One Run Driver, Not Only One Step Seam

**Status:** Accepted
**Date:** 2026-11-07

## Context

DR-045 made the lockstep scheduler the one engine for a run of one or more
targets. DR-044 made `Executor.Stepping` the one per-command seam. Several
callers still ran a plan another way: trace capture and trigger isolation
called `Executor.run/4`, the one-target path that does not drain the event
queue after each root. The scheduler drains after every root, so the events a
run folds at a boundary were missing from a trace of that run, and isolation
judged candidate values against a run that differed from the campaign's.

Each fix to one path had to be repeated in the others. A reproduction that
passed through the scheduler could still disagree with the trace that
explained it.

## Decision

1. `PropertyDamage.Runner.execute/2` is the one run driver. It takes a plan
   and a `PropertyDamage.Runner.Context` and runs them through
   `PropertyDamage.Scheduler.run/1`.
2. The boundary drain is part of every run: a campaign run, the reproduction
   of a failure, the capture of a `RunTrace` and the trigger isolation of
   `PropertyDamage.Analysis` all go through `Runner.execute/2`. A trace's step
   events are the events of the run it explains.
3. `RunTrace.Capture.capture/1` runs every model through one path. A model
   without expansions runs its roots as themselves; a model with expansions
   runs the leaves its target chose. Trigger isolation reruns on the
   reference target with the injectors and mocks its report recorded.
4. `Executor.run/4` stays as a one-target seam that does not drain per root.
   It is not how a run executes. The executor's own tests use it.
5. The shrinker's candidate runs go through the runner. Status: done; the
   shrinker hands each candidate to an oracle that `Runner.shrink_oracle/2`
   builds, and no longer calls the scheduler.

## Alternatives

- **Drain inside `Executor.run/4`.** Rejected: it would add the scheduler's
  boundary logic to a second driver, and the two would drift again.
- **Delete `Executor.run/4` now.** Rejected: many tests call it as the
  one-target seam of the executor, and moving them is a change of its own.

## Consequences

- A trace of a run records the events the run folded at each boundary. The
  step events of a trace captured before this change lack them.
- Isolation lists the values that pass when the commands run as the campaign
  ran them, injectors included.
- DR-045 carries a note that this record amends it.

## Open questions

- Whether `Executor.run/4` is deleted once its callers move to the runner or
  the stepping seam is not decided.
