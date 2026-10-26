# Handoff ledger: feat/verdict-grammar-dr-052

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seeded by
hand from the orchestrator's dispatch brief
(`threads/pd_check_contracts_build/dispatch_dr052.md` in the secretariat vault).

This branch implements DR-052 (`docs/decisions/DR-052-check-verdict-by-return.md`),
one verdict grammar for the three kinds of check: a `@check` judges its return,
an `@eventually` predicate's return is read the same way within the window, and
a `using:` relation's return too, through one reader,
`PropertyDamage.Verdict.read/1`, which replaces `Equivalence.verdict/3`. Every
numbered decision (1, 1a, 1b, 1c, 2, 3, 4, 6, 7) is a contract; decision 5
shipped in PR #82 and is only verified here. Non-goals: DR-051 (named
comparators, the `using:` migration from captures to names, `CompareAttribute`
and the custom `@/1`) is the next pull request.

Acceptance criteria:

- A1 `Verdict.read/1` exists with a doctest per row of the item-1a table;
  `Equivalence.verdict/3` is gone; no `:match`/`{:mismatch` outside CHANGELOG
  history.
- A2 A predicate `@check` returning `false` fails in executor, forensics and
  load-test worker, each with a RED log.
- A3 The failure message for a `nil` return matches item 4's shape.
- A4 The `if`-without-`else` tail is a `CompileError` naming the function and
  the rewrite; `unless` too; an `if` with `else` compiles.
- A5 Zero `if ..., do: fail!` sites remain in lib, guides, templates and tests
  (multi-line included).
- A6 `{:fail, "text"}` from a check fails with that text; `{:fail, %Exception{}}`
  with that exception; a bare exception struct and `{:error, _}` fail with the
  nudge sentence.
- A7 `StatePoller`: `{:fail, _}` ends the window at once; a raise fails at the
  first poll with poll count; `last_predicate_error` gone; throw and exit are
  caught.
- A8 Gauntlet on the final commit: `mix test` exit 0 with counts,
  `mix format --check-formatted` exit 0 (root and each touched bench),
  `mix credo --strict` exit 0.
