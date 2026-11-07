# Handoff ledger: w1-check-evaluator

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the design rulings of 2026-11-06 for the check evaluator: a projection's checks become one struct with an explicit kind, one module evaluates them, and every reader of the projection's internal check list goes through that module, so the two readers that crashed on `at:` and `@eventually` checks stop crashing.

Asked:

- `%PropertyDamage.Model.Projection.Check{}` with a `kind` field, emitted by the macros in `model/projection.ex`.
- `Projection.Checks` owns `step_checks/4` (the executor's filter-and-run loop moved unchanged, fire counting and telemetry included) and `list/1`.
- Every reader of `__checks__` outside the two owner files moves to `Checks`, one commit per reader.
- The known-defect tags for the forensics replay and the load-test worker are lifted in this change.
- Guides and moduledocs that mention the internal list are updated.

Acceptance criteria:

- `grep -rn '__checks__' lib` matches only `model/projection.ex` and `model/projection/checks.ex`.
- The check-kind matrix test is green for every reader at the head; the lifted tests fail at the base commit with the tag included and pass at the head without it.
- The two telemetry test files are unedited and pass (event names and measurements unchanged).
- The full local gate passes, including both zero-infrastructure benches with their audit models, and the module cycle count does not rise.

Non-goals: rewriting the load-test worker loop (a later change); new check kinds; the executor's own cycle.

## Sessions

Not captured: the eleven commits were made by a delegated agent whose session is not registered with the ledger hooks. Its progress log and report are kept with the review evidence outside the repo.

## Record

### 2026-11-07 03:17 · commit · 0223f00

feat(projection): emit checks as %Check{} structs with a kind

### 2026-11-07 03:23 · commit · 2421a03

refactor(executor): evaluate checks through Projection.Checks.step_checks/4

### 2026-11-07 03:27 · commit · 04e8669

refactor(forensics): read checks through Projection.Checks

### 2026-11-07 03:30 · commit · 9199487

refactor(load-test): read checks through Projection.Checks

### 2026-11-07 03:32 · commit · f65ff10

refactor(validation): read checks through Projection.Checks

### 2026-11-07 03:35 · commit · 5f16e30

refactor(suggestions): read checks through Projection.Checks

### 2026-11-07 03:40 · commit · 65e8fca

refactor(model): read checks through Projection.Checks

### 2026-11-07 03:42 · commit · c090d7d

refactor(failure-report): read checks through Projection.Checks

### 2026-11-07 03:45 · commit · d706109

docs(failure): name the check list instead of its internal function

### 2026-11-07 03:48 · commit · f6d785e

test: lift the known-defect tags for forensics, the load-test worker and the suggestions analyzer

### 2026-11-07 03:51 · commit · 58670a6

docs: describe checks as Check structs read through Projection.Checks

## Reconstruction

Assembled afterwards from the delegated agent's report; labeled as reconstruction.

- The kind set found in the macros is three, not four: "Kind set: step, phase, eventually (compare is not a kind)".
- The suggestions analyzer's tagged test went green after its reader move, so its tag was lifted with the other two: "All three RED at base a950d97 with --include known_defect (forensics_test 2 fail, matrix 3 fail); green at head".
- The load-test worker's recording changed shape: "the load-test worker now records at most one failure per projection per step (first failing check), documented in CHANGELOG".
- The matrix test's list of reader files was edited to the two owner files, and the changelog was edited, both outside the named file set: "I also edited the matrix @readers list to the two owner files, and touched CHANGELOG".
