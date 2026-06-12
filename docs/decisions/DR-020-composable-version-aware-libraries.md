# DR-020: Composable, Version-Aware Libraries

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

Persisted test artifacts — failure files, seed libraries, regression handling — are versioned and composable:

- **Version-aware**: `.pd` failure files embed the PropertyDamage version, Elixir version, and dependency versions, plus a checksum; loading emits structured warnings on mismatch (`{:property_damage_version_mismatch, ...}`, `{:dependency_version_mismatch, ...}`, `{:dependency_missing, ...}`). The seed library JSON carries a library `version` field and per-entry `dependency_versions`.
- **Composable**: regression handling composes via `Regression.compose/1` (save failures, dedup by fingerprint similarity, generate ExUnit tests — all as stackable handlers), and seed libraries are export/import-able JSON intended for sharing across machines and CI.

Introduced/consolidated by commit `799c6b4` ("feat: add composable, version-aware test library support").

Evidence level: moderate-to-high. The mechanisms are fully evidenced in code and the persistence spec; the exact original scope of the term "libraries" in the DR title is interpreted (seed/failure/regression libraries) since no original record survives.

## Context

(Inferred.) Saved failures and seeds outlive the code that produced them: a `.pd` file replayed six months later may target different command modules, a different PropertyDamage, or different SUT dependencies, and silently replaying it would produce misleading results. Version metadata turns that staleness into explicit warnings instead. Per-entry `dependency_versions` in the seed library similarly records the environment in which a bug-finding seed was discovered. Composability (handler composition, JSON export) reflects the goal stated in `lib/property_damage/seed_library.ex`: "Share discovered seeds across team members" and "Build a regression suite that catches known bug patterns" without coupling teams to one storage workflow.

## Consequences

- `lib/property_damage/seed_library.ex`: `@library_version`, seed entries with `dependency_versions`, status tracking (`:failing`/`:fixed`/`:flaky`), JSON export/import, and integration with `PropertyDamage.run` (`seed_library:` option runs failing seeds first).
- `openspec/specs/persistence/spec.md` requirements "Version-Aware Format" (all three warning shapes), "Seed Library" (export/import, status updates), and "Regression Test Management" (scenario "Composable handlers": `Regression.compose/1`).
- `.pd` files use Erlang term format with a version header and checksum (persistence spec, "Failure Persistence").

## References

- `openspec/specs/persistence/spec.md` (header: "DR-020 (Composable, Version-Aware Libraries)")
- Commit `799c6b4`
- Related: DR-017 (the failures being persisted), DR-008
