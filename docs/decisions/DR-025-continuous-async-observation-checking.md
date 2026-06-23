# DR-025: Continuous Async-Observation Checking (assertions fire on asynchronously-observed events)

**Status:** Accepted
**Date:** 2026-06-23

> Recorded as a design pass, to be implemented next. It completes the non-goal
> deferred by DR-024 (Lifecycle-Boundary Assertions): evaluating `@trigger every:`
> assertions on asynchronously-observed events. It does not change the `every:`
> trigger surface or `@poll_state`; it changes *where* the existing synchronous
> dispatch runs. Implementation is pending at the time of writing; the spec deltas in
> `openspec/specs/execution-engine`, `openspec/specs/projection`, and
> `openspec/specs/shrinking` describe the target behavior.

## Decision

A `@trigger every:` assertion fires on **every observed event**, regardless of how the
event reached the run. Today it fires only on a command and that command's **own
returned events**; the asynchronous observation paths fold events into projection state
but never evaluate assertions. This decision removes that gap.

- The asynchronous event paths — resource-poller and injector-adapter events
  (`process_injector_events`), mock-service events (`process_mock_events`), nemesis
  events (`process_nemesis_events`), and the two finalize-time drains that route through
  the injector path (the `@poll_state` await drain and the settled-state drain) — invoke
  the **existing** synchronous-assertion dispatch after folding each event.
- Dispatch is gated by the **existing** `should_run?/4` on `step_type`/module. An
  asynchronously-observed event has `step_type: :event` and its own module, exactly like a
  command's own event. No event source is introduced into the assertion model; the engine
  has never distinguished "where an event came from," and this decision does not start.
- There is **no new trigger surface**: no new attribute, no new `every:` value, and no
  per-assertion or per-run opt-in flag. An assertion that should fire only after commands
  already has the vocabulary to say so: `@trigger every: :command`.

Evaluation rules:

- Async events are asserted **incrementally**: each event is folded into projection state,
  then the assertion dispatch runs on that new state for that event, then the per-event
  counters (`:step`, `:event`, and the event module) advance, before the next event. The
  reported failure therefore names the event that actually introduced the violation, and
  its `command_index` is carried as the failure's location.
- Command-own events keep their existing **batch-against-final** timing (folded together,
  then asserted against the final folded state). The asymmetry is deliberate (see Context).
- `assertion_mode` is honored exactly as today (`:halt` stops at the first violation —
  including mid-drain and during the finalize drains; `:record` accumulates;
  `:log` warns; `:disabled` skips).
- Branching evaluates async events per branch against that branch's own counter map, so the
  existing per-branch counter delta-merge stays correct.

A companion change sharpens shrink convergence:

