# DR-040: Per-Step State Timeline (Derived, Not Captured)

**Status:** Accepted
**Date:** 2026-07-04

> Builds on DR-033 (`RunTrace` as the execution record), DR-035 (`RunComparison`
> field-divergence ranking), and DR-037 (generation-determinism audit). Follows
> the DR-039 persistence-refusal precedent for the format bump. Does not
> relitigate any of those; it adds a per-command projection-state view and the
> recording needed to make it faithful.

## Problem

A `FailureReport` keeps exactly two authoritative projection snapshots
(`state_before_failure`, `state_at_failure`). Every other "what was the state at
step N?" question — the human debugging surface, and `RunComparison`'s state
delta — had no answer, so cross-run state comparison degraded to a two-point
sample. We want per-step state without paying to snapshot projections at every
command (memory) and without a persistence format that stores N state maps.

## Decision

1. **Per-step state is DERIVED from the trace, never captured.** No projection
   snapshot is taken at any step. State at a step is recomputed by re-folding the
   recorded items (commands + events) through the model's projections. This costs
   nothing at run time beyond a small fold-order record and keeps the persisted
   artifact the size of the event log, not the size of the event log times the
   state.

2. **Two derivation modes.**
   - **Faithful** (`RunTrace.state_at/2`, `state_before/2`, `state_timeline/1`)
     — the human surface. Folds in the run's *real* fold order, so async /
     injected events land exactly where they folded. This is the mode whose
     failure-step value equals the runtime snapshot (least surprise: it is the
     state the run actually had).
   - **Canonical** (`RunTrace.canonical_state_timeline/1`) —
     `RunComparison`-internal. Folds each step's executed command then its
     attributed events, in flattened order, ignoring *when* async events folded.
     It is timing-immune by construction, so an async fold-order difference
     between two runs of the same plan can never manifest as a state divergence
     in the comparison. Used only for cross-run alignment, not offered as the
     human timeline.

3. **Fold-order recording (executor, additive) + persistence v6.** To make
   faithful derivation possible, the executor keeps a monotonic per-run fold
   counter. Every event stamps `EventLog.Entry.fold_index` when it folds into
   projections (`nil` for entries that are recorded but never folded — `:stutter`
   retries, `:telemetry`); every command's own fold records an ordinal by
   position (`RunTrace.command_fold_ordinals`). Branches fork the counter and
   `merge_branch_states` unions the ordinal maps; the verified branch
   `linearization` is now recorded on the `RunTrace` so the merge order is
   recoverable. Persistence bumps **v5 → v6**; pre-v6 files are **refused** with
   `{:error, {:unsupported_format_version, version, 6}}` (the DR-039 mechanism), a
   pre-v6 file has no fold-order record so its timeline cannot be derived. The
   v5-era retroactivity is knowingly sacrificed (the framework is unpublished; no
   persisted artifacts exist outside test fixtures).

4. **Projection-purity check.** The faithful-derived state at the failing step
   MUST equal the persisted runtime `state_at_failure` (and `state_before_failure`
   at its step). A pure projection re-derives identically; a mismatch means an
   `apply/2` read something outside its `(state, event)` inputs (a clock, a
   counter, the environment). Exposed as `RunTrace.verify_projections/4` and
   `FailureReport.verify_projections/1`, returning `:ok` or
   `{:non_pure_projections, [module]}`. Because faithful replays the *real* fold
   order, a pure-but-async projection re-derives correctly and does NOT
   false-positive — the load-bearing property. This is a two-point sample
   (before + at the failing step): honest partial coverage, not a whole-run
   proof. A generation-side companion (`PropertyDamage.audit_projections/2`, wired
   into `mix pd.audit`) folds each generated plan twice and names any projection
   whose two folds disagree — the dev/CI early warning for the same impurity.

5. **State divergence enters `RunComparison` ranking via canonical states.** Each
   projection's canonical per-step state is flattened into leaf-path fields
   (`{:state, position, projection, path}`) and classified by the existing DR-035
   machinery. Async-timing skew is impossible in this signal by construction
   (canonical attribution). A projection whose state varies *within* an outcome
   group is reported in `RunComparison.state_warnings` (a likely non-pure
   projection). **Flattening policy** (implementer-owned): flatten maps / structs
   / lists to leaf paths, bounded by max depth 5 and max fan-out 64; beyond either
   bound a subtree compares as one opaque leaf. This keeps the field set bounded
   on deeply nested or very wide state while preserving fine-grained diffs for the
   common shallow case.

## Context

The recording is what flipped the design. An earlier sketch parked the command
fold ordinals (record only entry `fold_index`) and homed the timeline
report-only. The projection-purity check is the consumer that needs command
ordinals (to place the command fold relative to its events) and needs the check
homed where the snapshots live (`FailureReport`), so both were kept. The
purity check is also the reason faithful must replay the real fold order rather
than attribution order: only the real order matches the runtime snapshot for an
async run, so only the real order avoids false positives.

## Consequences

- `EventLog.Entry` gains `fold_index`; `RunTrace` gains `command_fold_ordinals`
  and `linearization`. All three ride the existing persistence framing (v6).
- The fold counter threads through the command / injector / mock / injected /
  nemesis folds, the branch fork+merge, and the finalize drains. `check_async`'s
  shadow re-fold (assertion evaluation on a throwaway projection copy) is left
  alone: it does not build entries and does not advance run state.
- Faithful branching derivation mirrors `merge_branch_states`: branch steps fold
  branch-locally from the post-prefix state; suffix steps fold the merged state
  (branches replayed in verified `linearization` order when recorded, else branch
  order) then the suffix. Unattributed async entries in a branching run are folded
  by faithful (they carry a `fold_index`) but excluded from canonical (no
  attribution) — the same partial-coverage caveat the comparator already documents.
- The projection-purity check is two-point (before + at the failing step). Full
  per-step purity would require folding and comparing at every step against a
  captured snapshot at every step — i.e. capture, the thing this DR rejects.

## Alternatives considered

- **Runtime snapshot capture (a state map per step).** Rejected: it is the
  memory + persistence cost this DR exists to avoid, and it dissolves the "at
  which instant?" ambiguity by fiat rather than by deriving the answer the fold
  order already determines.
- **Park the command fold ordinals (entry `fold_index` only).** Rejected: the
  purity check needs the command's fold position relative to its events, and
  homing the timeline report-only would repeat the dead-field mistake (a recorded
  field with no consumer). The purity check is the consumer that justifies the
  ordinals.
- **Report-only homing of the timeline.** Rejected: the timeline is a property of
  a run (`RunTrace`), which a report composes; homing it on the report would deny
  it to bare captures and to `RunComparison`.
- **Continuous double-fold purity checking (every step).** Rejected: whole-run
  purity coverage would require a captured reference state at every step, which is
  snapshot capture by another name. Two-point sampling is the honest bound.
- **Canonical states as the human timeline.** Rejected: canonical deliberately
  discards async fold timing, so its failure-step value would NOT match the
  runtime snapshot for an async run — surprising as a human surface and useless
  as a purity reference. Canonical is comparison-internal; faithful is the human
  surface.
