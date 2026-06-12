# DR-003: Reuse Through Standard Elixir

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Reusable test components (shared command configurations, projections, simulators) are built with standard Elixir mechanisms — protocols, plain functions, module composition, and generator composition — rather than a framework-specific plugin or inheritance system. PropertyDamage deliberately ships no DSL for component reuse.

Evidence level: moderate. No single artifact states this decision; it is the consistent pattern across the guide, the command moduledoc, and the absence of any reuse DSL in `lib/`.

## Context

(Inferred.) Different models structure state differently (flat maps vs nested maps), so reusable `when:`/`with:` configuration needs an abstraction over state access. The framework could have imposed a state schema or a registration DSL; instead, `guides/reusable_components.md` (added in the Unreleased CHANGELOG section as "Building Reusable Components") shows the chosen approach: define a domain protocol (e.g. `PaymentAccess`) and implement it per state shape. Likewise, generator reuse happens by calling another command's `generator/1` and extending it ("Composability" design principle in `lib/property_damage/command.ex`).

## Consequences

- `guides/reusable_components.md`: protocols abstract state access so one command configuration works across models ("Solution: Protocols for State Access").
- `lib/property_damage/command.ex` design principles: "Composability: The `generator/1` function enables composition. A specialized command can call another command's generator and extend it."
- `CHANGELOG.md` (Unreleased, Added): the guide "Explains protocols for state access across different state structures" and "Covers reusable command configurations and assertion projections".
- No reuse-specific macros exist beyond the `use` macros that wire up behaviours; sharing is done with `def`, `defprotocol`, and function references in command specs.

## References

- `openspec/specs/model/spec.md` (header: "DR-003 (Reuse Through Standard Elixir)")
- Related: DR-002 (agnosticism is what makes this reuse possible)
