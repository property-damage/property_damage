# Handoff ledger: w8-harness-migration

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seed this
from whatever produced it: a grill-me ledger, a campaign wave contract, a
ticket, or by hand.

Source: the maintainer's design rulings of 2026-11-09 for the executor seam, second of two changes. The first moved the step primitives into `Executor.Step` and replaced the mock-registry threading with a step observer; it left `Executor.run/4` in place because the executor's own test harness drove it from forty files. This change moves that harness and deletes the function.

Asked:

- The executor's tests call `Executor.Stepping` (`init_state`, `step/4`, `drain/2`, `finalize/2`) through one test support helper, or the runner where a whole run is meant; then `Executor.run/4`, `run_logged/4` and `execute_linear` are deleted. A test may change its call shape, not what it asserts; an assertion that must change is listed with its reason.
- The trace-capture fidelity control that used the executor path is retired with a note if it cannot be kept.
- Hygiene: residue sweep for every removed name; CHANGELOG Breaking for the removed functions; the full local gate and the two zero-infrastructure benches pass; the cycle count does not rise.

Acceptance criteria:

- A grep for `Executor.run(` over the library, the tests, the benches, the guides, the docs, the spec and `CLAUDE.md` is empty; `executor.ex` defines no `run`, `execute_sequence`, `run_logged` or `execute_linear`.
- No assertion is removed or weakened; the goldens and fixtures are byte-identical to the base.
- The full local gate and the two benches pass; no cycle contains an executor file.

