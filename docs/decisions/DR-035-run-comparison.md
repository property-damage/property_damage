# DR-035: Run Comparison over Full Traces

**Status:** Accepted
**Date:** 2026-07-02

> Part of the run-comparison campaign (with DR-033, DR-034, DR-036).
> Supersedes the failure-analysis domain's "Diff-Based Debugging" requirement
> and deletes `PropertyDamage.Diff`.

## Decision

1. **Delete `PropertyDamage.Diff` outright; `PropertyDamage.RunComparison`
   replaces it, consuming `RunTrace` records (DR-033).** The old module was
   broken by construction: a passing run produced no report to compare;
   `compare_reports/2` aligned two *shrunk* sequences (two independently
   shrunk failures are different plans); alignment was naive index-zip (one
   insertion cascades every later row into "different"); state was two-point;
   there was no comparability guard; and nothing in `lib/` called it. Its
   pure value-diff and formatting helpers may be re-derived where useful, but
   the surface is removed, not deprecated (pre-v1 clean break).

2. **Comparability guard, on fingerprints.** All compared traces must share a
   plan identity: equal `plan_fingerprint` (DR-036) and equal model. Raw
   `==` on sequences is explicitly *not* the oracle — before DR-036 it could
   never hold across captures, and even after, the fingerprint excludes the
   derived registry and gives one named, testable definition of "same plan".
   A differing `plan-generated` command-field value between runs that claim
   the same plan (DR-034) is a second, cheap tripwire. On violation the
   comparison refuses (or clearly flags, for the tripwire) rather than emit a
   misleading diff. Shrunk-plan traces (`plan_source: :shrunk`) are
   comparable only against traces of the same shrunk plan; a shrunk trace
   never aligns against a full run — a shrunk sequence is a different,
   smaller plan.

3. **Two-level rows, positional command alignment, LCS event alignment.**
   Rows are commands and their events; SUT-call/request-body rows are out of
   scope (no adapter hook now). Commands align by branch-aware
   `%Sequence.Position{}` from `RunTrace.steps/1` — identical across
   same-plan runs by construction, so command alignment is trivial and
   total. Events *within* a command align by longest-common-subsequence
   keyed on the event struct module: same module = one row whose fields are
   diffed; different module = insert/delete. A model may supply a per-event
   identity function to override the module key (for models emitting many
   same-module events per command). Entries with no command index (injector,
   telemetry) belong to no step and are **excluded from comparison in this
   version** — stated as a limit, not discovered as one; nemesis and
   injected events attributed to commands (DR-030) do participate.

4. **Discriminative classification is core and emits a ranking.** Runs
   partition by outcome into passing and failing groups (columns are
   otherwise peers — any run may be compared against any other). For each
   aligned field difference: varies within the passing group → `incidental`;
   stable within each group but different between groups → `discriminating`;
   otherwise → `weak`. The output is a ranked suspicion list (most
   discriminating first), not just cell coloring. With N=2 the analysis
   degrades to a plain pairwise diff. Provenance (DR-034) shades everything:
   `run-scoped` differences render as correlation identifiers and are never
   suspicious; `server-resolved` differences are the ranking's subject;
   `plan-generated` differences are comparability violations. Two
   robustness rules: when the failing group contains multiple distinct
   failure signatures, the comparison surfaces that (pooling unlike failures
   silently would corrupt "stable within group"); and same-module event runs
   differing only in repetition count (settle/probe polling, whose count is
   timing-dependent) are down-ranked as incidental rather than reported as
   inserted-event noise.

5. **Capture is `RunTrace`'s job; comparison is `RunComparison`'s.**
   `RunTrace.capture(model:, adapter:, seed:, run_number:, run_nonce:, ...)`
   runs ONE full, unshrunk plan and returns its trace, pass or fail (the
   comparator never runs a SUT). `RunComparison.compare([trace], opts)`
   returns a pure `%RunComparison{}` (aligned table + ranking + header).
   `RunComparison.investigate(model:, adapter:, seed:, run_number:, runs: N)`
   is flakiness sugar: same plan, N captures, a fresh recorded `run_nonce`
   per capture (collision-free on a shared SUT), returning the traces (and
   their comparison). Salt policy by use case: flakiness = distinct nonces;
   regression across versions with a fresh SUT per side may share a nonce
   for the cleanest like-for-like.

   > **Superseded (2026-07-03).** This DR originally kept
   > `PropertyDamage.Flakiness` as a separate cheap outcome-level detector,
   > with "deepening it onto traces" left as future work. That module has since
   > been removed and its capability folded into `RunComparison`: `investigate/1`
   > is the single-seed flakiness tool, `scan/1` is the corpus scan (the
   > `discover_flaky` replacement, per-seed verdicts with bounded memory), and
   > `outcome_summary/1` is the cheap outcome-level view (pass/fail counts +
   > distinct failure signatures) both are built on. There is no longer a
   > separate flakiness module.

