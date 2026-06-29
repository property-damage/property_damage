# DR-032: Core Adapter Timeout + Ambient-State Removal

**Status:** Accepted (design pass; implementation in progress)
**Date:** 2026-06-29

> Part of the served/servant clean-break campaign (discrepancy sweep / deep cleanup). Closes a
> spec-vs-implementation gap and removes the framework's remaining ambient global mutable state.

## Decision

- **Core adapter timeout.** Command execution in the core `Executor` is subject to
  `adapter.timeout/1` (default 30s, per-command override), per the execution-engine "Adapter
  Timeout" requirement. Today the only consumer of `timeout/1` is `load_test/worker.ex`; a hung
  `execute/3` in an ordinary run has no wall-clock bound. The timeout wraps command execution
  and surfaces a `CommandTimeoutError`-style failure.
- **Per-instance nemesis fault state.** Cooperative/host-effect nemeses (ClockSkew, SlowIO,
  CertificateExpiry, MemoryPressure, CPUStress, ResourceExhaustion) stop storing fault state in
  *shared global* process-dictionary keys. Each `inject/2` returns a per-instance handle that
  `restore/2` consumes, so concurrent instances no longer collide and cleanup no longer
  blanket-sweeps every instance.
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
