# DR-031: Nemesis Generation Dispatch (new!/2 + precondition/1 wired into generation)

**Status:** Accepted (design pass; implementation in progress)
**Date:** 2026-06-29

> Part of the served/servant clean-break campaign (discrepancy sweep). Makes a documented,
> spec-locked feature — weighted nemesis generation — actually work, rather than deleting it.

## Decision

The sequence generator dispatches the `Nemesis` generation callbacks:

- When a model's `commands/0` includes a nemesis module (optionally weighted, e.g.
  `{PartitionNetwork, weight: 1}`), the generator selects it by weight alongside ordinary
  commands and produces an instance via `nemesis_module.new!(state, overrides)` (when exported),
  filtered by `nemesis_module.precondition/1`. Nemesis modules do **not** implement
  `generator/1` and do not `use PropertyDamage.Command`, so the generator branches on
  `Nemesis.nemesis_module?/1` rather than falling through to the command generator.
- `precondition/1` becomes a real generation-time filter (a nemesis whose precondition is unmet
  for the current state is not selected).

## Context

`Nemesis.new!/2` is implemented in all eleven built-in nemeses (and `@spec`'d), and
`precondition/1` is a required callback implemented everywhere, but neither is called by
`generator.ex` — it only generates command instances via `cmd_module.generator(overrides)`.
A bare nemesis module listed in `commands/0` would fall through `normalize_command_spec` →
`build_spec_from_legacy` and then crash in the generator (no `generator/1`). So the
`fault-injection/spec.md` "Model Integration" requirement ("the framework SHALL select Nemesis
commands according to their weights during sequence generation") was unimplemented: nemesis
commands only reached the runtime when pre-baked into a sequence. This DR closes that gap.

## Consequences

- `lib/property_damage/generator.ex` (command-instance step branches on nemesis modules),
  `lib/property_damage/nemesis.ex` (dispatch helpers as needed). Coordinated with DR-028
  (command spec resolution) so nemesis modules are normalized coherently.
- Spec: `openspec/specs/fault-injection` (Model Integration scenario now backed by code).
- Tests: weighted nemesis generation produces nemesis command instances; `precondition/1`
  filters; existing pre-baked-sequence paths still work.

## References

- `openspec/specs/fault-injection/spec.md` (Model Integration). Related DR-028.
