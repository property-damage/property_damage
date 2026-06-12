# DR-009: Projections See Commands and Events

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

A projection's `apply/2` callback receives both command structs and event structs, in execution order. This is an explicit, deliberate deviation from pure event sourcing, where projections fold over events only.

Evidence level: high for the decision itself; the spec states the deviation is deliberate. Rationale is partly stated in the spec ("enables richer invariant checking") and partly inferred.

## Context

The projection spec records the intent directly: "This is a deliberate deviation from pure event sourcing that enables richer invariant checking" (`openspec/specs/projection/spec.md`, requirement "Projections See Both Commands and Events"). (Inferred elaboration:) in SPBT, useful invariants often relate what was attempted to what happened — e.g. "every CancelOrder against a paid order produces OrderCancellationRejected". If projections saw only events, intent would have to be smuggled into synthetic events. Feeding commands through `apply/2` also lets `@trigger every: :command` assertions and command-keyed triggers (`@trigger every: CreateOrder`) work uniformly, and lets `apply/2` raise on invalid transitions the moment the offending command is processed.

## Consequences

- `lib/property_damage/model/projection.ex`: `apply/2` is called with commands and with each produced event; the executor (`lib/property_damage/executor.ex`) routes both through projections.
- Trigger specs distinguish the two stream elements: `every: :command`, `every: :event`, `every: SomeModule` match either kind (`openspec/specs/projection/spec.md`, "Synchronous Assertions via @trigger").
- Simulators predict events from commands during generation, and the command sequence projection applies both predicted events and the commands themselves, keeping symbolic and concrete phases consistent (`lib/property_damage/model.ex` generation loop).
- Projections that only care about events simply pattern-match events and pass commands through (default `apply/2` returns state unchanged).

## References

- `openspec/specs/projection/spec.md` (header: "DR-009 (Projections See Commands and Events)")
- Related: DR-004, DR-012
