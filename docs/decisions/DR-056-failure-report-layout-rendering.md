# DR-056: One Report Layout, Two Renderers

**Status:** Accepted
**Date:** 2026-10-27

## Context

DR-055 decided what the terminal and markdown failure reports show: five
sections, one step label in every section, both sides of a comparison, the
events under their step, full projection state, and a Reproduction section
that binds `targets` once. It left open how the formatter builds them and
several details the implementation has to fix.

The formatter printed each format with its own code, each walking the report
again, and the two had drifted: the markdown had its own headings and printed
tables where the terminal printed listings. DR-054 adds log lines under each
step and a Setup section, so every new kind of line would have been written
twice.

DR-055 also leaves these questions open:

- A leaf's position names its root by the root's index as generated
  (`{:leaf, root_id}`), and shrinking does not renumber it. A shrunk report
  whose failing root is printed as `[0]` would label its leaves `[2.0]` and
  `[2.1]`.
- A branching run's suffix commands need a label that differs from every
  prefix label.
- A comparison failure is localized to a root, while the variant may have run
  that root as leaves.
- `EventLog.Entry.timestamp` is monotonic time, and a `RunTrace` records no
  monotonic run start to count event offsets from.
- The variant's `state_at_failure` is the snapshot after the run finalized, so
  it holds folds that happened after the failing boundary. The reference's
  state is the DR-040 cut at the boundary.
- `Failure.Divergence` drops the time the comparison waited, which decision 3
  prints.
- The formatter options `:show_event_log`, `:show_state`, `:show_original`,
  `:max_events` and `:max_commands` have no caller in the library.

## Decision

1. **The report is built once as plain data and printed twice.**
   `PropertyDamage.FailureReport.Layout.build/1` reads a report and returns the
   banner, the seed and the sections in order. Each section is a heading, the
   language of its markdown fence, and a list of lines. A line is a labeled
   field, a listing header, a step, an event, a note, a projection header, a
   projection attribute, or a comment, code or text line of Reproduction.
   Values stay terms in the layout. `PropertyDamage.FailureReport.Render` prints
   the layout as terminal text, with or without ANSI color, and as markdown.
   The layout holds no ANSI codes and no markdown. A new kind of line (DR-054's
   log lines) or a new section (Setup) is added to the layout and to the one
   function that prints each line.

2. **Labels come from `Sequence.Position.label/2`.** Every index counts from 0.
   A root is `[i]`, a branch command `[branch b.i]`, and a setup or teardown
   command `[setup i]` or `[teardown i]`. `label/2` takes, beside the position,
   the reading-order index (`Sequence.indexed/1`) of the root the command is or
   belongs to:
   - A leaf is `[i.j]`, where `i` is the reading-order index of the root it is
     listed under and `j` its offset among that root's leaves. The generated id
     inside `{:leaf, root_id}` never prints.
   - A suffix command is `[n]`, where `n` is its reading-order index: the
     number of prefix commands, plus every branch command, plus its offset in
     the suffix. This is also the executor's command index for that command, so
     the label equals `failed_at_index` for a failure in the suffix, as it does
     in the prefix. No suffix label equals a prefix label.

   `Position.describe/1` keeps its prose for its other callers.

3. **One failing step carries one label everywhere.** For `:diverged` and
   `:did_not_converge`, the failing step is the root at the failing boundary,
   `[i]`, also when the variant ran it as leaves: the root's own line carries
   `►`, and its leaves follow it unmarked. Both listings mark it. For a setup
   command's failure, the failing step is `[setup i]`. For every other failure,
   it is the step the failure was localized to, a leaf `[i.j]` when a leaf
   failed. The Failure section's `At` field, every `►` line and the Projections
   heading print that one label. A failure that no step is tied to (an adapter
   `setup/1`, a latency budget, a whole-run or teardown check, a linearization
   failure) prints no `►` and no `At` field. The word after `◄──` is
   `diverged`, `did not converge` or `failed`.

4. **A root line names what the target ran there.** A root that ran as leaves
   names its entry (`as Refund[1]`); a root that ran as itself in place of an
   entry says `as itself (identity, by shrinking)` or
   `as itself (identity, forced)`. A command's `label/2` text follows as
   `# label`.

5. **Events print under their step, with an offset from the target's run
   start.** The run start is the earliest timestamp in that target's own event
   log, setup entries included, because the trace records no monotonic run
   start (`RunTrace.timestamp` is wall-clock time). A step's events print in
   timestamp order, stable for equal timestamps, as `+S.SSs`, then `event` for
   an event the command returned or the source badge of any other source
   (`INJ`, `NEM`, `MOC`, `STU`, `POL`, `TEL`, `EMT`), then the event. Entries
   with no command print after the listing under "Not tied to a command",
   only when there are some.

6. **Both sides of the Projections diff come from one source.** For a
   comparison failure, the `-` side is `reference_state_at_failure` and the `+`
   side is `RunTrace.state_at(trace, Position.prefix(failed_at_index))`, the
   variant's state cut at the same boundary (DR-040), computed when the report
   is printed. Nothing the variant folded after the boundary shows.
   `state_at_failure` keeps its meaning, and the JSON format is unchanged. For
   every other failure, the sides are `state_before_failure` and
   `state_at_failure`. Each projection's header names the event folded last on
   the `+` side, at or before the failing step's last fold; a trace without
   fold ordinals names the failing step's last event.

