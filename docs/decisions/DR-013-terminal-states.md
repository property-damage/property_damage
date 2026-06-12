# DR-013: Terminal States

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Models may declare when a command sequence should stop growing by implementing the optional callback `terminate?/3`. It receives `(state, command_just_executed, events_produced)` and returns a boolean; returning `true` stops generation for that sequence. Without the callback, generation runs until the configured `max_commands` limit. Termination is thus model-defined and can key off a specific command type, a state predicate, or a terminal event.

Evidence level: the mechanism is directly evidenced in spec and code; rationale is inferred.

## Context

(Inferred.) Many SUT workflows have natural endpoints — an order is deleted, an account is closed, a payment reaches a final state — after which further commands are meaningless or would only generate noise (e.g. endless `OrderNotFound` events). A pure length cap cannot express this. Giving the model a `terminate?/3` predicate keeps generated sequences realistic, complements `when:` preconditions (which prevent invalid commands but cannot end a sequence), and gives shrinking less junk to remove. The signature mirrors the information available at each generation step in the loop (state, command, simulated events).

## Consequences

- `lib/property_damage/model.ex`: optional callback `terminate?/3`; the moduledoc example terminates after `%DeleteOrder{}`; the generation loop repeats "until max_commands or terminate?/3 returns true".
- `openspec/specs/model/spec.md` requirement "Terminal States" with scenarios for terminating on a command match, a state condition, an event, and the no-callback default.
- Works in the symbolic phase: `terminate?/3` is evaluated against simulator-predicted events during generation, so no SUT interaction is needed to decide termination.

## References

- `openspec/specs/model/spec.md` (header: "DR-013 (Terminal States)")
- Related: DR-007 (the generation loop it hooks into)
