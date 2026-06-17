# DR-022: Unified Progress Projection

**Status:** Accepted
**Date:** 2026-06-16

> Unlike DR-001 through DR-020 (reconstructed after the fact), this is a
> forward-looking decision recorded at the time it was made, as part of unifying
> the progress / completion reporting story across the public surface.

## Decision

All long-running public operations (`PropertyDamage.run/1`, `Mutation.run/1`,
`Differential.run/1`, and the load-test `Runner`) report progress through a
single **derived projection**: a `%PropertyDamage.Progress{}` value consumed by
zero or more consumers.

**Central principle — the causal arrow points one way:**

> Authoritative state is the source of truth; `Progress` is a pure projection of
> it. Metrics and results are **not** derived from `Progress`.

The authoritative result of an operation is its **return value**. A terminal
`Progress` carrying a `*Result` payload is a *copy* emitted for consumers (it is
what an async consumer such as the load-test runner observes), never the source.

**Structure.** A thin envelope carries only common metadata; the payload is the
discriminator:

```elixir
%PropertyDamage.Progress{
  data:       <one payload struct>,  # discriminator = data.__struct__
  at:         integer(),
  elapsed_ms: non_neg_integer(),
  run_id:     term()
}
```

There is **no `kind` or `operation` field** — both are derivable from `data`'s
struct type, so carrying them would invite drift. One `telemetry_event/1`
function is the single site that maps a payload struct to its
`{operation, kind}` (e.g. `RunUpdate → {:test_run, :progress}`). There is one
`{Update, Result}` payload pair per operation; `*Result` payloads wrap the
operation's existing authoritative result rather than re-deriving it.

**Dispatch.** Consistency lives in the consumer interface
(`(Progress.t -> any)`), not the dispatch mechanism:

- Batch operations (run/mutation/differential) fan out to consumers
  **synchronously, in order, inline** (complete-before-return; a slow consumer
  only lengthens the run).
- The load-test runner dispatches through an **isolated notifier process** so a
  slow consumer cannot stall arrival scheduling; it **flushes and guarantees
  delivery of the terminal `*Result`** once generation has stopped.
- Consumer errors are caught and logged; the operation continues.
- When there are no consumers, no `%Progress{}` is built (zero cost on the hot
  path).

When the notifier's bounded buffer overflows it **deterministically decimates**
buffered intermediate updates (halve-on-full) to preserve temporal spread across
the whole run — never tail/head-drop, never a randomized reservoir — and the
terminal `*Result` and first update are exempt from decimation. This is safe
only because updates are self-contained (absolute counters + own timestamp);
consumers must not assume they see every update or compute deltas across
received updates.

**Output formatting is a consumer.** `verbose:` printing is reimplemented as a
built-in consumer rather than a parallel `if verbose` path; user `on_progress:`
is an additional consumer (multi-consumer fan-out). The existing printer module
`PropertyDamage.Progress` is renamed to `PropertyDamage.Progress.Printer` (a
phase-driven consumer); the name `PropertyDamage.Progress` becomes the envelope
struct.

**Telemetry is a uniform consumer.** It emits, for every operation, a coarse
`[:property_damage, <operation>, :progress | :result]` event. For `run/1` this
is **distinct from and additional to** the existing fine-grained
`sequence`/`command`/`check`/`shrink` spans: the spans are per-unit
instrumentation, the progress events are a coarse campaign heartbeat. Both layers
are kept and documented; the spans are unchanged.

**Breaking change.** The load test's `on_metrics:` and `on_complete:` options are
**removed** in favor of `on_progress:` (periodic snapshot → `LoadUpdate`; final
report → `LoadResult`). Acceptable pre-v1: PropertyDamage is unreleased
(stealth), so there is no third-party code to break, and the unified surface is a
net improvement.

## Context

Progress reporting had grown per-operation and inconsistent: `run/1` was
print-driven (`verbose:`) plus a fine-grained telemetry layer; `Mutation.run/1`
had `verbose:` plus an `on_progress:` callback; `Differential.run/1` had only
`verbose:`; the load test was callback-driven with differently-named
`on_metrics:`/`on_complete:` and no `verbose:`. There was no shared payload, and
the print path could drift from what actually happened.

The decisive design question was the causal direction. Deriving a run's metrics
from a stream of progress events was considered and **rejected**: load tests
already derive their sampled `on_metrics` snapshots *from* an authoritative
per-request aggregator (you cannot reconstruct accurate aggregates from a
downsampled stream), so "metrics from progress" would point the arrow opposite to
how load tests must work, make a lossy notification channel load-bearing for
correctness, and force per-iteration allocation onto `run/1`'s hot loop even with
no listeners. The consistent, correct direction is the inverse: authoritative
state is the source; `Progress` is a derived view.

`kind`/`operation` fields were considered for the envelope and **rejected** to
avoid a denormalization that can drift from the payload type; struct identity is
the discriminator instead. "Async dispatch everywhere" was considered for
uniformity and **rejected**: it breaks the ordered output the printer needs,
races completion for synchronous APIs, and is *more* machinery than inline
synchronous fan-out — the only operation that genuinely needs non-blocking
dispatch is the load-test runner (to protect arrival scheduling).

## Consequences

- New `PropertyDamage.Progress` envelope struct plus one `{Update, Result}`
  payload pair per operation, and a single `telemetry_event/1` mapping.
- A consumer fan-out mechanism: synchronous/ordered/error-guarded for batch
  operations with a zero-cost-when-unobserved guard; an isolated notifier process
  with a bounded, deterministically-decimating buffer and a guaranteed terminal
  flush for the load test.
- The existing printer module `PropertyDamage.Progress` is renamed to
  `PropertyDamage.Progress.Printer` and refactored into a phase-driven consumer
  installed by `verbose:`.
- Telemetry gains coarse `[:property_damage, <operation>, :progress | :result]`
  events for all operations; the existing fine-grained `run`/`sequence`/
  `command`/`check`/`shrink` spans are retained and unchanged.
- **Breaking:** load-test `on_metrics:`/`on_complete:` are removed in favor of
  `on_progress:`; `metrics_interval:` is retained as the snapshot cadence.
- The `observability` spec's Progress Reporting and Telemetry Events requirements
  are rewritten around the projection + consumer model; the `load-testing` spec
  is updated for the option change.

## Implementation notes

- **Zero-cost guard is load-bearing.** Build no `%Progress{}` when there are no
  consumers (verbose off, no `on_progress:`, no telemetry handler attached) — on
  `run/1`'s hot loop this must not regress allocation; verify with a no-listener
  benchmark.
- **Order must be preserved.** Batch fan-out emits in order (the printer depends
  on it); the load-test notifier preserves order within its buffer and its
  decimation removes interior samples without reordering the survivors.
- **Terminal delivery is guaranteed.** The `*Result` is delivered even if a
  consumer is slow: the load-test runner flushes and blocks for it only after
  generation has stopped, so it cannot be lost to decimation or a race.
- **`run_id`** identifies one top-level operation invocation, so a consumer can
  correlate updates with their result without relying on arrival order.
- **Payload set.** One `{Update, Result}` pair per operation (eight structs
  across the four operations). Implementation may land `run` + load-test first
  (the two designed poles) and add mutation/differential on the same pattern.

## References

- `openspec/specs/observability/spec.md` (Progress Reporting, Telemetry Events).
- `openspec/specs/load-testing/spec.md` (load-test options).
- Related: DR-014 (Assertion Modes — single-option precedent), DR-019 (Command
  Spec Pattern — derive-don't-duplicate precedent).
