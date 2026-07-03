# DR-038: Nemesis Toxiproxy config source and partition semantics

**Status:** Accepted
**Date:** 2026-07-03

> Refines the built-in network nemeses (`NetworkLatency`, `NetworkPartition`,
> `PacketLoss`) and their Toxiproxy integration. Amends the "Built-in Fault
> Types" requirement of the fault-injection spec.

## Context

The three built-in network nemeses each carried their own copy of the Toxiproxy
plumbing (config discovery, `:httpc` post/delete, URL building, status
dispatch), and each discovered its config from a **top-level** `:toxiproxy` key
on the nemesis execution context:

    def inject(command, %{toxiproxy: config}), do: ...

But the executor builds that context as
`%{adapter_context: ..., event_queue: ..., active_faults: ...}`
(`PropertyDamage.Executor.Nemesis`, both the inject and the auto-restore build
sites) and never sets a top-level `:toxiproxy`. So through `PropertyDamage.run`
the nemeses **always** ran simulated: live injection was unreachable through the
engine, exercised only by tests hand-calling `inject/2` with a hand-built
top-level context. The spec said injection happens "when configured in the
adapter context"; the implementation disagreed. This was an underbuilt feature.

Two smaller defects rode along:

- `:full` partition sent one unqualified `bandwidth` toxic. Toxiproxy defaults a
  streamless toxic to **downstream**, so a "full bidirectional partition" only
  blocked responses; requests still flowed.
- `:asymmetric` partition's doc ("requests go through, responses blocked") and
  its implementation were both exactly `:downstream` — duplicate vocabulary for
  one behavior.

## Decision

1. **The adapter context owns the Toxiproxy config.** An adapter's `setup/1`
   return MAY include `toxiproxy: %{proxy_name: ..., api_url: ...}`. Config
   discovery reads `context[:toxiproxy]` first (top-level, honored so direct
   `inject/2` calls and audits keep working), then
   `context.adapter_context[:toxiproxy]` (the engine path). There is **no**
   run-level `toxiproxy:` option: it would be a second config path for one
   concern and would diverge from the spec's "adapter context" wording.

2. **The plumbing is extracted to `PropertyDamage.Nemesis.Toxiproxy`.** It owns
   config discovery, the live-vs-simulated decision, HTTP over `:httpc` (starting
   `:inets` on demand so a host app need not remember to), and toxic
   apply/remove. Each nemesis keeps only its generator, a **pure** `toxics/1`
   returning JSON-encodable toxic maps, and its event construction. Restore
   derives the toxic names from the same `toxics/1`, so a nemesis that injects N
   toxics deletes exactly those N.

3. **`:full` partition is two toxics.** `pd_partition_up` (stream upstream) and
   `pd_partition_down` (stream downstream), both `bandwidth` rate `0`. Restore
   deletes both. `:upstream`/`:downstream` remain a single `pd_partition` toxic
   with `"stream"` set.

4. **`:asymmetric` is removed.** It was an alias of `:downstream`. Dropped from
   the generator, the struct's accepted `partition_type` values, and the
   moduledoc. This is a breaking change for models overriding
   `partition_type: :asymmetric`; pre-v1, taken as a clean break with a CHANGELOG
   entry.

5. **Simulated fallback is unchanged.** When no config is discovered, no HTTP
   happens and the event is tagged `simulated: true`
   (`PropertyDamage.Nemesis.simulated_event?/1`), so a no-op fault can never
   masquerade as a real one.

## Consequences

- Live network fault injection is now reachable through `PropertyDamage.run`:
  return `toxiproxy: %{...}` from your adapter's `setup/1`.
- A full partition genuinely cuts both directions.
- The three nemesis modules contain no URL strings, no `:httpc`, and no status
  dispatch; `PropertyDamage.Nemesis.Toxiproxy` is the single owner.
- Models using `partition_type: :asymmetric` must switch to `:downstream`.
