# DR-005: Projection Naming

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Projection-related model callbacks are named after their role, not their mechanism:

- `state_projection/0` was renamed to `command_sequence_projection/0` — it returns the projection used for command sequence generation.
- `extra_projections/0` was renamed to `assertion_projections/0` — these projections verify invariants.

Evidence level: high; the renames are recorded in the CHANGELOG and in commit history.

## Context

The original names described position ("extra") or a vague notion ("state") rather than purpose. Since all projections track state (DR-004), "state projection" did not distinguish anything, and "extra" said nothing about what the projections do. The CHANGELOG (Unreleased, Changed) records both breaking renames with rationale: "Clearer name: returns the projection used for command sequence generation" and "Clearer name: these projections verify invariants". The rename trail in git: `057c668` ("feat: rename state_projection to command_sequence_state"), `0847595` ("refactor!: rename state_projection and extra_projections callbacks"), `39dcd04` ("refactor(mix-tasks): unify projection terminology across generators").

## Consequences

- `lib/property_damage/model.ex` documents `command_sequence_projection/0` (required) and `assertion_projections/0` (optional).
- `CHANGELOG.md` carries both renames as BREAKING entries.
- Mix generators use the unified terminology (`39dcd04`), so scaffolded code matches the docs.
- `openspec/specs/projection/spec.md` requirement "Dual Projection Roles" is written in terms of the new names.

## References

- `openspec/specs/projection/spec.md` (header: "DR-005 (Projection Naming)")
- `CHANGELOG.md` Unreleased section
