# DR-002: Model and Command Agnosticism

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Models are agnostic of transport details and command internals; commands are agnostic of model state shape and execution transport. Each layer knows only its own concern:

- Commands define WHAT operations exist and their fields.
- Models define WHEN to use them and HOW to parameterize them.
- Adapters define HOW to execute them against the SUT.

This three-way separation is stated verbatim as a design principle ("Separation of Concerns") in the `PropertyDamage.Command` moduledoc.

Evidence level: the separation is directly evidenced in code and docs; the historical sequencing of the decision is inferred from commit subjects.

## Context

(Inferred.) Early versions coupled commands to state: commands carried `new!(state, _)` constructors, `creates_ref/0`, and preconditions (visible in the legacy examples inside `lib/property_damage/ref.ex` and the legacy-callback table in `lib/property_damage/command.ex`). That coupling prevented reusing a command across models with different state structures. Commit `c6bddca` ("feat!: decouple commands from state via model-level wiring") is the breaking change that established agnosticism, moving state-dependent logic into the model (DR-007) and leaving commands pure (DR-006). Commit `b01de90` ("feat: add model-free execute/2 API for static regression tests") shows the inverse benefit: sequences can execute without any model at all.

## Consequences

- `lib/property_damage/command.ex` moduledoc: "State-dependent concerns (preconditions, ref selection, expected events) are defined in the **Model**, not the Command. This separation enables command reuse across different Models with different state shapes."
- `openspec/specs/model/spec.md` purpose: "A model ties together commands, projections, and optional simulators without knowing transport details or command internals."
- Transport lives exclusively in adapters (`lib/property_damage/adapter.ex`); models and commands contain no HTTP/client code.
- `guides/reusable_components.md` builds on this agnosticism to share commands across models via protocols (DR-003).

## References

- `openspec/specs/model/spec.md` (header: "DR-002 (Model and Command Agnosticism)")
- Related: DR-006 (Pure Command Generators), DR-007 (Model-Level Command Wiring), DR-015 (Adapter Separation)
