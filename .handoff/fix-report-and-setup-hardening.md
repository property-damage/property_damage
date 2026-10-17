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

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

_Not yet written._
