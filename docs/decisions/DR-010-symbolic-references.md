# DR-010: Symbolic References

**Status:** Superseded by DR-021 (placeholder resolution identity) and DR-011 (external field markers). As of 2026-06-18 the `%Ref{}` / `make_ref/0` mechanism, the `creates_ref/0` command callback, and the `PropertyDamage.Ref` module have been removed from the codebase. This record is retained for historical context.
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

> **Superseded.** Server-generated identities are now declared with `external()` on
> event structs (DR-011) and resolved through position-keyed `%Placeholder{}`
> values captured at execution time (DR-021). The symbolic-ref lifecycle below
> describes the original, now-removed design.

## Decision

Server-generated entity identities are represented during generation by symbolic references built on Erlang's `make_ref/0`. A ref has a three-phase lifecycle:

1. **Symbolic phase** — `symbolic/1` creates a ref with unique identity and no value; generated commands refer to future entities through it.
2. **Concrete phase** — when the adapter returns a real ID, the framework resolves the ref to that value.
3. **Usage phase** — later commands holding the same ref get the concrete value substituted before execution; using an unresolved ref fails.

Ref identity is the underlying `make_ref/0` value; labels are debugging metadata only.

Evidence level: high (historical); the mechanism was implemented in the since-removed `lib/property_damage/ref.ex`. The command-level API (`creates_ref/0`, `Ref.symbolic/1` in generators), the `%Ref{}` struct, and downstream resolution by `make_ref/0` identity have all been replaced by `external()` markers (DR-011) and position-keyed placeholders (DR-021).

## Context

(Inferred.) Two-phase execution requires generating full command sequences before any SUT contact, yet later commands must reference entities created by earlier ones (cancel the order you created). Symbolic refs solve this without guessing IDs. `make_ref/0` gives globally unique, cheap identities with no registry. This mirrors the symbolic/dynamic state split in established SPBT tools (the two-phase design in `openspec/specs/execution-engine/spec.md` "Two-Phase Execution").

## Consequences (historical)

These described the original design; the listed code and spec requirement have since been removed or replaced.

- `lib/property_damage/ref.ex` implemented `symbolic/1`, `resolve/2`, `value!/1` and documented the lifecycle (deleted in v0.2).
- The execution-engine spec's "Symbolic Reference Resolution" requirement (creation in the symbolic phase, substitution before execution, failure on unresolved refs, identity by `make_ref/0`) is folded into the "External Field Markers" requirement.
- The shrinker never shrank ref values and used ref production/consumption to build the dependency DAG (DR-017); it now does the same for placeholders (DR-021).
- Branching/parallel execution and replay relied on the ref resolution map; placeholders carry the equivalent identity by position and id.

## References

- `openspec/specs/execution-engine/spec.md` (header: "DR-010 (Symbolic References)")
- `CLAUDE.md` key subsystems: "Ref ... Symbolic reference system linking command outputs to future command inputs"
- Related: DR-011 (supersedes the command-level declaration API), DR-017
