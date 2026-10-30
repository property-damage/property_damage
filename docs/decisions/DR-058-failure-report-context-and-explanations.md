# DR-058: Failure Report Context and Explanations

**Status:** Accepted
**Date:** 2026-10-30

## Context

A reader meets a failure report without the intent behind the model, the check
or the path. The terminal text names a check function and a step label and
nothing more. The author's docs say what the model claims and why the check
exists, and they never reach the report.

Reading those docs is harder than it looks. `Code.fetch_docs/1` returns
`{:error, :module_not_found}` for a module compiled from an `.exs` file, and
test files are `.exs` files. A report that relied on the docs chunk alone
would print a false "no docs" line for a model with good docs.

Two questions follow. What does the report print so that a reader learns what
was being checked, and what happens when the author wrote no doc? And how can
a person, or a language model working for a person, explain a failure from the
run's evidence without PropertyDamage calling a model itself?

This record answers the first question and ships that answer. It also decides
the answer to the second, which a following change builds. The two parts are
marked below.

## Decision, part one: the section, shipped with this record

The items below ship with this record.

1. **A section "What this checks" sits second.** It comes directly after
   Failure and before Minimal Reproduction (and before the Setup section of
   DR-054, when the run has one). The terminal text, the markdown and the HTML
   page all show it. The reader meets what broke, then what it means, then the
   evidence. This amends DR-055 decision 1: the report has six sections. The
   cost: in a CI log tail the section sits a screen or more above the end.

