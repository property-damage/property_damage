# DR-010: Symbolic References

**Status:** Accepted (reconstructed); core mechanism retained, command-level API superseded by DR-011
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Server-generated entity identities are represented during generation by symbolic references built on Erlang's `make_ref/0`. A ref has a three-phase lifecycle:

1. **Symbolic phase** — `symbolic/1` creates a ref with unique identity and no value; generated commands refer to future entities through it.
2. **Concrete phase** — when the adapter returns a real ID, the framework resolves the ref to that value.
3. **Usage phase** — later commands holding the same ref get the concrete value substituted before execution; using an unresolved ref fails.

Ref identity is the underlying `make_ref/0` value; labels are debugging metadata only.

Evidence level: high; the mechanism is documented in `lib/property_damage/ref.ex` and specified in the execution-engine spec. Note: the original command-level API (`creates_ref/0`, `Ref.symbolic/1` in generators) is deprecated in favor of `external()` markers (DR-011), but symbolic linking of outputs to inputs remains the execution model.

## Context

(Inferred.) Two-phase execution requires generating full command sequences before any SUT contact, yet later commands must reference entities created by earlier ones (cancel the order you created). Symbolic refs solve this without guessing IDs. `make_ref/0` gives globally unique, cheap identities with no registry. This mirrors the symbolic/dynamic state split in established SPBT tools (the two-phase design in `openspec/specs/execution-engine/spec.md` "Two-Phase Execution").

## Consequences

- `lib/property_damage/ref.ex` implements `symbolic/1`, `resolve/2`, `value!/1` and documents the lifecycle (marked DEPRECATED in favor of `external()`; see DR-011).
- `openspec/specs/execution-engine/spec.md` requirement "Symbolic Reference Resolution": creation in the symbolic phase, substitution before execution, failure on unresolved refs, identity by `make_ref/0`.
- The shrinker never shrinks ref values ("Refs are never shrunk (would break dependencies)", `lib/property_damage/shrinker.ex`) and uses ref production/consumption to build the dependency DAG (DR-017).
- Branching/parallel execution and replay rely on the ref resolution map (`openspec/specs/persistence/spec.md`, replay steps include the "ref resolution map").

## References

- `openspec/specs/execution-engine/spec.md` (header: "DR-010 (Symbolic References)")
- `CLAUDE.md` key subsystems: "Ref ... Symbolic reference system linking command outputs to future command inputs"
- Related: DR-011 (supersedes the command-level declaration API), DR-017