- A9 CHANGELOG, OpenSpec and guides updated; guide snippets executed.
- A10 Ledger `Contract` section present.

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-10-26T11:21 · `a5198fba-9199-4087-8540-25375c6e631e` · `/home/work_bc/.claude/projects/-home-work-bc-srv-secretariat-common/a5198fba-9199-4087-8540-25375c6e631e.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-10-26T11:21 · commit · d5d37d4

feat(verdict)!: read check, predicate and relation returns with one grammar

A @check, an @eventually predicate and a using: relation each judged
their return by their own rule, so false meant fail, not yet or
disagree depending on the attribute (DR-052 item 1a).
PropertyDamage.Verdict.read/1 reads all three: truthy passes, nil and
false are falsy, {:fail, reason} fails with that reason, and a bare
exception struct or an {:error, _} tuple fails with a sentence naming
the grammar.

Relations now go through it: Equivalence.verdict/3 is gone, by_key/1
returns true or {:fail, mismatch}, and stutter and @compare read the
using: answer through Verdict.

BREAKING CHANGE: a using: relation no longer returns :match or
{:mismatch, detail}; it returns a truthy value, false, or
{:fail, detail}.

**Files:** `lib/property_damage/comparison.ex`, `lib/property_damage/comparison_mismatch.ex`, `lib/property_damage/equivalence.ex`, `lib/property_damage/event_log/entry.ex`, `lib/property_damage/executor/stutter.ex`, `lib/property_damage/stutter.ex`, `lib/property_damage/verdict.ex`, `test/property_damage/compare_divergence_test.exs`, `test/property_damage/compare_predicate_test.exs`, `test/property_damage/equivalence_test.exs`, `test/property_damage/stutter_using_test.exs`, `test/property_damage/verdict_test.exs`

### 2026-10-26T11:29 · commit · 869bc08

refactor(checks): rewrite the if-do-fail! idiom as a predicate

A check written as `if condition, do: fail!(...)` returns nil when it
passes, and DR-052 reads a nil return as a failure (item 2). Every such
check in the library docs, the pd.gen.projection template, the
suggestion formatter, the guides, the README, the benches, and the tests
and their support modules now reads `condition or fail!(...)`, with the
condition negated where the old form tested for the failure.

Behavior is unchanged under the raising contract: a passing check
returns true instead of nil, and a failing one raises as before.

**Files:** `README.md`, `benches/cachex_bench/lib/cachex_bench/model.ex`, `benches/gitea_bench/lib/gitea_bench/state.ex`, `benches/kratos_bench/lib/kratos_bench/state.ex`, `benches/oban_bench/lib/oban_bench/retry.ex`, `benches/oban_bench/lib/oban_bench/uniqueness.ex`, `benches/openapi_bench/lib/openapi_bench/consistency.ex`, `benches/openapi_bench/test/support/load_scenario.ex`, `benches/redis_bench/lib/redis_bench/model.ex`, `guides/async_and_eventual_consistency.md`, `guides/chaos_engineering.md`, `guides/cheatsheet.md` (+49 more)

### 2026-10-26T11:30 · commit · 329d7d5

feat(check)!: judge a @check by its return value

A check written as a predicate passed on false, because a check failed
only when it raised (DR-052 item 1). The executor (every: and at:
checks), forensics, the load-test worker and the linearization checker
now read a check's return through Verdict: a truthy return passes, nil
or false fails with a message that names the check, shows the value and
gives the three accepted forms (item 4), {:fail, reason} fails with that
reason, and a bare exception or {:error, _} fails with the grammar
nudge. A raise fails as before.

The failure is an ordinary check failure with the same state snapshot;
no new failure kind and no persistence change. {:fail, "text"} carries
the same CheckFailed that fail!/2 raises, so it is fail!/2's returned
form.

BREAKING CHANGE: a @check that returned nil or false used to pass and
now fails.

**Files:** `lib/property_damage.ex`, `lib/property_damage/executor.ex`, `lib/property_damage/forensics.ex`, `lib/property_damage/linearization.ex`, `lib/property_damage/load_test/worker.ex`, `lib/property_damage/telemetry.ex`, `test/property_damage/check_verdict_test.exs`, `test/property_damage/linearization_test.exs`

### 2026-10-26T11:30 · commit · 9737bfa

feat(projection)!: refuse a @check that ends in if without else

The retired `if condition, do: fail!(...)` idiom returns nil when the
check passes, which a check now reads as a failure (DR-052 item 3). At
@on_definition a projection reads each @check clause's body, later
clauses included; a clause whose last expression is an if or unless
without else is a CompileError naming the clause and the rewrite. An if
with else, an if earlier in the body, an @eventually and a helper still
compile. The guard covers the taught shape only; any other nil return
fails at run time with the verdict message.

BREAKING CHANGE: a projection whose @check ends in if or unless
without else no longer compiles.

**Files:** `lib/property_damage/model/projection.ex`, `test/property_damage/check_tail_guard_test.exs`

### 2026-10-26T11:35 · commit · 4127a9d

feat(eventually)!: read the @eventually predicate as a verdict

The poller treated a raise inside the predicate as "not yet": it kept
the error as last_predicate_error and polled until the window expired,
so a partial predicate cost the whole window per trigger and surfaced as
a timeout. A predicate also had no way to say "never" (DR-052 item 6).

StatePoller now reads each poll through Verdict: nil and false are not
yet, a truthy value is satisfied, and {:fail, reason} (or a value that is
not a verdict) ends the window at once with a {:failed, id, info} result.
A raise, exit or throw in the predicate ends it at once too, as a
CheckFailed naming the check, the poll count and what escaped; the
poller never dies of it. Finalization and the lockstep variant report a
failed window as a check failure at the command that opened it, under
check_mode as before. last_predicate_error is gone, and the timeout
report says the predicate never became true, with nothing else.

BREAKING CHANGE: a predicate that raised to mean "not yet" now fails
at its first poll; write it as a total predicate that returns false.

**Files:** `lib/property_damage/executor/finalization.ex`, `lib/property_damage/failure_report/formatter.ex`, `lib/property_damage/state_poller.ex`, `lib/property_damage/variant.ex`, `test/property_damage/eventually_verdict_test.exs`, `test/property_damage/state_poller_test.exs`

### 2026-10-26T11:41 · commit · 690d009

docs(checks): teach one verdict grammar for the three kinds

The guides and moduledocs taught that a check fails only by raising and
that a using: relation returns :match or {:mismatch, _}; both changed
with DR-052. The Projection moduledoc now carries the grammar table, the
three verbs (a @check judges its return, an @eventually its predicate's
return, a @compare its value through the relation), the three accepted
check forms, and composition with `with true <- ...` beside the `&&`
trap. writing_invariants.md gains the same, async_and_eventual_consistency.md
teaches total predicates and {:fail, reason} as "never", and the
cheatsheet, differential, idempotency and path-equivalence guides and the
README use the verdict forms. The runnable idempotency example reads a
retry through Stutter.compare_events/3 now that Equivalence.verdict/3 is
gone.

**Files:** `README.md`, `guides/async_and_eventual_consistency.md`, `guides/cheatsheet.md`, `guides/differential_testing.md`, `guides/idempotency_testing.md`, `guides/path_equivalence_testing.md`, `guides/writing_invariants.md`, `lib/mix/tasks/pd.gen.projection.ex`, `lib/property_damage/model/projection.ex`

### 2026-10-26T11:42 · commit · 5e84bc9

docs(openspec): specify the verdict grammar of DR-052

The projection, eventual-consistency, differential-testing and
concurrency specifications still described a check that fails only by
raising, a poller that treats a raise as not yet, and relations that
return :match or {:mismatch, _}. They now require the verdict grammar:
a @check passes on a truthy return and fails on nil, false or
{:fail, reason} with the item-4 message, a check ending in if without
else is a compile error, an @eventually predicate's {:fail, reason} or
raise ends the window at once as a check failure, and a using: relation
returns a verdict read by PropertyDamage.Verdict. Each change carries
Given/When/Then scenarios referencing DR-052.

**Files:** `openspec/specs/concurrency/spec.md`, `openspec/specs/differential-testing/spec.md`, `openspec/specs/eventual-consistency/spec.md`, `openspec/specs/projection/spec.md`

### 2026-10-26T11:42 · commit · dd1d21b

docs(changelog): record the DR-052 verdict grammar as breaking

The unreleased section gains one BREAKING entry for DR-052: the three
accepted @check forms, the compile error for a check ending in if
without else, the @eventually never-and-raise changes, and the retired
:match and {:mismatch, _} relation returns with Equivalence.verdict/3.

**Files:** `CHANGELOG.md`

### 2026-10-26T11:57 · commit · a14c438

fix(eventually): keep the raised exception when a predicate raises

A raise inside an @eventually predicate was wrapped in a CheckFailed to
carry the poll count, so ErrorOrigin classified a bug in the predicate
as an SUT error. The poller now keeps the raised exception itself, with
its stacktrace (an exit or a throw becomes an ErlangError holding it).
The check name and poll count travel beside it: Failure.eventually_failed/1
builds the check failure with the exception as its detail and the poll
count and elapsed time in a new Failure.Check context field, and the
report message names the check and the poll. A {:fail, reason} "never"
keeps its CheckFailed and stays an SUT error.

**Files:** `lib/property_damage/executor/finalization.ex`, `lib/property_damage/failure.ex`, `lib/property_damage/failure_report.ex`, `lib/property_damage/scheduler.ex`, `lib/property_damage/state_poller.ex`, `lib/property_damage/variant.ex`, `openspec/specs/eventual-consistency/spec.md`, `test/property_damage/eventually_verdict_test.exs`, `test/property_damage/state_poller_test.exs`

### 2026-10-26T11:58 · commit · f9b28b3

docs(changelog): describe the relation verdict in the unreleased DR-046 entries

The :match and {:mismatch, _} relation returns were added and retired
inside the same unreleased section, so their retirement breaks no 0.2.0
user. The DR-046 entries for @compare using:, Equivalence and stutter
using: now describe the final verdict grammar, and the DR-052 BREAKING
entry keeps only what breaks a 0.2.0 user: the check return verdict,
the retired idiom's compile error and the @eventually predicate
semantics.

**Files:** `CHANGELOG.md`

### 2026-10-26T12:11 · commit · 306fbd3

docs(notebooks): rewrite the demo notebook's checks as predicates

The first DR-052 sweep missed the Livebook notebook. Its two
assert_balance_non_negative checks ended in `unless ... do fail!(...)
end`, which the compile guard now refuses, so the docs gate failed on
the notebook. Both checks now read `negative == [] or fail!(...)`, and
the notebook's prose says a check's return is its verdict instead of
"a returned value is ignored".

**Files:** `notebooks/property_damage_demo.livemd`

### 2026-10-26T12:14 · commit · afe389c

test(scheduler): cover the poll context of a recorded lockstep failure

Scheduler.recorded_failure/1 restores the poll context of an
@eventually failure recorded under check_mode: :record, and no test
drove it. A two-target run under :record with a raising predicate now
asserts that the reported check failure carries context.poll_count, the
raised KeyError, and a message naming the check and the poll.

**Files:** `test/property_damage/eventually_verdict_test.exs`

## Reconstruction

Written 2026-10-26 by the orchestrator when the PR opened, from the implementer's
hand-back reports in this session's transcript. Labeled as reconstruction: it
extends the Record and does not contradict it.

- **Interpretation points the implementer raised and did not decide alone.**
  Quoted from the first hand-back: "Seven interpretation points need your
  ruling; none blocked the work." They were the `read/2` signature, the relation
  nudge row, the silently-agreeing retired forms, persisted values without a
  version bump, the error-origin classification of a predicate raise, the
  uncovered `{:fail, other}` shape, and the CHANGELOG `:match` mention. Rulings:
  1 and 2 and 4 and 6 accepted as interpretations; 5 and 7 became fix-backs A
  and B (commits a14c438, f9b28b3); 3 is recorded as a proposed DR-052 amendment
  for the owner, not implemented.
- **Why the idiom rewrite commit precedes the verdict commit.** Quoted: "The
  idiom rewrite lands before the check verdict and the compile guard. Either of
  those would otherwise turn the old idiom red, so each commit stays green on
  its own."
- **How the sweep was done and what it missed.** Quoted: "A scripted rewrite
  handled about 120 sites; the rest I edited by hand." The sweep covered lib,
  test, guides, benches and README; the orchestrator's run of the docs gate
  with network found two more sites in `notebooks/property_damage_demo.livemd`,
  fixed as fix-back C (306fbd3).
- **Offline workarounds that were later replaced by online runs.** Quoted:
  "I seeded its template inside the worktree's gitignored `tmp/` from the main
  checkout's cached packages, so no network was used." The gate was later run
  with network and a fresh template (exit 0, 18 passed). Benches were "rewritten
  and format-checked, but not compiled or tested" in the first round; the
  orchestrator compiled all six under OTP 27 afterwards.
- **Fix-back A deviation.** Quoted: "`Exception.normalize/3` hands back exit and
  throw payloads unchanged, so it produces no exception there. I wrap those as
  `%ErlangError{original: {kind, reason}}` instead."
- **Fix-back D outcome.** Quoted: "the clause in `Scheduler.recorded_failure/1`
  that restores the context is live code, not dead." RED with the clause
  removed: 7 tests, 1 failure.
