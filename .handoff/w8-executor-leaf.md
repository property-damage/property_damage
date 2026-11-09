# Handoff ledger: w8-executor-leaf

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seed this
from whatever produced it: a grill-me ledger, a campaign wave contract, a
ticket, or by hand.

Source: the maintainer's design rulings of 2026-11-09 for the executor seam (contracts recorded in the design record, sections "executor step leaf and step observer"), from the abstraction audit's finding that the executor's submodules call back into sixteen undocumented functions of the parent and that the mock registry is threaded by hand through eleven files. This is the first of two changes; the second moves the executor's test harness off `Executor.run/4` and deletes it.

Asked:

- A leaf module in the executor namespace holds the step primitives (command execution with its outcome, mock notification, event handling, step checks, async checks, await registration, poller spawning, placeholder resolution, runtime injection, poller-state getters) and calls nothing in the executor, stepping, finalization, phases or stutter modules; those call the leaf. After the move the executor module keeps no undocumented public function, and no module cycle contains an executor file.
- Every public leaf function takes at most four arguments: the command or index, the executor state, a `%Stepping.Context{}` and one keyword of options; no longer positional list survives in the leaf, stepping or finalization.
- `Executor.State` gains accessors for the twelve fields the Variant reads and update functions for the four writes, and the Variant reads and writes the executor state only through them.
- One step observer replaces the mock-registry threading: a behaviour with callbacks at the four points the registry is notified today (before the adapter call, after the events, at drain, at finalize), registered on the executor state once by the Variant; `MockServiceRegistry` is its first implementation. The `:mock_registry` option of the executor's run function goes.
- Locked before the move: the observer notification sequence per step and the finalize ordering, written against the registry's current behavior, with the locked files' digests recorded.
- Hygiene: the cycle gate in CI drops by one; residue sweep for every moved name; DR-029 gets a status note correcting its seam list; the mocking guide's complete example either gains the runnable marker or is covered by a test that executes the same mock end to end; CHANGELOG Breaking for the removed option.

Acceptance criteria:

- `mix xref graph --format cycles` lists no cycle containing `executor.ex` or any `executor/*.ex`; the CI gate equals the count.
- `executor.ex` has no `@doc false` function; `grep -nE 'exec\.[a-z_]+' lib/property_damage/variant.ex` is empty.
- `grep -rn mock_registry lib` matches no executor file (scope ruled on 2026-11-09, see Contract drift).
- The locked tests pass unchanged; the full local gate and the two zero-infrastructure benches pass.

Non-goals: the harness migration and the deletion of `Executor.run/4` (the second change); the facade's doc line naming the runtime handle (a concurrent change owns the facade); renaming the adapter-facing `runtime.mock_registry` handle.

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-09T18:32 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-09T18:32 · commit · 3d5ea2a

test(executor): lock the step-observer sequence and the finalize ordering

Nothing pinned what a mock adapter is told during a run or the order in
which a run with a mock finishes, so a change to how the executor notifies
mocks could reorder callbacks unnoticed. These tests record the callbacks
of a recording mock through PropertyDamage.run/1 and through
Executor.Stepping: command, event, projections snapshot and teardown order,
the drain and finalize folds of late mock events, a raising mock, and the
finalize chain (folds, final check, teardown). They also run the complete
example of the mocking guide end to end, since its blocks cannot run in the
docs check.

**Files:** `test/property_damage/finalize_ordering_test.exs`, `test/property_damage/mocking_guide_example_test.exs`, `test/property_damage/step_observer_sequence_test.exs`, `test/property_damage/step_observer_stepping_test.exs`, `test/support/step_observer_support.ex`

### 2026-11-09T18:48 · commit · 206d46a

refactor(executor)!: move the step primitives into a leaf and thread the context

The executor modules formed one dependency cycle: stepping, finalization,
phases and stutter called back into the executor's undocumented public
functions, and the step primitives took seven or eight positional
parameters. The primitives now live in PropertyDamage.Executor.Step, which
calls none of those modules. Stepping composes a step from them (execute,
then the stutter retries, then the poller start), the executor's own loop
steps through Stepping, and each primitive takes the command or index, the
executor state, the Stepping.Context and one keyword of options.

Stepping.Context moves to a file of its own so the leaf can take it without
depending on stepping.ex. Stepping.step_leaf/5 becomes step_leaf/4, taking
the leaf step as a {command, position} pair. The unused Executor.run_logged/4
is deleted. The cycle through the executor files is gone.

**Files:** `CHANGELOG.md`, `lib/property_damage/executor.ex`, `lib/property_damage/executor/finalization.ex`, `lib/property_damage/executor/state.ex`, `lib/property_damage/executor/step.ex`, `lib/property_damage/executor/stepping.ex`, `lib/property_damage/executor/stepping/context.ex`, `lib/property_damage/executor/stutter.ex`, `lib/property_damage/load_test/worker.ex`, `lib/property_damage/replay.ex`, `lib/property_damage/runtime/run_services.ex`, `lib/property_damage/variant.ex`

### 2026-11-09T18:52 · commit · f461a61

refactor(executor): read the executor state through accessors

The Variant read twelve fields of the executor state and wrote four by
reaching into the struct, so any change to the state's shape had to be made
in the Variant too. Executor.State now has an accessor for each field the
Variant reads and an update function for each write (put_logs/2,
clear_pollers/1, drop_poller/2, put_result/2), and the Variant goes through
them. put_result/2 takes over the fold-counter arithmetic of a finished run.

**Files:** `lib/property_damage/executor/state.ex`, `lib/property_damage/variant.ex`

