# DR-014: Assertion Modes

**Status:** Accepted (reconstructed)
**Reconstructed:** 2026-06-12 from spec references, code, and git history; the original record was never written.

## Decision

How the framework reacts to assertion failures is a single run-level option, `assertion_mode:`, with four values (validated by NimbleOptions):

- `:halt` (default) — stop on the first assertion failure.
- `:disabled` — skip all assertions.
- `:record` — record failures but continue executing.
- `:log` — log failures as warnings and continue.

This one option replaced the earlier pair of `run_assertions` and `assertion_mode` options (commit `2c966c0`, "refactor!: unify run_assertions and assertion_mode options").

Evidence level: high; the modes and their docs are in `lib/property_damage/options.ex`, and the unification commit is in history.

## Context

(Inferred plus commit evidence.) Different testing contexts want different failure handling: property runs want fail-fast (`:halt`); load testing and soak-style runs want to keep going while collecting violations (`:record`, see commits `4de1768` "feat(load-test): add assertion support to load testing" and `b11b27a` "display assertion failures in report output"); exploratory or noisy-environment runs want visibility without aborting (`:log`); and performance baselines may want assertions off entirely (`:disabled`). Having a boolean toggle *and* a mode was redundant and ambiguous (`run_assertions: false` vs `assertion_mode: :disabled`), hence the unification into one enum.

## Consequences

- `lib/property_damage/options.ex`: `assertion_mode: [type: {:in, [:disabled, :halt, :record, :log]}, default: :halt, ...]` with per-mode docs.
- `:log` mode formatting is considered elsewhere in the framework, e.g. `lib/property_damage/resource_poller.ex` uses `Exception.message/1` "for cleaner log output in `:log` assertion mode".
- Load testing reports aggregate assertion failures by exception module (commit `bbda7da`), which presupposes a continue-on-failure mode.

## References

- `openspec/specs/projection/spec.md` (header: "DR-014 (Assertion Modes)")
- Commits `2c966c0`, `4de1768`, `b11b27a`, `bbda7da`
- Related: DR-012 (what an assertion is), DR-004
