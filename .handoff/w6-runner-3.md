# Handoff ledger: w6-runner-3

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the maintainer's design rulings of 2026-11-07 for the run seam; this is the last of three changes. The first added `PropertyDamage.Runner.execute/2` and moved the campaign run onto it, the second moved the failure reproduction; this one moves the trace capture and the trigger isolation, the two callers that ran a plan without the per-root boundary drain.

Asked:

- `RunTrace.Capture` (both of its paths) and `Analysis.eliminates?` (both clauses) run through `Runner.execute/2`; the two direct engine calls go; the three fidelity tests checked in red earlier lose their tag and pass; the CHANGELOG records that traces and trigger isolation now run the boundary drain the run runs.
- After this change no call to the executor's one-target run function remains in the library outside the executor module itself (the function stays, documented as the test-facing path without the drain, because the executor's own test harness drives it from many files; its migration is a later change).
- A decision record amends the one-runner record: one runner at the run level, not only the step level; the drain is part of every run; the shrinker follows in a later change. Index row and the openspec engine spec where it names the drivers.
- Docs sweep of the moduledocs and guides that name the drivers; cycle count never rises.

Acceptance criteria:

- The two fidelity test files (trace capture, trigger isolation) fail at the base commit and pass here untagged; the runner characterization still passes; the goldens are byte-identical to the base.
- `grep -rn 'Executor.run(' lib` has no hit outside `lib/property_damage/executor.ex`; the Scheduler entry is called from the runner and the shrinker only.
- The decision record exists and is indexed; the full local gate passes; the module cycle count does not rise.

Non-goals: the shrinker's option list and oracle (a later change); the migration of the executor's test harness; `failure_intelligence*` (a concurrent change, now merged).
## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-07T10:17 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-07T10:32 · commit · 8dd204e

refactor(runner)!: capture traces and isolate triggers through the runner

A trace and a trigger isolation reran their plan through the one-target
executor path, which does not drain the event queue after each root. The
events a run folds at a boundary were missing from the trace, and isolation
judged candidate amounts against a run that differed from the campaign's.

Both now run the plan through Runner.execute/2 with a single target, so
they run the boundary drain a run runs. Trace capture takes one path for
every model; a model without expansions runs its roots as themselves.
Isolation brings up the injectors and mocks that the report's reference
target declared. The two fidelity tests no longer carry the known_defect
tag.

BREAKING CHANGE: the step events of a RunTrace include the events folded at
the boundary after each root.

**Files:** `CHANGELOG.md`, `CLAUDE.md`, `lib/property_damage/analysis.ex`, `lib/property_damage/executor.ex`, `lib/property_damage/executor/phases.ex`, `lib/property_damage/run_trace/capture.ex`, `lib/property_damage/runner.ex`, `lib/property_damage/runtime/run_services.ex`, `lib/property_damage/scheduler.ex`, `test/property_damage/analysis_fidelity_test.exs`, `test/property_damage/run_trace/capture_fidelity_test.exs`

### 2026-11-07T10:32 · commit · c4767f6

docs(decisions): amend the one-runner record for the run-level runner

The one-runner record covered the engine, but trace capture and trigger
isolation ran plans through another path that skipped the per-root
boundary drain. The new record states that one runner drives every run,
campaign, reproduction, trace capture and trigger isolation included, and
that the shrinker follows in a later change.

Adds DR-065, a note on DR-045, the index row and spec lists, and an
execution-engine requirement with scenarios for trace capture and trigger
isolation.

**Files:** `docs/decisions/DR-045-one-runner.md`, `docs/decisions/DR-065-one-run-driver.md`, `docs/decisions/README.md`, `openspec/specs/execution-engine/spec.md`

### 2026-11-07T10:20 · decision · isolation reruns

The linear trigger-isolation rerun passes the report's seed, because the engine needs an integer seed and the old direct call had none. The isolation's default target is built from the report's recorded first entry through a private helper in the analysis module, so the rerun carries the report's injectors and mocks; the report's own reference-target function is untouched because the replay and the exports rely on it dropping them. Documented in the function's doc and in the CHANGELOG.

### 2026-11-07T10:30 · decision · executor run function stays

The executor's one-target run function and its linear loop are kept, documented as the path without the per-root drain that the executor's own tests drive (many call sites across the test tree); production runs go through the runner. Their removal, with the harness migration, is a later change.

### 2026-11-07T10:40 · decision · rebase onto the merged first change

The branch was rebased onto the merged first change and the rebased second change; the only conflict was the decision-record index, where the concurrent change's row and this one's row now sit side by side.

### 2026-11-07T10:17 · commit · cab1523

refactor(runner)!: capture traces and isolate triggers through the runner

A trace and a trigger isolation reran their plan through the one-target
executor path, which does not drain the event queue after each root. The
events a run folds at a boundary were missing from the trace, and isolation
judged candidate amounts against a run that differed from the campaign's.

Both now run the plan through Runner.execute/2 with a single target, so
they run the boundary drain a run runs. Trace capture takes one path for
every model; a model without expansions runs its roots as themselves.
Isolation brings up the injectors and mocks that the report's reference
target declared. The two fidelity tests no longer carry the known_defect
tag.

BREAKING CHANGE: the step events of a RunTrace include the events folded at
the boundary after each root.

**Files:** `CHANGELOG.md`, `CLAUDE.md`, `lib/property_damage/analysis.ex`, `lib/property_damage/executor.ex`, `lib/property_damage/executor/phases.ex`, `lib/property_damage/run_trace/capture.ex`, `lib/property_damage/runner.ex`, `lib/property_damage/runtime/run_services.ex`, `lib/property_damage/scheduler.ex`, `test/property_damage/analysis_fidelity_test.exs`, `test/property_damage/run_trace/capture_fidelity_test.exs`

### 2026-11-07T10:23 · commit · fa72b8a

docs(decisions): amend the one-runner record for the run-level runner

The one-runner record covered the engine, but trace capture and trigger
isolation ran plans through another path that skipped the per-root
boundary drain. The new record states that one runner drives every run,
campaign, reproduction, trace capture and trigger isolation included, and
that the shrinker follows in a later change.

Adds DR-065, a note on DR-045, the index row and spec lists, and an
execution-engine requirement with scenarios for trace capture and trigger
isolation.

**Files:** `.handoff/w6-runner-3.md`, `docs/decisions/DR-045-one-runner.md`, `docs/decisions/DR-065-one-run-driver.md`, `docs/decisions/README.md`, `openspec/specs/execution-engine/spec.md`

## Reconstruction

Labeled as reconstruction: assembled after the fact from the wave's evidence files, not from the commits.

- The reviewer's seam read recorded the structural result: "Capture is one path for expansion and non-expansion models; the setup-failure trace is kept" and "Analysis eliminates? uses a shared passes?/2 in both clauses".
- The implementer's own weak spots: "a setup failure in capture now takes the scheduler's failure reason, which is already Failure.setup_failed", "the trace outcome still reads the result's success and failure_reason, as the expansion path did before", and "mocks carried into isolation reruns are exercised by no test".
- One full-suite run showed a single failure in the regression tests, "a log-capture race: another async test's 'identical config' warning leaked into its captured log"; it passed alone and on the rerun, and was recorded as a flake outside this change.
- The decision record was numbered on a tree that did not yet hold the concurrent change's record ("DR-064 was not in the tree"); the number reserved for this change stood after the rebase.