7. **The Failure section prints these fields, in this order:** `Failure` (the
   kind in words); `Observation` for a comparison, or `Invariant` and
   `Property` (DR-026) when the invariant's name differs from the check's, then
   `Check`; `Target` when a run of several targets failed other than by
   comparison; `At`; the kind's own fields; `What went wrong` and `Hint` or
   `Location` for a failure in test code; one `Also differed` line per further
   observation; one `Other failure` line per other failure of the run, with
   the further observations of a listed comparison failure under it; and
   `Shrink` when the shrinker stopped at a budget. The kind's own fields are
   `Reference`, `Variant`, `Compared` and `Mismatch` for a divergence;
   `Variant` and `Compared` for a failure to converge; `Statistic`, `Bound`,
   `Limit`, `Measured` and `Verdict` for a latency budget; `Cause` and
   `Message` for a setup failure; one `Attempt` field per attempt and
   `Difference` for an idempotency violation; `Waited`, `Trigger`, `Predicate`
   and `Final state` for a poll timeout; `Message` otherwise.
   - `Failure.Divergence` gains `waited_ms` and `within_ms`, set where the
     comparison measures them. `Compared` reads
     `using <relation>, still differing after N ms (bound M ms)`, or
     `still pending` for a failure to converge. A failure to converge records
     no relation, so its `using:` is read from the projection's `@compare`
     declarations; `==` prints when there is none. A version-15 file saved
     before the fields existed loads with each of them `nil`, and `Compared`
     then says `at the bound (M ms)`.
   - `Mismatch` prints only the reason a relation failed with: a
     `ComparisonMismatch` holding a message, or another exception.
   - Every value starts at one column, two spaces past the longest label, and
     the lines after a value's first continue at that column.

8. **Every value is printed by one `inspect/2` call** with `pretty: true`,
   `limit: :infinity` and `printable_limit: :infinity`, fitted to a 100-column
   line counted from the column the value starts at. A colored report adds
   `syntax_colors:`; a `-` or `+` line is red or green and gets no syntax
   colors. Color never changes a line's visible text. The banner box is 72
   columns wide, and a colored box line is the plain line wrapped in color
   codes, so both banners have one width with and without color.

9. **Markdown is the plain terminal layout in markdown dress.** It opens with
   `# BUG DETECTED!`, or `# TEST CODE ERROR` and a line saying the system is
   not at fault, then `Seed: <seed>`. Its `## ` headings are the terminal's,
   in the same order, and each section's body is one fenced block whose text
   equals the terminal's body without color. Projections is fenced `diff` and
   Reproduction `elixir`, so the labels between the Reproduction calls are
   Elixir comments (`# Rerun from the seed:`), and a report without an
   artifact ends with a line that starts `(no artifact`, a refused artifact
   included.

10. **Reproduction binds the targets once.** When `targets` is not empty, the
    section opens with `targets = <targets_source/1>`. Every call prints
    `targets: targets` in place of the list. A pid, reference, port or function
    found in an entry's options, in a map that is not a struct, or in a list is
    named by its path (`config.recorder`, a list element by its index) on one
    comment line under the binding, which says to rebuild the list as the test
    does.

11. **`Formatter.format/3` keeps its signature.** The terminal format reads
    `:color` only and the markdown format reads no option. `:show_event_log`,
    `:show_state`, `:show_original`, `:max_events` and `:max_commands` are
    dropped: every step and every event prints. The JSON and compact formats
    are unchanged.

## Consequences

- A change to the layout is made once and shows in both formats; markdown
  cannot drift from the terminal text.
- A leaf, a suffix command and a comparison's failing root each carry the same
  label in the Failure section, the listings and the Projections heading.
- Event offsets are relative to the first event the target recorded, not to the
  moment the run began; an adapter that is slow to return its first event
  shifts nothing, because every offset of that target counts from the same
  start.
- Printing the Projections section of a comparison failure folds the variant's
  trace once more. The cost is one fold of one run, paid only when the report
  is printed.
- A report prints every step and every event; a long run prints a long
  report. A reader who wants a short summary uses the compact format.
- Tests that matched the removed sections, the old labels or the old wording
  of the footer labels (`Replay the shrunk failure:` is now a comment line)
  match the new layout.

## Alternatives considered

- **Label a leaf by the root id its position holds.** Rejected: the id is the
  root's index as generated, so after a shrink it names a root that is not in
  the report, and `[2.1]` would sit under `[0]`.
- **Number the suffix after the prefix alone (`[p + i]`).** Rejected: it skips
  the branch commands, so the label would not be the executor's command index,
  and a suffix failure's `At` would differ from `failed_at_index`.
- **Mark the variant's last leaf for a comparison failure.** Rejected: a
  comparison judges the root's boundary, not a leaf, and the reference's
  listing has no leaf to mark.
- **Take the variant's side from `state_at_failure`.** Rejected: it holds what
  the variant folded while the run finalized, after the boundary, while the
  reference's side does not, so the diff would show differences the
  comparison never saw.
- **Store the variant's cut state on the report.** Rejected: the trace already
  derives it, and a new field would change the JSON format and the persistence
  shape for a value the printer can compute.
- **Keep a separate markdown renderer.** Rejected: two renderers of one layout
  drifted once already, and DR-055 decision 11 asks for the same layout.
- **Print commands and events with their short module name
  (`Transfer {...}`).** Rejected: DR-055 decision 10 prints every value with
  one `inspect/2` call, and a short name hides which module a struct is.
