# DR-066: The Report Is an Overlay on Its Trace, and Serializes as One JSON Document

**Status:** Accepted
**Date:** 2026-11-09

## Context

A `PropertyDamage.FailureReport` embeds a `RunTrace` (DR-033), yet it also
stored eight fields the trace already holds: `seed`, `run_number`, `model`,
`timestamp`, `command_labels`, `failure_reason`, `setup_commands` and
`teardown_commands`. Every builder had to fill both copies, and a report whose
copy and trace disagreed had no defined answer. Two helpers, `from_legacy/2`
and `to_legacy/1`, existed to move between the stored and the derived shape.

The same report also had four JSON shapes that drifted apart: the atom-keyed
map `Persistence.export_json/1` encoded, the formatter's `:json` output (type
`"property_damage_failure_report"`, version `"2.0"`), the bundle a failure
page carries in its `pd-bundle` tag (format 1), and the explain page reader's
view of that bundle. A program that read one of them could not read another.

## Decision

1. **The report is an overlay on its trace.** The eight fields are no longer
   stored. `FailureReport.seed/1`, `run_number/1`, `model/1`, `timestamp/1`,
   `command_labels/1`, `failure_reason/1`, `setup_commands/1` and
   `teardown_commands/1` read them from the embedded trace (and, for the two
   command lists, from the trace's plan). Each accessor returns `nil`, `%{}` or
   `[]` for a report with no trace. `from_legacy/2` and `to_legacy/1` are
   removed.
2. **`state_at_failure` and `state_before_failure` stay stored.** They are the
   executor's observation of the projections at the failing step. Deriving
   them would fold the event log through the projections again, which this
   change does not do.
3. **One JSON document.** `PropertyDamage.FailureReport.Document.build/2`
   returns a string-keyed map with `"format" => 2`. The keys are listed in the
   `Document` moduledoc. Under `sources: true` the document also holds the
   source members `modules`, `ids`, `missing_sources` and `redactions`; without
   it, those four keys are absent.
4. **Every JSON surface is that document.** `Formatter.format(report, :json)`
   writes it, `Persistence.export_json/1` returns it encoded as indented JSON,
   `FailureReport.Bundle.build/2` returns it, and the HTML page carries
   `Document.build(report, sources: true)` in `pd-bundle`. The atom-keyed
   export map, the formatter's `"2.0"` shape and the bundle's format 1 are
   removed, and `Formatter.reference_json` is gone with them. `Bundle` stays as
   a thin delegate to `Document`, and the source gathering lives in
   `Bundle.Sources`.
5. **The explain page reader accepts format 1 and format 2.** A page written
   before this change keeps its explanation checkable. A new page carries
   format 2.
6. **Persistence format 20.** Files of format 19 and older are refused with
   `{:error, {:unsupported_format_version, saved, 20}}`: a format 19 file holds
   the eight fields in the struct and no longer decodes into the current one.
   Capture the failure again to write a new file.
7. **The struct's raw-read surface.** Code outside the report's own modules
   still reads these fields straight from the struct: `original_sequence`,
   `failed_at_index`, `report_kind`, `variant`, `trace`, `external_markers`,
   `state_at_failure`, `error_origin`, `error_origin_details`, `replay` and
   `replay_path`. They are the report's stable fields. The readers are the
   exports, `PropertyDamage.Analysis` and the failure-intelligence modules.
   The eight derived fields are not part of that surface.
8. **Dependency cycles.** The module cycle between `FailureReport` and
   `ReplayArtifact` is not broken by this change, so the count of such cycles
   is unchanged.

## Alternatives

- **Keep the stored copies and check them against the trace.** Rejected: the
  check would run on every load and every builder, and two copies stay two
  copies.
- **Derive `state_at_failure` and `state_before_failure` too.** Rejected for
  now: they are what the executor observed, and recomputing them folds the
  projections a second time. It is a separate decision.
- **Keep one JSON shape per surface.** Rejected: the shapes already drifted
  once, and every reader needed a key map per surface.
- **Delete `Bundle`.** Deferred: callers of `Bundle.build/2` keep working
  through the delegate. Removing it is a later, mechanical change.

## Consequences

- A report whose trace is missing has no seed, model or failure reason. Code
  that builds a report by hand passes a trace, or reads `nil`.
- Code that read `report.seed` and the other seven fields reads the accessor.
- A program that reads the JSON export, the formatter's JSON or the page
  bundle reads one key set; the old keys (`type`, `version`, `what_this_checks`,
  and the atom-keyed export fields) are gone. The context items live under
  `context`.
- Saved reports of format 19 and older cannot be loaded.
- Explain pages of format 1 still read.
