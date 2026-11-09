# Handoff ledger: w11-thin-failure-report

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seed this
from whatever produced it: a grill-me ledger, a campaign wave contract, a
ticket, or by hand.

Source: the maintainer's design rulings of 2026-11-09 for the failure report (contracts recorded in the design record, section "thin FailureReport"), from the abstraction audit's finding that the report stored eight values its own trace already held and serialized itself three different ways.

Asked:

- A decision record first: the report is an overlay on its trace. The eight trace-held fields (`seed`, `run_number`, `model`, `timestamp`, `command_labels`, `failure_reason`, `setup_commands`, `teardown_commands`) leave the struct and become accessors over the trace; `state_at_failure` and `state_before_failure` stay stored as the executor's observations. One report JSON document replaces the three shapes (the persistence export, the formatter's JSON and the bundle), with its name, key set and integer format number; the persistence format bumps and older files are refused. Index row; the persistence and failure-analysis specs amended.
- Locked before the move: a report file written by the base code becomes the refusal fixture for the previous format and a test asserts the loader refuses it after the bump; a round-trip test asserts save-then-load equality through the accessors for a fixed failure with setup and teardown commands and logs; an equality test asserts the one document is identical from the three entry points (export, formatter, bundle without sources) for the same report; the viewer specs stay green. The eleven test files that hard-code the version move to one named accessor.
- The struct thins: `FailureReport` exposes one accessor per removed field reading the trace; `new/1` takes what the trace needs and builds no copy; `ReportBuilder` passes nothing twice; the legacy conversions go or derive. Every reader outside the report modules uses the accessors; the remaining raw reads of the other fields are listed in the record as the struct's stable surface.
- One JSON document under the report modules: string keys, an integer format, built from the layout and the context, with the bundle's source sections as optional members present when sources are requested. The formatter's `:json`, the persistence export and the bundle return it; the HTML page embeds it in its data tag and the viewer reads the one key set.
- Hygiene: persistence version bumped, the loader refuses the previous version and below with the existing error shape, the version comment block and moduledoc updated, the refusal fixture tracked; the cycle count does not rise (breaking the report's cycle was optional); residue sweep for the eight field names as struct keys; sweep of the report and persistence moduledocs, the repository guidance line and the guides describing the export; CHANGELOG Breaking and Changed; full gate, the two zero-infrastructure benches, the browser specs in CI.

Acceptance criteria:

- A grep for raw reads of the eight fields (`report.<field>` or a struct literal with the key) in the library outside the report modules is empty.
- The three entry points produce equal documents for one report, and the viewer specs pass.
- The loader refuses the tracked previous-format fixture with the existing error shape; the round-trip test passes through the accessors; the eleven version pins read one accessor.
- The decision record exists and is indexed; the full local gate passes; the module cycle count does not rise.

Non-goals: deriving `state_at_failure` and `state_before_failure` (re-folds projections; recorded); changes to the trace beyond a read accessor; the load-test worker (a concurrent change); the service-container benches (CI runs them).

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-09T20:45 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-09T20:45 · commit · 68dc55b

test(persistence): add a format-19 report fixture

The format-19 refusal had no saved file to load. Add a report saved at
format 19, with a setup command, a teardown command and a failing check,
and the small model that builds it.

**Files:** `test/fixtures/persistence/format_19_report.pd`, `test/support/report_overlay_fixture.ex`

### 2026-11-09T20:48 · commit · 16e3da9

test(persistence): read the format version from one accessor

Eleven test files hard-coded the format number, so every bump meant
editing each one. Add Persistence.version/0 and read the number from it.

**Files:** `lib/property_damage/persistence.ex`, `test/property_damage/expansion_report_test.exs`, `test/property_damage/failure_identity_persistence_test.exs`, `test/property_damage/latency_budget_test.exs`, `test/property_damage/log/log_filter_memory_test.exs`, `test/property_damage/log/log_persistence_test.exs`, `test/property_damage/log/setup_log_test.exs`, `test/property_damage/other_failures_test.exs`, `test/property_damage/persistence_format_version_test.exs`, `test/property_damage/persistence_test.exs`, `test/property_damage/replay_paths_test.exs`, `test/property_damage/run_targets_test.exs`

### 2026-11-09T20:54 · commit · 78148b3

test(failure_report): lock the format round trip, the refusal of the previous format and the one JSON document

The report is about to derive eight values from its trace and to serialize
as one JSON document under a new format version. Pin that behavior first:
a format-19 file is refused, a saved report keeps the eight values read
through accessors, and the formatter, the export and the bundle give one
equal document. Tests that describe the new behavior carry known_defect
until the change lands; a characterization test holds the eight values
steady across the move.

**Files:** `test/property_damage/failure_report_overlay_test.exs`, `test/property_damage/persistence_format_version_test.exs`

### 2026-11-09T21:20 · commit · dc4f0ce

refactor(failure_report)!: derive the trace-held fields instead of storing them and refuse format 19

A report copied eight values its own trace already holds (seed, run_number,
model, timestamp, command_labels, failure_reason, setup_commands and
teardown_commands), so the two records could drift and the struct carried 47
fields.

The report now reads them from the trace through accessors of the same
names, and new/1 stores no copy. from_legacy/2 and to_legacy/1 are removed.
Saved files change shape, so the persistence format is 20 and files of
format 19 and older are refused. Guides, benches and specs read the values
through the accessors.

**Files:** `CHANGELOG.md`, `README.md`, `benches/cachex_bench/test/expansions_test.exs`, `benches/cachex_bench/test/replay_test.exs`, `benches/gitea_bench/test/login_setup_test.exs`, `benches/oban_bench/test/compare_test.exs`, `benches/oban_bench/test/job_refs_shrink_test.exs`, `benches/oban_bench/test/retry_test.exs`, `benches/oban_bench/test/seeded_bug_test.exs`, `benches/oban_bench/test/uniqueness_test.exs`, `guides/debugging_failures.md`, `guides/differential_testing.md` (+129 more)

### 2026-11-09T21:48 · commit · 8a1fabc

feat(failure_report)!: serialize the report as one JSON document

Three JSON shapes described one failure and shared no key list: the
formatter's `:json` output, `Persistence.export_json/1` and the bundle in
every HTML page. A reader of one could not use another.

`FailureReport.Document.build/2` now writes one document (format 2). The
formatter, the export, `Bundle.build/2` and the page's `pd-bundle` tag all
return or embed it. The source members (`modules`, `ids`, `missing_sources`,
`redactions`) appear only with `sources: true`; the page asks for them.
`failure` carries `kind`, the context list is `context` (not
`what_this_checks`), and the top-level `type` and `version` are gone.

`pd.explain` still reads pages that carry a format 1 bundle.

**Files:** `lib/property_damage/failure_report/bundle.ex`, `lib/property_damage/failure_report/bundle/sources.ex`, `lib/property_damage/failure_report/document.ex`, `lib/property_damage/failure_report/explanation.ex`, `lib/property_damage/failure_report/formatter.ex`, `lib/property_damage/failure_report/html.ex`, `lib/property_damage/persistence.ex`, `test/mix/tasks/pd_explain_default_test.exs`, `test/mix/tasks/pd_explain_edges_test.exs`, `test/mix/tasks/pd_explain_hardening_test.exs`, `test/property_damage/compare_divergence_test.exs`, `test/property_damage/compare_reporting_test.exs` (+10 more)

### 2026-11-09T21:53 · commit · 1ae965f

docs: record the report as an overlay on its trace

The report stored eight fields its trace already holds and serialized as four
drifting JSON shapes. DR-066 records the accessors that read the eight fields
from the trace, the one JSON document all JSON surfaces return, and format 20.
The persistence and failure-analysis specs name the document and the refusal of
older files, and earlier records carry a note where this one amends them.

**Files:** `docs/decisions/DR-033-run-trace-execution-record.md`, `docs/decisions/DR-041-structured-failure-vocabulary.md`, `docs/decisions/DR-045-one-runner.md`, `docs/decisions/DR-055-failure-report-layout.md`, `docs/decisions/DR-058-failure-report-context-and-explanations.md`, `docs/decisions/DR-066-report-overlay-and-one-json-document.md`, `docs/decisions/README.md`, `openspec/specs/failure-analysis/spec.md`, `openspec/specs/persistence/spec.md`

### 2026-11-09T21:58 · commit · 2ad5575

docs(failure_report): describe the thin report and the one JSON document

Docs still named the eight report fields as struct fields and left the JSON
export, the formatter output and the page bundle as separate shapes. The
moduledocs, CLAUDE.md, README, guides and CHANGELOG now name the accessors and
the one document, and the integration guide reads the seed through its accessor.

**Files:** `CHANGELOG.md`, `CLAUDE.md`, `README.md`, `guides/debugging_failures.md`, `guides/differential_testing.md`, `guides/integration_testing.md`, `lib/property_damage/failure_report.ex`, `lib/property_damage/failure_report/document.ex`, `lib/property_damage/failure_report/explanation.ex`

### 2026-11-09T22:10 · commit · 2d37aae

fix(failure_report): keep the JSON document when one section fails to render and name the failure

A section whose rendering raised on user code, such as a projection's
__compares__/0, lost the whole JSON export and its logs. Each section builder
now has its own rescue on the document path: the section is left out, the raise
is logged as a warning, and a top-level render_errors list names the section and
carries the message. The terminal and markdown formats still raise.

**Files:** `CHANGELOG.md`, `docs/decisions/DR-066-report-overlay-and-one-json-document.md`, `lib/property_damage/failure_report/document.ex`, `lib/property_damage/failure_report/layout.ex`, `openspec/specs/failure-analysis/spec.md`, `test/property_damage/failure_report/json_logs_test.exs`

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

_Not yet written._

Labeled reconstruction: assembled from the wave's on-disk reports after the commits, with verbatim quotes. It extends the Record and contradicts none of it.

- Version pins (from the orchestrator's report, `evidence/w11/suborch_report_w11.md`, R1): "`Persistence.version/0` added by the test author (one lib line)"; the eleven files that hard-coded the version "now read `Persistence.version()`".
- Bump folded into the thinning (same report, R4): "version 20 and the loader refusal folded into the thin commit; two locked lines amended to accessors (the fields no longer exist)"; the separate bump commit the plan named does not exist.
- Record order (same report, R5): "DR-066 lands after the code (main accepted; Amendment 1)".
- Document keys (same report, R2 and R3): the sources option is "`sources: true`"; the document's "`"failure"` carries `"kind"`".
- Bundle kept (same report, R6): "`Bundle` kept as a delegate (locked test calls it); `Explanation` accepts formats 1 and 2."
- Section guard (same report, E1): "per-section guard in `Layout.bundle_data`, `render_errors` member, `Logger.warning`; terminal and markdown still raise; limit: Context items and listing log-message functions are computed before the guards and stay unguarded." The orchestrator's escalation brief (wave doc, "Escalation E1") recorded why: removing the first version's catch-all rescue left one pre-existing test failing, "a report whose Failure section raises still formats as JSON with the same logs", because the base formatter's JSON never built the page layout while the base bundle did.
- Struct and surface (same report): "Struct fields: 47 before, 39 after"; the stable raw-read surface is "original_sequence, failed_at_index, report_kind, variant, trace, external_markers, state_at_failure, error_origin, error_origin_details, replay, replay_path (listed in DR-066)".
- Replay artifact (main's ruling, design record log): the accessor swaps in `replay_artifact.ex` were accepted as part of the readers' migration; the ownership list had named that file as an escalation.
