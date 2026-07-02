# DR-033: Run Trace as the Execution Record

**Status:** Accepted
**Date:** 2026-07-02

> Part of the run-comparison campaign (with DR-034, DR-035, DR-036), which
> replaces the deleted `PropertyDamage.Diff` surface. This record defines the
> unit the comparator consumes: the full, outcome-neutral record of one run.

## Decision

1. **`PropertyDamage.RunTrace` is the execution record of a single run,
   independent of outcome.** It carries:

   - *Identity / reproduction:* `seed`, `run_number`, `run_nonce`,
     `mint_epoch` (DR-034), `model`, `adapter`, UTC `timestamp`, best-effort
     `source_revision` (`{sha, dirty?}` via the `git rev-parse --verify` +
     `status --porcelain` pattern already used by `mix pd.bisect`, with an
     explicit option override; `nil` outside a git checkout).
   - *Plan:* `plan` (the `%Sequence{}` this run executed), `plan_source`
     (`:generated` — a pure function of the effective seed — or `:shrunk` — a
     shrinker product, not regenerable from the seed), and `plan_fingerprint`
     (DR-036 canonical identity).
   - *Execution record:* `executed` (the concrete commands actually sent,
     post placeholder/mint resolution, keyed branch-aware by
     `%Sequence.Position{}`), `event_log` (the complete list of
     `EventLog.Entry` with per-entry provenance), `command_labels` (flattened
     index → label, computed as the report does today), and `outcome`
     (`:pass | {:fail, reason}`).

   The field is named `plan`, deliberately **not** `original_sequence`: a
   report-embedded trace describes the shrunk run, whose plan is the shrunk
   sequence, while `FailureReport.original_sequence` keeps meaning the
   generated plan of the failing exploration run. Reusing the name would give
   it two meanings.

2. **`RunTrace` owns the structural step-query interface.** `steps/1` and
   `event_entries_at/2` move from `FailureReport` to `RunTrace` with their
   branch-aware `%Sequence.Position{}` semantics unchanged; `%FailureReport.Step{}`
   becomes `%RunTrace.Step{}` and gains one field: `executed_command` (the
   concrete resolved command from `executed`, `nil` when not captured), while
   `command` keeps meaning the plan's symbolic command so existing renderers
   and exporters are unaffected. A step describes any run, passing or failing;
   `failed?` is simply never true on a passing trace.

3. **`FailureReport` composes a `RunTrace` and keeps only failure-specific
   concerns.** The report embeds the trace of **the run the report
   describes**: the shrunk minimal reproduction when its re-execution
   reproduced the failure, otherwise the original failing run (this is the
   existing non-reproduction fallback in `handle_failure`, which the previous
   draft of this decision contradicted by saying "shrunk" unconditionally).
   Field disposition rule, decided here rather than left open:

   - *Deep structures live once, on the trace:* the report's `event_log` and
     `shrunk_sequence` struct fields are removed; `FailureReport.event_log/1`
     and `shrunk_sequence/1` become accessors over `trace` (clean break,
     pre-v1; all in-tree callers updated). `steps/1` / `event_entries_at/2`
     delegate to the trace.
   - *Scalar identity is duplicated:* `seed`, `run_number`, `model`,
     `adapter`, `timestamp` stay as report fields (they are the report's
     locator surface, printed and pattern-matched everywhere; duplicating
     scalars is harmless, duplicating structures is not).
   - *Failure/shrink overlay stays on the report:* `original_sequence` (the
     generated plan), `failed_at_index`, `failure_type`/`failure_reason`/
     `check_name`/`failure_message`, invariant identity, error origin,
     state snapshots (`state_before_failure`, `state_at_failure` — state rows
     are deferred, see DR-035), `idempotency_violation`, `poll_timeout_info`,
     `branch_id`, `linearization`, shrink statistics, `assertion_fires`.
     `failure_step/1` and `failure_index/1` remain report-level locators
     defined over the embedded trace.

