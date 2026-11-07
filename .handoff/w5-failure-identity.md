# Handoff ledger: w5-failure-identity

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the design rulings of 2026-11-06 for failure identity: the failure, not the shrinker, owns the signature that says two failures are the same; the three kind levels are named by level and the report's function and field names agree with the level they carry; stored key renames bump the persistence format; plus the maintainer's rulings of 2026-11-07 that identical failures must score exactly 1.0 in the similarity module (ruling b on the gauntlet brief) and that the Fingerprint's own `failure_type` field waits for the verification change.

Asked:

- `Shrinker.failure_signature/2` becomes `Failure.signature/2`, next to `Failure.from_signature/2`; `ReplayArtifact.reproduced?/2` is rebased on it.
- The kind levels are named by level: `Failure.class/1`, `Failure.kind/1`, `Failure.report_kind/1`; `FailureReport.failure_type/1` takes the name of the level it returns, every call site is updated, and the report field agrees with the function that fills it.
- Every "same failure?" comparison in the library goes through `Failure.signature/2`; the ad-hoc comparisons found by grep are listed.
- A stored key rename bumps the persistence version with fixture regeneration and refusal of the old version; otherwise a no-bump is recorded with a round-trip proof. Export JSON key renames are listed in the changelog.
- Identical failures score exactly `1.0` in `FailureIntelligence.similarity_score/2`, with a test shown red first.

Acceptance criteria:

- The old names are gone from the library, tests, guides, specs and benches except where a ruling keeps them (the Fingerprint field, the plural `failure_signatures` list names, the changelog entries announcing the renames).
- A report saved at the previous format version is refused by the loader with the version pair named; the locked persistence and artifact tests fail at the base commit and pass at the head.
- A replay artifact of a real failure reports `reproduced?` true through `Failure.signature/2`.
- The similarity self score is `1.0` at the head and was below it at the base.
- The full local gate passes, including both zero-infrastructure benches with their audit models, and the module cycle count does not rise.

Non-goals: `FailureIntelligence.Fingerprint` and `Verification` (a later change); renaming the `RunComparison` list fields; any fourth kind level.

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-07T07:32 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-07T07:32 · commit · b137128

test(persistence): lock the failure kind split, signature home and replay format 3

The failure vocabulary reused one word for two levels: the report field
`kind` held the outcome while `failure_type` held the fine kind. The
replay artifact also recorded the failure as three loose keys.

These tests lock the split (`kind` is the fine kind, `report_kind` is the
outcome), format 19 for saved reports, `Failure.signature/2`, and a replay
artifact at format 3 that records one signature. A tracked format-18 report
fixture covers the refusal of the previous format.

**Files:** `test/fixtures/persistence/format_18_report.pd`, `test/property_damage/failure_identity_artifact_test.exs`, `test/property_damage/failure_identity_persistence_test.exs`

### 2026-11-07T07:35 · commit · 7bc1d70

test(persistence): correct the expected values in the failure kind tests

Four assertions guessed the check name form, the other-failure fixture and the
count of report kinds wrongly. They now match what the base code returns for
those values.

**Files:** `test/property_damage/failure_identity_persistence_test.exs`

### 2026-11-07T07:50 · commit · 8ec2694

refactor(failure)!: move the failure signature next to from_signature

The signature builder and its type lived in the shrinker, far from
Failure.from_signature/2 that inverts it, so code that only compares
failures had to reach into the shrinker. Failure.signature/2 and the
Failure.signature type now sit beside from_signature/2, and the shrinker,
the run entry point, run comparison, the export file naming and the tests
call them there.

BREAKING CHANGE: Shrinker.failure_signature/2 and the type
Shrinker.failure_signature are removed; use Failure.signature/2 and
Failure.signature.

