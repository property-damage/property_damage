# Handoff ledger: w9-loadtest-on-stepping

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seed this
from whatever produced it: a grill-me ledger, a campaign wave contract, a
ticket, or by hand.

Source: the maintainer's design rulings of 2026-11-09 for the load-test worker (contracts recorded in the design record, section "LoadTest on Stepping"), from the abstraction audit's finding that the worker kept its own command loop while every other run stepped through `Executor.Stepping`, and that the loop skipped settle, setup and teardown commands, eventual checks, stutter, mocks and injectors.

Asked:

- One worker session is a Stepping session: per generated sequence the worker builds a state with `Stepping.init_state/2` over its shared context (the adapter stays set up once per worker), runs setup commands, each root with a drain after it, teardown commands, and `finalize/2`. The worker's own loop and per-command machinery go, and the worker calls `Stepping` only, never the executor's leaf. Built behind a private option first with a parity test on a fixed seed (same command modules in order, same resolved placeholder values, same outcomes), then the option, the old loop and the parity test removed in the same PR.
- Load runs gain the engine's behaviors: settle, setup and teardown commands, eventual checks and the startup, teardown and periodic checks, mocks and injectors, and stutter through a `stutter:` load option. Request latency is the duration of one `Stepping.step/4`; a finalize failure counts as a check failure of its sequence. Metrics gain a per-run phase count (setup commands, teardown commands, eventual-check evaluations, stutter retries) printed by the report; load runs emit the same command and check telemetry as a run.
- Hygiene: the worker-generation regression guard stays green and untagged; the load guide's example runs in the docs check or through a test; the cycle count and gate stay; residue sweep for the deleted names; the guide's "load runs skip" paragraph rewritten; CHANGELOG Changed and Added.

Acceptance criteria:

- `grep -nE 'execute_sequence_commands|execute_commands|execute_single_command|run_checks_for_command|InjectionWindow|Task\.async' lib/property_damage/load_test/worker.ex` is empty, and the worker calls `Stepping` only.
- A load run over a model with setup and teardown commands and an eventual check reports a nonzero count for each phase.
- The worker-generation tests pass untagged; `docs_verify` passes with the guide's example covered; the full local gate and the two zero-infrastructure benches pass; no cycle contains a load-test file.

Non-goals: the executor and stepping files beyond one delegate for the startup checks (ruled mid-wave); the failure report (a concurrent change); the service-container benches (CI runs them).

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-09T20:43 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-09T20:43 · commit · 8d3bfb7

test(load_test): pin the worker's session against the stepping seam

A worker runs sequences through its own loop, which skips settle,
setup, teardown and eventual checks. The test compares a worker that
steps each sequence through the engine with one that uses the loop:
same commands, same resolved placeholder values, same outcomes. It
fails until the worker takes a session option.

**Files:** `test/property_damage/load_test/worker_session_parity_test.exs`

### 2026-11-09T20:46 · commit · 33cf86b

feat(stepping): expose the startup checks to stepping callers

A caller that steps a sequence itself had no route to the checks that
run before the first command, so only the lockstep driver could run
them. Add Stepping.run_startup_checks/1, a delegate to the engine's
own function.

**Files:** `lib/property_damage/executor/stepping.ex`

### 2026-11-09T20:52 · commit · 42b5ca1

feat(load_test): run a worker session through the stepping seam behind an option

A load worker runs each sequence through its own loop, which skips
startup checks, setup and teardown commands, settle and eventual
checks, so a load run exercises a different system than a property run
of the same model. Add a private session option: :stepping runs the
sequence as a stepping session over the engine's per-command path
(startup checks, setup, each root timed, a drain after each root,
finalization, teardown). :legacy stays the default and runs the old
loop.

**Files:** `lib/property_damage/load_test/worker.ex`, `test/property_damage/load_test/worker_session_parity_test.exs`, `test/property_damage/load_test/worker_session_phases_test.exs`

### 2026-11-09T21:01 · commit · bc68877

refactor(load_test)!: remove the worker's own command loop

The load-test worker carried its own command loop beside the stepping
session, so a load run skipped setup, teardown, startup checks and
eventual checks and drifted from the engine. The session is now the only
path: delete the loop, its check and projection helpers, the timeout task
wrapper and the `:session` option, and the parity test that compared the
two.

The test adapter for the check-enabled model now answers struct events,
which the engine requires; the loop had tolerated plain maps.

**Files:** `lib/property_damage/load_test/worker.ex`, `test/property_damage/load_test/worker_session_parity_test.exs`, `test/property_damage/load_test/worker_session_phases_test.exs`, `test/property_damage/load_test_test.exs`

### 2026-11-09T21:07 · commit · 042d691

feat(load_test): count the phases a load run executes and accept a stutter option

