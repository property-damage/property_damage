# DR-061: The Report and the Replay Artifact Record the Run's External Markers

**Status:** Accepted
**Date:** 2026-11-04

## Context

A run names extra atoms to treat as `external()` markers through the
`external_markers:` run option (DR-032). An event field that holds such an
atom becomes a placeholder when the run simulates a command, and a later
command that consumes the field receives the value the system minted.

Every path that runs a failure again simulates the report's commands again:
`PropertyDamage.replay/1`, `PropertyDamage.shrink_further/2`,
`PropertyDamage.Analysis.isolate_trigger/2`, the exports, `mix pd.replay`,
`mix pd.reshrink` and `PropertyDamage.run/1` with `only: [replay: path]`.
Neither the failure report nor the replay artifact recorded the markers. A
caller had to pass them again where an option existed, and where none existed
(`Replay`, `Analysis`, the exports and both Mix tasks) a model with
`expansions/0` that relied on atom markers could not run its failure again: a
command that consumed a marked value got a placeholder no registry knew.

## Decision

1. `%PropertyDamage.FailureReport{}` gains `external_markers`, the run's
   `external_markers:` option (`[]` by default). Every report a run, a latency
   budget or a re-shrink builds sets it.
2. The replay artifact term gains `external_markers`. The artifact format
   becomes `2`, and the loader refuses format `1`.
3. The persistence format becomes version `16`. A file of version `1` to `15`
   is refused with `{:unsupported_format_version, version, 16}`, and a
   version-16 report lacking `external_markers` is refused with
   `{:missing_field, :external_markers}`.
4. Every path that simulates a report's commands again uses the recorded
   markers. Where the path takes an `external_markers:` option
   (`shrink_further/2`, and `run/1` with `only: [replay: path]`), a given
   option replaces the recorded list. `PropertyDamage.Replay` still takes no
   such option.
5. An exported ExUnit test that re-runs the report's seed passes the recorded
   markers as `external_markers:`. One that replays an artifact reads them from
   the artifact.

## Alternatives

- **Keep asking the caller for the markers.** Rejected: four of the paths have
  no option for them, so a model that relies on atom markers could not replay,
  analyze or export its failures.
- **Load version-15 files with `external_markers: []`.** Rejected: an empty
  list is a guess. For a run that named markers it is wrong, and the replay
  would fail in the way this record removes. The convention for a persistence
  change is that the loader refuses older files.
- **Keep artifact format 1 and add the key.** Rejected: a format-1 file without
  the key would be refused by the shape check with a message about a missing
  key, where a format number names the cause.

## Consequences

- A loaded report replays, re-shrinks, isolates its trigger and exports
  without the caller naming the markers again.
- Saved `.pd` and `.pdtrace` files of version 15 and earlier, and replay
  artifacts of format 1, no longer load. The user captures the failure again.
- Reading an artifact resolves each recorded marker as an existing atom. A
  marker that no loaded module names is refused as an unknown atom, so the
  module that defines it must be loaded before the artifact is read.
- `PropertyDamage.Expansion.for/5` still takes no markers: it reads no report.
