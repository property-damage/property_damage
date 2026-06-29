# DR-029: Executor Internal Stage Architecture (typed run-state, cohesive modules, explicit RNG)

**Status:** Accepted (design pass; implementation in progress)
**Date:** 2026-06-29

> Part of the served/servant clean-break campaign. Applies the framework's own layering
> discipline to its largest servant module. Almost entirely internal: the public seam and all
> observable behavior (DR-024/025/026 ordering, determinism) are preserved; the decomposition
> is recorded here so future contributors do not re-tangle it or reorder the finalize chain.

## Decision

- **Typed run state.** Introduce `%PropertyDamage.Executor.State{}` with `@enforce_keys` on the
  always-present fields and **all ghost fields declared** (`:active_faults` default `%{}`,
  `:async_halt` default `nil`, plus every field currently entering only via
  `Map.get(state, :k, default)`). `put_state/2` is rewritten from `Map.merge` to `struct!/2`
  so an undeclared-key write **raises** rather than silently corrupting (today's `Map.merge`
  onto a struct produces a malformed-but-matching value). A structural test pins the field
  names Replay consumes (`event_log`, `projections`).
- **Cohesive-module strangler.** Each concern cluster moves into its own module —
  `Executor.Finalization`, `Executor.Stutter`, `Executor.Nemesis`, `Executor.Events`,
  `Executor.Settle`, `Executor.Branching` — each taking `%Executor.State{}` (plus its args) and
  returning `State` **or the rich tagged result its job actually needs** (finalize keeps its
  five-outcome return including the async-halt `command_index` precedence and the `:record`
  accumulator; branching keeps its three-outcome merge including `:linearization_failed`).
  There is **no** uniform `Stage` behaviour: a binary `{:cont | :halt}` contract is lossy
  against the real control flow. `executor.ex` becomes a thin orchestrator. The Reporter
  observer seam (Telemetry/Progress) is unchanged and is explicitly *not* the model for these
  state-mutating clusters.
- **Explicit RNG.** The process-global `:rand` (seeded in `property_damage.ex`, consumed by
  stutter) is replaced by an explicit RNG term threaded through `%Executor.State{}` and the
  shrinker, landed as its own golden-tested commit. Target is **self-consistent determinism**
  (same seed → same stutter decisions, plus DR-017 shrink-equivalence), not byte-identical
  reproduction of the old global stream. `Generator.run_seed` (the determinism users rely on)
  is untouched throughout.
- **Preserved invariants.** The finalize ordering — `finalize_pollers` → `finalize_resource_
  pollers` → `settle_event_queue` → `finalize_after_settle` → `run_phase_assertions(:teardown)`,
  with the async-halt / poll-timeout / settle-halt / resource-halt precedences — is locked by
  ordering guard tests written before extraction. Public seam (`run/4`, `execute_sequence/9`,
  `init_state/2`, `step_command/7`, `stop_pollers/1`) is unchanged.

## Context

`executor.ex` was ~3,504 lines, interleaving the run-loop parti with branching, settle, stutter,
pollers, nemesis, and event ingestion over an **untyped** flat state map (no defstruct), with
ghost fields never initialized in `build_initial_state/7`, ambient `:rand`, and process-dict
inject/poller channels (removed in DR-027). Telemetry/Progress were successfully layered out via
the Reporter observer seam — proof the decomposition is achievable — but that seam does not
generalize to clusters that mutate run state. The typed struct is the gating enabler; the
strangler extracts cohesive modules one gauntlet-green commit at a time, finalize first (behind
the ordering guards) so every later extraction runs against a guarded invariant.

## Consequences

- `lib/property_damage/executor.ex` + new `lib/property_damage/executor/*.ex`; `replay.ex`,
  `shrinker.ex` (RNG threading; field-name dependency). Ordering guard tests + RNG golden test.
- Spec: an `openspec/specs/execution-engine` note recording the internal stage architecture and
  re-affirming the DR-024/025/026 ordering invariants. No observable-behavior spec delta.

## References

- Re-affirms DR-024 (lifecycle assertions), DR-025 (continuous async checking), DR-026
  (per-assertion firing), DR-017 (shrink equivalence). Depends on DR-027 (process-dict removal).
