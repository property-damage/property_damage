# DR-041: Structured Failure Vocabulary (`%Failure{}`)

**Status:** Accepted
**Date:** 2026-07-04

> Follows the DR-039 / DR-040 persistence-refusal precedent for the format bump.
> Builds on the Phase-B precedent (DR-033 era) of replacing materialized
> `FailureReport` fields with accessors. Does not relitigate the shrinker's
> failure-equivalence contract (DR-017, DR-025); it re-expresses it over the new
> type without changing its granularity.

## Problem

A run's `failure_reason` was a loose family of `{:tag, ...}` tuples — at least
fifteen distinct shapes across the codebase, constructed at ~15 sites in
`executor.ex` / `executor/branching.ex` / `executor/nemesis.ex` /
`executor/finalization.ex` / `linearization.ex`, and read by three independent
interpreters that had each drifted:

- `Shrinker.failure_signature/1` (per-tag clauses plus a granularity-losing
  `elem(0)` catch-all),
- `FailureReport` (which re-parsed the tuples into six *denormalized* fields:
  `failure_type`, `check_name`, `failure_message`, `invariant_name`,
  `idempotency_violation`, `poll_timeout_info`, also written by
  `finalization.ex`),
- `FailureIntelligence` fingerprinting.

Concrete drift the tuples had accumulated: `:ref_resolution_error` still named
the long-deleted `%Ref{}` system; `:adapter_error` shipped in **two** arities
(a 2-tuple and a 3-tuple carrying `partial_events`); `{:branch_failure, id,
inner}` recursively wrapped every other shape; and two adapter-contract shapes
(`:retry_from_sync_command`, `:malformed_adapter_return`) plus
`:projection_violation` were handled by nobody's `failure_signature`/report
clause, so they degraded silently. There was no single place that documented the
closed set of reasons, and any consumer could invent a shape.

## Decision

Introduce one structured, public type — `%PropertyDamage.Failure{}` — as the
sole `failure_reason` vocabulary, and move every producer and consumer onto it in
a single breaking change.

1. **Nested type, illegal states unrepresentable.**

   ```elixir
   %Failure{
     type: %Failure.Assertion{} | %Failure.Execution{} | %Failure.Framework{},
     branch_id: non_neg_integer() | nil
   }
   ```

   The envelope holds cross-class commons. `branch_id` **absorbs** the recursive
   `{:branch_failure, id, inner}` wrapper: a branch failure is an ordinary failure
   whose envelope records the branch. Each class struct owns its `kind` (a closed,
   documented set), a `name` where one is meaningful (only `Assertion`), and a
   class-specific payload (`detail`, plus `partial_events` on `Execution`).

2. **Three classes.** `Assertion` (a property/invariant did not hold),
   `Execution` (the machinery around the SUT failed to run a command),
   `Framework` (PropertyDamage itself could not proceed). `Failure.class/1`
   returns `:assertion | :execution | :framework` for grouping/serialization.
   The namespace is `Failure.*` deliberately: `PropertyDamage.AssertionFailed`
   (the intentional-failure exception) and Elixir's own `AssertionError` make
   sibling top-level names a collision minefield.

3. **Kinds are globally unique atoms** across the three classes, so `{kind, name}`
   identifies a failure without also naming the class. Final inventory:
   - Assertion: `:assertion_failed` (trigger + check failures unified — `name`
     and `detail` absorb both old payload styles), `:idempotency_violation`,
     `:linearization`, `:poll_timeout` (keeps its assertion `name`),
     `:settle_timeout`, `:projection_violation`.
   - Execution: `:adapter_error` (both old arities merge; optional
     `partial_events`), `:nemesis_error`, `:stutter_execution_failed`,
     `:resource_poller_error`, `:poll_error`, `:retry_from_sync_command`,
     `:malformed_adapter_return`.
   - Framework: `:placeholder_resolution` (**renamed** from
     `:ref_resolution_error`, which named the deleted `%Ref{}` system),
     `:unknown`.

4. **The shrinker signature is `{kind, name}` — exactly today's granularity.**
   Keying on the globally-unique *kind* (not the coarser class) is load-bearing:
   a `:poll_timeout` of assertion `:x` and an `:assertion_failed` of `:x` share a
   name but are different bugs. A class-based signature (`{:assertion, :x}` for
   both) would merge them and let the shrinker swap one bug's identity for the
   other's during minimization. A RED-first test locks this non-equivalence.

5. **Persistence v7, pre-v7 refused.** A report's persisted shape changes (the
   `failure_reason` is a nested struct and the six denormalized fields are gone),
   so `@version` goes 6 → 7 and pre-v7 files are refused with the same mechanism
   and error shape as the DR-039 / DR-040 bumps. Not folded into DR-040's v6:
   the two breaks are independent and staging them separately keeps each
   refusal's rationale legible.

6. **Delete-and-derive on `FailureReport`.** The six denormalized fields are
   deleted from the struct and replaced by accessor functions over
   `report.failure_reason` — `failure_type/1` (the kind), `check_name/1`,
   `failure_message/1`, `invariant_name/1`, `idempotency_violation/1`,
   `poll_timeout_info/1` — mirroring the Phase-B materialized-field → accessor
   precedent. `finalization.ex` stops writing those fields and constructs proper
   `%Failure{}` values. Formatter/exporter titles are keyed by kind, so their
   byte-exact goldens were regenerated deliberately.

## Rejected alternatives

- **Flat `class` + `kind` fields on one struct.** Re-admits illegal states (a
  `class: :assertion, kind: :adapter_error` combination is expressible). The
  nested type makes the illegal combinations unrepresentable.
- **Normalized tuple families** (keep tuples but enforce a uniform arity /
  shape). Convention-enforced uniformity across ~15 sites and three interpreters
  is exactly today's disease; nothing stops the next drift.
- **A fourth `:convergence` class** for tuning-noise kinds (`:poll_timeout` /
  `:settle_timeout`). Rejected: triage of "possibly tuning, not a bug" moves to a
  documented `kind in [:poll_timeout, :settle_timeout]` check rather than a class
  boundary, keeping the class taxonomy about *where* a failure originates. This is
  an accepted risk (the most likely thing to resurface post-ship).
- **Folding the format bump into DR-040's v6.** Rejected per (5).
- **Keeping the six denormalized fields** alongside the structured reason.
  Rejected: denormalized projections of one source of truth drift; accessors
  cannot.
