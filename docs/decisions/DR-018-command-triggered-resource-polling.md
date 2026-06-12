# DR-018: Command-Triggered Resource Polling

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Adapters can spawn background pollers from within `execute/2` via the context's `start_poller` function (`ctx.start_poller.(opts)`), implemented by the `PropertyDamage.ResourcePoller` GenServer (added in commit `52a5906`). A poller takes a `poll_fn`, `interval_ms`, `timeout_ms`, and a `handler` that maps each poll result to `:continue`, `{:inject, event(s)}`, `{:done, event(s)}`, or `{:error, reason}`. Injected/done events flow into the shared EventQueue (DR-016). Timeout behavior is configurable via `on_timeout` (`:fail` default, `:ignore`, custom reason, or a function).

This lets a command return immediately with an initial event while the resource's subsequent state changes are observed asynchronously — distinct from settle/retry (DR-008), which blocks re-executing the *command* until it succeeds.

Evidence level: high; module, context plumbing, and spec scenarios all exist.

## Context

(Inferred from moduledoc and usage pattern.) `lib/property_damage/resource_poller.ex`: "This allows commands to return immediately with an initial event while a poller monitors the resource for subsequent state changes." Payment-style flows motivate it (the moduledoc example polls an authorization through `processing → pending_review → approved/declined`): a single command triggers a multi-step server-side lifecycle, and each transition should appear as its own event at roughly the time it happens, so projections and `@poll_state` assertions see a realistic timeline instead of one batched result. Settle alone cannot express this because it produces no intermediate events.

## Consequences

- `lib/property_damage/resource_poller.ex`: handler return-value table, structured error support (exceptions formatted via `Exception.message/1` in `:log` assertion mode), `on_timeout` handling.
- `openspec/specs/execution-engine/spec.md` "Adapter Execute Context": `:start_poller` is part of the standard adapter context alongside `:inject`.
- `openspec/specs/eventual-consistency/spec.md` covers resource polling next to settle and `@poll_state` as the framework's three eventual-consistency tools.
- Test commands with poller-driven flows live under `test/support/` (see `executor_test_support.ex`).

## References

- `openspec/specs/eventual-consistency/spec.md` (header: "DR-018 (Command-Triggered Resource Polling)")
- `openspec/specs/execution-engine/spec.md` (header: "DR-018 (Resource Polling)")
- Commit `52a5906`
- Related: DR-008 (settle), DR-016 (EventQueue and injection)