2. **The items and their order depend on the failure kind.** The first item is
   always the meaning of the kind. The `Model` item follows (the model's
   moduledoc), then the subject with its supporting items, then the Path
   items (reference target first), then the `Command` item unless the command
   is the subject or the kind prints none. `FailureReport.Context` builds them.

   | Kind | Subject, then supporting items |
   |------|--------------------------------|
   | `check_failed`, `poll_timeout` | `Check` (found by the check name in the projection's `__checks__/0`, through the `projection` field of the failure; left out when not found), `Projection`, `Property` (the description of the `@invariant` the check validates, when it has one) |
   | `projection_violation` | `Projection` |
   | `diverged`, `did_not_converge` | `Observation` (the `{projection, function}` key), `Relation` (the function `using:` names, only when it names a module function), one `Also differed` item for each other observation that differed, `Projection` |
   | `adapter_error`, `nemesis_error`, `stutter_execution_failed`, `resource_poller_error`, `retry_from_sync_command`, `malformed_adapter_return` | `Command` is the subject and is the only item after `Model` |
   | `setup_failed` | `Command` for a failing setup command; for a failure in `Adapter.setup/1`, nothing after `Model` |
   | `latency_exceeded` | none; no `Command` item |
   | `poll_error`, `idempotency_violation`, `linearization`, `settle_timeout`, `placeholder_resolution`, `unknown` | none; `Command` closes the section |

   `poll_error` has no subject because its failure carries no check name, so
   the report prints the meaning, the model, the Path items and the command.
   The `Command` item that closes the section is the command of the marked
   step, and a failure with no marked step prints none.

3. **A subject prints its whole doc and a supporting item its first
   paragraph.** The first paragraph ends at the first blank line. Docs print as
   written: PropertyDamage never parses the structure of a doc. A heading such
   as `## When it fails` is a writing habit, not an API, and a doc that ignores
   the habit prints correctly. The layout:
   - Labels sit at column 2 and text at column 16.
   - A label of 14 characters or more stands alone on its line. A name
     (`MyApp.Balances.balance_of_bob/2`) follows its label on the same line, or
     on the next line when the label stands alone.
   - Every doc line is indented to column 16, so a `## ` line inside a doc
     cannot start a section in the markdown or the page. A blank doc line
     prints empty.
   - PropertyDamage's own text, the meaning, is wrapped at 80 columns. User
     docs are never wrapped or cut, and nothing caps the length of the section.

4. **Every failure kind has a meaning text.**
   `PropertyDamage.Failure.Explain.meaning/1` has one clause for each kind from
   `PropertyDamage.Failure.kind/1`, and a test enumerates the kinds and fails
   when one has no text. A value that is not a kind raises
   `FunctionClauseError`; the section handles that by printing the text of
   `:unknown`, the kind for a reason PropertyDamage cannot classify. The texts
   of kinds that point at the test rather than the system open with "Unable to
   test the system". This record does not restate the texts.

5. **A missing doc prints one gap line.** The line says what is missing, then
   the fix and where to make it. It prints every time, also for an expansion
   with one entry. A gap line is a place to add a doc, never evidence about the
   failure. The templates, with a `MyApp` example each:

   | When | Line |
   |------|------|
   | A function has no `@doc` | `(no description: add @doc to MyApp.Balances.balance_of_bob/2)` |
   | A function has `@doc false` | `(no description: MyApp.Balances.balance_of_bob/2 has @doc false; replace it with a @doc)` |
   | A module has no `@moduledoc` | `(no description: add @moduledoc to MyApp.Balances)` |
   | A module has `@moduledoc false` | `(no description: MyApp.Balances has @moduledoc false; replace it with a @moduledoc)` |
   | The docs cannot be read | `(no description: PropertyDamage cannot read the docs of MyApp.Balances; declare it with use PropertyDamage.Model.Projection)` |
   | An expansion entry has no `doc:` | `(no description: add doc: "..." to the first entry that MyApp.Model.transfer_paths/2 returns for Transfer)` |

   The unreadable-docs line names the `use` line for the role of the item:
   `use PropertyDamage.Model` for `Model`, `use PropertyDamage.Command` for
   `Command`, and `use PropertyDamage.Model.Projection` for every other label.
   The entry line counts the entry by its index in the list the function
   returned (`first` to `tenth`, then `11th`, `12th`) and names the function
   that returned it; it says `expansions/0` when the choice has no function.

6. **Three `use` macros capture docs at compile time.**
   `use PropertyDamage.Model`, `use PropertyDamage.Model.Projection` and
   `use PropertyDamage.Command` record the docs of the module and its source
   path. `PropertyDamage.Docs.fetch/1` reads that capture
   (`__pd_docs__/0`), then the docs chunk (`Code.fetch_docs/1`), then returns
   `:unavailable`.
   - Every model in the repo is declared with `use PropertyDamage.Model`. A
     bare `@behaviour PropertyDamage.Model` still compiles, and its docs are
     read from the docs chunk when it has one.
   - The `use` must come before every `def` and `defp` of the module,
     including the functions another `use` injects (for example the defaults
     of `use GenServer`). Otherwise the module does not compile: when the
     module closes, a `CompileError` at the line of the first `use` names the
     functions defined before it and says to move the `use` above them.
   - A `@moduledoc` set by a `@before_compile` registered after `use` is not
     captured. The workaround is to set `@moduledoc` in the module body, or to
     register that callback before `use`.
   - Events and adapters are not captured. No source text is stored in the
     compiled module.

   Why a capture: the docs chunk is missing for `.exs`-compiled modules, which
   would print a false gap for a model with good docs.

7. **`Failure.Check` carries `projection`.** It is the projection module whose
   check failed, set for `check_failed` and `poll_timeout`. `name` stays an
   atom. The Failure section prints a `Projection` line. Why: two projections
   can define checks with the same name, and the section must show the doc of
   the one that failed. Residue: the seed library and the failure grouping
   still key on the bare check name. A file saved before the field loads it as
   `nil`, and the persistence version stays 15: the loader fills the field with `nil`
   without a warning.

8. **An expansion entry takes `doc:`.** The doc describes the whole route,
   never one step:

   ```elixir
   {[Pay, PartialRefund, PartialRefund], weight: 2, doc: "refund in two halves"}
   ```

   The doc travels inside the entry, so a realized choice carries the doc of
   the entry it realized, and shrinking cannot attach it to another entry. A
   realized choice also records `function`, the model function that returned
   the entry, so the gap line can name it. `doc:` on a leaf is warned about
   and ignored, like `when:` and `weight:`. This amends the entry option list of
   DR-049 decision 3.

   The Path item reads `"<target>" ran <Root> as steps [i],[j]`, then the doc.
   It names no entry key and no ordinal. A target prints a Path item for a root
   it ran as a listed entry, including the listed identity (`as steps [0]`). A
   target that ran the root as itself without a listed entry (`expansion:
   :identity`, a root absent from the list, or an identity that shrinking
   substituted) prints none.

9. **The JSON format and the HTML page carry the section.** The JSON format
   has a `what_this_checks` key: a list in print order, each item
   `{"label", "name", "text", "missing"}`. `text` is as printed without its
   indent, `name` is `null` for the meaning, and `missing` is true for a gap
   line. The HTML page shows the section open, above the target columns, as
   preformatted text equal to the terminal's.

## Decision, part two: decided now, built in a following change on `main`

None of the items below is built yet. A later record amends this one if the
build changes any of them.

10. **The bundle.** Whenever the HTML page is written, PropertyDamage also
    embeds a bundle: raw JSON in `<script type="application/json"
    id="pd-bundle">`. It is built from the report's structs, never by parsing
    the report text. It holds:
    - `format`, `pd_version`, the fields of the Failure and the meaning text;
    - the items of the section, with their full docs;
    - the listing (targets, steps, entries);
    - the Projections, Setup and Reproduction sections as data;
    - the module docs and source files of the model, the projections, the
      named commands, the named events and the adapters.

    The bundle refers to the report text the page already holds instead of
    copying it. The viewer never renders the bundle; it reads it only to
    resolve citations. Why embedded in the page: source changes after the run,
    the person explaining may have only the CI artifact, and a separate file
    gets lost when the page is forwarded.

11. **Citation ids follow the labels of DR-056.**

    | Id | Cites |
    |----|-------|
    | `failure:<Field>` | a field of the Failure section |
    | `step:<target>:<label>` | a step of a target's listing |
    | `entry:<target>:<label>:<n>` | an entry under a step |
    | `context:<label>` | an item of the section "What this checks" |
    | `section:<title>` | a whole section |
    | `source:<Module>.<fun>/<arity>` | a function, from its first clause's line to the line before the next function |
    | `source:<Module>:<from>-<to>` | a line range, for code outside functions |

    Why function ids: a line range that is off by a few lines still passes a
    bounds check and points at the wrong code, while a function id resolves
    exactly through the line the capture records.

12. **Adapter source is in the bundle.** Many failures come from the test side
    (an adapter or a UI driver), and an explanation that cannot read the
    adapter cannot rank "the test is wrong" against "the system is wrong".
    Test data is treated as non-sensitive. If a run has no source tree, the
    bundle says the source is missing and never omits it silently.

13. **`mix pd.explain PAGE` and its modes.** An engineer runs it in the test
    project.
    - `--prompt` prints the full prompt (the instructions, then the bundle) to
      stdout.
    - `--apply FILE|-` checks the schema of the explanation and every
      citation. On failure it exits 1 with the list of bad citations and
      leaves the page untouched. On success it embeds `<script
      type="application/json" id="pd-explanation">` with the bundle hash and
      the prompt version, replacing any earlier explanation.
    - With no mode it writes `PAGE.explain/bundle.json` and `instructions.md`
      and prints their paths, the prompt version and the bundle hash. When the
      page already holds an explanation for the same hash and prompt version,
      it exits 0 and says so.
    - `--with CMD` pipes the prompt into `CMD` and reads the explanation from
      stdout: the whole output if it parses as JSON, otherwise the last fenced
      `json` block. It applies the explanation. On failure it runs `CMD` again
      with the previous answer and the errors, up to 3 attempts
      (`--attempts`) of 10 minutes each (`--timeout`), and prints `attempt N/3`
      and the reason before each retry. No command is built in;
      `config :property_damage, :explain_with` is the fallback.

    The prompt version is one constant, and changing the instructions bumps
    it. PropertyDamage reads every bundle format it has shipped and refuses
    unknown ones.

14. **The explanation is ranked hypotheses.** Each hypothesis has a rank and a
    likelihood word, and each claim carries citations. `--apply` rejects a
    hypothesis without a rank or a likelihood, and a citation that does not
    resolve (an unknown id, or a source range outside its file).

15. **PropertyDamage ships a skill.** `priv/claude/skills/pd-explain/SKILL.md`
    tells an agent to run `mix pd.explain PAGE` (and stop if the page is
    already explained), read `instructions.md` and `bundle.json`, write
    `explanation.json`, run `--apply`, fix and apply again up to 3 times, and
    report the page path with a summary. The skill holds no rules of its own:
    the instructions live in PropertyDamage because they depend on the bundle
    format. A project links the skill from the installed dependency, so it
    always matches the installed version. People use the skill or `--with`; the
    `mix pd.explain` modes are the interface the skill uses.

16. **A page with an explanation opens on two tabs.** The tabs are Explanation
    and Run, with Explanation first. Every citation links to its evidence and
    highlights it, and a `source:` citation unfolds the cited lines. The tab
    opens with the fixed line "Hypotheses ranked by a language model from this
    run; each claim links to its evidence." Hypotheses print as "Hypothesis 1
    (likely)", never as "Cause", and the tab has no footer. A page without an
    explanation looks as it does today.

17. **No model-calling code lives inside PropertyDamage.** `mix pd.explain`
    prints instructions and applies an explanation. Whatever produces the
    explanation runs outside, on request only.

## Consequences

- Pages grow to about 150 to 300 KB once they carry a bundle. This is an
  estimate; the build measures it. The guides recommend setting
  `PD_REPORT_HTML` in CI so every failure leaves a page. The default of
  PropertyDamage stays off.
- `--with` in CI costs money on every failure, so it runs only when asked, and
  the docs say so.
- This is the one exception to DR-057: the page carries a bundle and an
  optional explanation that the terminal text does not. The rendered report
  itself still equals the terminal text.
- DR-055 decision 1 is amended (a sixth section), and the entry option list of
  DR-049 gains `doc:`.
- An adapter that inlines a credential or an internal host name carries it
  into every page. The change that builds the bundle decides whether such
  literals are masked.
- A gap line is missing context to whatever reads the report, never evidence
  about the failure. A reader (human or model) must not rank a gap line as a
  cause.
- The seed library and the failure grouping still key on the bare check name.
- A module whose beam lost its attributes (for example to `:beam_lib.strip/1`)
  has no capture. If it also has no docs chunk, the section prints the
  unreadable-docs line for it.
- A module declared with a bare `@behaviour` and compiled from an `.exs` file
  prints the unreadable-docs line, because it has neither a capture nor a docs
  chunk. The line names the `use` that fixes it.
- A module with a function above its `use` of a capturing macro no longer
  compiles, with the error of decision 6.
- Persistence stays at version 15. A reader of an old file sees `nil` for the
  projection of a failed check and no Projection line.

## Alternatives considered

- **The check name as a `{projection, check}` tuple.** Rejected: it ripples
  into replay results, seed-library file names and `pd.replay` output.
- **Leaving the duplicate-name gap.** Rejected: the section would show the
  wrong doc, or two docs, exactly when the reader needs the right one.
- **A `use` macro without migrating every model.** Rejected: that leaves two
  ways to declare a model.
- **`Code.fetch_docs/1` alone.** Rejected: every `.exs` model would print a
  false gap.
- **Storing source text in the compiled module.** Rejected: the bundle reads
  the file at failure time instead.
- **Printing the Path gap only when a target's route differs from the
  reference's.** Rejected: the line then appears and disappears with the run,
  and a reader cannot tell a missing doc from a same route.
- **Naming the route by key or ordinal ("route 2 of 3", "alternate").**
  Rejected: it invites questions about the other routes, and it is wrong when
  the reference itself ran an expansion.
- **Parsing the structure of a doc into cards.** Rejected: docs print as
  written, and the structure would become an API that a doc can break.
- **The section after Projections, before Reproduction.** Rejected: the
  meaning of the failure would follow the evidence it explains.
- **The section last.** Rejected: it moves the replay command up from the end
  of the report.
- **Lifting the section to the top in the HTML only.** Rejected: the page and
  the terminal would differ.
- **A terminal-only length cap.** Rejected: it breaks the one text everywhere.
- **A flag that hides the section.** Rejected: the report would have two
  layouts to test and to read.
- **Opaque citation ids such as `e17`.** Rejected: they are unreadable in raw
  JSON and against the terminal text.
- **A parser that reads the report text to build the bundle.** Rejected: the
  report text does not mark every boundary; an adapter's setup lines, for
  example, read as part of the previous target's last step.
- **Gzip plus base64 for the bundle.** Rejected: it is unreadable without a
  tool, and CI artifacts are zipped anyway.
- **Writing the bundle only on request.** Rejected: a page explained later
  would need source that has since changed.
- **One command that calls a model itself.** Rejected: it puts model-calling
  code inside PropertyDamage.
- **A pipe-only interface.** Rejected: it loses the retry loop.
- **The logic in the skill.** Rejected: the rules would live outside the
  version they depend on.
- **An annotation API with selectors instead of a language model.** Rejected:
  it is heavy and still tied to log shapes.
- **Writing the bundle beside the page.** Rejected: it is lost when the page is
  forwarded.
