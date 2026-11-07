# DR-064: Fixes Are Verified on the Replay Artifact

**Status:** Accepted
**Date:** 2026-11-07

## Context

`FailureIntelligence.Verification.verify_fix/3` re-runs `failure.seed` through
`PropertyDamage.run(seed:, max_runs: 1)`, adds neighbouring seeds from a
private generator, and calls the fix verified when the run returns `:ok`. It
never replays the shrunk sequence and compares no failure identity.

A change to generation breaks this. The original seed then draws a different
plan that passes, the shrunk sequence still fails, and the function reports
`:verified`. A run that fails with another failure is reported as
`:still_failing`, although it is a different failure. The options
`:include_similar` and `:similar_threshold` are documented and read by no
code. `verify_cluster/3` and `still_fails?/4` re-run fingerprint seeds only, so
they share the flaw.

The replay artifact (DR-050) already holds what verification needs: the
shrunk commands, the targets, and the failure's `Failure.signature/2` under
`failure.signature`. `ReplayArtifact.reproduced?/2` compares that signature.

## Decision

1. Two runs show the same failure when `Failure.signature/2` agrees, the
   comparison the replay artifact already makes. `verify_fix/3` replays the
   shrunk sequence from `report.replay`, on the targets the artifact records,
   through `PropertyDamage.run(only: [replay: path])`. It writes the term with
   `ReplayArtifact.write/2` into a fresh temporary directory, replays it and
   removes the directory. It never generates a plan from a seed.
2. `verify_fix(report, model, opts)` returns a map whose `status` is one of:
   - `:verified`: the replay runs to completion with no failure.
   - `:still_failing`: a failure with the recorded signature recurs.
   - `:different_failure`: a failure with another signature occurs. The map
     carries `new_signature` and the report of the new failure.

   Every result carries `signature` (the original), `failure` (the report of
   the recurring or new failure, else `nil`) and a one-line `summary`. The
   statuses `:partially_fixed` and `:flaky`, the `confidence` score and the
   variation counters are removed: one replay cannot support them.
3. A report whose `replay` is `nil` or `{:refused, _}` is refused with
   `{:error, :no_replay_artifact}`, documented in the typespec. No seed re-run
   happens. `verify_fixes/3` maps over reports and returns
   `[{report, result_or_error}]`.
4. Neighbouring seeds become exploration, a separate public function:
   `FailureIntelligence.explore_neighbouring_seeds(report, model, opts)`,
   implemented in the new module `PropertyDamage.FailureIntelligence.Exploration`.
   Its options are `:targets` (one entry, required), `:max_seeds` (default 10)
   and `:seed_range` (default 1000). It returns a map with `original_seed`,
   `seeds_run`, `passed` and `failures`, a list of `%{seed:, report:}` for each
   seed whose run fails. Its documentation says that it samples other plans and
   gives no verification verdict. The variation generator moves there, and no
   name in the module says verify, status or confidence.
5. `verify_cluster/3`, `still_fails?/4` and its `seed_target/2` helper are
   removed. A clustered fingerprint holds a seed and no replay artifact, so
   it cannot be verified, and no seed-only path keeps the word verify.
   Verifying a cluster is `verify_fixes/3` over its reports. The options
   `:include_similar` and `:similar_threshold` are removed.
6. The fingerprint field `failure_type` is renamed `kind` and rebased on the
   components of the failure signature, so fingerprint identity agrees with the
   replay artifact's. The code for this lands in a later commit of the same
   change.
7. No persisted shape changes. The replay artifact, the persistence output and
   the export JSON keep their format. None of them stores the fingerprint
   struct: `SeedLibrary` entries carry their own `kind` field, and its loader
   reads `failure_type` only as the old name of that entry field, so the
   rename in item 6 does not reach a stored file.

## Alternatives

- **Keep the seed re-runs and add a signature check.** Rejected: the run still
  never executes the shrunk sequence, so a changed generator still hides the
  failure.
- **Regenerate the shrunk sequence from the seed and replay it.** Rejected: it
  depends on generation, the thing a fix may change.
- **Keep `verify_cluster/3` over seeds.** Rejected: see item 5. A seed alone
  cannot say that the same failure is gone.

## Consequences

- A verdict no longer depends on the generator. A fix that changes generation
  cannot turn a failing sequence into `:verified`.
- A report saved without a replay artifact cannot be verified. The caller
  gets `{:error, :no_replay_artifact}` and captures the failure again.
- `:different_failure` tells the caller that the fix moved the failure rather
  than removed it, which `:still_failing` used to hide.
- Callers of `verify_cluster/3`, `:partially_fixed`, `:flaky` and
  `confidence` change. This is a breaking change before v1.
- Users who want neighbouring seeds call `explore_neighbouring_seeds/3` and
  read passes and failing seeds, not a verdict.
