# DR-021: Placeholder Resolution Identity

**Status:** Accepted
**Date:** 2026-06-14

> Unlike DR-001 through DR-020 (reconstructed after the fact), this is a
> forward-looking decision recorded at the time it was made, as part of
> implementing the `external()`/Placeholder system properly (Phase 5, item R3).

## Decision

Placeholder resolution uses a **split identity scheme**:

- **Consumer resolution is by id.** A command that consumes a server-generated
  value embeds a `%PropertyDamage.Placeholder{}` carrying a stable
  `make_ref/0` id. Before execution, the embedded placeholder is resolved to its
  concrete value by looking up that id in the registry. This is invariant under
  shrinking and branching because the id travels inside the command struct,
  which the shrinker preserves.

- **Producer capture is by structured position, rebuilt per run.** When a
  command's real events come back from the SUT, the framework learns *which*
  placeholder each external value fills via a **producer-link** keyed by a
  structured position: `{:prefix, i}` | `{:branch, branch_idx, i}` |
  `{:suffix, i}`. The producer→placeholder-id link is transported from
  generation, and the position index used to apply it is **rebuilt for each
  execution (and each shrink re-run) from the current command positions**, never
  persisted as a stale key.

The registry transports its **id-indexed** placeholder map plus the
producer-link from generation to execution via a new `registry` field on
`PropertyDamage.Sequence`. The position index (`by_location`) is derived, not
transported.

## Context

The `external()` marker system (DR-011) was wired at the consumer end and dead
at the producer end. Nothing instantiated placeholders during generation
(`Placeholder.new/4` and `PlaceholderRegistry.register/2` had zero production
callers), so raw `%External{}` sentinels leaked into projection state and to the
SUT, and the legacy `Ref` (DR-010) was the only working identity mechanism.

The harder problem was *capture*: matching a returned real value to the
placeholder it fills. The original code keyed capture on
`{event_module, path, command_index, event_index}`, a position in generation
space. Positions are not stable:

- **Branching:** the executor starts every parallel branch at the same running
  index (`branch_start_index = length(prefix)`), so two branches each producing
  the same event module collide on `command_index`.
- **Shrinking:** removing commands shifts indices, so a placeholder minted at
  generation index N no longer matches the producing command's run-time index.

Two designs were considered (see the R3 design note,
`r3_external_design_20260614.md`, in the project's planning notes):

- **Option A (rejected):** make everything id-based, carrying a stable per-command
  generation id in an out-of-band `command_ids` list on `Sequence`. An adversarial
  review showed the list is silently dropped at every `Sequence` reconstruction
  boundary (`Sequence.linear/1`, `map/2`, `filter/2`), because the shrinker core
  operates on a bare command list and rebuilds the sequence from it. For branching,
  `Sequence.to_list/1` flattens the structure, so the list cannot track commands
  across branches without re-introducing position anyway.
- **Option B (accepted):** producer-instance identity is irreducibly positional in
  generation space (two identical command structs are indistinguishable), so embrace
  a structured positional producer-link and rebuild the position index per run.
  This fits the existing shrinker architecture: the position index is derived from
  data already available at each run, and only the id-indexed registry transports.

The decisive insight: only the producing command's *instance* identity needs
position; the consumer side already resolves by id and is invariant. So the
design isolates position to capture and makes it a derived, per-run quantity.

## Consequences

- `PropertyDamage.Sequence` gains a `registry` field (default `nil`). Structure-
  preserving operations (`map/2`, `filter/2`, `linear/1`, `branching/3`) carry it
  explicitly; `to_list/1` drops it by design (it already discards branch structure).
- The generator instantiates placeholders during simulation in all three
  recursions (linear, prefix, branch): it substitutes `external()` markers in
  simulated events with `%Placeholder{}`, registers them by id, records the
  producer-link by structured position, and applies the substituted events to
  projection state. A generator affordance surfaces available external values from
  state to `with:` functions so commands can actually consume them.
- The executor seeds `state.placeholder_registry` from `sequence.registry`,
  rebuilds the position index per run, and captures externals from real events by
  structured producer position. The location-keyed capture path
  (`PlaceholderRegistry.resolve_by_location`, the `by_location` transport, and the
  positional `command_index` field on `Placeholder`) is replaced.
- The **linear** shrinker tracks an original→candidate position mapping so capture
  during a shrunk re-run forms the correct position key (the hierarchical path
  already tracks survivors via its `kept` MapSet).
- `Ref` (DR-010) remains functional and is not removed; both mechanisms resolve by
  id and coexist via the executor's combined resolution path.

## References

- R3 design note `r3_external_design_20260614.md` (problem analysis, adversarial
  review, Option A vs B) in the project planning notes.
- `openspec/specs/execution-engine/spec.md` (External Field Markers requirement).
- Related: DR-010 (Symbolic References), DR-011 (External Field Markers),
  DR-017 (Hierarchical Delta Debugging).
</content>
</invoke>
