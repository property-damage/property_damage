# Handoff ledger: wb-remove-branching

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seed this
from whatever produced it: a grill-me ledger, a campaign wave contract, a
ticket, or by hand.

Source: the maintainer's ruling of 2026-11-06 that the branching execution mode is removed as a clean break (its branches ran one after another on one target and detected no races), with one run driver left for a later runner extraction. A concurrent mode built on the scheduler is a separate, future design.

Asked:

- Remove `Executor.Branching`, `Linearization`, the branching path and state merge in `Executor.run`, the `branching:` run option and the option refusals that existed only for it, the branch-aware shrink strategies, and the branching parts of Generator, Sequence, Expansion, Replay, RunTrace, Timeline, the `pd.audit` and `pd.replay` tasks, `PropertyDamage.IEx`, Audit, Telemetry, Placeholder, Model and FailureReport.
- `Sequence` loses its `branches` field and `Sequence.linear?/1`; every sequence is linear.
- The five places that chose between the linear and the branching path (`run/1`, reproduce, the shrinker, `RunTrace.capture`, Analysis) call the linear scheduler path directly, with no new runner abstraction.
- Persistence: if a persisted shape loses a field, the format version bumps with fixture regeneration and the loader refusing older files; otherwise a current-format file round-trips and that is recorded.
- A decision record supersedes DR-053 and annotates DR-044 and DR-045; CHANGELOG Unreleased carries a breaking Removed entry.
- `guides/parallel_testing.md` is deleted with its docs entry; the concurrency spec is deleted or trimmed to what stays true; the Redis bench loses its linearization test.
- Locked before any engine edit: a fixed-seed characterization of linear runs on two seeded-defect models, written by a separate author, that stays green across the removal.

Acceptance criteria:

- `grep -rniE 'branching|branches:|linearization|linearizab' lib test guides README.md CLAUDE.md openspec benches notebooks priv` returns no hit; hits remain only in released CHANGELOG history and decision records.
- For every seed of the locked set, the plan, outcome, events, failure and shrunk reproduction rendered at the base commit and at the head are identical, and the locked test passes at both.
- Passing the removed run option raises the unknown-option error.
- A file of the previous persistence format is refused with the version error, or round-trips if no shape changed; whichever holds is recorded with its proof.
- The full local gate passes, the module cycle count does not rise, and the Redis bench suite passes without its linearization test.

Non-goals: extracting the runner (a later branch); a concurrent execution mode; the known-defect tests and the test helper from main.

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-06T23:01 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-06T23:01 · commit · a3c39e0

test: pin linear run behavior for a fixed seed set

A refactor of the run engine can change what a linear run generates,
reports or shrinks without any existing test noticing. Pin it: for 24
seeds of each of two seeded-defect models (a ledger whose account id the
SUT mints through external(), and a key/value store whose delete is a
no-op), the test compares the run's generated plans, outcome, events,
failure and shrunk reproduction with golden files.

The rendering is plain data (commands as module and args, events as
source, module and fields, placeholders as labels) so the files survive
changes to the engine's own structs. generate.exs rewrites the goldens;
two runs in separate VMs produce identical files.

**Files:** `test/fixtures/seed_characterization/generate.exs`, `test/fixtures/seed_characterization/ledger.exs`, `test/fixtures/seed_characterization/store.exs`, `test/property_damage/seed_characterization_test.exs`, `test/support/seed_characterization_support.ex`

### 2026-11-06T23:34 · commit · 484a9eb

refactor!: remove the branching execution mode

A sequence could carry parallel sub-sequences, but those branches ran one
after another on one target, so the mode detected no races. It still cost a
second run driver, a state merge, an ordering checker that searched for a
sequential explanation of the branch results, and a choice between two
paths at every place that runs a sequence. This change removes the mode
and keeps one driver: every sequence is linear and runs through the
lockstep scheduler. A concurrent mode, if one is built later, starts from
that driver.

Removed: Executor.Branching, the Linearization module, the run option
that selected the mode with its nested keys, the option refusals that
existed only for it (with latency:, check_mode:, several targets, an
only: shape and a model with expansions, and the minimum prefix length
against max_commands), the branches and suffix fields of Sequence with
their functions, the branch and suffix sections of Sequence.Position,
branch_id on Failure and EventLog.Entry, the branch failure kind, and the
branch shrink strategies. Run, reproduce, the shrinker, RunTrace.capture
and Analysis call the linear path directly. The tasks and the IEx helpers
lose their flags for the mode.