**Files:** `benches/cachex_bench/test/expansions_test.exs`, `lib/property_damage.ex`, `lib/property_damage/export/common.ex`, `lib/property_damage/failure.ex`, `lib/property_damage/run_comparison.ex`, `lib/property_damage/shrinker.ex`, `test/property_damage/compare_convergence_test.exs`, `test/property_damage/compare_divergence_test.exs`, `test/property_damage/compare_reporting_test.exs`, `test/property_damage/compare_schedule_test.exs`, `test/property_damage/expansion_paths_test.exs`, `test/property_damage/expansion_shrink_test.exs` (+4 more)

### 2026-11-07T08:00 · commit · ca2f520

refactor(failure)!: name the kind levels and rename failure_type to kind

A failure had three names that shared two words: FailureReport.failure_type/1
returned the fine kind while the report struct's kind field held the coarser
outcome, so "kind" meant different things in the report, the failure and the
JSON export. The levels are now class/1, kind/1 and report_kind/1, documented
together in the Failure moduledoc, and each word means one level everywhere.

BREAKING CHANGE: FailureReport.failure_type/1 is now FailureReport.kind/1 and
failure_type_summary/1 is now kind_summary/1. The type failure_type is now
kind; the old type kind is now report_kind. The FailureReport field kind, the
FailureReport.new/1 option :kind and Progress.RunResult's kind field are now
report_kind, as is the kind key of the runner failure maps. Export metadata
and Persistence.list/2 entries use kind in place of failure_type, and
Persistence.export_json/1 writes the report outcome under report_kind.

**Files:** `README.md`, `benches/cachex_bench/test/expansions_test.exs`, `benches/cachex_bench/test/latency_test.exs`, `benches/cachex_bench/test/replay_test.exs`, `benches/gitea_bench/test/login_setup_test.exs`, `benches/gitea_bench/test/seeded_divergence_test.exs`, `benches/oban_bench/test/compare_test.exs`, `benches/openapi_bench/test/stutter_test.exs`, `guides/differential_testing.md`, `guides/dual_transport_testing.md`, `guides/path_equivalence_testing.md`, `lib/mix/tasks/pd.replay.ex` (+109 more)

### 2026-11-07T08:03 · commit · 69144c6

refactor!: compare failures through Failure.signature/2 in every reader

The scheduler decided that a failure found again at finalize time was the
same failure by its own tuple of variant index, root, report kind and name,
a second definition of failure identity beside Failure.signature/2. It now
keys on the root and Failure.signature/2, so every same-failure comparison in
lib (shrinker, run entry point, run comparison, scheduler) uses one
definition. The finer kind makes the scheduler stricter: two failures of one
check that sort into one report kind but have different kinds stay separate.

BREAKING CHANGE: a finalize-time failure is dropped as a duplicate only when
its kind, name, target and root all match a lockstep failure.

**Files:** `lib/property_damage/scheduler.ex`

### 2026-11-07T08:14 · commit · 070064b

feat(persistence)!: bump the format to 19 for the renamed failure keys

A saved report stored its outcome in a field called kind while the failure
inside it also had a kind, so files and JSON exports used one word for two
levels. The report field is now report_kind and the fine kind is kind, so a
format 18 file no longer decodes into the current report. The saved format
is 19, the loader refuses 18 and older, and the JSON export writes kind for
the fine kind and report_kind for the outcome.

The replay artifact records the failure as one Failure.signature/2 tuple and
the root instead of three loose keys, and reproduced? compares the signature,
the failing target and the root. The seed library stores its fine kind under
kind and loads versions 1 and 2 by mapping the old failure_type key.

BREAKING CHANGE: format 18 and older failure files are refused; the replay
artifact is format 3 and refuses format 2; export_json/1 renames failure_type
to kind and kind to report_kind (and failure_type to kind in other_failures);
the seed library file is version 3, SeedLibrary.add_seed/3 and record_run/3
take :kind in place of :failure_type, and stats/1 returns by_kind.

