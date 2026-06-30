# DR-030: Command-Correlated Injector Events (Command.awaits/2, judgment via projections)

**Status:** Accepted (amended 2026-06-30; supersedes this DR's original push-settle design)
**Date:** 2026-06-29

> Part of the served/servant clean-break campaign. Implements *properly* the
> capability the dead `Adapter.register_handler/2` callback promised — a command
> correlating an external injector event back to itself — by locating it on the
> correct (semantic) surface. Pre-v1 breaking change; `register_handler/2` is
> removed (see DR-027).

## Decision

- **Declaration (semantic, on `Command`):** a new per-instance callback
  `Command.awaits(state, command) -> [%PropertyDamage.Await{match}]` (optional,
  default `[]`). Each `%Await{}` carries a single field, **`match`**, a predicate
  `(event -> boolean)` built from the resolved command and its captured response
  (the correlation key). It is evaluated post-`execute` (after placeholder
  capture). Correlation operates on **domain events** — `Adapter.Injector.to_event/1`
  has already stripped transport — so it is a semantic concern, not a transport
  one, and lives on neither the outbound `Adapter` nor the inbound
  `Adapter.Injector`.
- **Pure correlation, not judgment.** An `%Await{}` only *attributes*: when an
  injector event satisfies a registered `match`, the framework sets that event's
  `command_index` to the declaring command (today injector events fold with
  `command_index: nil`), persistently for the rest of the run (a matcher outlives
  the command that declared it, so late/saga arrivals still correlate). It does
  **not** block, time out, or assert. The match registry is threaded on
  `%Executor.State{await_matchers}` and consulted at every queue drain
  (per-command, finalize, nemesis, branch).
- **Judgment lives in projections.** All pass/fail decisions over a command's
  correlated set reuse the existing assertion machinery rather than a second
  bespoke "wait for eventual consistency" path:
    - **liveness** ("the event must eventually arrive") is a `@poll_state`
      assertion over the correlated set. The `@poll_state` finalize drain already
      awaits the internal `EventQueue`, so no separate await loop is needed.
    - **safety / cardinality** ("at most one", "exactly N") is a `@trigger` /
      `@invariant` assertion over the correlated set.
- **Locality of liveness failures.** A `@poll_state` poll-timeout now carries the
  `command_index` of the command whose event opened the poll window (threaded
  through `triggered_by`), reported as the failure's `failed_at_index`, so the
  shrinker keeps locality. (Previously poll-timeouts reported `nil`.)
- **Multiplicity:** an event satisfies **at most one** await (first-registered,
  deterministic); overlapping matchers log a diagnostic and the first wins;
  unmatched injector events fold as ambient (`command_index: nil`) as today.
- **Simulator mode:** the symbolic phase has no injector queue, so a simulated
  awaited event folds as the command's own `Model.simulate/2` output and is
  thereby attributed to that command. This makes `Command.awaits` ↔ `Model.simulate`
  an explicit, documented contract: the simulator predicts the event its
  `awaits/2` correlates live, so simulated and live projection states agree.

## Context

`register_handler/2` was declared and documented ("commands that register
handlers which receive events from injector adapters") but invoked nowhere, and
its documented semantics did not map onto the injector → shared-`EventQueue` →
uniform-drain flow: injector events folded uniformly with no per-command
correlation. The irreducible missing capability is **attribution**: only the
*command* can build the correlation key from its own resolved fields, and a
projection cannot set an event-log entry's `command_index` itself. That is what
`awaits/2` supplies.

### Why no bespoke await loop (amendment)

This DR originally specified a `%Await{match, await}` with an `await` policy atom
(`:first` / `:none`) and a **framework push-settle await**: for a required await,
block post-`execute`, draining the `EventQueue` with settle backoff until a match
arrives or a timeout fails the command. That design was dropped during
implementation review. The atom conflated two separable concerns —
**correlation** (always wanted) and **judgment** (liveness/safety) — and the
push-settle loop **duplicated** machinery that already exists: `@poll_state`'s
finalize drain (`Executor.Finalization.drain_await_loop`) already awaits the
internal `EventQueue` until a predicate over folded events holds, or times out.
A second eventual-consistency path is exactly the served/servant duplication this
campaign removes. So liveness collapses to a `@poll_state` over the correlated
set, and safety to a `@trigger`/`@invariant` — one surface for correlation
(`awaits/2`), one surface for judgment (projections).

The one capability the push-settle loop uniquely offered — forward-feeding an
awaited event's `external()` data into a *later* command (which needs an inline
block, since `@poll_state` resolves only at finalize) — is YAGNI for this
campaign (the Gitea webhook bench treats the webhook as an observed side-effect,
not downstream input) and, if ever needed, belongs to `:async` execution
semantics on the command's own result, not to `awaits/2`.

## Consequences

- New `lib/property_damage/await.ex` (`%Await{match}`); `command.ex` gains the
  optional `awaits/2` callback; `%Executor.State{}` gains `await_matchers`;
  `Executor.Events.process_injector_events/5` performs first-registered
  attribution + overlap diagnostic; the executor registers a command's matchers
  post-capture before draining; `Executor.Finalization` attributes poll-timeouts
  to the triggering command. Deletes `register_handler/2` (done under DR-027).
- No new finalize failure mode: attribution only relabels `command_index` on
  folded events, so the locked finalize precedence ladder (DR-029) is undisturbed.
- Spec deltas: `openspec/specs/command` (awaits correlation),
  `openspec/specs/eventual-consistency` (liveness over a correlated set via
  `@poll_state`; poll-timeout locality), `openspec/specs/execution-engine`
  (injector-event `command_index` attribution). `CHANGELOG.md` BREAKING entry.
- Demonstrated end-to-end by the Gitea webhook bench (`benches/gitea_bench`,
  P9): a `CloseIssue` correlates its `issues/closed` webhook via `awaits/2`, with
  an "exactly one webhook per close" `@invariant` over the correlated set.

## References

- `openspec/specs/eventual-consistency/spec.md`, `openspec/specs/execution-engine/spec.md`
- Depends on DR-027 (Runtime handle, `register_handler/2` removal), DR-029
  (Executor.Events / Finalization extraction). Related DR-016, DR-021, DR-024,
  DR-025.
