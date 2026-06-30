# DR-028: Single command_spec Surface for Static Command Metadata

**Status:** Accepted (implemented)
**Date:** 2026-06-29

> Part of the served/servant clean-break campaign. Collapses the `Command` behaviour to one
> canonical declaration surface and one consumption seam, deleting the transitional dual path
> DR-019 left behind. Pre-v1 breaking change; no deprecation window.

## Decision

Organizing principle: **static facts live in the `command_spec/1` map; per-instance
computations are function callbacks.**

- `command_spec/1` is the single static-metadata surface, authored via
  `use PropertyDamage.Command, <opts>` or an override. It **gains** `:observables` (from
  `downstream_observables/0`), `:idempotent` (from `idempotent?/0`), and
  `:acceptable_retry_events`, alongside the existing `:execution`/`:settle`/`:shrink`/`:when`/
  `:with`/`:weight`. `read_only?/0` collapses into the `:shrink` enum (no redundant boolean).
- The surviving **function callbacks** are all per-instance (they take the command and/or
  state): `generator/1` (required), `idempotency_key/1`, `label/2`, and the new `awaits/2`
  (DR-030). A per-instance value cannot live in a static map, so these stay functions.
- **Deleted cleanly:** `semantics/0`, `settle_config/0`, `read_only?/0`, `idempotent?/0`,
  `acceptable_retry_events/0`, `downstream_observables/0`, `build_spec_from_legacy/1`, and the
  legacy branch of `Model.resolve_spec/2`.
- **One consumption seam:** every servant read resolves through the materialized spec map.
  The scattered `function_exported?/3` probes (`stutter.ex`, `validation.ex`, `pd.validate.ex`,
  `shrinker.ex`) are retired; `settle.ex` already accepts the spec map.

## Context

`generator/1` is the clean parti, but `Command` had accreted nine optional callbacks, several
belonging to other subsystems (stutter, settle, validation/shrinking). DR-019 introduced
`command_spec/1` to consolidate, but only folded three callbacks (`semantics`, `settle_config`,
`read_only?`) and left the rest as scattered direct probes, producing a dual declaration path
*and* a dual/scattered read path. The dual declaration path is verifiably benign (the legacy
builder loses no data; the model re-merges its opts), so the real bite is the scattered reads
and the servant accretion. Pre-v1, the clean fix is one declaration surface + one read seam,
with the individual static callbacks removed rather than deprecated.

## Consequences

- `lib/property_damage/command.ex` (spec map, `use` macro, deletions), `model.ex`
  (`resolve_spec`/`normalize_command_spec`), `settle.ex`, `stutter.ex`, `validation.ex`,
  `shrinker.ex`, `lib/mix/tasks/pd.validate.ex`, and the framework's own generators
  (`pd.gen.command`, `pd.scaffold`) + `test/support` commands + guides (migrated to the single
  surface).
- Spec deltas: `openspec/specs/command` (rewrite the Optional Metadata Callbacks +
  Legacy Callback Fallback requirements), `openspec/specs/concurrency` (idempotent /
  acceptable-retry), `openspec/specs/shrinking` (read_only → shrink).
- Supersedes the legacy-fallback portion of DR-019. `CHANGELOG.md` BREAKING entry.

## References

- `openspec/specs/command/spec.md`
- Supersedes part of DR-019 (Command Spec Pattern); related DR-006, DR-007, DR-008, DR-030.
