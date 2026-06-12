# DR-008: Command Semantics (sync / probe / async)

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Every command declares one of exactly three execution semantics, carried in the `:execution` field of its command spec (legacy callback: `semantics/0`):

- `:sync` — a synchronous mutation; completes on adapter response (default).
- `:probe` — a read-only query; settle/retry logic applies (DR-008 + Settle); does not mutate the SUT; prioritized for removal during shrinking.
- `:async` — an asynchronous operation requiring polling for completion; settle/retry applies; protected during shrinking when its refs are consumed downstream.

A fourth value, `:mock_config`, existed historically and was removed: commit `d9eb01d` ("refactor!: remove :mock_config command semantics"). Mock configuration is instead handled by mock service adapters (execution-engine spec, "Mock Service Adapter").

Evidence level: high. The three values, their settle behavior, and the shrinking interactions are all in code, specs, and dedicated tests.

## Context

(Inferred plus commit evidence.) Eventually consistent SUTs need the framework to distinguish "do something" from "observe something" and "start something that finishes later". Naming evolved: commit `b4f0f17` ("refactor: rename command role/0 to semantics/0 and clarify semantics values") shows the concept hardening, and the `command_spec/1` migration table maps `semantics/0` to `:execution` (DR-019). The `:mock_config` removal suggests the team decided that configuring mocks is adapter/infrastructure behavior, not a command semantic; presenting it as a command semantics value conflated test orchestration with SUT operations. (Rationale for the removal is inferred from the commit subject and the existence of the Mock Service Adapter requirement; no recorded rationale survives.)

## Consequences

- `lib/property_damage/command.ex`: spec field `execution: :sync | :probe | :async`; `@callback semantics() :: :sync | :probe | :async` retained as a legacy fallback (`get_legacy_semantics/1`).
- `lib/property_damage/settle.ex`: retry logic applies to `:probe`/`:async` commands (defaults `timeout_ms: 2000`, `interval_ms: 100`, `backoff: :linear`).
- Shrinking: probe commands are prioritized for removal; see `test/property_damage/shrinker_test.exs:725` ("Probe Shrinking Priority Tests (DR-008)", added by commit `0311981`), `test/support/test_commands.ex:109`, and `test/support/executor_test_support.ex:253`.
- `openspec/specs/command/spec.md` requirement "Execution Semantics"; `openspec/specs/eventual-consistency/spec.md` covers the probe/async settle behavior.
- Async ref protection: "async commands whose refs are used by subsequent commands are protected during shrinking" (command spec).

## References

- `openspec/specs/command/spec.md` (header: "DR-008 (Command Semantics)")
- `openspec/specs/eventual-consistency/spec.md` (header: "DR-008 (Command Semantics -- probe/async)")
- Test references listed above; commits `b4f0f17`, `d9eb01d`, `0311981`
- Related: DR-017 (shrinking), DR-018 (resource polling)
