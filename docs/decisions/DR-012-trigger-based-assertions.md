# DR-012: Trigger-Based Assertions

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Assertions are ordinary two-argument functions inside projection modules, decorated with module attributes that declare *when* they run:

- `@trigger` for synchronous assertions: `every: 1` (every step), `every: :command`, `every: :event`, `every: Module`, `every: [Mod1, Mod2]`, sampling forms `every: N`, `every: {N, :command}`, `every: {N, Module}`.
- `@poll_state` for temporal (eventually-true) assertions: `after: Event` (or a list), `timeout:`, `interval:`, with bare integers meaning seconds and `{value, unit}` tuples for `:milliseconds`/`:seconds`/`:minutes`. The function returns a predicate `(state -> boolean)` polled in the background.

Assertions pass by returning and fail by raising. Detection happens at compile time via an `@on_definition` hook; metadata is exposed through a generated `__assertions__/0`. The `assert_` name prefix is conventional, not required, but an `assert_*`-named two-arity function *without* a trigger attribute is a CompileError (a likely-forgotten-attribute guard).

Evidence level: high; fully specified and implemented, with a clear commit trail.

## Context

(Inferred plus commit evidence.) Earlier APIs used configurable check triggers (`:always`, `:end_of_sequence` in the 0.1.0 CHANGELOG) and later an `assert/2`-callback style (`6d9d9b1` "feat: redesign assertion API with assert/2 and trigger syntax", `c715b27` "refactor!: use assert_* function naming for projection assertions"). The attribute-based design puts the firing condition next to the assertion code, supports sampling for expensive checks, and lets one projection carry many independently-triggered assertions. The prefix requirement was relaxed in `e4c1f88` ("fix: remove assert_ prefix requirement for @trigger assertions"); temporal assertions arrived in `624b1bb` ("feat(projection): add temporal assertions with @poll_state attribute").

## Consequences

- `lib/property_damage/model/projection.ex`: `use` macro registers `@trigger`/`@poll_state`, the `@on_definition` hook, and `@before_compile` generation of `__assertions__/0`.
- `openspec/specs/projection/spec.md` requirements "Synchronous Assertions via @trigger", "Temporal Assertions via @poll_state", "Assertion Detection and Metadata", "assert_* Prefix Convention and Enforcement".
- Assertion functions receive `(state, command_or_event)`; raising marks failure, so plain ExUnit assertions work inside them.
- The executor fires sync assertions at trigger points and spawns background pollers for `@poll_state` (eventual consistency support).

## References

- `openspec/specs/projection/spec.md` (header: "DR-012 (Trigger-Based Assertions)")
- Commits `6d9d9b1`, `c715b27`, `e4c1f88`, `624b1bb`
- Related: DR-004, DR-009, DR-014
