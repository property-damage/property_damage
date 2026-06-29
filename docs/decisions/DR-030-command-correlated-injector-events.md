# DR-030: Command-Correlated Injector Events (Command.awaits/2 + framework push-settle)

**Status:** Accepted (design pass; implementation in progress)
**Date:** 2026-06-29

> Part of the served/servant clean-break campaign. Implements *properly* the capability the
> dead `Adapter.register_handler/2` callback promised — a command correlating and awaiting
> external injector events — by locating it on the correct (semantic) surface. Pre-v1 breaking
> change; `register_handler/2` is removed (see DR-027).

## Decision

- **Declaration (semantic, on `Command`):** a new per-instance callback
  `Command.awaits(state, command) -> [%PropertyDamage.Await{match, await}]`. `match` is a
  predicate `(event -> boolean)` built from the resolved command and its captured response
  (correlation key); `await` is the policy. It is evaluated post-`execute` (after placeholder
  capture). Correlation operates on **domain events** — `Adapter.Injector.to_event/1` has
  already stripped transport — so it is a semantic concern, not a transport one, and lives on
  neither the outbound `Adapter` nor the inbound `Adapter.Injector`.
- **Mechanism (framework push-settle):** after `execute/3` and at finalize drains, the framework
  awaits the internal `EventQueue` (drain + settle backoff, reusing `command_spec.settle`) for a
  match. Polling the SUT is not viable for a push-only result; awaiting the framework's own
  queue is. On match: **attribute the registering command's `command_index`** to the event
  (today injector events fold with `command_index: nil`), fold it through projections +
  assertions (DR-025), and capture `external()` placeholders (DR-021). A *required* await that
  times out fails the command, like a settle timeout.
- **Lifetime vs await (liveness/safety, mirroring DR-024):** a handler keeps attributing *all*
  its matches to its command for the rest of the run (so cardinality invariants such as "at most
  one" are checkable on the command's correlated set via a `Projection` `@invariant`); the await
  only gates the *first/required* match. `await: :none` correlates without blocking (saga-style
  late arrivals).
- **Multiplicity:** an event satisfies **at most one** handler (first-registered, deterministic);
  overlapping matchers raise a diagnostic; unmatched injector events fold as ambient
  (`command_index: nil`) as today.
- **Simulator mode:** no real await — correlation matches `Model.simulate/2`-predicted events
  synchronously. This makes `Command.awaits` ↔ `Model.simulate` an explicit, documented contract.
- The matcher is a pure predicate, so there is no per-command setup-failure path; listening is
  owned by `Adapter.Injector.setup/1`.

## Context

`register_handler/2` was declared and documented ("commands that register handlers which receive
events from injector adapters") but invoked nowhere, and its documented semantics did not map
onto the injector → shared-`EventQueue` → uniform-drain flow: injector events folded uniformly
with no per-command correlation. The motivating case — a command whose result returns
asynchronously via a webhook — cannot be served by the pull-based settle loop or `start_poller`
(nothing to poll on a push-only SUT), only by awaiting the internal queue. Correlation matches
on domain fields and is therefore transport-agnostic and reusable across inbound transports,
which is why it belongs on the semantic surface rather than duplicated per injector.

## Consequences

- New `lib/property_damage/await.ex`; `command.ex` (callback), `executor.ex` (await loop on the
  extracted `Executor.Settle`), `event_queue.ex` / `process_injector_events` (attribution),
  `adapter/injector.ex` (canonical inbound seam). Deletes `register_handler/2`.
- Spec deltas: `openspec/specs/command` (awaits), `openspec/specs/eventual-consistency`
  (push-settle await), `openspec/specs/execution-engine` (injector-event `command_index`
  attribution). `CHANGELOG.md` BREAKING entry.
- Demonstrated end-to-end by the Gitea webhook bench (`benches/gitea_bench`).

## References

- `openspec/specs/eventual-consistency/spec.md`, `openspec/specs/execution-engine/spec.md`
- Depends on DR-027 (Runtime handle), DR-029 (Executor.Settle). Related DR-016, DR-021, DR-024,
  DR-025.
