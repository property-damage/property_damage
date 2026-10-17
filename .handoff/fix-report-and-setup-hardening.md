# Handoff ledger: fix/report-and-setup-hardening

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

- 2026-10-17T17:34 · `a9f269c9-a9a4-4923-a1de-e3f98470ccf8` · `/home/work_bc/.claude/projects/-home-work-bc-srv-secretariat-common/a9f269c9-a9a4-4923-a1de-e3f98470ccf8.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-10-17T17:34 · commit · b0dc600

docs(expansion): say :identity also names one leaf equal to its root

**Files:** `lib/property_damage/expansion.ex`

### 2026-10-17T17:36 · commit · c991983

fix(mix): print a divergence's check name in pd.replay and pd.reshrink

The summary line of both tasks interpolated the comparison key, a
{projection, name} tuple, and raised Protocol.UndefinedError on every
divergence report. The key now goes through FailureReport.format_name/1,
the formatter the exporters already use.

**Files:** `.handoff/fix-report-and-setup-hardening.md`, `CHANGELOG.md`, `lib/mix/tasks/pd.replay.ex`, `lib/mix/tasks/pd.reshrink.ex`, `test/mix/tasks/pd_replay_test.exs`, `test/mix/tasks/pd_reshrink_test.exs`

### 2026-10-17T17:38 · commit · d2a3dd0

fix(report): badge poller, telemetry and injected events in the Event Log

The terminal report and the timeline each carried their own badge table,
and both lacked the three sources the event log entry documents last, so
those events printed as ???. One table now serves both printers.

**Files:** `.handoff/fix-report-and-setup-hardening.md`, `CHANGELOG.md`, `lib/property_damage/failure_report/formatter.ex`, `lib/property_damage/failure_report/source_badge.ex`, `lib/property_damage/failure_report/timeline.ex`, `lib/property_damage/validation.ex`, `test/property_damage/executor/stepping_outcome_test.exs`, `test/property_damage/failure_report/timeline_test.exs`, `test/property_damage/formatter_test.exs`

### 2026-10-17T17:38 · commit · 9f241e7

fix(report): honor color: false in the timeline

Every colored span in the timeline ended with a reset sequence written
unconditionally, so plain output kept the reset bytes. The reset now
follows the color flag like the other color helpers.

**Files:** `.handoff/fix-report-and-setup-hardening.md`, `CHANGELOG.md`, `lib/property_damage/failure_report/timeline.ex`, `test/property_damage/failure_report/timeline_test.exs`

### 2026-10-17T17:40 · commit · 8d6a4b3

fix(report): keep a placeholder argument whole and mark a cut value

The terminal report cut every command argument at a fixed width with no
marker, so a placeholder printed without its closing bracket and two ids
that differed past the cut printed alike. A placeholder now prints whole;
a value the formatter cuts ends with a marker.

**Files:** `.handoff/fix-report-and-setup-hardening.md`, `CHANGELOG.md`, `lib/property_damage/failure_report/formatter.ex`, `test/property_damage/formatter_test.exs`

### 2026-10-17T17:42 · commit · 32dfa1e

fix(runtime): tear down earlier injectors when a later setup raises

An injector setup/1 that raised escaped the per-run wiring, so the
injectors set up before it kept their listeners, and a mock setup that
raised left every injector up because the mocks were set up outside the
block whose after clause tears the injectors down. The raise is now the
setup failure it is on every path, with the exception as its detail.

**Files:** `.handoff/fix-report-and-setup-hardening.md`, `CHANGELOG.md`, `lib/property_damage/runtime/run_services.ex`, `test/property_damage/run_services_test.exs`, `test/property_damage_test.exs`

### 2026-10-17T17:43 · commit · 0635614

fix(trace): return a setup-failed trace when an injector setup fails

RunTrace.capture/1 matched the run result against {:ok, _}, so an
injector setup that failed on a model without expansions raised
MatchError in mix pd.audit and in run comparison. The capture now
returns a trace whose outcome is the setup failure, as the scheduler
path already did.

**Files:** `.handoff/fix-report-and-setup-hardening.md`, `CHANGELOG.md`, `lib/property_damage/run_trace.ex`, `test/property_damage/capture_injectors_test.exs`

### 2026-10-17T17:47 · commit · d60adca

fix(executor): fail an @eventually whose function returns no predicate

The executor handed the check function's return to the poller unchecked,
so a function that returned a boolean raised BadFunctionError on every
poll behind a warning and surfaced as a window timeout. The return is now
checked where the poller would be spawned: anything but a 1-arity
function is a check failure at that step, naming the check and the value,
handled under check_mode like a synchronous check.

**Files:** `CHANGELOG.md`, `lib/property_damage/executor.ex`, `lib/property_damage/model/projection.ex`, `openspec/specs/eventual-consistency/spec.md`, `test/property_damage/eventually_return_test.exs`

### 2026-10-17T17:49 · commit · cf6819f

test(expansion): cover a leaf when: and the :follow path on a rewritten root's id

Two paths share the re-fold that keeps a rewritten root's id in the
target's simulated state and had no test of their own: a leaf whose
module's commands/0 when: reads that state, and the shrinker's phase 3,
where a second target copies the reference's rewrite and the roots after
it read the id again.

**Files:** `test/property_damage/expansion_root_placeholder_state_test.exs`

### 2026-10-17T17:51 · commit · dcf6a13

fix(options): refuse latency: and a non-default check_mode: with branching:

A branching run executes one branch at a time on one target through the
linear engine, which records no latency samples and halts at the first
failing check whatever check_mode: says. Both combinations were accepted
and ignored; they are option errors at run start now.

**Files:** `CHANGELOG.md`, `lib/property_damage/options.ex`, `test/property_damage/branching_option_conflicts_test.exs`

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

_Not yet written._
