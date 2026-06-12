# DR-017: Hierarchical Delta Debugging

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Failing sequences are shrunk with a dependency-aware, two-phase algorithm rather than naive one-at-a-time removal:

- **Phase 1 (sequence shrinking)**, in three ordered steps: (1) drop commands after the failure point (never executed); (2) *hierarchical* shrinking — build a DAG of command dependencies from ref production/consumption, group commands by depth, and try removing whole groups starting from the deepest level; (3) linear shrinking of remaining individual commands. A `granularity_threshold` controls when to switch from hierarchical to linear.
- **Phase 2 (argument shrinking, optional)** — simplify values in surviving commands (integers toward 0, strings/lists toward empty); refs are never shrunk.
- A candidate is accepted only if it preserves **failure equivalence**: same failure type and check name, at the same or an earlier index. Shrinking is deterministic given the seed.

Evidence level: high; algorithm, config, and equivalence rules are all in the shrinker moduledoc and spec.

## Context

(Inferred.) Removing commands one at a time is O(n) executions per pass and tends to get stuck: removing a producer without its consumers (or vice versa) changes the failure rather than preserving it. Grouping by dependency depth lets the shrinker discard entire irrelevant subgraphs in one adapter run — the hierarchical analogue of delta debugging's chunked search — which matters because every shrink attempt pays a full adapter setup/execute/teardown lifecycle (DR-015). Failure equivalence (rather than "any failure") ensures the minimal reproduction demonstrates the same bug, and determinism makes CI failures reproducible locally — both rationales stated in `lib/property_damage/shrinker.ex`.

## Consequences

- `lib/property_damage/shrinker.ex`: two-phase design, failure equivalence, determinism, branching-sequence strategies (remove branches, shrink branches, convert to linear, reduce branch count); config in `PropertyDamage.Shrinker.Config` (`granularity_threshold`, `max_iterations`, `max_time_ms`, `shrink_arguments`).
- `openspec/specs/shrinking/spec.md` requirements "Failure Equivalence", "Two-Phase Shrinking", "Phase 1 Sequence Shrinking Steps", "Hierarchical Dependency Graph".
- Shrink hints interact with the hierarchy: `:prefer_remove` (typical for probes, DR-008) prioritizes removal; `:prefer_keep` protects commands; async producers with consumed refs are protected (`openspec/specs/command/spec.md`).
- Tests: `test/property_damage/shrinker_test.exs` (including the DR-008 probe-priority section at line 725).

## References

- `openspec/specs/shrinking/spec.md` (header: "DR-017 (Hierarchical Delta Debugging)")
- Related: DR-008 (shrink hints), DR-010 (refs feed the dependency graph)
