# DR-006: Pure Command Generators

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Commands define a single pure callback `generator/1` that takes an overrides map and returns a `StreamData.t(map())` of plain field maps (not structs). The framework wraps generated maps into the command struct. Generators must not read test state or touch the SUT; anything state-dependent is supplied from the outside as overrides (via the model's `with:` option, DR-007). Raw values in overrides are auto-lifted to constant generators by `PropertyDamage.Generator.merge_overrides/2`.

Evidence level: directly evidenced by code, spec, and the breaking commit.

## Context

(Inferred plus commit evidence.) The 0.1.0 CHANGELOG describes a "two-layer generator architecture (`generator/1` and `new!/2`)" with "command preconditions for state-aware generation"; the legacy example in `lib/property_damage/ref.ex` shows commands that took state directly (`new!(state, _)`). State-aware commands cannot be reused across models and are harder to shrink and reason about. Commit `c6bddca` ("feat!: decouple commands from state via model-level wiring") made generators pure and moved state dependence to the model. Purity also makes generators composable: a specialized command can call another command's generator and extend it.

## Consequences

- `lib/property_damage/command.ex`: "Pure Generator Architecture" section; `@callback generator(overrides :: map()) :: StreamData.t(map())`; design principles on reusability and composability.
- `openspec/specs/command/spec.md` requirement "Pure Generator Architecture": "Generators MUST NOT depend on test state or the system under test; state-dependent logic belongs in the Model." Scenarios cover override application, auto-lifting, and composability.
- `lib/property_damage/generator.ex` provides `merge_overrides/2` for the override-merging idiom used by every command.
- Mix generator `mix pd.gen.command` scaffolds commands in this shape (`CLAUDE.md`).

## References

- `openspec/specs/command/spec.md` (header: "DR-006 (Pure Command Generators)")
- Related: DR-002, DR-007, DR-019
