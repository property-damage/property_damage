# DR-032: Core Adapter Timeout + Ambient-State Removal

**Status:** Accepted (implemented)
**Date:** 2026-06-29

> Part of the served/servant clean-break campaign (discrepancy sweep / deep cleanup). Closes a
> spec-vs-implementation gap and removes the framework's remaining ambient global mutable state.

## Decision

- **Core adapter timeout.** Command execution in the core `Executor` is subject to
  `adapter.timeout/1` (default 30s, per-command override), per the execution-engine "Adapter
  Timeout" requirement. Today the only consumer of `timeout/1` is `load_test/worker.ex`; a hung
  `execute/3` in an ordinary run has no wall-clock bound. The timeout wraps each
  `adapter.execute/3` attempt (`PropertyDamage.Executor.Timeout`, reused by the worker) and
  surfaces a `CommandTimeoutError` through the adapter-error channel (it returns `{:error, ...}`
  rather than raising, so it composes with the settle retry loop and the stutter path).

  **Always-on, cross-process (decided by grilling, 2026-06-30).** A hard wall-clock bound on
  arbitrary code is only enforceable by running it in a separately-killable process: you cannot
  interrupt a blocked synchronous call from within its own process, and a trappable signal is
  just a mailbox message a blocked process never reads. So `execute/3` runs in a child `Task` on
  every command. We chose this **always-on** rather than opt-in. The consequence (process-bound
  state no longer lives in the same process as `execute/3`) is bounded:
  - Connection-ownership libraries (Ecto `SQL.Sandbox`, Mox) keep working with **no changes**,
    because `Task.async` propagates `$callers` and those libraries resolve ownership through it
    (verified: the run process is in `$callers` inside `execute/3`).
  - Adapters relying on the run process's **process dictionary** or **`self()` identity** break.
    This is capability-preserving: any such adapter can be rewritten to thread state through
    `user_context` (an Agent/ETS/`:atomics` ref) or to register a stable process whose pid rides
    in `user_context`, so documenting the caveat constrains nothing users can express. These are
    patterns DR-027 already steers away from; the only such adapters in-tree were test helpers,
    now migrated.
  - A timed-out command is killed mid-flight, so partial non-atomic external effects may remain.
    This is inherent to any hard timeout, not specific to cross-process execution.
  The alternatives considered and rejected: opt-in enforcement (spares the in-process case but
  weakens the guarantee to "can be bounded"), and a reversed watchdog that kills the run process
  (destroys run state, and reduces to the same cross-process problem one level up).
- **Remove the misaligned nemeses (supersedes the per-instance-handle plan).** The nemeses that
  stored fault state in *shared global* process-dictionary keys (ClockSkew, SlowIO,
  CertificateExpiry, CPUStress, MemoryPressure, ResourceExhaustion) plus the one-shot ProcessKill
  are **removed**, not re-plumbed. The original plan was to give each `inject/2` a per-instance
  handle that `restore/2` consumes. Grilling (2026-06-30) reframed the problem: these nemeses are
  *architecturally misaligned*, not merely sharing state. They stress or observe the **local BEAM/
  host** (CPU, memory, OS resources, local process kills) or install a virtual clock the adapter
  reads via a global no-arg API; none of that reaches an **external** System Under Test driven
  through an adapter. The host-stress ones also destabilize the run (and now manufacture false
  `CommandTimeoutError`s under the new core timeout). The remaining built-ins are the three
  Toxiproxy network nemeses (`NetworkPartition`, `NetworkLatency`, `PacketLoss`), which fault the
  SUT's real network path and hold **no** BEAM-local fault state, so the shared-global-key problem
  is eliminated by removal and no `inject`/`restore` contract change is needed. This is removing a
  misaligned feature, not down-scoping an underbuilt one.
- **external_markers off Application env.** `External` reads `external_markers` from an explicit
  run option threaded through the run rather than `Application.get_env/3` (a config-time ambient
  channel).
- **Spec contradiction fix.** The `eventual-consistency` spec's settle-interval (Requirement says
  300ms, its own scenario said 100ms) is reconciled to 300ms, matching the implementation.

## Context

The discrepancy sweep found these as the residue of "ambient/global mutable state" and
spec-vs-implementation drift. The adapter-timeout gap means an ordinary run can hang
indefinitely on a wedged `execute`. The global-process-dict nemesis state means two instances of
the same cooperative nemesis interfere and restore deletes all instances' keys. These are
cleanliness/robustness fixes that complete the "no ambient state" goal alongside DR-027 (inject/
poller process-dict removal) and DR-029 (explicit RNG).

## Consequences

- `lib/property_damage/executor.ex` (timeout around command execution), `nemesis/*.ex`
  (per-instance handles via `inject/2`/`restore/2`), `lib/property_damage/external.ex` (option),
  and the `eventual-consistency` spec.
- Spec notes: `openspec/specs/execution-engine` (timeout now core), `openspec/specs/fault-injection`
  (per-instance fault state). Sequenced after the tensions whose machinery each item touches.

## References

- `openspec/specs/execution-engine/spec.md` (Adapter Timeout), `openspec/specs/eventual-consistency/spec.md`.
  Completes the ambient-state removal begun in DR-027 and DR-029.
