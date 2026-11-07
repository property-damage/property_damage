# Handoff ledger: w13-fix-verification

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the maintainer's design rulings of 2026-11-07 for fix verification (the audit's finding that verification re-ran neighbouring seeds, which draw unrelated plans, and compared no failure identity), after the failure signature landed in `Failure.signature/2` and the replay artifact in `FailureReport.replay`.

Asked:

- A decision record first: "same failure" is the replay artifact plus `Failure.signature/2`; fix verification replays the shrunk sequence through the report's replay artifact and never draws a plan from a seed; neighbouring seeds become a separate, honestly named exploration mode with no verdict; the openspec Fix Verification requirement is amended.
- `verify_fix/3` returns `:verified` only when the replay runs with no failure whose signature equals the recorded one; a recurring matching failure is `:still_failing`; a failure with another signature gets its own status carrying the new signature; a report without a replay artifact gets a refusal value, never a seed re-run. `verify_fixes/3` follows; cluster verification takes reports with replays or is removed; the dead options `include_similar` and `similar_threshold` go.
- The fingerprint is rebased on the signature: the field `failure_type` becomes `kind`, `from_failure_report/1` fills `kind` and `check_name` from the signature's components, the similarity breakdown and weight key, the pattern trait and the stale comment follow; any stored shape carrying the field bumps its version.

Acceptance criteria:

- Two tests fail at the base commit and pass here: a "fix" that changes generation so the original seed draws a passing plan while the shrunk sequence still fails is reported `:verified` at the base and `:still_failing` here; a replay that fails with another signature is `:still_failing` at the base and the new status here.
- The gauntlet's end-to-end file for this subsystem stays green, with its edits listed.
- `grep -rn failure_type` over lib, test, guides, openspec, docs and benches is empty outside the tests that assert the name's absence, the seed-library legacy loader, and the record text.
- The full local gate passes and the module cycle count does not rise.

Non-goals: the runner extraction (a concurrent change owns `property_damage.ex`, `analysis.ex` and the trace capture); `seed_library.ex`, `persistence.ex`, `replay_artifact.ex` and `failure.ex`.
## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-07T09:37 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-07T09:13 · commit · 90d4e3c

docs(decisions): verify fixes on the replay artifact and name seed exploration

Fix verification re-ran seeds, so a change to generation turned a failing shrunk sequence into a passing plan and the fix read as verified. DR-064 verifies on the replay artifact and compares the failure signature, moves neighbouring seeds to a separate exploration function that gives no verdict, and amends the failure-analysis requirements.

**Files:** `docs/decisions/DR-064-verify-fixes-on-the-replay-artifact.md`, `docs/decisions/README.md`, `openspec/specs/failure-analysis/spec.md`

### 2026-11-07T09:22 · commit · 510e56e

fix(failure_intelligence)!: verify a fix by replaying the shrunk sequence and matching the signature

verify_fix/3 re-ran the report's seed and neighbouring seeds and called the
fix verified when they passed. A change to generation made the seed draw a
passing plan while the shrunk sequence still failed, and a run that failed
with another failure read as still failing.

verify_fix/3 now replays the shrunk sequence from the report's replay artifact
and compares Failure.signature/2 with the recorded one. It returns :verified,
:still_failing or :different_failure, and {:error, :no_replay_artifact} when
the report holds no artifact. Neighbouring seeds move to
explore_neighbouring_seeds/3, which gives no verdict. The statuses
:partially_fixed and :flaky, the confidence score, verify_cluster/3,
still_fails?/4 and seed_target/2 are removed.

**Files:** `CHANGELOG.md`, `lib/property_damage/failure_intelligence.ex`, `lib/property_damage/failure_intelligence/exploration.ex`, `lib/property_damage/failure_intelligence/fingerprint.ex`, `lib/property_damage/failure_intelligence/verification.ex`, `test/property_damage/failure_intelligence_end_to_end_test.exs`, `test/property_damage/failure_intelligence_test.exs`, `test/property_damage/failure_intelligence_verification_test.exs`, `test/support/failure_intelligence_support.ex`

