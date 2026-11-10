# Handoff ledger: wh-hardening-2

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the hardening wave's table of filed findings (campaign tracking, outside this repository); this is the second of three pull requests and carries the framework defects fixed with red-proven tests, the test-only pins with mutation controls, and the cleanups the triage assigned to it.

Asked:

- Fix each framework defect the earlier changes filed, with a test proven red at the base before the fix: a directory listing that crashes on an unreadable report; a missing seed failing deep inside the engine; the shrinker silently ignoring options that moved to the runner context; isolation reruns validating candidates with the default markers; suggestion example code emitting a removed check form; check-failure messages whose detail-key order depends on atom creation order; a raising stutter relation surfacing as an unknown failure.
- Pin behaviors that had no dedicated test, each with a mutation control that turns the new test red: the teardown-site spec switch, isolation reruns carrying mocks, the log-capture filter in the regression test, hierarchical shrinking with carried expansions, the campaign loop's failure and replay branches.
- Cleanups: delete the unreachable expansion fallbacks, remove the test-only accumulating injection window, mark shared helpers internal, seed the kratos bench campaign, and break the report cycle through the Inspect implementation so the module cycle count drops and the gate ratchets down.
- Triage every remaining row of the group with evidence: already fixed at the base, not reproducible, not a defect by measurement, or not reachable in the asked shape.

Acceptance criteria:

- Every defect-fix test fails on the base checkout and passes at the head; every pin test turns red under its recorded mutation and green with the mutation restored.
- The regenerated store goldens differ from the base only in the key order of recorded check messages, proven by a standalone comparison that fails on a tampered copy; the ledger goldens are byte-identical.
- A raising stutter relation is reported as a check failure carrying the exception, never as an idempotency violation, and shrinking and replay treat it as a stutter failure.
- The cycle gate in the CI workflow is lower than at the base and equals the count at the head.
- The full local gate passes; nothing references the removed accumulating window.

Non-goals: argument shrinking inside the generator's domain and the shrinker's per-candidate idempotency key (both ruled into the generator-aware shrinking change); the explain prompt's wording; the load-test and failure-report findings of the third pull request.

## Sessions

No hook-observed session: the branch was built by delegated agents in a worktree outside the hooked session, so this ledger was assembled by the orchestrating session from the on-disk reports and `git log`.

## Record

The commit list, from `git log` after the rebase onto `main` (the hook recorded no entries for this branch):

### commit · 2d10c78

fix(persistence): list a directory that holds an unreadable report

Persistence.list/2 raised in DateTime.compare/2 when a directory mixed a loadable report with a file it could not load, such as one of an older format version. Sort only the dated entries and list the unreadable file after them, in the documented shape.

### commit · 03eb4ac

fix(runner): name a missing seed and count the setup time of a failed setup

A context without an integer seed failed inside the engine with a FunctionClauseError, so Runner.execute/2 now raises an ArgumentError that names the seed. A target whose setup failed left no result, so its adapter time was dropped from the run's adapter_ms; the run now carries the timers of those targets and the runner sums them.

### commit · 70bb064

fix(shrinker): reject options that moved to the runner context

Shrinker.shrink/2 ignored the options that now live on Runner.Context (concurrency, compare, check_mode, keep_attempts, run_nonce, stutter_config), so a caller who passed one saw no effect. Raise an ArgumentError on an unknown option and point to the context.

The changelog gains the fixed entries for the persistence, runner and shrinker changes.

### commit · 6f491c9

fix(suggestions): emit the @check form in example code

The analyzer's example code used a check(:always) call and a def check/3 clause, a syntax the projection DSL no longer accepts. Emit the @check every: 1 form with PropertyDamage.fail!/2, and test that every example parses and compiles inside a projection. Also pin that analyze/1 reads checks of the current shape.

### commit · 3fa5a8a

fix(analysis): validate isolation candidates with the report's external markers

Trigger isolation validated each candidate with the default external markers, so a model with custom markers folded candidates unlinked. Pass the markers recorded on the report to the sequence validator.

### commit · 737f922

test: cover isolation mocks, teardown specs, expansion shrinking and campaign branches

Pin four paths that had no test: an isolation rerun consults a mocked service, the teardown step reads the command spec, the hierarchical shrinker carries expansions through a fake oracle, and the campaign loop reaches its failure handler and replay step. Make the regression log assertion ignore warnings from other tests.

