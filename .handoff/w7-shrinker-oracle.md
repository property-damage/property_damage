# Handoff ledger: w7-shrinker-oracle

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the maintainer's design rulings of 2026-11-07 for the run seam (the shrinker takes an oracle) and the audit's shrink-cost measurement, after the one run driver landed in `PropertyDamage.Runner.execute/2`. The shrinker was the last caller of the Scheduler outside the runner, and its candidate loop is the one place that can time every shrink candidate.

Asked:

- The shrinker takes an oracle: a function from a candidate plan and the per-candidate mint epoch to an outcome, built by the facade from the runner through one public builder that the facade's two call sites and the shrinker tests share; the shrinker executes nothing itself and no longer calls the Scheduler.
- One outcome type replaces the four result shapes and the equivalence booleans: status, the failure's signature, root and reason; adoption matches the outcome's signature against the original and the later-root rule.
- Locked before the move: a fake-oracle suite (an in-memory predicate over the candidate, no adapter, no model process, no Scheduler) covering linear removal, hierarchical removal, argument simplification and the setup-failed and invalid paths, with its wall time recorded; shrink parity against the fixed-seed goldens, which are not regenerated. The existing shrinker tests move onto the builder with their assertions unchanged.
- Shrink-cost measurement, no optimization: the oracle times each candidate and emits the documented shrink telemetry events that nothing emitted; adapter setup and teardown are timed where they run; a script runs the gitea bench's seeded divergence model over its fixed seed set under Docker and reports the share of campaign time spent shrinking and the share of that in setup and teardown; a decision brief closes with a recommendation on adapter-session reuse.
- Hygiene: the cycle count never rises (and the gate is lowered if it drops); docs sweep of the runner moduledoc, the one-runner record, the shrinking spec and the performance guide; CHANGELOG Breaking for the option change and Added for the telemetry.

Acceptance criteria:

- The fake-oracle suite passes with no engine reference and runs in well under a second of test time; the goldens are byte-identical to the base and the golden and parity tests pass.
- A grep for the Scheduler entry in the library finds the runner only.
- The measurement results and summary exist with the two shares; the brief exists with a recommendation.
- The full local gate passes; the module cycle count does not rise.

Non-goals: adapter-session reuse itself (a conditional later change); the executor's own test harness; the benches' code.
## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-07T11:19 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-07T11:19 · commit · 09317d8

test(shrinker): lock a fake-oracle suite and shrink parity