Non-goals: the leaf, the accessors and the observer (the first change); the CI gate value (set by the maintainer's delegate at the rebase onto the concurrent facade change); `Executor.execute_raw/3`, which stays.

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-09T19:27 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-09T19:27 · commit · a416176

test: add a stepping-based run helper for the executor tests

The executor's own tests call Executor.run/4 forty files over, so the old run function cannot leave the library while they do. StepRun.run/4 takes the same arguments and answers the same result, composed from the public stepping seam, and a parity test runs ten sequences through both and compares the results field by field.

**Files:** `test/property_damage/step_run_parity_test.exs`, `test/support/step_run.ex`

### 2026-11-09T19:34 · commit · b595a26

test: drive the executor tests through the stepping seam

The executor tests called Executor.run/4 and Executor.execute_sequence/12 directly, which keeps both public functions alive for no caller but the tests. They now run through the stepping-based test helper; the assertions are unchanged.

**Files:** `test/property_damage/adapter_timeout_test.exs`, `test/property_damage/awaits_test.exs`, `test/property_damage/eventual_consistency_test.exs`, `test/property_damage/executor/finalization_raise_test.exs`, `test/property_damage/executor/finalize_ordering_test.exs`, `test/property_damage/executor_adversarial_test.exs`, `test/property_damage/executor_executed_capture_test.exs`, `test/property_damage/executor_mechanisms_integration_test.exs`, `test/property_damage/executor_settled_test.exs`, `test/property_damage/executor_test.exs`, `test/property_damage/injection_test.exs`, `test/property_damage/lifecycle_checks_test.exs` (+2 more)

### 2026-11-09T19:48 · commit · 7072788

test: drive the executor tests through the stepping seam

These tests called Executor.run/4, which keeps that public function alive for no caller but the tests. They now run through the stepping-based test helper; the assertions are unchanged.

**Files:** `test/property_damage/stutter_shrink_test.exs`

### 2026-11-09T19:52 · commit · 1c78f20

refactor(executor)!: remove the one-target run function

Executor.run/4 and Executor.execute_sequence/12 were a second run path that only tests still called, and their docs and the engine spec still named them. The tests now run through the stepping seam, so both functions and their private helpers are deleted, and the docs and the engine spec describe the runner and the stepping seam instead.

BREAKING CHANGE: PropertyDamage.Executor.run/4 and PropertyDamage.Executor.execute_sequence/12 are removed. Run through PropertyDamage.Runner.execute/2, or step commands through PropertyDamage.Executor.Stepping.

**Files:** `CHANGELOG.md`, `lib/property_damage/executor.ex`, `lib/property_damage/executor/phases.ex`, `lib/property_damage/executor/stepping.ex`, `lib/property_damage/runtime/run_services.ex`, `lib/property_damage/scheduler.ex`, `lib/property_damage/variant.ex`, `openspec/specs/execution-engine/spec.md`, `test/property_damage/step_run_parity_test.exs`

### 2026-11-09T19:53 · commit · 0b12337

refactor(executor)!: remove the one-target run function

Executor.run/4 and Executor.execute_sequence/12 were a second run path that only tests still called, and their docs and the engine spec still named them. The tests now run through the stepping seam, so both functions and their private helpers are deleted, and the docs and the engine spec describe the runner and the stepping seam instead.

BREAKING CHANGE: PropertyDamage.Executor.run/4 and PropertyDamage.Executor.execute_sequence/12 are removed. Run through PropertyDamage.Runner.execute/2, or step commands through PropertyDamage.Executor.Stepping.

**Files:** `CHANGELOG.md`, `lib/property_damage/executor.ex`, `lib/property_damage/executor/phases.ex`, `lib/property_damage/executor/stepping.ex`, `lib/property_damage/runtime/run_services.ex`, `lib/property_damage/scheduler.ex`, `lib/property_damage/variant.ex`, `openspec/specs/execution-engine/spec.md`, `test/property_damage/step_run_parity_test.exs`

### 2026-11-09T19:57 · commit · ccd1628

refactor(executor)!: remove the one-target run function

Executor.run/4 and Executor.execute_sequence/12 were a second run path that only tests still called, and their docs and the engine spec still named them. The tests now run through the stepping seam, so both functions and their private helpers are deleted, and the docs and the engine spec describe the runner and the stepping seam instead.

BREAKING CHANGE: PropertyDamage.Executor.run/4 and PropertyDamage.Executor.execute_sequence/12 are removed. Run through PropertyDamage.Runner.execute/2, or step commands through PropertyDamage.Executor.Stepping.

**Files:** `CHANGELOG.md`, `lib/property_damage/executor.ex`, `lib/property_damage/executor/phases.ex`, `lib/property_damage/executor/stepping.ex`, `lib/property_damage/runtime/run_services.ex`, `lib/property_damage/scheduler.ex`, `lib/property_damage/variant.ex`, `openspec/specs/execution-engine/spec.md`, `test/property_damage/seed_library_replay_test.exs`, `test/property_damage/step_run_parity_test.exs`

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

Labeled reconstruction: assembled from the wave's on-disk reports after the commits, with verbatim quotes. It extends the Record and contradicts none of it.

- Helper first (from the orchestrator's report, `evidence/w8/suborch_report_w8_pr2.md`): the helper `PropertyDamage.Test.StepRun` landed with "a parity test against the old `Executor.run/4`" before any file moved; the parity test was deleted with the function in the last commit.
- Two groups (same report): a first group of "13 files + variant_test_support.ex" and a second of "26 files, all through StepRun.run; none needed PropertyDamage.run/1", so the runner path was not needed for any executor test.
- Fidelity control (same report, P3): "trace-capture fidelity control (capture_fidelity_test.exs) kept intact via the helper; nothing retired (contract allowed retirement; not needed)."
- Record entries 1c78f20 and 0b12337 name commits that are not on the branch: the final commit was amended once for a comment-only edit (same report, P4: "a comment-only edit was amended into ccd1628 after the implementer's gate; I re-ran the entire gate at ccd1628 myself"). The Record keeps the superseded entries as contemporaneous evidence.
- CHANGELOG (same report, P2): arities were dropped from historical mentions of the removed functions because "docs gate fails on links to removed functions"; two Breaking entries were added.
- Residue left on purpose (same report): `Executor.run` survives in decision-record history only; `execute_sequence(` elsewhere is `Worker.execute_sequence`; `run_logged` elsewhere is `Runtime.InjectionWindow.run_logged` and a test-local helper.