6. **One self-contained HTML artifact.** `RunComparison.to_html/1` renders a
   single HTML file: inline CSS/JS, no external hosts (repo self-sufficiency
   rule), readable with JavaScript disabled (static pre-rendered table; JS
   adds only accordion collapse and quick-select column swap). An embedded
   `<script type="application/json" id="run-comparison-data">` block is the
   machine-readable source of truth. **The JSON encoding is a defined,
   versioned schema** — `%RunComparison{}` contains atoms, tuples
   (`{:branch, id}` sections), and arbitrary structs that `Jason` cannot
   encode as-is: positions encode as `{"section": "prefix" | "suffix" |
   {"branch": id}, "offset": n}`, structs as `{"struct": "Module", "fields":
   {...}}`, non-JSON scalars via `inspect`, and the blob carries a
   `schema_version`. Golden-file tests lock the HTML and assert the JSON
   round-trips and contains no external URLs. Columns are runs grouped
   pass/fail with the subject run fixed and references in a horizontal
   accordion; semantic-difference rows highlight amber (distinct from
   pass/fail green/red) with per-attribute added/removed/changed marks. A
   reproducibility header names model, adapter, UTC timestamp, source
   revision, seed, run number, and per-run nonce/epoch, with `mint_per_run`
   correlation ids surfaced prominently (they are the join key into SUT
   logs). No sibling `.json` file is written.

## Context

The use cases are regression localization ("this plan passed on commit A and
fails on commit B — where do the runs diverge?") and flakiness localization
("this plan fails one time in five — what differs between the passing and
failing executions?"). Both need full, unshrunk, same-plan runs as input —
which is exactly what `FailureReport` is not, and why the report-consuming
`Diff` could never work. `RunTrace` (DR-033) supplies the input;
deterministic identity (DR-036) makes "same plan" decidable; provenance
(DR-034) separates correlation noise from behavioral signal so the ranking
points at causes rather than at every UUID that legitimately differs.

Settled scope decisions, restated so they are not relitigated casually:
two-level rows (no raw SUT request/response capture hook yet); state rows
deferred (they would pull in the projection-lifecycle work — `RunTrace`'s
per-position structure leaves a clean slot); event identity defaults to
struct module with a model override; the discriminative classifier is core
(not a post-processing extra); one HTML file, no sibling JSON.

`Differential.Equivalence`'s name-based `@structural_ignore_fields`
normalization (`:id`, `:uuid`, `:request_id`, ...) is today's ad-hoc answer
to the same noise problem provenance solves semantically; converging
Differential onto provenance classification is deliberate future work.

## Consequences

- Delete `lib/property_damage/diff.ex` + `test/property_damage/diff_test.exs`
  (zero other callers, verified). New `lib/property_damage/run_comparison.ex`
  (+ submodules for alignment, classification, HTML rendering);
  `RunTrace.capture/1` beside the trace type.
- The comparison core is pure data-in/data-out and testable without a SUT:
  guard tests (unequal fingerprint refuses; mixed failure signatures
  flagged), alignment tests (inserted event yields one LCS gap, not a
  cascade), classifier tests (2 passing + 1 failing where one field is
  stable-in-pass/different-in-fail must rank first; a field varying across
  passes must rank incidental; settle-repetition noise down-ranked).
- HTML golden files are snapshot-fragile — locked early, updated
  deliberately; the embedded JSON schema version gates machine consumers.

## References

- `openspec/specs/differential-testing/spec.md` (Run Comparison),
  `openspec/specs/failure-analysis/spec.md` (Run Comparison Supersedes Trace
  Diffing).
- Depends on DR-033 (RunTrace), DR-034 (nonce, provenance), DR-036
  (fingerprint). Supersedes the pre-campaign "Diff-Based Debugging"
  requirement. Related: DR-022 (progress/observability precedent for
  consumer-facing artifacts), DR-030 (command-correlated injector events —
  what makes injected events comparable at all).