The shrinker runs every candidate through the scheduler itself, so no test can
drive it without an adapter and a run, and nothing pins how many candidates it
tries. Add a suite that drives it with an in-memory oracle (a predicate over
the candidate's roots) and a parity test that records the iterations and stop
reason of every seed the seed characterization runs.

The oracle tests are tagged known_defect until the shrinker takes an oracle;
their untagged controls prove the predicates and the model can tell a failing
candidate from a passing one. The parity test passes on the current shrinker
and must stay green when candidate running moves behind the oracle.

**Files:** `test/fixtures/shrink_parity/generate.exs`, `test/fixtures/shrink_parity/iterations.exs`, `test/property_damage/shrink_parity_test.exs`, `test/property_damage/shrinker_oracle_test.exs`, `test/support/fake_oracle.ex`, `test/support/shrink_oracle_fixtures.ex`, `test/support/shrink_parity_support.ex`

### 2026-11-07T11:30 · commit · af8b94c

refactor(shrinker)!: take an oracle and one outcome type

A shrinker test needed a whole system to run, because the shrinker ran
every candidate through the scheduler itself and read four result shapes
back. The shrinker now hands each candidate's plan and a fresh mint epoch
to a required oracle, `(plan, mint_epoch) -> %Shrinker.Outcome{}`, and
adopts the candidate on a failed outcome with the original signature at
the same or an earlier root. A candidate the validator, the expansion
realization or the replay check rejects never reaches the oracle and
still costs one iteration.

Runner.shrink_oracle/2 builds the oracle that runs a candidate through
Runner.execute/2 on every target, and forces stutter on for a stutter
signature. The run's failure path and shrink_further/2 use it, so no code
outside the runner calls the scheduler. The shrinker tests that need a
real system build their oracle through one test helper, and the
fake-oracle suite runs untagged.

BREAKING CHANGE: Shrinker.shrink/2 requires `oracle:` and no longer takes
`concurrency:`, `compare:`, `check_mode:`, `keep_attempts:`,
`stutter_config:` or `run_nonce:`; these are fields of the
Runner.Context passed to Runner.shrink_oracle/2.

**Files:** `CHANGELOG.md`, `CLAUDE.md`, `docs/decisions/DR-065-one-run-driver.md`, `lib/property_damage.ex`, `lib/property_damage/runner.ex`, `lib/property_damage/shrinker.ex`, `lib/property_damage/shrinker/outcome.ex`, `openspec/specs/shrinking/spec.md`, `test/property_damage/async_shrink_convergence_test.exs`, `test/property_damage/external_shrink_test.exs`, `test/property_damage/setup_commands_shrink_test.exs`, `test/property_damage/shrink_expansion_axis_test.exs` (+5 more)

### 2026-11-07T11:41 · commit · 7b08628

feat(telemetry): emit the shrink events with candidate and adapter timings

The shrink telemetry events were documented but never emitted, and nothing
told a user how much of a shrink goes to bringing the adapters up and down.
The shrinker now emits start, one iteration event per candidate and stop. The
stop event carries candidate_ms, setup_ms and teardown_ms totals.

Each variant times its adapter's setup/1 and teardown/1 into a counter it
hands to its result, and the runner's oracle sums the counters of a run into
the new Outcome.adapter_ms field. Timing and emission change no candidate,
count or mint epoch.

**Files:** `CHANGELOG.md`, `guides/performance_tuning.md`, `lib/property_damage/runner.ex`, `lib/property_damage/shrinker.ex`, `lib/property_damage/shrinker/outcome.ex`, `lib/property_damage/telemetry.ex`, `lib/property_damage/variant.ex`, `test/property_damage/shrink_telemetry_test.exs`, `test/property_damage/shrinker_oracle_test.exs`

### 2026-11-07T11:53 · commit · 096a2d4

docs: drop an em-dash from the shrinker bullet

**Files:** `CLAUDE.md`

### 2026-11-07T11:30 · decision · oracle shape and the shrinker's inputs

The oracle takes the candidate plan and the per-candidate mint epoch and returns the outcome struct; the builder is `PropertyDamage.Runner.shrink_oracle/2` (context and original signature). The run options that only parameterize execution (concurrency, compare, check mode, keep attempts, run nonce, stutter config) move into the runner context the facade builds; the shrinker keeps the model, the targets, the seed and the mint-epoch counter because it builds and validates candidates from them, and executes nothing. The seven existing shrinker test files that call the shrinker directly were edited at the call and the alias only.

### 2026-11-07T11:41 · decision · measurements

The outcome carries the adapter setup-and-teardown time of its candidate run; the shrink stop event carries the candidate count and the adapter time; durations are in native time units as the other telemetry events use. The measurement ran the gitea bench's divergence model over seeds 1 to 8 under Docker; one seed never failed and is excluded from the shrink share.

### 2026-11-07T11:53 · decision · docs micro-fix

One em-dash in the shrinker bullet of the contributor guide was replaced; a docs-only commit, re-checked with the formatter and the docs check.

## Reconstruction

Labeled as reconstruction: assembled after the fact from the wave's evidence files, not from the commits.

- The test author recorded the fake-oracle suite's timing as "predicate controls 0.00 to 0.5ms each; gated-model validator controls 1.1ms and 18.1ms (first-call compile warmup)" and the full suite at "2m9s wall".
- The reviewer's reading of the oracle contract: the phrase "holds no model, target" was read as "executes nothing", because the shrinker must build and validate candidates from the model's spec table and the targets' expansions; recorded as a ratification, not a contract change.
- The measurement summary: "shrinking 73.6% of campaign time (7 shrinking seeds; 70.9% all 8); setup+teardown 19.7% of shrink time". The brief reads that against the audit's gate ("only if setup and teardown dominate") and recommends no session reuse, keeping the telemetry as the early warning.
- Forward findings the reviewer named: the shrinker silently ignores the options that moved to the context; a setup-failed candidate loses its setup time; the hierarchical fake-oracle case carries no expansions.
