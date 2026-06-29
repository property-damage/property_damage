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
- `runtime` is a `%PropertyDamage.Runtime{inject, start_poller, stutter, handlers}` handle.
  `Runtime.stuttering?/1` exposes the retry/first-execution distinction (replaces the
  implicit `%{stutter: _}` key-presence check). `stutter` is `nil` on the first execution.
- `inject` and `start_poller` are per-command closures over a **run-scoped Agent sink**
  (`%PropertyDamage.Runtime.Sink{}`) created once per run and carried in
  `%PropertyDamage.Executor.State{}` (DR-029). The sink is **append-only** (ordered injected
  events + started pollers); injected events are folded in order *after* `execute/3` returns,
  which is observably identical to today's real-time fold (assertions run post-`execute`).
- `Adapter.teardown/1` receives `user_context` (exactly the `setup/1` return). The framework
  owns poller/handler teardown.
- `teardown` is best-effort: wrapped in `try/rescue` with `Logger.warning` (implements the
  execution-engine "SHALL log a warning if teardown raises" requirement; previously a bare
  `after`).
- A reserved-key guard raises if `setup/1` returns a map containing a framework-reserved key.
- The two process-dictionary channels (`@injection_ctx_key`, `@resource_pollers_key`) are
  **deleted**.
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
