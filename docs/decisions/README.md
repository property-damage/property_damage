# Decision Records

## About these records

These Decision Records were **reconstructed after the fact** on 2026-06-12. The OpenSpec specifications under `openspec/specs/` cite DR-001 through DR-020 by number and title, but the records themselves were never written. Note also that the specs were written *after* the code (commit `06c5405`, "docs: add OpenSpec specifications across 14 domains"), so the DR numbering in the specs already refers to decisions that had long been embodied in the codebase.

Each record below was reconstructed from three sources: the spec citations (which supply the titles), the code and its moduledocs, and git history. Every record is marked **Accepted (reconstructed)** and distinguishes evidenced statements (with file and commit references) from inferred rationale (explicitly labeled "Inferred"). No original rationale survives; where a "Context" section explains *why*, treat it as a best-effort inference unless a source is cited.

All 20 referenced DRs had sufficient evidence to reconstruct; none were left unreconstructed.

Records numbered DR-021 and above are **not** reconstructions: they are forward-looking decisions recorded at the time they were made, and each carries a plain `Accepted` status with a decision date.

Every record is **self-contained**: it carries enough context and rationale to stand on its own from this repository. Records reference only material that ships with the repo (other DRs, `openspec/specs/`, source) and never point to external or private documents — a reader with only the published code must find all relevant context here.

## Index

| DR | Title | Summary |
|----|-------|---------|
| [DR-001](DR-001-models-as-behaviour-modules.md) | Models as Behaviour Modules | Models are plain modules implementing the `PropertyDamage.Model` behaviour; no DSL or process. |
| [DR-002](DR-002-model-and-command-agnosticism.md) | Model and Command Agnosticism | Commands define WHAT, models define WHEN/HOW to parameterize, adapters define HOW to execute. |
| [DR-003](DR-003-reuse-through-standard-elixir.md) | Reuse Through Standard Elixir | Component reuse via protocols, plain functions, and generator composition; no plugin system. |
| [DR-004](DR-004-unified-projection-type.md) | Unified Projection Type | One projection behaviour serves both state tracking and assertions; both callbacks optional. |
| [DR-005](DR-005-projection-naming.md) | Projection Naming | `state_projection` → `command_sequence_projection`; `extra_projections` → `assertion_projections`. |
| [DR-006](DR-006-pure-command-generators.md) | Pure Command Generators | `generator/1` is pure, returns StreamData of field maps; no state or SUT access. |
| [DR-007](DR-007-model-level-command-wiring.md) | Model-Level Command Wiring | State-dependent config (`weight:`, `when:`, `with:`) declared in the model's command list. |
| [DR-008](DR-008-command-semantics.md) | Command Semantics | Exactly three execution semantics: `:sync`, `:probe`, `:async`; `:mock_config` was removed. |
| [DR-009](DR-009-projections-see-commands-and-events.md) | Projections See Commands and Events | `apply/2` receives both; a deliberate deviation from pure event sourcing. |
| [DR-010](DR-010-symbolic-references.md) | Symbolic References | **Superseded** by DR-011/DR-021. `make_ref/0`-based refs (since removed) linked command outputs to future inputs across two phases. |
| [DR-011](DR-011-external-field-markers.md) | External Field Markers | `external()` on event struct fields marks server-generated values; replaces `creates_ref/0` (now removed). |
| [DR-012](DR-012-trigger-based-assertions.md) | Trigger-Based Assertions | Assertions are functions decorated with `@trigger` / `@poll_state` attributes; pass-by-not-raising. |
| [DR-013](DR-013-terminal-states.md) | Terminal States | Optional `terminate?/3` lets models stop sequence generation at natural workflow endpoints. |
| [DR-014](DR-014-assertion-modes.md) | Assertion Modes | Single `assertion_mode:` option: `:halt` (default), `:disabled`, `:record`, `:log`. |
| [DR-015](DR-015-adapter-separation.md) | Adapter Separation | All transport in adapters; strict setup/execute/teardown lifecycle, repeated per shrink attempt. |
| [DR-016](DR-016-injector-pattern.md) | Injector Pattern | External events enter via Injector adapters and a shared EventQueue, plus mid-execution `ctx.inject`. |
| [DR-017](DR-017-hierarchical-delta-debugging.md) | Hierarchical Delta Debugging | Two-phase shrinking with dependency-depth group removal and failure equivalence. |
| [DR-018](DR-018-command-triggered-resource-polling.md) | Command-Triggered Resource Polling | `ctx.start_poller` spawns background ResourcePollers that inject events as resources change. |
| [DR-019](DR-019-command-spec-pattern.md) | Command Spec Pattern | `command_spec/1` (modeled on `child_spec/1`) with three-tier override priority. |
| [DR-020](DR-020-composable-version-aware-libraries.md) | Composable, Version-Aware Libraries | Versioned `.pd` files and seed libraries with mismatch warnings; composable regression handlers. |
| [DR-021](DR-021-placeholder-resolution-identity.md) | Placeholder Resolution Identity | Consumer resolution by id; producer capture by structured position rebuilt per run. Recorded at decision time (not reconstructed). |
| [DR-022](DR-022-unified-progress-projection.md) | Unified Progress Projection | One `%Progress{}` projection across run/mutation/differential/load-test; consumers (callback, printer, telemetry) subscribe; metrics derive from authoritative state, not from progress. Recorded at decision time. |
| [DR-023](DR-023-seed-library-ephemeral-replay.md) | Seed Library as an Ephemeral Replay Working Set | Seed library is an ephemeral, self-pruning working set of recently-failing seeds, replayed before random exploration; supersedes DR-020's seed-library status machine. Recorded at decision time. |
| [DR-024](DR-024-lifecycle-boundary-assertions.md) | Lifecycle-Boundary Assertions (`@trigger at:`) | A second trigger axis `at:` fires a synchronous assertion once at a lifecycle boundary: `:teardown` (settled final state, the safety check) and `:startup` (initial state). Recorded at decision time. |

## Which specs cite which DRs

- `openspec/specs/model/spec.md`: DR-001, DR-002, DR-003, DR-007, DR-013
- `openspec/specs/command/spec.md`: DR-006, DR-008, DR-019
- `openspec/specs/projection/spec.md`: DR-004, DR-005, DR-009, DR-012, DR-014, DR-024
- `openspec/specs/execution-engine/spec.md`: DR-010, DR-011, DR-015, DR-016, DR-018, DR-024
- `openspec/specs/shrinking/spec.md`: DR-017
- `openspec/specs/eventual-consistency/spec.md`: DR-008, DR-018, DR-024
- `openspec/specs/persistence/spec.md`: DR-020

DR-008 is additionally cited in `test/property_damage/shrinker_test.exs`, `test/support/test_commands.ex`, and `test/support/executor_test_support.ex`.
