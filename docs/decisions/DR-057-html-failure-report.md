# DR-057: HTML Failure Report

**Status:** Accepted
**Date:** 2026-10-29

## Context

DR-055 and DR-056 fix what the terminal failure report shows and how it is
built. A long report is still hard to read in a terminal: a comparison
failure lists two targets one after the other, every step carries its log
lines and events, and the same line repeats once per settle attempt. A reader
wants the targets side by side, steps that open on demand, and the differing
events of one step in one place.

A reader also wants to keep a failure: attach it to a ticket, send it to a
colleague, or collect the failures of a whole test suite and browse them. A
terminal scroll-back does none of that.

Three questions follow. What does the page hold, so that it cannot disagree
with the terminal report? Where does a page go, and what happens when it
cannot be written? How are several pages browsed?

## Decision

1. **The page is one self-contained HTML file.** It holds the report's
   terminal text without color, embedded as JSON data, and the viewer that
   reads it, embedded at compile time from `priv/failure_report/viewer.html`
   (`FailureReport.HTML.render/1`). The page loads nothing from the network
   and opens from disk: the viewer is one inline script and one inline style
   with no external reference.

2. **The page is built from the terminal text, not from the report structs.**
   `render/1` calls `Formatter.format(report, :terminal, color: false)`, the
   layout `format_failure` prints (DR-056), so the log tag filter of DR-054
   applies as it does there: the report's `log:` option, or `PD_LOG`, which
   replaces it. The viewer parses that text in the browser. The page body
   therefore carries nothing the terminal text does not carry, and the two
   cannot disagree. The viewer adds only reading aids:
   - one column per target, with a step's events compared across targets;
   - steps that unfold to their log lines and events;
   - repeated log lines collated into one row with a repeat count;
   - the detail under a log line folded by its indentation;
   - a chip per log tag that shows or hides that tag's lines.

   The browser tab title and the file name are the one place the page says
   more than the terminal text: they name the failing target after its
   adapter, as `Adapter.name`, when the name does not already say it (two
   suites can run one model under one target name against different
   adapters). Nothing in the page body carries that qualifier.

3. **The directory comes from a run option and an environment variable.**
   The run option `report_html: dir` (default `false`, which writes no page)
   and the environment variable `PD_REPORT_HTML` choose it. When
   `PD_REPORT_HTML` is set and not blank, it replaces the option; a blank
   value counts as unset. A failing run writes its page into that directory.
   An error while rendering or writing the page, such as a directory that
   cannot be created or an invalid `PD_LOG`, costs one logged warning, never
   the report: the run returns its report unchanged.

4. **One page per failing run, named after what failed.** The file name joins
   the model, the failing target, the failure kind and the seed
   (`seed<N>`) with `-`, and replaces every character outside letters,
   digits, `.`, `_` and `-` with `_`. The target is the adapter-qualified name
   of decision 2. A report with none of these facts is named
   `failure_report.html`. A later failure with the same model, target, kind and
   seed therefore replaces the earlier page instead of adding a second. A
   write goes to a temporary file in the same directory and is renamed into
   place, so a reader sees the old file or the new one, never half of one.

5. **`write/2` keeps an index current, and `write_index/1` rebuilds it.**
   `FailureReport.HTML.write/2` rebuilds `index.html` in the directory after
   each page. `write_index/1` rebuilds it from the report pages present, in
   file name order; a page whose title cannot be read stays out. Runs in
   separate processes that write into one directory call it afterwards, since
   two writers can each list the directory before the other's page lands. The
   index is built from `priv/failure_report/index.html`. It shows one report
   at a time in a frame, with buttons to move between them. The left and
   right arrow keys also move between reports while the index page has focus;
   a browser may keep the key presses inside the report frame, so the buttons
   are the dependable way.

6. **The viewer and the index template ship in the Hex package.** Both sit
   under `priv/failure_report/`, and the package `files` list names `priv`.
   The compile-time embedding reads them, and the build recompiles the module
   when either changes.

## Consequences

- A failure keeps its whole report in one file that needs no server, no
  network and no tool beyond a browser.
- The terminal text is the single source of the report's content. A new kind
  of line added to the layout reaches the page without a change to the
  Elixir side.
- The viewer parses text, so a change to the printed layout can break a
  reading aid without breaking any terminal output. The viewer refuses text
  with no `## ` sections.
- An error in the page writer cannot hide the failure report: the page is
  written after the report is built, and any error while rendering or
  writing it costs one warning.
- Pages accumulate in the directory until someone removes them. The index
  lists every page present, so a stale page from an earlier run shows up
  until it is deleted.
- The package grows by the viewer and the index template.
- The package contents check in `scripts/check_package_contents.sh` admits
  `priv/`.

## Alternatives considered

- **Render the page from the report structs in Elixir.** It would give the
  page direct access to every field. It would also be a third renderer beside
  the two of DR-056, and each new kind of line would be written three times
  and could drift from the terminal text. Parsing the terminal text keeps one
  source, at the cost of a viewer that depends on the printed layout.
- **Load the viewer from a CDN or from a separate file.** It would keep each
  page small. It would also break opening one file from disk: a saved page
  attached to a ticket would show nothing offline or away from its sibling
  file. Embedding the viewer in every page costs size and removes both
  failures.
- **One page per run and no index.** It is simpler, and a test suite with
  several failures then leaves a directory of pages to open one by one. The
  index trades one more generated file for browsing them in place.
- **A fixed directory instead of an option.** It would need no configuration,
  and it would write into a place the user did not choose. An option per run
  plus an environment variable for a whole suite lets a developer turn pages
  on for one command without editing code.
- **Fail the run when the page cannot be written.** It would make a missing
  directory loud. It would also lose the report the run exists to produce, so
  a warning is the cost instead.
