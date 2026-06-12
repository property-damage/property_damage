# DR-015: Adapter Separation

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

All SUT transport lives in a dedicated Adapter behaviour, separate from models, commands, and projections. Adapters translate command structs into real operations (HTTP calls, function calls, message sends) and return domain events: `execute/2` returns `{:ok, [events]}` or `{:error, reason}`. The lifecycle is strict — `setup/1` once, `execute/2` per command, `teardown/1` once — and is repeated in full for every run *and every shrink attempt*, with teardown guaranteed even on failure. Complex adapters split by domain using the `delegate_execution for: [...], to: SubAdapter` macro.

Evidence level: high; behaviour, lifecycle, and delegation are all in code and spec.

## Context

(Inferred.) Keeping transport out of models and commands is what makes the symbolic phase possible (no SUT contact during generation) and makes a model reusable against different transports (HTTP today, direct function calls in CI, a mock service in development). The strict per-run lifecycle gives shrinking a clean slate per candidate sequence, which is required for failure equivalence checks to be meaningful (DR-017). The events-out contract (`{:ok, [events]}`) keeps the adapter on the same vocabulary as projections and simulators: everything downstream consumes events, regardless of transport.

## Consequences

- `lib/property_damage/adapter.ex`: behaviour and lifecycle diagram, including interaction with model hooks (`setup_each` before `Adapter.setup` on every run and shrink attempt); `delegate_execution/1` macro; stutter/idempotency context; `:inject` context function (DR-016).
- `openspec/specs/execution-engine/spec.md` requirements "Adapter Lifecycle" (teardown on failure, full lifecycle per shrink attempt), "Adapter Execute Context", "Command Delegation to Sub-Adapters", "Adapter Timeout" (default 30s, per-command overrides).
- `lib/property_damage/command.ex` design principles: "Adapters define HOW to execute them against the SUT."
- Sub-adapters receive the same context as the parent, so delegation is purely organizational.

## References

- `openspec/specs/execution-engine/spec.md` (header: "DR-015 (Adapter Separation)")
- `CLAUDE.md` ("Adapter ... Bridge to the SUT")
- Related: DR-002, DR-016, DR-018