### 2026-11-07T09:27 · commit · 0b5feeb

refactor(failure_intelligence)!: rebase the fingerprint on the failure signature

A fingerprint named a failure with `failure_type`, a word the failure model
retired, so fingerprint identity could disagree with the signature the replay
artifact records.

The fingerprint field `failure_type` is now `kind`, and `from_failure_report/1`
fills `kind` and `check_name` from the components of `Failure.signature/2`.
`from_raw_failure/1` reads `:kind`. The similarity breakdown and weight key
and the cluster pattern key are renamed the same way. Hashes and scores keep
their values.

**Files:** `CHANGELOG.md`, `lib/property_damage/failure_intelligence.ex`, `lib/property_damage/failure_intelligence/fingerprint.ex`, `lib/property_damage/failure_intelligence/patterns.ex`, `lib/property_damage/failure_intelligence/similarity.ex`, `openspec/specs/failure-analysis/spec.md`, `test/property_damage/failure_intelligence_end_to_end_test.exs`, `test/property_damage/failure_intelligence_test.exs`

### 2026-11-07T09:31 · commit · 17948cc

docs: describe fix verification on the replay artifact and seed exploration

The debugging guide still showed the seed-variation form of verify_fix with
its removed options and statuses.

Step 9 now explains that verify_fix replays the shrunk sequence, lists the
three statuses and the missing-artifact refusal, and shows
explore_neighbouring_seeds for sampling other seeds without a verdict. The
cluster bullet points to verify_fixes.

**Files:** `guides/debugging_failures.md`

### 2026-11-07T09:36 · decision · guide fences

The two new examples in the fix-verification section of `guides/debugging_failures.md` carry no runnable marker, like the example they replace: they use the placeholder model and adapter and are not executed by the docs check. Ruled as the file's own convention; the behavior they show is covered by the new test file.

### 2026-11-07T09:36 · decision · seed exploration errors

`explore_neighbouring_seeds/3` runs each seed with `replay_dir: false` and lets an adapter setup error raise instead of counting it as a failing seed. Ruled during the wave: a setup error is not evidence about the seed.

### 2026-11-07T09:37 · commit · f24a8ec

test(failure_intelligence): drop retired statuses from a fixture comment

The intermittent-switch comment named the removed partially fixed and flaky statuses.

**Files:** `test/support/failure_intelligence_support.ex`

### 2026-11-07T09:48 · commit · ca30c2e

docs(openspec): describe fix verification on the replay artifact in the overview

The failure-analysis overview still said fixes are verified with seed variations. It now names replay of the shrunk sequence and seed exploration.

**Files:** `openspec/specs/failure-analysis/spec.md`

### 2026-11-07T09:48 · commit · f0dac87

docs(failure_intelligence): stop referencing the hidden replay artifact module

The Verification moduledoc linked a module hidden from the docs, so ex_doc warned. It now names the report's replay field.

**Files:** `lib/property_damage/failure_intelligence/verification.ex`

## Reconstruction

Labeled as reconstruction: assembled after the fact from the wave's evidence files, not from the commits.

- The verification path at the base compared no failure identity: its pass test was `result == :ok`, so any failure counted as "still failing" (verification evidence, "Names chosen" and "RED" sections).
- The implementer first committed the decision record, which the wave's reviewer checked against the ruling before any code was written ("R1 (wave doc 'DR review'): DR-064 accepted").
- Both red tests were reproduced on the base by a second agent in a scratch checkout: "generation-change test left :verified / right :still_failing; different-signature test left :still_failing / right :different_failure; both fail on the status assertion, mix test exit 2".
- The `failure_type` residue outside this change's files was traced to the seed-library legacy loader and its tests ("loader reading the old stored key of a version 1/2 library entry as kind"), left as is.