### commit · b7ef8ba

docs(changelog): note the example code and isolation marker fixes

### commit · 58d9140

fix(check_failed): list check-failure detail keys in a stable order

A small map prints its keys in atom creation order, so the same check failure rendered differently depending on which tests had created the atoms first. Print the detail map with sorted keys. The store-seed fixture changes only in the order of keys inside recorded check messages.

### commit · 29c7ca2

fix(stutter): report a raising using: relation as a check failure

A stutter relation given with using: that raised escaped the step and surfaced as an unknown failure. The relation is the model author's code, not the system disagreeing with itself, so rescue it in Stutter.compare_events/3 and report a check failure named :stutter, as a raising compare relation already is. Shrink candidates and the replay keep stutter on for that failure so it reproduces.

### commit · 4f64def

docs(changelog): note the stable check message order and the raising stutter relation

### commit · 698db24

refactor(failure_report): move the Inspect implementation to its own module and lower the cycle gate

failure_report.ex sat in an eight-file cycle only because its Inspect implementation called the formatter. Move the implementation unchanged into failure_report/inspect.ex, which breaks the cycle, and lower the xref gate in CI from 3 to 2.

### commit · 414e8d5

refactor(runtime)!: remove InjectionWindow.run_accumulating/2

No library code called it, and run/3 and run_logged/4 open the same window for a caller that supplies its own runtime.

### commit · 7ddd3d2

refactor: drop unreachable expansion fallbacks and mark shared helpers internal

reproduction_expansion/4 and report_expansion/3 kept no-expansion clauses that a full suite run never reached, because the found expansion is always a map; remove them. variant_of/1, project_fires/1, merge_fires/2 and Sequence.plan/2 are public only because the campaign and reproduction modules share them; mark them @doc false.

### commit · 3959d2d

test: seed the kratos bench campaign and pin a later target's failed setup time

The kratos bench drew an unseeded campaign and sometimes never reached the gated command; seed it and print the seed on failure. Add a test that the setup time of a second target whose setup fails reaches adapter_ms.

### commit · 476abfc

docs(changelog): reword the removed-function note so docs build without a warning

The note named the removed function with a link-shaped reference that ex_doc cannot resolve.


## Reconstruction

Assembled afterwards by the orchestrating session from the wave's on-disk reports (campaign evidence, outside this repository). Labeled as reconstruction; the Record above wins where they disagree.

- Group A report on the row that did not reproduce: "WH-25 not reproducible (setup failure yields :different_failure with signature {:setup_failed, nil, 0}, no CaseClauseError; probe red_WH-25.log)."
- Group C report on the goldens: "Only test/fixtures/seed_characterization/store.exs changed (13 lines); ledger.exs is unchanged." and "CONDITION passed: wh2_golden_diff_check.log, exit 0, 'only map key order differs (13 lines)'. A tampered copy makes it exit 1."
- Group C report on the failure kind: "Precedent: a raising `using:` relation in `@compare` is `Failure.check_failed(key, exception)` (lib/property_damage/comparison.ex:371-380). DR-052:52 and the differential-testing spec say the same. A raising projection `apply/2` is `:projection_violation`, which is projection code, so it does not fit." The orchestrator checked that the existing `stutter_execution_failed` kind means the retry's own execution failed, so it was not the precedent either.
- Group C report, weak spots: "A user check also named `:stutter` would be treated as stutter-related on replay." and "I rescue only exceptions, as comparison.ex does, not exits or throws." The sub-orchestrator ratified the collision as a forward finding rather than a reserved name.
- Group B2 report on the cycle break: "WH-19 FIXED. Cycles 3 -> 2 (cycles_before_WH-19.txt, cycles_after_WH-19.txt). Real cycle had 8 files; sole edge out of failure_report.ex was the Inspect impl calling Formatter." and on the measured non-defect: "WH-18 NOT A DEFECT. spec_table 3.73 us/call, valid_sequence? empty 2.47 us/call (FullModel, 3 commands, n=2000); a candidate runs the SUT (ms)."
- Group B2 report on the deletion evidence: "WH-11 deletion evidence is whole-suite instrumentation (benches not run) plus caller reading; the control shows callers rely on the map shape."
- The sub-orchestrator's gate run found the docs build red on two references to the removed accumulating window; the last commit rewords the changelog note that carried them.