### 2026-11-09T18:52 · commit · 6a61729

ci: lower the cycle gate to four

The executor files no longer form a dependency cycle, so the count of
module cycles fell from five to four. The gate lowers with it, so the
count cannot rise back.

**Files:** `.github/workflows/ci.yml`

### 2026-11-09T18:57 · commit · 7e0ff43

docs: name the real stepping seam and the step leaf

DR-029 listed a public step_command/7 seam that does not exist, and the
CLAUDE.md Executor bullet did not name the module that now holds the step
primitives. DR-029 gains a note naming the Stepping functions and the
Executor.Step leaf, and the CLAUDE.md bullet names the leaf. The Step
moduledoc no longer links to hidden modules, which broke the docs build.

**Files:** `CLAUDE.md`, `docs/decisions/DR-029-executor-stage-architecture.md`, `lib/property_damage/executor/step.ex`

### 2026-11-09T19:10 · commit · 447c727

refactor(executor)!: notify a step observer instead of threading the mock registry

The mock registry pid was threaded through the executor state, the step
primitives, the drains and finalization, so every executor module knew about
mocks. A PropertyDamage.Executor.StepObserver behaviour now names the four
points of a run the executor reports: before the adapter call, after a
step's events, at a drain and at finalization. MockServiceRegistry is its
first implementation and is registered once, by the Variant, through
MockServiceRegistry.observer/1. The observer also hands the adapter its
runtime handle, so runtime.mock_registry keeps working.

The :mock_registry option of Executor.run/4 and Stepping.init_state/2 is
removed in favor of :step_observer; execute_sequence/12 and the executor
state rename the field the same way. At finalization the registry keeps the
projections of the last step or drain, as before.

**Files:** `CHANGELOG.md`, `lib/property_damage/executor.ex`, `lib/property_damage/executor/events.ex`, `lib/property_damage/executor/finalization.ex`, `lib/property_damage/executor/state.ex`, `lib/property_damage/executor/step.ex`, `lib/property_damage/executor/step_observer.ex`, `lib/property_damage/executor/stepping.ex`, `lib/property_damage/mock_service_registry.ex`, `lib/property_damage/variant.ex`, `test/property_damage/executor/state_test.exs`, `test/property_damage/mock_events_boundary_test.exs` (+2 more)

### 2026-11-09T19:13 · commit · f6b5246

refactor(runtime): remove the unused logged services wrapper

RunServices.with_services_logged/2 existed for a caller that kept the log
lines of a failed adapter setup, and that caller is gone, so the wrapper and
its error-with-logs result shape had no producer left. The wrapper, its flag
and the result clause that only it reached are removed; with_services/2 is
unchanged.

**Files:** `lib/property_damage/runtime/run_services.ex`

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

Labeled reconstruction: assembled from the wave's on-disk reports after the commits, with verbatim quotes. It extends the Record and contradicts none of it.

- Guide example (from the test author's report, `evidence/w8/report_test_author.md`): "No remaining block of the guide's complete example can run in the docs check unchanged, so the guide is untouched. I wrote mocking_guide_example_test.exs instead." Ratified wave-locally as R1.
- Mock push timing (same report): "A mock cannot push during on_command/2 because it runs inside the registry process. The tests push from the adapter's request path during the step."
- Finalize snapshot (same report): "The registry's projection snapshot is not refreshed by finalize; this is pinned as observed." The observer's finalize callback is therefore a no-op in `MockServiceRegistry`.
- Composition (from the implementer's report, `evidence/w8/report_impl_leaf.md`): "Stutter runs outside `Step.execute/4`. The leaf may not call `stutter.ex`, so Stepping composes the step. One theoretical change: a `ProjectionError` or `MockEventsError` raised inside a stutter retry or an `@eventually` check function is no longer rescued into a step failure. No real code path raises these there." Ratified as R3 after the orchestrator read the old rescue scope (`executor.ex` at the base, lines 990 to 997) and the stutter path, which applies no events to projections.
- Arity reading (same report): "`Step.execute/4` takes both the command and the index, as `Stepping.step/4` already does. I read the arity rule as 'at most four'." Ratified as R4.
- Observer commit held for approval: the implementer's progress log records "END item 3 (NOT committed, by rule): implemented + full gate green with adapted tests"; three existing tests changed at the call shape only (`state_test.exs`, `mock_events_boundary_test.exs`, `variant_lifecycle_test.exs`), approved as R2 with "assertions' meaning unchanged", then committed as 447c727 unchanged.
- Dead wrapper: `RunServices.with_services_logged/2` lost its only caller when `Executor.run_logged/4` went in 206d46a; its removal (f6b5246) was asked by the orchestrator, not by the contract.
- Grep scope (from the orchestrator's report, `evidence/w8/suborch_report_w8_pr1.md`): "the adapter-facing handle (public mock-adapter contract the guide and tests rely on)" explains the fifteen remaining `mock_registry` lines; ruled in scope by the maintainer's delegate on 2026-11-09 (E1), with no executor file among them.
- Stutter rescue, run rather than read (probe at the head and the base, `evidence/w8/main/stutter_probe_result.md`): an adapter that raises inside a stutter retry is reported the same way at both commits (`:stutter_execution_failed`); a `using:` predicate that raises `PropertyDamage.ProjectionError` by hand was reported as `:projection_violation` at the base and surfaces as an unknown failure at the head. Inside a retry the engine runs only the adapter call and the comparison predicate (no projection apply, no mock fold, no check), so the difference needs user code to raise the framework's own error. Recorded as drift and filed for the hardening pass.
