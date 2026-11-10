# Handoff ledger: ws-fixes

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: a from-empty drive of the published documentation (a developer with no prior contact built a model, adapter, campaign, trace capture, load test and ExUnit export from the README and guides alone and recorded fourteen places the docs or the code failed them), plus a re-measurement of the abstraction audit's tables at `main`. This branch fixes what those two reports found.

Asked:

- The exported ExUnit test is a regression guard that can fail: the default form fails while the failure is found, the reproduce form fails once it no longer reproduces, the fixed form reports the resurfaced bug instead of crashing on an unqualified module, the moduledoc states what the chosen form asserts, the generated source compiles without warnings and is formatted, and the seed re-run carries the run's `max_commands:`.
- The report's run number reads the same everywhere: `FailureReport.run_number/1`, the one-line summary, the progress printer and the debugging guide agree on a 1-based number, without changing what the trace stores or the persistence format.
- The load-test terminal report draws every box at one width and logs the ramp-down line only when a ramp-down strategy is configured.
- Export and Analysis read the report through accessors instead of the five struct fields they still touched directly.
- Documentation: when the dependency can be `only: :test`; where `@eventually` events come from, with an executed poller snippet; what a placeholder's position means in the minimal reproduction; that a trace capture must repeat the run's generation options and that a report's own trace is the shrunk plan, with an executed comparison recipe; the load-testing guide's definition of a session, the rate denominators and the self-sizing pool's utilization.

Acceptance criteria:

- Each code fix ships with a test that fails on the base checkout and passes at the head; the locked seed goldens are byte-identical to the base and the persistence version is unchanged.
- No module outside the failure report reads the five fields directly.
- Every added guide snippet is executed by the docs gate; the full local gate passes and the module cycle count does not rise.

Non-goals: migrating the report-field reads inside tests and benches (the fields stay public); bundling the system under test into the explain bundle; rendering a placeholder's resolved value in the minimal reproduction; the remaining findings the re-audit listed for the maintainer (compile-time edges, the model-free execute path, the report module's size).

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-10T02:43 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-10T02:43 · commit · f98a193

fix(export)!: make the exported ExUnit test a regression guard that can fail

The exported ExUnit test passed with the bug present: its default form
printed a note when the failure no longer reproduced and passed when it
did, and its fixed-expectation form crashed on an unaliased FailureReport
instead of reporting the resurfaced bug. The seed re-run also dropped the
run's max_commands:, so it could generate another sequence.

The default is now the regression guard (expect_fixed: true), which fails
with its own message while any failure is found. The reproduce form fails
once the failure no longer reproduces. The moduledoc states what each form
asserts, the commands are listed as comments, the adapter alias appears
only when used, the source is formatted, and the seed re-run carries
max_commands:. The docs say how to keep a copy of the replay artifact
beside a committed test.

BREAKING CHANGE: expect_fixed: defaults to true in Export.to_exunit/2 and
the regression test handler.

**Files:** `CHANGELOG.md`, `README.md`, `guides/static_regression_tests.md`, `lib/property_damage/export.ex`, `lib/property_damage/export/exunit.ex`, `lib/property_damage/options.ex`, `openspec/specs/export/spec.md`, `test/property_damage/export_exunit_modes_test.exs`, `test/property_damage/export_test.exs`, `test/property_damage/setup_commands_report_test.exs`

### 2026-11-10T02:49 · commit · 5ad10f4

fix(failure_report)!: count the report's run number from 1

FailureReport.run_number/1 returned the trace's 0-based run index, while
the one-line summary, the progress printer and the debugging guide count
runs from 1, and only: [run: n] takes a 1-based run. A first-run failure
read as run 0 through the accessor and run=1 in the summary.

The accessor now adds one to the stored index. The trace and the
persistence format are unchanged: the builders that copy a report's run
into a new trace read the stored value, and so does the JSON document.

BREAKING CHANGE: FailureReport.run_number/1 returns 1 for a first-run
failure.

