# DR-016: Injector Pattern

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Events that originate outside command execution (webhooks, callbacks, message queues, mock-service side effects) enter the framework through a dedicated injection path rather than through adapter return values:

- **Injector adapters** (`PropertyDamage.Adapter.Injector` behaviour) listen to external sources, transform payloads via `to_event/1`, and push events to a shared **EventQueue**. They declare emitted event types with `@emits` for validation against the model's `injectable_events/0`. Lifecycle mirrors adapters (`setup/1` / `teardown/1`).
- **Mid-execution injection**: the adapter context's `:inject` function lets an adapter emit events immediately during `execute/2`, instead of batching them at the end (useful for `:async` commands).
- The executor drains pending queue events after each command and processes them through projections, recording source adapter and timestamp.

Evidence level: high; behaviour, queue, and context function are implemented and specified. Rationale partially documented in moduledocs.

## Context

`lib/property_damage/adapter/injector.ex` documents the inversion directly: "Unlike Adapter (which executes commands → produces events), Adapter.Injector receives external events → transforms → pushes to EventQueue." (Inferred elaboration:) async SUTs deliver outcomes out-of-band; without an injection path, tests could only poll. The pattern grew incrementally: `0ced9e2` ("feat: add mid-command event injection for async adapters"), `494b09e` ("fix: add inject function support to LoadTest.Session"), `b6c5c69` (ref preservation for injected events). `@emits`/`injectable_events/0` exist so pre-run validation can catch events no projection would handle ("Detecting orphan events that no assertion projection handles", injector moduledoc).

## Consequences

- `lib/property_damage/adapter/injector.ex`: behaviour with `setup/1`, `to_event/1` (returning `{:ok, event}` or `:skip`), `teardown/1`, and `@emits`.
- `lib/property_damage/adapter.ex` "Mid-Execution Event Injection" section: `ctx.inject` for `:async` commands.
- `openspec/specs/execution-engine/spec.md` requirements "Injector Adapter for External Events", "Shared Event Queue" (drain after each command, record source and timestamp), and "Mock Service Adapter" (mocks inject events through the same pipeline).
- `lib/property_damage/model.ex`: optional `injectable_events/0` callback ("Events that can arrive from Adapter.Injector modules").
- ResourcePoller (DR-018) reuses the EventQueue as its event sink.

## References

- `openspec/specs/execution-engine/spec.md` (header: "DR-016 (Injector Pattern)")
- Commits `0ced9e2`, `494b09e`, `b6c5c69`
- Related: DR-015, DR-018