**Files:** `CHANGELOG.md`, `benches/cachex_bench/test/fixtures/Model_seed3.replay.exs`, `lib/property_damage.ex`, `lib/property_damage/persistence.ex`, `lib/property_damage/replay_artifact.ex`, `lib/property_damage/seed_library.ex`, `test/property_damage/expansion_report_test.exs`, `test/property_damage/latency_budget_test.exs`, `test/property_damage/log/log_filter_memory_test.exs`, `test/property_damage/log/log_persistence_test.exs`, `test/property_damage/log/setup_log_test.exs`, `test/property_damage/other_failures_test.exs` (+12 more)

### 2026-11-07T08:21 · commit · 577f3d3

docs: name the failure kind levels and the moved signature in the docs

The guides, specs, decision records and notebook still named
Shrinker.failure_signature/2, FailureReport.failure_type/1, the report
kind field and format 18. They now use Failure.signature/2,
FailureReport.kind/1, report_kind, persistence format 19 and replay
artifact format 3, and the debugging guide explains the three levels of
failure name (class, kind, report kind). Decision records that quoted the
old names are reworded, not annotated.

**Files:** `benches/gitea_bench/README.md`, `docs/decisions/DR-023-seed-library-ephemeral-replay.md`, `docs/decisions/DR-025-continuous-async-observation-checking.md`, `docs/decisions/DR-033-run-trace-execution-record.md`, `docs/decisions/DR-041-structured-failure-vocabulary.md`, `docs/decisions/DR-045-one-runner.md`, `docs/decisions/README.md`, `guides/debugging_failures.md`, `guides/differential_testing.md`, `guides/dual_transport_testing.md`, `notebooks/property_damage_demo.livemd`, `openspec/specs/differential-testing/spec.md` (+5 more)

### 2026-11-07T08:24 · commit · ef97b1c

fix(failure_intelligence): score identical failures as exactly 1.0

The similarity score is a weighted sum, and the weights do not add up to
exactly 1.0 in binary floats, so a failure compared with itself scored
0.9999999999999999 and similar?/3 with a threshold of 1.0 rejected it. The
score is now the weighted sum divided by the weight total, which is exactly
1.0 when every component scores 1.0. Scores of different failures change
only by float rounding and the default threshold is unchanged.

**Files:** `CHANGELOG.md`, `lib/property_damage/failure_intelligence/similarity.ex`, `test/property_damage/failure_similarity_exact_test.exs`

### 2026-11-07T07:50 · commit · 7b7aa0f (appended by hand; the hook missed it)

test(persistence): mark the failure kind tests for the credo apply check and salt tmp paths

### 2026-11-07T08:40 · decision · residue predicate

The Fingerprint struct's own `failure_type` field and its readers stay for the verification change; the plural `failure_signatures` and `mixed_failure_signatures` list names on `RunComparison` stay. Both are excluded from the residue predicate (maintainer's agent, dispatch amendments 2 and 3).

### 2026-11-07T09:05 · decision · scheduler dedup key

The dedup key change in `69144c6` has no reachable path that differs today (every branch of `Scheduler.run_failures/4` traced, one probe run; not an exhaustive proof). Accepted as is with a hardening row asking for the test the day a fixture reaches it (maintainer's agent, dispatch amendment 4).

## Reconstruction

Assembled afterwards from the delegated agents' reports; labeled as reconstruction.

- `failure_type/1` returned the fine kind: "`FailureReport.failure_type/1` returns `Failure.kind/1`, the ~20-value level. It becomes `FailureReport.kind/1`, and `failure_type_summary/1` becomes `kind_summary/1`."
- The report field rename forced the bump: "The struct field `report.kind` holds `Failure.report_kind/1`. It becomes `report_kind`. That field rename is a stored-key rename, so persistence bumps 18 to 19".
- The artifact format moved too: "`ReplayArtifact.reproduced?/2` can only be rebased on `Failure.signature/2` if the artifact records the signature. It records the report kind today. So the artifact `@format` goes 2 to 3".
- Six report kinds were measured where the design said five: "the spec says `Failure.report_kind` has 5 values, but it has 6. The tests assert 6."
- The seed library carries a legacy mapping: "SeedLibrary is now version 3 and the loader maps the old key."
- The similarity fix: "self score 0.9999999999999999 at base, 1.0 at head".
