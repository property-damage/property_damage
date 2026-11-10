# Handoff ledger: wh-hardening-3

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the hardening pass's table of filed findings (campaign tracking, outside this repository); this is the third and last of its pull requests and carries the load-test worker and failure-report rows.

Asked:

- Failure report: an exception while the context items are built must not lose the JSON document; build them under the same per-section guard as the other sections, name the failed section in `render_errors` and keep the rest.
- Load-test worker: check failures that belong to the whole session (a failed startup check, an `@eventually` check still unsettled at the end of a halting session) are recorded under a named key instead of `nil`, and the guide says so.
- Executor: an adapter event that is not a struct is reported as the existing malformed-adapter-return failure where the engine would have read its struct, instead of crashing; no new failure kind and no change to the adapter contract.
- Load-test worker: a poller result that arrives after its session halted is dropped instead of logged as an unexpected message.
- Pin, with no behavior change, what the worker does today: it records the first failing check per projection per step; it keeps stepping after an adapter error, a raise or a settle timeout; it counts an eventual window when it opens and a stutter retry when the log kept its events.
- Triage the remaining rows of the group with evidence: the bundle delegate deletion, the persistence version pins, the accessor test's type-checker warning.

Acceptance criteria:

- Each defect-fix test fails on the base checkout and passes at the head; each pin test passes on both.
- With checks off, an adapter that answers plain maps still folds its events as before (the existing load-test and fixture suites stay green).
- The full local gate passes and the module cycle count does not rise.

Non-goals: whether a load session should stop at its first step failure (a load-test semantics decision recorded for the maintainer); the bundle delegate deletion (deferred by its decision record); the worker-versus-variant placeholder resolution difference.

## Sessions

No hook-observed session: the branch was built by delegated agents in a worktree outside the hooked session, so this ledger was assembled by the orchestrating session from the on-disk reports and `git log`.

## Record

The commit list, from `git log` after the rebase onto `main` (the hook recorded no entries for this branch):

### commit · 4fb246a

fix(failure_report): keep the document when the context section raises

The context items were built before the per-section guards, so an exception in them lost the whole report document. Build them under the same guard as the other sections, name the failed section in render_errors, and keep the other sections.

### commit · 098545d

fix(load_test): record session-level check failures under a named key

Check failures found at startup or at the end of a session name no command or event module, so the metrics recorded them under module nil. Record them under :session.

### commit · 1621a03

test(load_test): pin check recording, failed-step stepping and phase counts

Describe what the load worker does today: it records the first failing check per projection per step, keeps stepping after a failed step, and counts windows when opened and retries when the log kept their events.

### commit · c5e3f7c

fix(executor): report a non-struct adapter event as a malformed return

The checks read each event's module, so an adapter that answered a plain map crashed the engine on its struct. With checks on, a list that holds a non-struct event is now the malformed adapter return failure, carrying the adapter's return. With checks off nothing reads the module, so plain maps fold as before.

### commit · b1f2a2e

fix(load_test): drop a poller result that arrives after the session halted

A session that halted with an @eventually window open left its poller result in the worker's mailbox, and the worker logged it as an unexpected message. Ignore a poller result that reaches the worker between sessions.

### commit · 088ae67

docs(changelog): note the load-test and failure-report fixes

## Reconstruction

Assembled from the delegated agents' reports; labeled as reconstruction.

- The non-struct event row was filed as "validate events at the adapter boundary with a named error". The first implementation validated every event list and turned two existing tests red (a load-test fixture and an adversarial fixture answer plain maps on paths that never read the struct). The maintainer's ruling kept the adapter contract as it is: the failure is reported only where the engine reads the struct, which is when checks are on. The two tests that had been tagged as known defects were untagged once the fix landed.
- The failed-step row asked whether a load session should stop at its first step failure as the variant does. Ruled a semantics decision outside a hardening pass: the current behavior is pinned, the question goes to the maintainer.
- The phase-count row (a stutter retry that answers no events is not counted; the eventual count is pollers opened, not verdicts) was ruled not a defect: the guide and the spec already define the counts that way, and the pins describe them. Probing it found the late poller message, which became its own row and fix.
- The bundle delegate deletion stays deferred: its decision record already defers it, and it needs the locked overlay test unlocked and the explanation's first format dropped, which is one later change.
- The persistence version pins were already clean (no test outside the refusal test hard-codes the format number) and the accessor test already compared through accessors with no type-checker warning; both closed without a change.
- The `:session` key was accepted as an undocumented detail field, now described in the load-testing guide.
- Verification before the fixes were committed: `git diff -w` listed exactly the reported files after the implementer's one tree-wide `mix format`; the executor step module was byte-identical to the base before its own fix commit; the layout and document diffs were read.
