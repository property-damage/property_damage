# DR-024: Lifecycle-Boundary Assertions (`@trigger at:`)

**Status:** Accepted
**Date:** 2026-06-23

> Recorded as a design pass, to be implemented next. It extends DR-012
> (Trigger-Based Assertions) with a second trigger axis and does not change the
> existing `every:` or `@poll_state` behavior. Implementation is pending at the
> time of writing; the spec deltas in `openspec/specs/projection`,
> `openspec/specs/execution-engine`, and `openspec/specs/eventual-consistency`
> describe the target behavior.

## Decision

Add a second timing axis, `at:`, to the existing `@trigger` attribute. Where
`every:` samples an assertion *during* the command loop (after commands and
events, optionally every Nth), `at:` fires an assertion exactly once at a
**lifecycle phase boundary**:

- `@trigger at: :teardown` evaluates the assertion once on the **fully-settled
  final projection state**, immediately before `Adapter.teardown/1` runs. "Settled"
  means after both the state pollers (`@poll_state`) and the resource pollers have
  finalized: the one point in a run where no poller is live and every observed event
  has been folded into projection state.
- `@trigger at: :startup` evaluates the assertion once on the **initial projection
  state** (`init/0`), immediately after `Adapter.setup/1` and before the first
  command.

Constraints:

- An assertion carries **exactly one** timing: `every:` xor `at:` (and never with
  `@poll_state`), enforced at compile time, consistent with DR-012's single-trigger
  rule.
- The assertion keeps the two-argument shape `(state, command_or_event)`. At a phase
  boundary there is no triggering command or event, so the second argument is the
  phase atom (`:startup` or `:teardown`), which a state-only assertion ignores.
- `at:` assertions reuse the synchronous-assertion machinery: the same `@on_definition`
  detection, the same `__assertions__/0` metadata (recorded with the phase), the same
  pass-by-returning / fail-by-raising contract, the same `assertion_mode` handling
  (`:halt` / `:record` / `:log` / `:disabled`), and the same named-failure reporting.

Evaluation rules:

- `at: :teardown` runs on the **clean-completion path only**. It does not run when a
  run aborts early (an adapter crash, a synchronous `@trigger` failure, a
  ref-resolution error), because those have a more proximate failure and an unsettled
  state. A genuine `@poll_state` liveness timeout is itself a not-settled outcome and
  **preempts** the `:teardown` checkpoint: the run reports the poll timeout, and the
  checkpoint does not run (there is no settled state to evaluate).
- `at: :startup` runs **unconditionally** at the start of every run (startup always
  precedes any later abort). A failing `:startup` assertion halts the run before the
  first command.
- `Adapter.teardown/1` runs regardless of an `at: :teardown` verdict, so a failing
  safety assertion never leaks SUT resources (DR-015).

## Context

Verifying eventually-consistent systems requires both halves of "effectively-once"
(at-least-once delivery plus an idempotent or deduplicated effect):

- **Liveness** ("the effect eventually happens"): expressed today by `@poll_state`,
  whose poller resolves the instant its predicate is first true and then stops. This
  is a reachability test.
- **Safety** ("the effect never happens too much"): the bound that was missing. A
  `@poll_state` predicate cannot express it, because a value can pass *through* the
  correct number on its way to overshooting, and the poller resolves on that transient
  pass and stops watching. A synchronous `@trigger` cannot host it either, because it
  fires while a command and its own events are processed, before an asynchronous effect
  (for example a non-idempotent retry, or an undeduplicated duplicate) has settled.

A safety property ("this always holds") is the temporal dual of `@poll_state`'s
liveness ("this eventually holds"). Its natural evaluation point is the moment the
system has settled, on the final state. This is what `at: :teardown` provides, and it
closes the gap that motivated the decision: a persistent over-application (a counter
left above its expected value, a job applied twice) is still visible on the settled
state and is reported as a clear, named assertion failure rather than as a generic
poll timeout.

**The accumulator contract.** Because the projection is a fold over the full observed
event stream and the `:teardown` checkpoint runs after that fold completes, detection
depends on the projection *retaining evidence* of a violation. A safety projection
SHOULD accumulate (for example track a maximum observed value, a sticky `violated?`
flag, or an application count) rather than snapshot the latest value. A snapshot
projection that heals back to a legal value before settling would hide a transient
over-application. This is the central authoring guidance for `at: :teardown`
assertions and is documented prominently in the projection guides.

`at: :teardown` also makes real a timing that earlier documentation described but the
code rejected: an "end of sequence" check. The precise term is "settled" (after
pollers drain), not merely "end of the command sequence," which is why the chosen
phase name follows the adapter's own `setup`/`teardown` lifecycle vocabulary
(DR-015) rather than a sequence-relative one.

**Non-goal (deferred).** Evaluating safety assertions *continuously* at each
asynchronous observation (so a violation is reported at the exact event that caused it,
tightening the shrinker's target) is intentionally out of scope here. On an
accumulating projection it adds no detection power, only diagnostic locality and
cheaper failing runs; it belongs to the `every:` axis (asynchronous observations are
"during" the run) and is recorded as future work. The settled checkpoint is sufficient
for the safety bound itself.

## Consequences

- `lib/property_damage/model/projection.ex`: the trigger normalizer learns the `at:`
  key with values `:startup` and `:teardown`; the `@on_definition` hook records the
  phase in `__assertions__/0` metadata; the single-timing and dangling-attribute
  compile guards extend to `at:`.
- `lib/property_damage/executor.ex`: a `:startup` evaluation point after
  `init_projections` and `setup/1` and before the command loop; a `:teardown`
  checkpoint on the merged settled projections in result finalization, after both
  poller-finalize steps and before `teardown/1`, on the clean-completion path only.
  Branching evaluates `:teardown` once on the merged state; `:startup` runs on the
  shared initial state before any branch.
- Reporting: a phase-boundary failure surfaces through the existing named-assertion
  failure path, with the phase recorded so a message reads as a safety failure at
  `:teardown` (or `:startup`), distinct from a `@poll_state` poll timeout.
- `openspec/specs/projection/spec.md`: new requirement "Lifecycle-Boundary Assertions
  via `@trigger at:`"; the single-timing scenario extended to `at:`.
- `openspec/specs/execution-engine/spec.md`: the "Adapter Lifecycle" requirement gains
  the `:startup` and `:teardown` assertion evaluation points and their ordering
  relative to `setup/1` / `teardown/1`.
- `openspec/specs/eventual-consistency/spec.md`: the definition of "settled" (after
  state-poller and resource-poller finalize) and the liveness-timeout-preempts rule
  are recorded next to the State Poller requirement.

## References

- `openspec/specs/projection/spec.md` (header: "DR-024 (Lifecycle-Boundary Assertions)")
- `openspec/specs/execution-engine/spec.md`
- `openspec/specs/eventual-consistency/spec.md`
- Related: DR-012 (Trigger-Based Assertions), DR-014 (Assertion Modes), DR-009
  (Projections See Commands and Events), DR-015 (Adapter Separation), DR-018
  (Command-Triggered Resource Polling)
