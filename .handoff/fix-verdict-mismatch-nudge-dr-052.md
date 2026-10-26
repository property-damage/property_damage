# Handoff ledger: fix/verdict-mismatch-nudge-dr-052

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seed this
from whatever produced it: a grill-me ledger, a campaign wave contract, a
ticket, or by hand.

Source: the three record amendments the owner approved on 2026-10-26 after #84 (DR-052) and #85 (DR-051) merged, dispatched to an implementer by the orchestrator's brief (private vault, `dispatch_amend.md`).

Asked:
- `Verdict.read/2` fails the retired `{:mismatch, _}` shape with the grammar nudge for every kind, because under the grammar it is truthy and an unrewritten relation agrees silently (witnessed on a consumer); `:match` stays as it is.
- DR-052 record: item 1b names three shapes with the reason for `{:mismatch, _}` and for leaving `:match` out; the item 1a table lists the third shape; one sentence after the table says a `{:fail, other}` reason that is neither a string nor an exception is wrapped with `inspect/1`; the Status line carries the amendment.
- DR-051 record: item 6 says `stutter: [using:]` takes `{Mod, :fun}` and `{Mod, :fun, args}` beside a function and refuses a bare `:fun`, with the reason; the Status line carries the amendment.
- CHANGELOG `[Unreleased]`: the DR-052 BREAKING entry extended in place.
- Every sentence in lib, guides, README and OpenSpec that lists the nudge shapes agrees with the record.

Acceptance criteria:
- `A1` `Verdict.read({:mismatch, _}, kind)` returns `{:fail, exception}` carrying the nudge for every kind, and a `using:` relation returning it disagrees with that message in the report; the RED log shows the tests failing on the pre-change code.
- `A2` DR-052 item 1b, its table, the inspect sentence and the Status line read as asked.
- `A3` DR-051 item 6 and its Status line read as asked.
- `A4` The CHANGELOG entry is extended in place, no new version and no new BREAKING line.
- `A5` On the final commit under Elixir 1.20: `mix test`, `mix format --check-formatted`, `mix credo --strict` and `mix compile --warnings-as-errors --force` all exit zero.
- `A6` `git diff -w --stat main` lists only intended files.

Non-goals: a persistence version bump; any change to the `:match` reading; a release cut (deferred by the owner).

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-10-26T15:49 · `a5198fba-9199-4087-8540-25375c6e631e` · `/home/work_bc/.claude/projects/-home-work-bc-srv-secretariat-common/a5198fba-9199-4087-8540-25375c6e631e.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-10-26T15:49 · commit · 1e77a45

fix(verdict): fail the retired {:mismatch, _} shape with the grammar nudge

A relation that still returns the retired DR-046 form {:mismatch, detail}
returned a truthy value, so Verdict.read/2 agreed silently. It now fails with
the grammar nudge, carrying the value, for every kind. :match stays truthy:
it meant agreement, so nothing is lost. The guides, moduledocs and OpenSpec
scenarios that list the nudge shapes now list the third one.

**Files:** `guides/async_and_eventual_consistency.md`, `guides/cheatsheet.md`, `guides/differential_testing.md`, `guides/writing_invariants.md`, `lib/property_damage/equivalence.ex`, `lib/property_damage/model/projection.ex`, `lib/property_damage/verdict.ex`, `openspec/specs/differential-testing/spec.md`, `openspec/specs/eventual-consistency/spec.md`, `openspec/specs/projection/spec.md`, `test/property_damage/compare_predicate_test.exs`, `test/property_damage/verdict_test.exs`

### 2026-10-26T15:49 · commit · 896b17f

docs(decisions): amend DR-052 for the {:mismatch, _} nudge and the inspected reason

Item 1b names the retired {:mismatch, _} as a third non-verdict shape, and
the item 1a table lists it. The record also states what verdict.ex already
does with a {:fail, reason} whose reason is neither a string nor an
exception: it wraps inspect(reason).

**Files:** `docs/decisions/DR-052-check-verdict-by-return.md`

### 2026-10-26T15:49 · commit · ed3781b

docs(decisions): clarify DR-051 item 6, the stutter forms

Item 6 said stutter: [using:] accepts "the same named forms". The option
takes {Mod, :fun} and {Mod, :fun, args} beside a 2-arity function and
refuses a bare :fun, because a run option has no projection module to
resolve a local name against. The record now says so.

**Files:** `docs/decisions/DR-051-named-comparators.md`

### 2026-10-26T15:50 · commit · d2c0a2b

docs(changelog): note the {:mismatch, _} nudge

The DR-052 entry gains one sub-bullet: a relation returning the retired
{:mismatch, detail} now disagrees with the grammar nudge instead of agreeing.

**Files:** `CHANGELOG.md`

### 2026-10-26T15:53 · commit · 63ae013

docs(changelog): list the retired {:mismatch, _} in the DR-052 lead sentence

The lead sentence of the DR-052 BREAKING entry named two nudge shapes; it now
names the third, so it agrees with the sub-bullet and the record.

**Files:** `CHANGELOG.md`

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

_Not yet written._