The saved-file format becomes version 18: a version-17 sequence, trace
and event log carry the removed fields, so the loader refuses version 17
and older with {:error, {:unsupported_format_version, 17, 18}}. The JSON
export becomes version 2.0, whose event entries carry no branch_id. The
replay artifact format is unchanged.

BREAKING CHANGE: the parallel-branch execution mode is gone. Passing its
run option is now an unknown-option error; run linear sequences instead.
The Sequence, Sequence.Position, Failure and EventLog.Entry fields and
functions of the mode are removed. Saved failure files of format 17 and
older no longer load, and the JSON export reports version 2.0.

**Files:** `lib/mix/tasks/pd.audit.ex`, `lib/mix/tasks/pd.bisect.ex`, `lib/mix/tasks/pd.replay.ex`, `lib/property_damage.ex`, `lib/property_damage/analysis.ex`, `lib/property_damage/audit.ex`, `lib/property_damage/diagram.ex`, `lib/property_damage/error.ex`, `lib/property_damage/error_origin.ex`, `lib/property_damage/event_log/entry.ex`, `lib/property_damage/event_queue.ex`, `lib/property_damage/ex_unit.ex` (+116 more)

### 2026-11-06T23:45 · commit · 6404216

test(redis_bench): drop the linearization test

The parallel linearization test drove the removed `branching:` option and
`PropertyDamage.Linearization`. Delete it with the read-modify-write command,
event, model and adapter clause that only it used, and reword the bench
README and moduledocs.

**Files:** `benches/redis_bench/README.md`, `benches/redis_bench/lib/redis_bench.ex`, `benches/redis_bench/lib/redis_bench/adapter.ex`, `benches/redis_bench/lib/redis_bench/commands.ex`, `benches/redis_bench/lib/redis_bench/model.ex`, `benches/redis_bench/test/parallel_linearization_test.exs`, `benches/redis_bench/test/redis_bench_test.exs`

### 2026-11-07T00:08 · commit · 6da4f86

refactor: drop the last references to the removed branching mode

Three leftovers still named the removed mode. The ex_doc module groups
in mix.exs listed PropertyDamage.Linearization, a module that no longer
exists. The @label pattern in the log fixtures accepted a branch label
that no report can produce now. A run_targets test built the removed
option's name at run time, and it pinned only NimbleOptions' default
handling of an unknown key.

Remove the group entry and the dead pattern alternative, and delete the
test.

**Files:** `mix.exs`, `test/property_damage/run_targets_test.exs`, `test/support/log_fixtures.ex`

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

_Reconstruction, written at PR open from the review record kept outside the repo (the agents that wrote the code ran as subagents whose transcripts are not listed under Sessions, so this tier quotes that record, not a transcript)._

- The Record above misses two commits the hook did not capture: `20f7d32` (docs: drop the branching mode from guides and specs) and `f2d69c5` (docs(decisions): record the branching removal). Both are on the branch; `git log` is the authority.
- Before the engine edit, the review record ruled the suffix out with `branches`: "`suffix` holds commands run after branches merge; with branches gone it is always empty, so it goes with `branches` (dead state)", on the condition that a grep confirms "no linear path writes `suffix`". The grep at the base commit found no writer.
- The persistence bump was decided by evidence, not up front: the record notes "v17 load at head gave :unsafe_terms" for a report and trace written at the base commit, after which the version moved to 18 and a refusal test was added.
- The first agent to work on the removal reached its turn budget with the removal uncommitted; a continuation verified the tree and committed it, and a second continuation did the docs, decision record, changelog and bench. The record: "hit its 200-turn cap with the lib/test removal uncommitted; not resumed."
- The concurrency spec was trimmed rather than deleted: "stutter and idempotency kept, true of the linear engine".
- At review, an independent verifier found two leftover lines and a test that built the removed option's atom at run time whose own comment said it was built "so the retired option name appears in no source line"; the fix commit removed all three and did not replace the test.
