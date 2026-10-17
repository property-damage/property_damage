# DR-053: Branching Runs One Branch at a Time Until the Concurrent Redesign

**Status:** Accepted
**Date:** 2026-10-17

## Context

`branching:` generates a sequence with a prefix, two or more branches and a
suffix, runs it on one target, and judges the branch commands with the
linearization checker. The guide, the README, the option documentation and
the concurrency specification describe this as race detection: lost updates,
dirty reads, write-write conflicts, phantom reads; the specification says
the branches "execute concurrently against the SUT".

The executor does not do that. `Executor.Branching` runs the branches one
after another on the one adapter context, each from the forked post-prefix
model state and with synchronous checks disabled, then calls
`Linearization.check/5`, then merges the branch states and runs the suffix.
The checker enumerates the interleavings depth first, extending from the
first branch first, so the first candidate it verifies is the order in which
the system was actually called. A system that behaves correctly when called
one command at a time produces, for that candidate, exactly the events the
simulator predicts, and the check halts with `{:ok, _}`. No two commands ever
overlap at the system, so no lost update, dirty read or write-write conflict
can occur, and none can be detected.

A probe on 2026-10-17 made this concrete: a register whose increment is a
read followed by a write of the read value plus one loses an update when two
increments overlap (by hand: read, read, write, write ends at 1; under two
concurrent increments with a rendezvous between read and write it ends at 1),
and 30 seeds of 60 branching runs each against that register all pass, as do
the same seeds through the linear engine.

What the check proves today is therefore: there is an interleaving,
consistent with the order inside each branch, in which every command's
observed events contain the simulator's predicted events (fields that are
`nil`, placeholders or external markers are wildcards) and every
step-triggered `@check` passes. Three weakenings sit on top of the sequential
limit.

- `{:indeterminate, _}` (no simulator, or the candidate cap reached without a
  consistent ordering) is recorded and the run passes. A correct run passes
  at the first candidate, so the cap bites only on failing runs; a failing run
  with three branches of five commands has 756,756 interleavings and becomes
  a pass.
- Any ordering counts. A sequential defect that another ordering explains is
  accepted: a read that returned `nil` after a physically earlier write is
  taken as "read first". The linear engine, with checks on, reports it.
- The one oracle the path adds is conformance of observed events to the
  simulator's prediction, judged at run time. The linear executor never
  consults the simulator; it folds observed events into projections and runs
  the checks. That oracle has nothing to do with concurrency.

The in-repo lost-update bench exercises the conformance oracle, not a race:
its seeded adapter reports every increment from a snapshot it never
refreshes, so the second sequential increment reports an event no ordering
explains.

A redesign with physical concurrency was named as a goal for the differential
engine: a rewrite's differential run should cover concurrency behavior. The
differential engine compares targets at root boundaries in lockstep (DR-043,
DR-044, DR-046) and has no boundary inside a branch set. Under physical
concurrency two correct targets may resolve one race differently, so neither
observed events nor projection state can be compared inside the set; and a
racy target is nondeterministic, so a seed no longer reproduces a failure,
shrinking is no longer deterministic, and a replay artifact (DR-050) replays a
history that may not recur.

## Decision

1. **Branching stays single-target and runs one branch at a time** until the
   concurrent redesign replaces it. The executor and the checker are not
   changed before then.
2. **The documentation describes what the path does.** The parallel-testing
   guide, the README, the `branching:` option documentation, the `Sequence`
   moduledoc and the concurrency specification's branch-execution requirement
   say that branches execute one after another on one adapter context, that
   the checker models the interleavings afterward, and that the path detects
   no race. The list of races it "catches" is removed. The specification
   requirement reads: branches SHALL execute one after another, with the order
   inside each branch preserved; the linearization checker SHALL judge the
   branch commands against the simulator's predictions over the interleavings
   that preserve that order.
3. **Two option errors.** `latency:` with `branching:` is refused, because the
   path records no latency samples. A `check_mode:` other than the default
   with `branching:` is refused, because the path ignores it.
4. **Documented limits.** These are stated in the guide and stay until the
   redesign: no `@eventually` poller is spawned for a branch command; a replay
   artifact of a failure found on the branching path and converted to linear
   cannot re-execute placeholders minted in a branch (DR-050); the generator
   builds every branch from the post-prefix state while the executor and the
   shrinker judge the branches in reading order, so a generated run can fail
   its own checks in the second branch; `{:indeterminate, _}` passes; an
   ordering other than the executed one can explain a sequential defect, so
   the path may accept a run the linear engine would fail.
5. **The redesign's requirements**, recorded so its design starts from them:
   branches physically concurrent; the branch set one boundary unit, with no
   comparison inside it; cross-target comparison at the set's end only
   through observations the model declares order-independent, or through a
   named relation (DR-051) that is order-insensitive by construction, with
   undeclared observations skipped or refused there; `expansion: :reference`
   only, since a rewrite inside a branch changes the calls that race; a
   repeat-based reproduction policy, because a racy target is
   nondeterministic, with the shrinker and the replay artifact adapted to it.
   It reuses the checker, the prefix-branches-suffix sequence shape with its
   placeholder scoping, and the branch-aware shrinker; it replaces the
   sequential executor path and the state merge.
6. **The conformance oracle** (observed events checked against the
   simulator's prediction at run time, on the linear path) is a separate
   decision, not taken here.

## Consequences

- The next release ships `branching:` as taught today minus the race claims,
  with two new option errors (a CHANGELOG `Changed` entry) and the guide's
  limits section. The persistence format does not change.
- A reader who wants race detection is told, in the guide, that the library
  does not test races yet.
- The redesign is its own design effort, not an increment on the shipped
  path. Its brief starts from decision 5 and the probe's register.
- The ETS register bench keeps its name and its seeded adapter; its moduledoc
  is corrected to say that the lost update it detects is a stale report under
  sequential calls.

## Alternatives considered

- **Delete branching and the checker now.** Rejected because the redesign
  reuses the checker, the sequence shape, the branch position vocabulary and
  the branch-aware shrinker, and because deletion removes the `branching:`
  option and three report fields, a breaking change with a persistence bump
  before the release. Git history would keep the code, but a return would be
  a rewrite of the same pieces.
- **Fail on `{:indeterminate, _}`, or verify the executed order only.**
  Rejected as changes to the feature's meaning weeks before its replacement;
  both are recorded as limits instead.
- **Redesign now.** Rejected: physical concurrency needs a probabilistic
  reproduction policy, which changes the shrinker, the replay artifact and the
  seed guarantees; that is a design effort with its own brief.
- **Keep the race claims and the specification as written.** Rejected: a
  library that advertises detection it cannot perform is worse than one that
  says it does not test races yet.
