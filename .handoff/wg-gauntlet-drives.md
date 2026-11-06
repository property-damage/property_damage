# Handoff ledger: wg-gauntlet-drives

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the framework's abstraction audit (2026-11-03) found Analysis, FailureIntelligence and Suggestions thinly tested: no test ran their headline functions on the report of a real campaign.

Asked:

- One new end-to-end test file per subsystem: Analysis (`explain/1`, `isolate_trigger/2`), FailureIntelligence (`find_similar/3` and the fix-verification path), Suggestions (`analyze/2`). Each test runs a real failing campaign (`PropertyDamage.run` on a test model with a seeded defect) and calls the headline function on the resulting report.
- A headline path that fails merges with its test tagged `known_defect` and the failure quoted; a fix belongs to the subsystem's owner, not to this branch.
- The Analysis test pins today's `explain/1` output for a fixed seed, so a later refactor of the run driver can prove it kept the output.
- Rename the payment-specific names in `lib/property_damage/suggestions/patterns.ex` to domain-neutral ones (the framework is public and domain-agnostic).

Acceptance criteria (each can fail):

- Every new test file reaches its report through `PropertyDamage.run`; a hand-built `FailureReport` struct in a new test file fails the review.
- The campaign on the correct adapter passes and the campaign on the seeded defect fails, in the same test file, so the failing report is caused by the defect.
- A repo-wide grep for the old pattern names (`captured_amount`, `authorization_ref`, `capture_ref`) returns no hit.
- The vocabulary test is red before the rename and green after it.
- The full local gate passes: compile with warnings as errors (dev and test), format, credo strict, the whole suite, docs verify, report excerpts check, docs with warnings as errors.

Non-goals:

- Fixing any defect the tests find.
- Editing `test/property_damage/analysis_test.exs` or `test/property_damage/failure_intelligence_test.exs`.
- Deciding whether a subsystem is kept or cut (a separate decision for the maintainer).

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-06T21:36 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-06T21:36 · commit · 8aac381

test(analysis): drive explain and isolate_trigger from a real failing run

The analysis entry points were only exercised on hand-built structs, so a
mismatch with what a real run produces would go unseen. These tests run a
campaign that fails, then call explain and isolate_trigger on the result.
A shared support module builds the failing runs.

**Files:** `test/property_damage/analysis_end_to_end_test.exs`, `test/support/gauntlet_support.ex`

### 2026-11-06T21:36 · commit · 29d0f28

test(failure-intelligence): drive similarity and fix verification from real failing runs

Similarity and fix verification were only tested on synthetic inputs. These
tests produce failures from real runs, then compare them and verify a fix
against them.

**Files:** `test/property_damage/failure_intelligence_end_to_end_test.exs`

## Reconstruction

Written when the PR opened, from the agent reports kept outside the repo; labeled as reconstruction.

- The Record lists two of the four commits. The implementer that wrote the first two files stopped before committing anything; a second, narrower agent made all four commits from the first one's progress log. The hook captured the commits it saw.
- The first agent reported: "Plain `mix test` flaked once (3823/3824) on map key order in a check message (fixed)." The fixture now uses a single detail key.
- The first agent reported: "the shrinker can shrink past generator constraints." The check was changed to compare the reported balance with the ledger, so a shrunk sequence fails only when the defect fires.
- The verifier reported: "Not reproduced by me: the implementer's claim of 3 consecutive same-seed passes per file (I ran the full suite twice, green)."
