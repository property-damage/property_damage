# Handoff ledger: w10-facade-split

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seed this
from whatever produced it: a grill-me ledger, a campaign wave contract, a
ticket, or by hand.

Source: the maintainer's design rulings of 2026-11-09 for the facade split (contracts recorded in the design record, section "facade split"), from the abstraction audit's finding that the `PropertyDamage` module held the campaign loop, the seed-library replay, the reproduction path and three copies of the report assembly behind an untyped context map, and closed a module cycle through `Regression` and `FailureIntelligence`. Pure extraction: behavior unchanged, public surface unchanged.

Asked:

- `PropertyDamage.ReportBuilder` is the one caller of `FailureReport.new/1`; the three facade sites build their report through it.
- `PropertyDamage.Reproduction` holds the reproduction path (failure handling, the shrink-oracle construction, reproduce, the replay-artifact placement and writing, and the worker behind `shrink_further/2`); the facade delegates.
- `PropertyDamage.Campaign` holds the run loop behind `Campaign.run/1`, with `%PropertyDamage.Campaign.Context{}` replacing the untyped context map; the facade's `run/1` validates options and delegates. Campaign policy gets unit tests that never run a system (stop rules driven by a fake per-run function). `FailureIntelligence.Verification` and `Exploration` call the campaign instead of `PropertyDamage.run/1`, so no cycle contains the facade, `regression.ex` or any `failure_intelligence` file afterwards.
- Hygiene: the facade's public surface is unchanged (listed before and after with line counts); the CI cycle gate drops by one; residue sweep for every moved private name; docs that describe the loop point at the new modules; no new decision record; CHANGELOG Changed (internal).

Acceptance criteria:

- `grep -rn 'FailureReport.new' lib` matches the builder only (doc mentions aside).
- `mix xref graph --format cycles` lists no cycle containing `property_damage.ex`, `regression.ex` or a `failure_intelligence` file; the CI gate equals the count.
- The public functions, macros and delegates of `PropertyDamage` are the same set before and after.
- The policy tests pass with no engine reference, in well under a second of test time.
- The seed goldens and the three end-to-end test files are byte-identical to the base; the full local gate and the two zero-infrastructure benches pass.

Non-goals: any behavior change (a needed one escalates); the executor, variant, runtime and mock-service files (a concurrent change owns them); removing the facade's doc mention of the mock-registry handle while that change is unmerged.

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-09T18:26 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-09T18:26 · commit · b32d463

test(report_builder): pin the report fields each failure path builds

The three failure-report paths (a found failure, a latency breach and a
further shrink) had no test of which fields each sets. Real tiny failing
runs now pin the plan source, shrink counts, epochs, expansion presence,
fire counts and other failures per path, so a refactor of the assembly
code cannot change a report unnoticed.

**Files:** `test/property_damage/report_builder_characterization_test.exs`

### 2026-11-09T18:30 · commit · 2ea26b9

refactor(facade): build failure reports in one builder

The facade assembled each failure report inline at three sites (the latency
breach, the found failure and the further shrink), next to the helpers only
those sites use. The sites now call PropertyDamage.ReportBuilder, which is the
only caller of FailureReport.new/1 in lib/ and documents the fields each path
leaves unset. The helpers used only by report assembly moved with it. Reports
are field-for-field unchanged.

**Files:** `lib/property_damage.ex`, `lib/property_damage/report_builder.ex`

### 2026-11-09T18:38 · commit · 5a94272

test(reproduction): pin replay status and on_failure composition

The failure path had no test for a run with replay_dir: false, for an
unwritable replay_dir, or for on_failure: given together with regression:.
Pin the replay status each leaves on the report and that both handlers
receive it.

**Files:** `test/property_damage/reproduction_characterization_test.exs`

### 2026-11-09T18:41 · commit · 52d7a64

refactor(facade): move the reproduction path into its own module

The facade held the whole failure path (shrink, reproduce, build the report,
place the replay artifact, run on_failure) and the worker behind
shrink_further/2 beside the campaign loop. Move them into
PropertyDamage.Reproduction with bodies unchanged. The public surface of
PropertyDamage is identical: shrink_further/2 keeps its doc and delegates.

Two helpers the loop and the reproduction share move to the module that owns
the concept: Sequence.plan/2 builds the plan a run executes, and
ReportBuilder.project_fires/1 projects check firings out of the counters.

**Files:** `lib/property_damage.ex`, `lib/property_damage/report_builder.ex`, `lib/property_damage/reproduction.ex`, `lib/property_damage/sequence.ex`, `test/property_damage/eventual_consistency_test.exs`, `test/property_damage/flaky_failure_report_test.exs`, `test/property_damage/regression_test.exs`, `test/property_damage_test.exs`

### 2026-11-09T18:50 · commit · 0ce4e58

refactor(campaign): introduce a typed campaign context

The campaign context was an untyped map built in two places: a 33-key map
in `run/1` and an eleven-key map in the re-shrink. Readers used
`Map.get(ctx, :latency, false)` to cope with keys one builder omitted, and
the report builder and the failure path could not state what they took.

