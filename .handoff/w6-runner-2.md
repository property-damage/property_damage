# Handoff ledger: w6-runner-2

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the maintainer's design rulings of 2026-11-07 for the run seam; this is the second of three changes. The first added `PropertyDamage.Runner.execute/2` and moved the campaign run onto it; this one moves the failure reproduction; the third moves the trace capture and the trigger isolation.

Asked:

- The facade's private `reproduce` builds a `%Runner.Context{}` from the found failure and calls `Runner.execute/2` instead of `Scheduler.run/1`; `shrink_further` and `handle_failure` reach it unchanged. The shrinker's own option list stays for a later change.
- The option set equals the old Scheduler list field for field, with both the seed and the run seed kept.
- No behavior change; the locked tests and the goldens are not edited.

Acceptance criteria:

- `grep -c 'Scheduler.run(' lib/property_damage.ex` is zero.
- The test tree is byte-identical to the first change's head and the goldens to the base.
- The full local gate passes and the module cycle count does not rise.

Non-goals: the trace capture, the trigger isolation and the shrinker; `failure_intelligence*` (a concurrent change).
## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-07T09:58 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-07T09:58 · commit · e30093a

refactor(runner): reproduce failures through the runner

The reproduction of a found failure built its own scheduler option list,
so the run driver carried only campaign runs. Reproduction now builds a
plan and a runner context and calls Runner.execute/2 with the same option
set, and the campaign run and the reproduction share one small plan
helper. Behavior is unchanged. The runner moduledoc now names the two runs
it carries.

**Files:** `lib/property_damage.ex`, `lib/property_damage/runner.ex`

### 2026-11-07T10:05 · decision · shared plan helper

The symbolic plan map is built by one private helper for both the campaign run and the reproduction, so the five plan keys are named in one place. The runner moduledoc no longer says the driver is "meant to carry" the remaining runs; it names the two that are on it and the two that follow.

## Reconstruction

Labeled as reconstruction: assembled after the fact from the wave's evidence files, not from the commits.

- The reviewer's seam read recorded the option-set equality as "equals the old Scheduler list field for field. seed and run_seed are both kept as found.run_seed" and that "measure_latency stays at the Context default of false, which the old call also left unset".
- The commit carries no breaking marker and no CHANGELOG line "because behavior is unchanged".
