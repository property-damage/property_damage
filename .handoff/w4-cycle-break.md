# Handoff ledger: w4-cycle-break

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the design rulings of 2026-11-06 for the engine-report dependency cycle: the scheduler, the error modules and the run trace must not depend on the failure report, so that the engine can be read without the report and the report without the engine; and the ruling of 2026-11-07 that a fourth move breaks the two-module cycle the first three moves exposed.

Asked:

- `FailureReport.kind_of/1` becomes `Failure.report_kind/1`; the scheduler derives the report kind from the failure, not from the report module.
- `format_name/1` and `setup_location/1` leave `FailureReport` for a naming module under `Failure`; the module has no dependency back on the report.
- `RunTrace.capture/1` becomes `RunTrace.Capture.capture/1`; `RunTrace` is a plain record.
- The old names are removed, every caller is updated, and the whole tree is swept for the old names (library, tests, guides, specs, decision records, benches, the unreleased changelog section).
- Fourth move (ruling of 2026-11-07): the dependency cycle between `expansion.ex` and `validation.ex`, exposed when the large cycle split, is broken by removing one of its two edges.

Acceptance criteria:

- At the branch head, no module cycle contains `scheduler.ex` or `run_trace.ex`; no cycle contains both `scheduler.ex` and `failure_report.ex`; `mix xref graph` from `scheduler.ex`, `error.ex` or `error_origin.ex` to `failure_report.ex` prints no path.
- The module cycle count at the head is not above the count at the base commit, and the CI ceiling equals the measured count.
- A grep for the old names over the tree finds nothing outside the changelog entries that announce the renames.
- The test diff against the base commit changes module names and aliases only.
- The full local gate passes, including both zero-infrastructure benches with their audit models.

Non-goals: any behaviour change; the six-module cycle among `failure_report.ex`, its render files and `replay_artifact.ex` (outside the asked predicate; filed for a later change); the executor's own cycle.

## Sessions

Not captured: the four commits were made by a delegated agent whose session is not registered with the ledger hooks. The agent's progress log and report are kept with the review evidence outside the repo.

## Record

- 2026-11-07 02:17 commit `78d7396` refactor(failure): move report_kind out of FailureReport.
- 2026-11-07 02:23 commit `5b70bad` refactor(failure): move name formatting into Failure.Naming.
- 2026-11-07 02:27 commit `6e4cff8` refactor(run_trace): move capture into RunTrace.Capture.
- 2026-11-07 02:30 decision (maintainer's agent, recorded in the review evidence): the three moves hold the dependency predicate but the twelve-module cycle split into a six-cycle and a two-cycle, raising the count from five to six; a fourth move breaks the two-cycle so the count does not rise.
- 2026-11-07 02:36 commit `97c9a90` refactor(validation): break the expansion and validation dependency cycle.

## Reconstruction

Assembled afterwards from the delegated agent's report; labeled as reconstruction.

- Move 2 placed the two functions in their own module, `Failure.Naming`, rather than in `Failure`: "own module: format_name, setup_location, command_name; command_name was a private FailureReport helper, now public in Naming and FailureReport calls it". `setup_location/1` lost its report clause so the module has no edge back to the report: "No FailureReport clause; printer passes report.failure_reason".
- Move 3 kept `source_revision/0` on `RunTrace`: "RunTrace keeps source_revision/0 (git shell-out, no Scheduler ref) and Capture calls it".
- Move 4 removed the `expansion.ex` to `validation.ex` edge rather than the reverse: "moved `Validation.validate_command_callbacks!/1` ... to `PropertyDamage.Command.validate_callbacks!/1`, removing the expansion.ex -> validation.ex edge" and "I did not move the validation.ex:59 call site, because that would change which entry points run the expansion model check, and in what error order".
- The agent flagged one commit body as imprecise: "Commit 1 body says Error depended on FailureReport for kind; imprecise (only scheduler did). Cosmetic." The squash merge replaces the commit bodies.
- Unreleased changelog lines and decision records 033, 035, 043, 045, 048 to 050 and 063 were rewritten to the new names as part of the sweep; the agent listed this as a deviation to be checked. The changelog edits all sit in the unreleased section.