- The shrinker's failure signature distinguishes assertion failures **by name**
  (`{:assertion_failed, name, _}` carries `name` as the signature's `check_name`), instead
  of conflating all assertion failures. An asynchronously-observed failure and a
  `@trigger at: :teardown` failure of the **same** assertion remain equivalent, so the two
  do not look like different bugs during shrinking.

## Context

DR-024 added `@trigger at: :teardown`, a settled-state checkpoint that made **detection**
of a safety violation complete on an accumulating projection: any over-application that
*any* event ever observed survives in the folded state and is caught at teardown. DR-024
explicitly deferred evaluating safety assertions *continuously* at each asynchronous
observation, recording it as future work on the `every:` axis. This decision is that work.

**Why it is a bug fix, not a new feature.** The public trigger table documents
`@trigger every: :event` as "after any event." Today that is not true: the assertion fires
on a command's own events but is silently skipped for poller, injector, mock, and nemesis
observations, because those code paths fold projections without calling the assertion
dispatch. `should_run?/4` decides whether an assertion fires from `step_type` and module
alone; it has never modelled an event's *source*. So firing on asynchronously-observed
events does not add a capability — it makes the documented `every:` contract true and
closes the standing gap where async observations escaped assertion checking. Anyone who
wants command-only firing already expresses it with `@trigger every: :command`.

**Why detection was already complete, so the win is locality.** Because a projection is a
fold over the full observed event stream and the teardown checkpoint runs after that fold,
a violation that was ever observed is already visible at teardown (DR-024). What the
teardown checkpoint cannot give is *locality*: its failure has no position
(`failed_at_index` is nil), so it reports "the settled state is wrong," not "this event
made it wrong." Continuous checking reports the violation **at the offending event**, with
that event's `command_index` as the failure location. The shrinker truncates a failing
sequence at its failure index (verifying the truncation still fails before accepting it),
so a precise index lets the fast-path truncation fire and convergence is tighter and
cheaper. The shrinker tolerates a missing or imprecise index by falling back to its
general sequence search, so this is a convergence-quality improvement, not a correctness
prerequisite — which is exactly why it was safe for DR-024 to defer it.

**Why incremental, and why only for async events.** Asserting a drained batch of async
events against the single final folded state would, for an accumulating invariant, report
at the *first* matching event in the batch rather than the one that caused the violation —
a different, earlier `command_index`, possibly from an unrelated poller. The shrinker would
then fail to truncate there and fall back to its slower search, defeating the purpose.
Asserting incrementally as each event is folded reports the causal event's index, so the
truncated reproduction is valid. Command-own events are left on their existing
batch-against-final timing: changing them would alter behavior for every existing model
with multi-event commands, and own-event batches are typically one event, so locality
rarely matters there. The async-versus-own asymmetry is a deliberate, documented scope
boundary.

**Compatibility.** Within this repository, no model both samples (`every: N`) and produces
asynchronous events, no `every: Module` assertion targets a module also emitted
asynchronously, and the poller-using models either use `@poll_state` (which only reads
state and injects no events) or `at: :teardown`. So the observable behavior change in the
test and bench corpus is empty. For external models this is nonetheless a behavior change —
a `@trigger every:` assertion now also runs on asynchronously-observed events — and is
recorded as such in the changelog. The framework is pre-1.0 and has shipped behavior
changes of this kind before.

## Consequences

- `lib/property_damage/executor.ex`: the three asynchronous event processors
  (`process_injector_events`, `process_mock_events`, `process_nemesis_events`) evaluate the
  synchronous-assertion dispatch incrementally inside their per-event fold, threading the
  assertion counters, mode, and accumulated failures, and halting mid-drain under `:halt`
  mode (propagating `{:assertion_failed, name, reason}` with the offending event's
  `command_index`). The two finalize drains (the `@poll_state` await drain and the
  settled-state drain) inherit this because they route through the injector processor; a
  violation found while draining surfaces as a run failure rather than being folded
  silently. The incremental-versus-batch distinction is load-bearing for shrink
  convergence and is documented at the call sites. One nemesis sub-path is out of
  scope: the auto-restore re-injection (a fault lifting on its own) folds its events
  into projection state but does not evaluate them against `@trigger every:`
  assertions, because it represents fault *clearing* rather than a SUT effect under
  test; the nemesis command-injection path is where injected-fault events are
  asserted.
- `lib/property_damage/model/projection.ex`: unchanged. The trigger surface, normalizer,
  and `should_run?/4` are untouched; only the set of call sites that invoke the dispatch
  grows.
- `lib/property_damage/shrinker.ex`: `failure_signature/1` gains a clause for
  `{:assertion_failed, name, _}` that records `name` as `check_name`, placed before the
  generic tuple clause. Assertion failures are no longer conflated by `equivalent_failures?`
  (a behavior change for multi-assertion models — distinct assertions are no longer treated
  as the same bug), and an asynchronously-observed failure carries the observing event's
  `command_index` as `failed_at_index`.
- Reporting: an asynchronously-observed failure surfaces through the existing named
  `{:assertion_failed, name, reason}` path, with `step_type: :event`, the event source
  (`:resource_poller` / `:injector` / `:mock` / `:nemesis`) named in the message, and the
  observing event's `command_index` as the failure location — distinct from a `:teardown`
  settled failure (no position) and a `@poll_state` poll timeout (liveness).
- `openspec/specs/execution-engine/spec.md`: the asynchronous event paths and the finalize
  drains run the synchronous-assertion dispatch incrementally, with `:halt` propagation.
- `openspec/specs/projection/spec.md`: `@trigger every:` fires on all observed events
  including asynchronous ones; `@trigger every: :command` is the command-only opt-out; the
  documented "after any event" meaning of `every: :event` is now realized.
- `openspec/specs/shrinking/spec.md`: assertion failures are distinguished by name in the
  failure signature; an asynchronously-observed assertion failure carries the observing
  event's `command_index` as `failed_at_index`.
- Acceptance: a focused fixture (a model whose resource poller injects an over-application)
  drives a failing-first shrink-convergence test — red against the pre-change engine
  (the `every:` assertion never fires on the poller event), green after (the failure is
  reported at the injecting command's index and the shrinker converges to a minimal
  sequence ending there). The Oban bench, which expresses its safety check with
  `at: :teardown`, is unaffected and kept green as a regression check.

## References

- `openspec/specs/execution-engine/spec.md`
- `openspec/specs/projection/spec.md`
- `openspec/specs/shrinking/spec.md`
- Related: DR-024 (Lifecycle-Boundary Assertions — the deferred "continuous checking" this
  realizes), DR-012 (Trigger-Based Assertions — the `every:` axis), DR-014 (Assertion
  Modes), DR-009 (Projections See Commands and Events), DR-017 (Hierarchical Delta
  Debugging — the shrinker and failure equivalence), DR-018 (Command-Triggered Resource
  Polling), DR-016 (Injector Pattern)
