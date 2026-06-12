# DR-001: Models as Behaviour Modules

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Models are plain Elixir modules implementing the `PropertyDamage.Model` behaviour. The behaviour defines two required callbacks (`commands/0`, `command_sequence_projection/0`) and a set of optional callbacks (`assertion_projections/0`, `injectable_events/0`, `simulator/0`, `terminate?/3`, and the `setup_once/setup_each/teardown_each/teardown_once` lifecycle hooks). There is no model DSL, no model process, and no model struct: a model is a module that satisfies a contract.

Evidence level: the decision itself is directly evidenced by the code; the rationale below is inferred.

## Context

(Inferred.) A stateful PBT framework needs a single place that ties together commands, projections, simulators, and lifecycle. The idiomatic Elixir mechanism for such pluggable contracts is a behaviour (as used by `GenServer`, `Plug`, etc.). Using a behaviour rather than a macro DSL keeps models inspectable, testable as ordinary modules, and composable with standard language features (see DR-003). The commit `f0eef60` ("refactor!: introduce Simulator behaviour and reorganize modules") shows the project consistently reaching for behaviours when extracting contracts.

## Consequences

- `lib/property_damage/model.ex` defines the behaviour; the moduledoc documents required and optional callbacks and the generation loop.
- User models declare `@behaviour PropertyDamage.Model` and implement callbacks directly (see the `OrderModel` example in the moduledoc).
- All four other core contracts follow the same pattern: `lib/property_damage/command.ex`, `lib/property_damage/model/projection.ex`, `lib/property_damage/adapter.ex`, `lib/property_damage/nemesis.ex`.
- Optional callbacks are detected via `function_exported?/3`, so minimal models stay minimal.
- Pre-run validation (`mix pd.validate`, execution-engine spec "Pre-Run Validation") can check the module contract before execution.

## References

- `openspec/specs/model/spec.md` (header: "DR-001 (Models as Behaviour Modules)")
- `CLAUDE.md` ("Five core behaviours")
