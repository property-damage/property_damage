# Handoff ledger: w6-runner-1

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the maintainer's design rulings of 2026-11-07 for the run seam, from the audit's finding that six call sites drive runs and two of them skip the boundary drain, so a trace can run differently from the run it explains. This is the first of three changes: the runner beside the old path, the campaign run moved onto it.

Asked:

- `PropertyDamage.Runner.execute(plan, run_context)` is the one run driver: it runs the plan through `Scheduler.run/1` and returns the Scheduler's outcome unchanged. The plan carries the symbolic sequence (commands, variants, setup and teardown commands, placeholder registry); `%PropertyDamage.Runner.Context{}` carries every other key the call sites pass today, with the defaults the facade uses. A key no engine module reads is not carried, with the grep cited.
- Locked before the move: a runner characterization against the fixed-seed goldens of the two golden models; a trace-fidelity test on a model whose boundary drain changes what is observed, red at the base; the same for the linear trigger-isolation path. The goldens are not regenerated.
- This change: `Runner` and `Context` beside the old path; the facade's campaign run calls `Runner.execute/2`; nothing else moves.

Acceptance criteria:

- The characterization file passes at the head without its tag and fails at the base commit with the tag included (the runner does not exist there).
- The two fidelity files fail at the base and stay tagged here; a later change lifts them.
- `git diff --stat <base> -- test/fixtures/seed_characterization` is empty and the golden test passes.
- A seeded campaign through `PropertyDamage.run/1` calls `Runner.execute/2`, shown by a call trace.
- The full local gate passes and the module cycle count does not rise.

Non-goals: reproduce, trace capture, trigger isolation and the shrinker (later changes); `failure_intelligence*` (a concurrent change); the openspec engine spec (behavior unchanged here).
## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-07T09:24 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-07T09:24 · commit · 968d18d

test(runner): characterize the run driver against the goldens

No test pins what one linear plan does through the run driver a
campaign uses, so a driver that replaces the scheduler call could drift
unseen. Run the first plan of every golden seed through the scheduler
(untagged control, compared with the golden plans, outcome, failure kind
and check, and answered events) and through the driver (tagged until it
exists), and require equal outcome, events and failure identity.

**Files:** `test/property_damage/runner_characterization_test.exs`, `test/support/runner_support.ex`

### 2026-11-07T09:24 · commit · 23050a0

test(capture): pin trace and analysis reruns to the events of the run they explain

A trace and an analysis rerun execute the plan command by command, which
skips the fold of asynchronous events at each root boundary that a
campaign run performs. The captured events then sit in a different order
and a rerun accepts values that still fail. Add a fixture whose result
depends on that fold, controls showing the two orders differ and that the
fixture is quiet without an injector, and tagged tests for the trace
events and the isolate_trigger verdict.

**Files:** `test/property_damage/analysis_fidelity_test.exs`, `test/property_damage/run_trace/capture_fidelity_test.exs`, `test/support/boundary_drain_fixtures.ex`

### 2026-11-07T09:44 · commit · a76cd4d

refactor(runner): add Runner.execute/2 and move the campaign run onto it

A campaign run, a reproduction and a trace capture each assembled their
own scheduler call, so the paths that execute a plan could drift apart.
Add PropertyDamage.Runner, the one run driver: execute/2 takes the
symbolic plan and a Runner.Context holding the model, the targets and
the scheduler's run options, and returns the scheduler's outcome
unchanged. The campaign run now goes through it. The external_markers
key it passed is dropped, because the scheduler never read it.

The run driver characterization now runs in the default suite.

**Files:** `CLAUDE.md`, `lib/property_damage.ex`, `lib/property_damage/runner.ex`, `lib/property_damage/runner/context.ex`, `lib/property_damage/scheduler.ex`, `test/property_damage/runner_characterization_test.exs`

### 2026-11-07T09:46 · commit · e23d9be

refactor(runner): add Runner.execute/2 and move the campaign run onto it

A campaign run, a reproduction and a trace capture each assembled their
own scheduler call, so the paths that execute a plan could drift apart.
Add PropertyDamage.Runner, the one run driver: execute/2 takes the
symbolic plan and a Runner.Context holding the model, the targets and
the scheduler's run options, and returns the scheduler's outcome
unchanged. The campaign run now goes through it. The external_markers
key it passed is dropped, because the scheduler never read it.

The run driver characterization now runs in the default suite.

**Files:** `CLAUDE.md`, `lib/property_damage.ex`, `lib/property_damage/runner.ex`, `lib/property_damage/runner/context.ex`, `lib/property_damage/scheduler.ex`, `test/property_damage/runner_characterization_test.exs`

### 2026-11-07T09:30 · decision · characterization shape

A failing seed's golden events come from the shrunk reproduction, so the runner characterization compares the golden plans, the first run's verdict, the failure kind and check, and the answered-events prefix for passing seeds; it does not compare golden events or the root index for failing seeds. The characterization is tagged as a known defect until the runner exists, and the drained-event control asserts the event's position rather than its absence, because finalization drains the last event on the old path too.

### 2026-11-07T09:50 · decision · plan keys and wording

`execute/2` merges only the plan's own keys into the Scheduler options, so an extra plan key cannot reach the Scheduler unchecked. The moduledoc's "meant to carry" wording stands for this change and is reworded when the remaining callers move. `external_markers` is dropped from the context: neither the Scheduler nor the Variant reads it.

## Reconstruction

Labeled as reconstruction: assembled after the fact from the wave's evidence files, not from the commits.

- The test author found no existing test that compares a captured trace to the run it explains, and built the drain fixture as "a side effect inside a check, through one named Box process", which is why the three files that use it run with `async: false`.
- The red logs quote the base disagreement the fidelity tests pin: "the trace log is [cmd0, cmd1, Charged0, cmd2, ...] and the scheduler log is [cmd0, Charged0, cmd1, Charged1, cmd2]" and "isolate_trigger lists amounts [0,1,7,14,16] where the scheduler reference gives [0,1,7]".
- The implementer dropped the breaking marker from the commit because "no public signature changed (Runner and Runner.Context are new modules), so there is no CHANGELOG line".
- The seed default of `nil` was a recorded choice: "enforce_keys is pinned and the Scheduler has no default for seed. A context without a seed fails when it runs."
