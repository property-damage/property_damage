# DR-043: Targets Carry Every Per-Target Resource

**Status:** Accepted
**Date:** 2026-10-05

## Context

The adapter, its setup configuration, the injector adapters and the mock
services were run-level options of `PropertyDamage.run/1` (`adapter:`,
`adapter_config:`, `injector_adapters:`, `mock_services:`). A run therefore
had exactly one target. `PropertyDamage.Differential.run/1` accepted
`targets:`, but a differential target could not carry injectors or mocks, and
the reference target was marked with a per-target `role:` option, so a list
could name zero or several references.

DR-042 decided that `targets:` is the only place a target is described. This
record fixes the entry shape and the removal of the old keys.

## Decision

1. **Entry shape.** A `targets:` entry is a `Module` or a
   `{Module, keyword}` tuple, the same idiom `commands/0` uses. The full
   shape has five keys: `name:`, `config:`, `injectors:`, `mocks:` and
   `expansion:`. This record introduces the first four. `expansion:` is
   reserved for the decision record that introduces expansions; until then
   it is an unknown-key error.
   - `name:` is a string.
   - `config:` is a map (default `%{}`) and reaches `Adapter.setup/1`
     unchanged. There is no keyword-to-map conversion, because every
     `setup/1` takes a map.
   - `injectors:` is a list of injector adapter modules (default `[]`).
   - `mocks:` is a list (default `[]`) whose entries are `Mod` or
     `{Mod, config_map}`.
2. **One validator.** The run schema validates `targets:` with one custom
   validator. A nested NimbleOptions schema describes the entry keys, and
   the option docs render it. The validator normalizes every entry to
   `%PropertyDamage.Target{adapter, name, index, config, injectors, mocks}`;
   `index` is the zero-based position in the list.
3. **The first entry is the reference.** There is no `role:` option, so a
   list has exactly one reference by construction. Results and reports name
   each target by index and name; `PropertyDamage.Differential.Result`
   holds `%{index, name}` pairs in `reference` and `targets`.
4. **Default names.** A target without `name:` is named after the last
   segment of its adapter module, with no index suffix. Reordering
   `targets:` never renames a target, so the name is a stable identifier.
5. **Duplicate names are an error.** Two entries that resolve to the same
   name are an option error that asks for a distinct `name:`:
   ``two `targets:` entries resolve to name: "Adapter"; give each a distinct `name:` ``.
6. **Single-variant entry points.** Every entry point other than
   `PropertyDamage.Differential.run/1` takes exactly one entry. A list of
   another length raises
   ``expected exactly one `targets:` entry (a single-variant run), got N; use `PropertyDamage.Differential.run/1` to compare several targets``.
   An entry point whose engine cannot honor `injectors:` or `mocks:` raises
   `` `injectors:` is not supported by <entry point> (targets entry N) ``
   (or the same for `mocks:`) instead of ignoring the key.
7. **Removal with no mapping.** There is no compatibility layer.
   - The run-level keys `adapter:`, `adapter_config:`, `injector_adapters:`
     and `mock_services:` are option errors that name `targets:`, for
     example `` `adapter:` was replaced by `targets:`; pass the adapter module as a `targets:` entry ``
     and `` `adapter_config:` was replaced by `targets:`; pass the map as `config:` in a `targets:` entry ``.
     The `injector_adapters:` and `mock_services:` messages name
     `injectors:` and `mocks:` the same way.
   - A per-target `role:` is an error:
     `` targets entry N: `role:` was removed; the first `targets:` entry is the reference ``.
   - A per-target `opts:` is an error:
     `` targets entry N: `opts:` was renamed `config:` ``.
   - A `{Module}` 1-tuple is invalid:
     ``targets entry N is malformed: expected an adapter module or `{AdapterModule, keyword}`, got: {Module}``.
   - `PropertyDamage.Differential.Target` is replaced by
     `PropertyDamage.Target`.
8. **Isolation is the target's job.** Two targets that run against one
   system isolate their slices of state through `config:` (a tenant, an
   account, a path prefix). The framework documents this and does not
   provide it. `mix pd.validate --targets` warns when two targets use the
   same adapter with an identical `config:`, the configuration where a
   collision is certain.

## Rationale

- Putting the adapter, its config, its injectors and its mocks in one entry
  lets every variant be a full target. A comparison between two variants
  then covers the same surface as a single-variant run, and one validator
  and one struct serve every entry point.
- The first-entry rule removes a state that `role:` allowed (no reference or
  several) and needs no validation.
- A name derived from the module alone is stable under reordering. An index
  suffix would rename targets whenever the list changed, which breaks any
  stored report that mentions a name.
- Raising on `injectors:` and `mocks:` where an engine cannot honor them
  turns a silently ignored key into an immediate error.
- Collisions between variants on one system come from shared state in the
  system, which only the target's configuration can separate.

## Alternatives considered

- **Derive generated values per variant to avoid collisions.** Rejected: a
  hidden coupling in the plan. Values that look arbitrary would depend on
  the variant, and a replayed sequence would not mean the same thing in
  another list.
- **Keep `role:` and validate that exactly one entry is the reference.**
  Rejected: the first-entry rule gives the same guarantee without an
  option or a validation.
- **Index suffix on default names.** Rejected: reordering would rename
  targets.
- **Keyword `config:` converted to a map.** Rejected: every `setup/1` takes
  a map, and a conversion is a second form to document and test.
- **Accept the old run-level keys as aliases.** Rejected: pre-v1 clean
  break; an alias would keep two ways to describe a target.

## Consequences

- `PropertyDamage.Target` is the one target struct. `Executor.run/4` takes
  the adapter configuration as `config:`.
- The model lifecycle-hook context key `adapter_config` stays. Those hooks
  are slated for removal by a later decision, and renaming the key now would
  be churn.
- `FailureReport.adapter` and `RunTrace.adapter` stay module fields, so the
  persistence format does not change.
- DR-042 decided that `targets:` is the only place a target is described;
  this record gives the entry shape and the detailed removal. The `adapter:`
  option that DR-035 lists for `RunTrace.capture/1` and
  `RunComparison.investigate/1` is now a `targets:` entry (inside `capture:`
  for the comparison functions).
