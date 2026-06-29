# DR-027: Adapter Runtime Handle (execute/3, explicit %Runtime{}, no ambient process-dict)

**Status:** Accepted (design pass; implementation in progress)
**Date:** 2026-06-29

> Part of the served/servant clean-break campaign. Separates the user's served data
> (their `setup/1` return) from the framework's servant plumbing (`inject`, `start_poller`,
> `stutter`) into distinct, explicit channels, and removes the ambient process-dictionary
> state the plumbing used to live in. Pre-v1 breaking change; no shim.

## Decision

`Adapter.execute/2` becomes `Adapter.execute/3`: `execute(command, user_context, runtime)`.

- `user_context` is **exactly** what the adapter's `setup/1` returned — zero framework keys.
- `runtime` is a `%PropertyDamage.Runtime{inject, start_poller, stutter}` handle.
  `Runtime.stuttering?/1` exposes the retry/first-execution distinction (replaces the
  implicit `%{stutter: _}` key-presence check). `stutter` is `nil` on the first execution.
  (Command-correlated injector events are declared on `Command.awaits/2` per DR-030, not
  carried on the runtime handle, so there is no per-command handler field here.)
- `inject` and `start_poller` are per-command closures over an explicit
  `PropertyDamage.Runtime.Sink` (an `Agent`, created per command), which replaces the former
  process-dictionary channels. The sink carries the per-command injection context (the evolving
  projections, the newest-first event log, and the injected events in injection order) plus the
  resource pollers started during the command, and is surfaced through the `%Runtime{}` handle.
  `inject` folds the event into projections in the **caller** process exactly as before, so a
  projection `apply/2` that raises a transition-invariant violation still propagates into the
  adapter (rather than crashing the Agent); only the already-computed result is stored in the
  sink. Referencing the sink by pid (not the process dictionary) is what makes `inject` and
  `start_poller` work when the adapter runs in a spawned process (e.g. the load-test worker's
  `Task`), which the process dictionary did not.
- `Adapter.teardown/1` receives `user_context` (exactly the `setup/1` return). The framework
  owns poller/handler teardown.
- `teardown` is best-effort: wrapped in `try/rescue` with `Logger.warning` (implements the
  execution-engine "SHALL log a warning if teardown raises" requirement; previously a bare
  `after`).
- No reserved-key guard is needed: because `execute/3` passes `user_context` as a distinct
  argument and merges nothing into it, a `setup/1` that returns a map with an `:inject` (etc.)
  key can no longer collide with framework plumbing. (An earlier draft proposed a guard against
  the `Map.put` merge; the merge is gone, so the collision it guarded against cannot occur.)
- The two process-dictionary channels (`@injection_ctx_key`, `@resource_pollers_key`) are
  **deleted** (the executor's per-command channel and the load-test worker's channel).
- In `Executor.execute_raw/3` (raw mode, no projections), `runtime.inject` routes the emitted
  event through the run's `EventQueue` (the only collection channel raw mode has), replacing the
  former practice of merging the `:event_queue` into the adapter's context map. `start_poller`
  is unavailable in raw mode.
- `Adapter.register_handler/2` is **deleted** from the behaviour; the capability it promised
  is reimplemented on the semantic surface (see DR-030).

## Context

`execute/2` received one kitchen-sink map merging the user's `setup/1` return with framework
keys (`:inject`, `:start_poller`, `:stutter`) via `Map.put`. The user could not tell at a
glance which keys were theirs; a `setup/1` that returned `:inject` was silently clobbered. The
plumbing itself lived in the executor's **process dictionary**, which is ambient and fragile:
it broke the `load_test` worker's inject (set in the worker process, read in a spawned `Task`
child → cross-process `ArgumentError`) and `Differential` never wired `:inject` at all. The
`@type context` typedoc and the `teardown/1`/`register_handler/2` docs falsely claimed those
callbacks received the full merged context; `teardown/1` actually got the raw `setup/1` return.

An explicit `%Runtime{}` carried as a distinct argument restores the served/servant layering,
makes the plumbing testable and cross-process-safe (the sink pid works inside a `Task`), and
fixes the `load_test`/`Differential` inject gaps for free.

## Consequences

- `lib/property_damage/adapter.ex` (behaviour, `delegate_execution` forwards 3 args, doc/type
  fixes), `lib/property_damage/runtime.ex` (new), `lib/property_damage/executor.ex`
  (per-command setup), `lib/property_damage.ex` (setup/teardown), and every adapter:
  `differential.ex`, `load_test/worker.ex`, `mutation/mutating_adapter.ex`, `iex.ex`,
  `replay.ex`, all `test/support` adapters, the `benches/*` adapters, and the `pd.gen.adapter`
  / `pd.scaffold` templates.
- Spec deltas: `openspec/specs/execution-engine` (Adapter Execute Context, Adapter Lifecycle,
  sub-adapter delegation), `openspec/specs/eventual-consistency` (`start_poller`).
- `CHANGELOG.md` BREAKING entry. Reconciles DR-015/016/018 with the new arg shape.

## References

- `openspec/specs/execution-engine/spec.md` (Adapter Execute Context, Adapter Lifecycle)
- Related: DR-015 (Adapter Separation), DR-016 (Injector Pattern), DR-018 (Resource Polling),
  DR-029 (Executor stage architecture / run-state struct), DR-030 (command-correlated events)