`PropertyDamage.Campaign.Context` is now the one struct both builders
fill. `model`, `targets` and `target` are required; the other fields default
to the value they hold when their option is off. The re-shrink leaves the
campaign-only fields at their defaults. `measure_latency` and
`stutter_config` are derived by functions of the struct, and the
seed-library config is passed to the replay phase instead of stored.
Specs of `ReportBuilder` and `Reproduction` take `Context.t()`.

**Files:** `lib/property_damage.ex`, `lib/property_damage/campaign/context.ex`, `lib/property_damage/report_builder.ex`, `lib/property_damage/reproduction.ex`

### 2026-11-09T18:58 · commit · d952aa7

refactor(facade): move the campaign loop behind Campaign.run/2 with a typed context

`PropertyDamage` held the whole campaign loop (option handling, seed and
nonce resolution, telemetry, the run loop, accumulators, the seed-library
replay phase and coverage accumulation) beside the public API, and the
loop could not be driven without a model, an adapter and the scheduler.

The loop now lives in `PropertyDamage.Campaign`. `run/1` keeps its doc,
spec and signature and delegates to `Campaign.run/2`. `Campaign.loop/2` is
the loop alone: each run is the context's `run_once` step, which defaults to
the campaign's own, so a test can pass a `%Campaign.Context{}` and a fake
step.

The `on_failure` callback builder moved to the facade and reaches the
campaign as an argument, so `Campaign`, `Reproduction` and `ReportBuilder`
no longer reference `Regression` or the facade. `Reproduction.shrink_further`
takes the public function name for its error message. Behavior is unchanged.

**Files:** `CLAUDE.md`, `lib/property_damage.ex`, `lib/property_damage/campaign.ex`, `lib/property_damage/campaign/context.ex`, `lib/property_damage/reproduction.ex`

### 2026-11-09T19:08 · commit · 0a40f2d

test(campaign): pin the run loop policy without running a system

The run loop's stop and accumulator rules were covered only by runs
against real systems. The tests drive Campaign.loop/2 with a fake run
step and pin the run count, the first-run offset, the stop at the first
failure, accumulator threading, the replay mark and the latency budget.

**Files:** `test/property_damage/campaign_policy_test.exs`

### 2026-11-09T19:11 · commit · f3a6c06

refactor(failure_intelligence): run verification and exploration through the campaign

Verification and exploration called the facade's run/1, which made the
facade, the failure intelligence modules and the regression handler one
dependency cycle. Both reruns pass no on_failure or regression option,
so they now call the new Campaign.run/1, which runs the campaign with no
callback. Behavior is unchanged.

**Files:** `lib/property_damage/campaign.ex`, `lib/property_damage/failure_intelligence/exploration.ex`, `lib/property_damage/failure_intelligence/verification.ex`

### 2026-11-09T19:13 · commit · 8b1aead

ci: lower the cycle gate to four

The dependency cycle count is now four, so the gate allows no more.

**Files:** `.github/workflows/ci.yml`

### 2026-11-09T19:18 · commit · 52f6143

docs: point the run loop and reproduction text at Campaign and Reproduction

Decision records, CLAUDE.md and the execution-engine spec named the
PropertyDamage module as the home of the run loop, the replay phase and the
failure handling. Those now live in Campaign, Reproduction and ReportBuilder,
so the text names the new modules, and the changelog records the move.

**Files:** `CHANGELOG.md`, `CLAUDE.md`, `docs/decisions/DR-023-seed-library-ephemeral-replay.md`, `docs/decisions/DR-026-invariant-catalog-and-coverage.md`, `docs/decisions/DR-027-adapter-runtime-handle.md`, `docs/decisions/DR-033-run-trace-execution-record.md`, `docs/decisions/DR-034-reproducible-run-inputs-and-minted-values.md`, `openspec/specs/execution-engine/spec.md`

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

Labeled reconstruction: assembled from the wave's on-disk reports after the commits, with verbatim quotes. It extends the Record and contradicts none of it.

- Context fields (from the campaign implementer's report, `evidence/w10/report_campaign.md`): "Dropped keys: none unread. Every one of the 31 map keys is read", so the struct keeps every key of the old map; the two extra values the facade set after validation (`generator`, `measured_metrics`) ride on the struct too.
- Campaign entry (from the orchestrator's report, `evidence/w10/suborch_report_w10.md`, R3): "on-failure callback private to the facade and injected via Campaign.run(opts, on_failure_for), plus Campaign.run/1 for callers without it". The facade keeps the callback builder because it calls `Regression`; `Verification` and `Exploration` use `Campaign.run/1`.
- Builder helpers (same report, R1 and R2): "ReportBuilder variant_of/project_fires/merge_fires public" because `Reproduction` and `Campaign` call them; filed as a forward finding ("could find better homes").
- Policy tests (same report, R6): "policy test reads a real MinimalModel only for the invariant catalog, replay execution not reachable with a fake, named". The tests pin the stop rules and the accumulator effects; replay execution and failure handling are not driven by them (Known debt).
- Reproduction docs (from the reproduction implementer's report, `evidence/w10/report_reproduction.md`): "shrink_further @doc in Reproduction is a short pointer; the full doc stays on the facade."
- Cycle gate: the count fell to four at f3a6c06 and the gate followed in 8b1aead; a concurrent change lowers it by one as well, and the final number is set when the second of the two is rebased.