A load report did not say whether a run executed setup, teardown, eventual
checks or stutter retries, and a load run could not turn stutter on. Metrics
gain `phase_counts` (setup commands, teardown commands, eventual checks,
stutter retries), recorded per sequence by the worker from the session state
and shown by `format/2` and `summary/1` when any is nonzero. `LoadTest.run/1`
accepts `stutter:` with the validation `PropertyDamage.run/1` uses, threaded
runner to pool to worker to the session. The `record_request` doc now states
that latency is the duration of one root's step, think time excluded.

**Files:** `lib/property_damage/load_test.ex`, `lib/property_damage/load_test/metrics.ex`, `lib/property_damage/load_test/report.ex`, `lib/property_damage/load_test/runner.ex`, `lib/property_damage/load_test/worker.ex`, `lib/property_damage/load_test/worker_pool.ex`, `lib/property_damage/options.ex`, `test/property_damage/load_test/worker_session_phases_test.exs`

### 2026-11-09T21:17 · commit · 454247d

docs(load_test): describe what a load run now executes

The guide and the moduledocs said load workers skip setup and teardown
commands and that a command over its timeout raises. A worker now runs each
sequence through the engine step: startup checks, setup commands, roots with
settle and drain, the `@eventually` and teardown checks, then teardown
commands. State that order, that checks follow `check_mode`, that only roots
count as requests, the latency definition, the `stutter:` option and the
phase counts, and fix the timeout wording and the doc examples that showed
the removed worker loop.

**Files:** `guides/load_testing.md`, `lib/property_damage/command_timeout_error.ex`, `lib/property_damage/load_test.ex`, `lib/property_damage/mint.ex`, `lib/property_damage/placeholder_registry.ex`, `lib/property_damage/runtime/injection_window.ex`, `lib/property_damage/runtime/sink.ex`

### 2026-11-09T21:20 · commit · 39aedf2

test(load_test): run the load guide's example

The load guide had no example that ran, so its account of setup, teardown,
`@eventually` checks and stutter in a load run was unchecked. Add a runnable
example to the guide, which the docs check executes, and a guide-example test
that places its module bodies under the test module and asserts nonzero phase
counts. A run with checks disabled opens no eventual check, which shows the
assertions can fail.

**Files:** `guides/load_testing.md`, `test/property_damage/load_test_guide_example_test.exs`

### 2026-11-09T21:24 · commit · ff9a038

docs(load_test): update the load-testing requirements

The load-testing spec described a worker that executes a sequence with its own
loop, a timeout that raises, and a default check mode of `:record`, which the
code never had. Describe the engine session a worker runs, the timeout as an
adapter error that counts one error, the `:disabled` default and what it
disables. Add requirements for the session phases, request latency, the
`stutter:` option and the phase counts, each with scenarios.

**Files:** `openspec/specs/load-testing/spec.md`

### 2026-11-09T21:28 · commit · aff8f06

docs: record the load-test changes in the changelog

Load runs changed what they execute, how latency is measured and what
`Worker.execute_sequence/1` returns, and gained the `stutter:` option and
phase counts. List them under Unreleased, the three behavior changes as
breaking.

**Files:** `CHANGELOG.md`

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

Labeled reconstruction: assembled from the wave's on-disk reports after the commits, with verbatim quotes. It extends the Record and contradicts none of it.

- Startup checks (from the orchestrator's report, `evidence/w9/suborch_report_w9.md`): "E1 (startup checks route) ruled by main, Amendment 1: Stepping.run_startup_checks/1 delegate (33cf86b). Only executor/ edit." The contract forbade the worker calling the leaf and the leaf held the only startup-check function, so one delegate was added on the stepping seam.
- Teardown (same report, R2): "teardown runs after finalize, as the Variant does; stepping path draws teardown via Generator.teardown_commands/3 (load sequences carry none)."
- Struct events (same report, R3 and R4): "engine requires struct events; test fixture CheckedEvent/CheckedAdapter added, used only by the checks-enabled test; no engine change." One existing load test returned plain-map events and crashed in the engine once the worker stepped through it.
- Parity (same report): "seed 20261109, worker 3, 12 sequences, model Create(external id)/Use/Boom({:error,_}); series: executed command modules in order, resolved placeholder values, ok-or-error outcomes"; red first, then green, then deleted with the option.
- Latency (same report): "duration of Stepping.step/4 for a root (resolve, adapter call, settle, step checks; think time excluded; setup and teardown are not requests). C probed think_time {100,100}: latency_max 0.609 ms over 450 requests."
- Cycle count (same report): an implementer read two cycles at its head; the orchestrator re-ran the listing in both environments and found "3 cycles (mutation/operators, failure_report, run_comparison), none through load_test"; the gate stays.
- Shared option (same report, R5): "B added a shared @stutter_option in lib/property_damage/options.ex (not on the ownership list; used by run/1 and load test schemas, behavior-preserving)", confirmed by the maintainer's delegate at hand-back.
- Record entry aff8f06 names a commit not on the branch: the changelog commit was amended once to 418e9a0; the Record keeps the superseded entry as contemporaneous evidence.
