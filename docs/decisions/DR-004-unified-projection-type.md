# DR-004: Unified Projection Type

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

There is exactly one projection behaviour, `PropertyDamage.Model.Projection`, used for both roles a projection can play:

1. The command sequence projection that drives generation (`when:` filtering, `with:` parameterization, simulation).
2. Assertion projections that verify invariants during execution.

State tracking (`init/0`, `apply/2`) and assertions (`@trigger`, `@poll_state` functions) live in the same behaviour; both state callbacks are optional with defaults, so a module can be state-only, assertion-only, or both. There is no separate "check", "observable", or "assertion" module type.

Evidence level: directly evidenced by code, spec, and a trail of unifying commits.

## Context

(Inferred from commit history.) Earlier iterations had distinct concepts: the 0.1.0 CHANGELOG lists "State projections" and "Assertion projections" with separate "check triggers", and commits show the convergence: `9b4d216` ("refactor: remove obsolete observables and checks code"), `794464f` ("refactor!: simplify projection and assertion system"), `40df8cd` ("refactor(assertions): make init/apply optional, change assert/2 to assert/3"), `2c966c0` ("refactor!: unify run_assertions and assertion_mode options"). The unification removes duplicate APIs and lets one module both track state and assert on it, since assertions usually need exactly the state the projection already reduces.

## Consequences

- `lib/property_damage/model/projection.ex` is the single behaviour; `use PropertyDamage.Model.Projection` sets up assertion detection for any projection.
- `openspec/specs/projection/spec.md` purpose: "A single behaviour supports both roles, from state-only projections that drive command generation to assertion-only projections that validate system correctness." Requirement "Dual Projection Roles" and scenario "Same behaviour for both roles" pin this down.
- Requirement "Simplified Assertion-Only Projections": modules may omit `init/0`/`apply/2` entirely (defaults: `%{}` and identity).
- Model callbacks distinguish the roles only by position: `command_sequence_projection/0` vs `assertion_projections/0` (`lib/property_damage/model.ex`).

## References

- `openspec/specs/projection/spec.md` (header: "DR-004 (Unified Projection Type)")
- Related: DR-005 (naming of the two roles), DR-009, DR-012, DR-014
