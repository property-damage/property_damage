# Handoff ledger: w6-runner-3

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seed this
from whatever produced it: a grill-me ledger, a campaign wave contract, a
ticket, or by hand.

_Not yet seeded._

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-07T10:17 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

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

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

_Not yet written._
