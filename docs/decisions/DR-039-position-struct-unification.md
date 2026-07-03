# DR-039: Position Struct as the One Position Vocabulary

**Status:** Accepted
**Date:** 2026-07-03

> Amends DR-036 (Deterministic Symbolic Identity) on *encoding only*, and
> touches DR-034's mint-key representation. Does NOT relitigate DR-036's real
> commitments — determinism, id opacity, plan-fingerprint identity — which stand
> unchanged. Completes DR-021's `%Sequence.Position{}` ("the single position
> vocabulary"), whose adoption had stalled at the failure-query surface.

## Decision

1. **`%Sequence.Position{section, offset}` is the ONE position vocabulary.**
   The raw tuples `{:prefix, i} | {:branch, b, i} | {:suffix, i}` are removed
   everywhere they named a command's position: the `%Placeholder{}` `position`
   field and id coordinate, the `PlaceholderRegistry` `producer_link` keys, the
   executor's `current_position`, the generator's minting and remaps, the
   shrinker's remap, the `%Mint{}` marker keys, the determinism audit, the
   export step plan, and the Differential/LoadTest capture keys. `section`
   stays `:prefix | :suffix | {:branch, id}`; the 2-tuple `{:branch, id}` is a
   field *inside* the struct (already spoken by RunComparison, the timeline, and
   the HTML report) and is unaffected.

2. **This amends DR-036's encoding only.** Placeholder ids stay pure functions
   of `(position, event_index, path)` and stay opaque comparable terms; only the
   `position` element of that coordinate is now a struct rather than a tuple.
   The plan fingerprint stays `sha256(term_to_binary(canonical, minor_version:
   2))`; the canonical term now contains `%Position{}` structs instead of
   tuples. DR-034's mint keys (`{run_nonce, mint_epoch, position, path, kind}`)
   likewise carry the struct. Determinism and opacity are preserved: a 3-key
   struct (`__struct__`, `section`, `offset`) encodes deterministically, so
   `term_to_binary` remains stable, and no caller inspects the coordinate's
   shape.

3. **Persistence bumps to format version 5; pre-v5 files are refused.** A file
   written under format version `1`–`4` is rejected with
   `{:error, {:unsupported_format_version, version, 5}}` (asking the user to
   re-capture), because its persisted terms carry tuple-encoded positions inside
   arbitrary user command/event structs. No deep-converting loader is provided:
   a recursive tuple-position rewriter over arbitrary user terms is exactly the
   encoding-interpretation logic this change deletes, and it would be kept alive
   for artifacts that do not exist (the framework is unpublished; persisted
   files outside test fixtures do not exist). The pre-v4 `RunTrace` synthesis
   path (which folded a pre-DR-033 file's legacy `event_log`/`shrunk_sequence`
   into a trace) is deleted in the same change and its spec requirement
   superseded.

4. **Fingerprint and minted-value discontinuity is accepted.** Because the
   canonical plan term and the mint key now contain structs, plan fingerprints
   and derived minted values differ across this boundary. This has zero
   consumers today: fingerprint continuity and minted-value stability have no
   dependents, and no persisted artifacts exist outside test fixtures. This is
   the last cheap moment for the representation change.

## Context

DR-021 introduced `%Sequence.Position{}` (candidate 1, PR #6) as the single
position vocabulary, but adoption stopped at the query surface. The raw tuples
remained the vocabulary of the entire generation/execution/shrink half, bridged
to the struct-speaking half (RunTrace, RunComparison, Step, timeline) only by
`Position.from_tuple/1` at two executor sites. The split was actively generating
defects: `step_plan.ex` typed a field as `Position.t()` while matching tuples at
runtime; `mint.ex` accepted both forms and stored one; the DR-037 audit chose
tuples for user-facing output. Every new feature had to pick a side.

DR-036's genuine commitments are determinism, id opacity, and plan-fingerprint
identity — the raw-tuple encoding was *inherited* from DR-021, not decided.
Fingerprint continuity and minted-value stability have no consumers, and no
persisted artifacts exist. The unpublished framework and the
implement-don't-doc-downscope rule (which applies to `Position`'s moduledoc
promise) make now the right time to finish the unification rather than keep the
mixed state alive.

## Consequences

- `%Position{}` appears in persisted terms (it already did via
  `RunTrace.executed`); the persistence drift/version machinery is unaffected.
- `Position.from_tuple/1` and `@type tuple_form` are removed once nothing speaks
  tuples. `Position` grows non-speculative constructors (`prefix/1`, `branch/2`,
  `suffix/1`) used at the ~13 minting sites and a shared prose formatter
  (`describe/1`) shared by the audit and `mix pd.audit`.
- The shrinker stops rebuilding `producer_link` by hand and calls
  `PlaceholderRegistry.remap_positions/2` (registry internals move back into the
  registry).
- Rendered position labels that embed offsets (`_b1_2`, `pre0`) are byte-stable:
  `Placeholder`'s `loc/1` and step_plan's `position_suffix/1` keep their bespoke
  output strings but match on the struct, so the F3 export/diagram goldens are
  unchanged.

## Alternatives considered

- **F5-lite (keep tuples internally, struct at the boundary).** Rejected
  2026-07-03: it preserves exactly the split that generates defects and defers
  the representation change past the last cheap moment.
- **A struct→tuple canonicalization pass in `fingerprint/1`** to preserve old
  fingerprints. Rejected: discontinuity is accepted (decision 4), and a
  canonicalizer keeps the tuple encoding alive forever — the superseded
  DR-036-era idea.
- **A deep-converting v-N loader** that rewrites tuple positions inside stored
  terms. Rejected (decision 3): it resurrects the encoding-interpretation logic
  this change deletes, for artifacts that do not exist.