4. **Capturing `executed` is new executor work, always on.** The executor
   already produces each `resolved_command` (the concrete command passed to
   the adapter) and discards it after updating projections; it now
   accumulates them into the run result keyed by the current structured
   position, including inside branch workers (merged with the branch states).
   Cost is bounded by the same order as the event log, so this is not gated
   behind a capture flag — which also means the failing run's trace is
   complete for free when a report is built.

5. **Full traces are captured on demand, not retained per exploration run.**
   Ordinary exploration keeps its current memory profile; a `RunTrace` is
   materialized only (a) on the explicit capture path `RunTrace.capture/1`
   (DR-035), and (b) for the run a `FailureReport` describes. `RunTrace`
   owns capture because capture produces a trace; `RunComparison` (DR-035)
   only consumes traces.

6. **Persistence.** A `RunTrace` serializes standalone — same binary framing
   as reports (`"PD"` magic, version byte, crc32, compressed ETF payload)
   with the payload gaining an explicit `kind` (`:run_trace` or
   `:failure_report`); loaders dispatch on `kind`, not file extension
   (`.pdtrace` is the suggested convention for trace files). The persisted
   report format advances v3 → v4 (the report now embeds a trace). Loading a
   pre-v4 report **synthesizes** the embedded trace from the legacy fields
   (`shrunk_sequence` → `plan` with `plan_source: :shrunk`, `event_log`,
   `seed`/`run_number`/identity; `run_nonce`, `mint_epoch`, `executed`, and
   `plan_fingerprint` are `nil`), so `steps/1` keeps working on old files
   under the domain's tolerant-loading rules. The persistence-time
   dependency-version capture and struct-drift checks extend to walk the
   embedded trace.

## Context

The deleted `PropertyDamage.Diff` failed because it had no honest input: a
passing run returned `{:ok, stats}` with no record, and a `FailureReport` is
a *shrunk* artifact — two independently shrunk failures are different plans
that cannot be aligned. The framework had no first-class "what one run did"
value at all: the executor's result map is ephemeral, and the report
duplicates fragments of it (event log, sequences, snapshots) with
failure-specific fields mixed in. Every consumer that wanted the execution
record (timeline, formatter, fingerprint, exporters, forensics) went through
the report, so passing runs were structurally invisible.

`RunTrace` gives the record a name and one owner. The composition (report =
trace + failure overlay) was explicitly pulled into this campaign rather than
deferred, because the alternative — `RunTrace` with its own step
implementation beside the report's — would fork the just-stabilized step
interface (the Phase-B/8b work) into two drifting copies.

Trap for implementers, worth restating: **the report's trace is not the
comparator's input for regression work.** The report's trace describes the
shrunk reproduction (`plan_source: :shrunk`); a regression diff wants the
*full failing run's* trace (`plan_source: :generated`), captured via the
DR-035 path. The two share a type, not a purpose.

## Consequences

- New `lib/property_damage/run_trace.ex` (+ `run_trace/step.ex`);
  `failure_report.ex` shrinks to composition + overlay; `timeline.ex`,
  `formatter.ex`, `fingerprint.ex`, `analysis.ex`, `diagram.ex`, exporters
  re-point at `%RunTrace.Step{}` (mechanical rename plus the accessor
  migration for the removed `event_log`/`shrunk_sequence` fields).
- Executor result gains the `executed` accumulation (linear loop, branch
  workers, branch-state merge).
- `Persistence` gains trace save/load and the v4 report format with v3
  synthesis on load.
- The characterization tests locking `FailureReport.steps/1` output must be
  written against the pre-move behavior first; the move must not change any
  existing rendered output.

## References

- `openspec/specs/failure-analysis/spec.md` (Run Trace as the Execution
  Record; Structural step query interface), `openspec/specs/persistence/spec.md`
  (Run Trace Persistence).
- Depends on DR-036 (deterministic identity, plan fingerprint). Consumed by
  DR-035 (Run Comparison). Run identity fields defined by DR-034.
- Supersedes the execution-record duplication implied by the failure-report
  requirements as they stood before this campaign; the `Diff` supersession
  itself is recorded in DR-035.