**Files:** `CHANGELOG.md`, `lib/property_damage/failure_report.ex`, `lib/property_damage/failure_report/document.ex`, `lib/property_damage/failure_report/formatter.ex`, `lib/property_damage/progress/printer.ex`, `lib/property_damage/report_builder.ex`, `lib/property_damage/reproduction.ex`, `test/property_damage/campaign_policy_test.exs`, `test/property_damage/engine_telemetry_test.exs`, `test/property_damage/failure_report_overlay_test.exs`, `test/property_damage/lockstep_run_test.exs`, `test/property_damage/report_builder_characterization_test.exs` (+2 more)

### 2026-11-10T02:51 · commit · c447f52

fix(load_test): align the terminal report boxes and log ramp-down only when configured

The terminal report's rows were padded to hand-counted widths that did not
match the box edges, so the right border wandered from box to box. The
runner also logged "starting ramp-down" at the end of every run, though
the default :immediate strategy has no ramp-down.

Every box is now drawn by one helper that pads or cuts each row to one
width, and the runner logs the line only for a ramp-down strategy other
than :immediate.

**Files:** `lib/property_damage/load_test/report.ex`, `lib/property_damage/load_test/runner.ex`, `test/property_damage/load_test_test.exs`

### 2026-11-10T02:53 · commit · f2a2e66

refactor(failure_report): read the remaining report fields through accessors

Export, Analysis and the reproduction, replay and printer paths read five
report fields directly (failed_at_index, report_kind, variant,
external_markers, original_sequence), where every other consumer goes
through FailureReport accessors. A change to how a report holds one of
them would have to find each such read by hand.

FailureReport gains one accessor per field, and those callers read
through them. Behavior is unchanged.

**Files:** `lib/property_damage/analysis.ex`, `lib/property_damage/export/common.ex`, `lib/property_damage/export/exunit.ex`, `lib/property_damage/export/step_plan.ex`, `lib/property_damage/failure_report.ex`, `lib/property_damage/progress/printer.ex`, `lib/property_damage/replay.ex`, `lib/property_damage/replay_artifact.ex`, `lib/property_damage/report_builder.ex`, `lib/property_damage/reproduction.ex`

### 2026-11-10T02:55 · commit · d812979

docs: explain installation scope, eventual-check events, placeholders, run numbers and trace capture

A developer building a first model from the docs could not tell whether the
dependency belongs under only: :test, where the events that settle an
@eventually check come from, what a placeholder's position means in a
minimal reproduction, which run a report's run number names, or how to
capture a trace that compares with a failing run.

The README and guides now cover each: the environments the dependency is
needed in, a poller recipe for @eventually, the placeholder position as the
producer's place in the original plan, the 1-based run number, and a
capture recipe that repeats max_commands: and checks plan, failure
signature and comparability.

**Files:** `README.md`, `guides/debugging_failures.md`, `guides/writing_invariants.md`

## Reconstruction

Assembled from the implementer's report; labeled as reconstruction.

- The run-number item had a stop condition: if the stored field or the persistence format had to change, report instead of changing it. It did not: the accessor adds one to the stored index, the summary and printer drop the increment they carried, and the builders that copy a run into a new trace and the JSON document keep the stored value. The report quotes the origin: the campaign loop numbers runs from `first_run` 0, or `only: [run: n]` minus one.
- The exported-test item changed existing tests that pinned the old generated source and the old run number; the report lists them.
- Generated source that does not parse (a target config holding a pid) is returned unformatted instead of raising; the report notes the case was unparseable before the branch.
- The accessor item migrated the twelve listed reads and the other library hits a sweep found (replay, reproduction, report builder, replay artifact, progress printer); the reads inside the report's own modules and the roughly four hundred reads in tests and benches were left, with a proposal for a separate mechanical change.
- The poller snippet runs to about twelve formatted lines rather than the four the request named; it was executed in a scratch test with a never-confirming control.
- Found and not fixed, from the report: the load-test session gauges are never updated by any caller; the analysis module carries its own ExUnit generator in the old shape; the trace stores the run number beside the run's effective seed, so the pair does not regenerate the plan as its moduledoc says; the exported seed re-run omits `stutter:`, `check_mode:` and `compare:`.
