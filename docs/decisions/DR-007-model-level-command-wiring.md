# DR-007: Model-Level Command Wiring

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

State-dependent command configuration is declared in the model's `commands/0` list, not in the command modules. Three wiring options exist:

- `weight:` — relative selection frequency among currently-valid commands (default 1).
- `when:` — precondition `(state -> boolean)` evaluated against the command sequence projection state (default: always true).
- `with:` — `(state -> map)` (or a plain map) producing generator overrides, enabling state-dependent parameterization such as selecting existing refs (default: `%{}`).

Commands may be listed bare, as `{Module, opts}`, or as `%{command: Module, ...}` maps; all forms normalize to command specs (DR-019).

Evidence level: directly evidenced by code, spec, and the breaking commit `c6bddca` ("feat!: decouple commands from state via model-level wiring").

## Context

(Inferred.) This is the counterpart of DR-006: once generators are pure, the state-dependent half (when a command is valid, how to parameterize it for the current state) must live somewhere that has access to state. The model already owns the command sequence projection, so it is the natural owner. Wiring at the model level also means the same command can be wired differently in different models (different weights, different preconditions), which is the reuse goal of DR-002/DR-003.

## Consequences

- `lib/property_damage/model.ex` moduledoc documents the options and the generation loop: filter by `when:`, weighted-random select, generate with `with:` overrides, simulate, apply, repeat.
- `openspec/specs/model/spec.md` requirements "Command Wiring Options", "Command Specification Formats", and "Command Sequence Generation Loop".
- Weights are relative among valid commands only (model spec scenario: weight 3 vs 1 yields ~75% selection).
- The wiring options became spec fields (`:when`, `:with`, `:weight`) in the `command_spec/1` map, so commands may also ship defaults for them (DR-019 priority layering).

## References

- `openspec/specs/model/spec.md` (header: "DR-007 (Model-Level Command Wiring)")
- Related: DR-002, DR-006, DR-019
