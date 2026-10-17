# Handoff ledger: docs/check-contracts-dr-051-052

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seed this
from whatever produced it: a grill-me ledger, a campaign wave contract, a
ticket, or by hand.

Source: the rulings of 2026-10-16 and 2026-10-17 on the check contracts
(named comparators, the check verdict with two amendments, the future of
branching), recorded as decision records before any implementation.

**Asked.** Three new decision records, Accepted, with the index and the
amended status line of DR-046: DR-051 (named comparators), DR-052 (a check's
verdict is its return value, one grammar for the three check kinds) and
DR-053 (branching runs one branch at a time until the concurrent redesign).
Documentation only: no library code, no guide, no CHANGELOG entry.

**Acceptance criteria.**

- Each record is self-contained: context, numbered decisions, consequences,
  alternatives considered, so a reader who has not seen the ruling can
  reconstruct it.
- The three records agree with each other where they touch: the verdict
  reader, the retired relation answers, the `using:` forms.
- The records agree with `main` as it stands at the merge: nothing they call
  future is already shipped without saying so, and nothing they call current
  has been removed.
- The index lists the three records and names every spec that cites them.
- No campaign or vault vocabulary in the repository.

**Non-goals.** Implementing DR-051 or DR-052 (a breaking migration, its own
branch); the branching redesign; any change to code.

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-10-17T18:47 · `a9f269c9-a9a4-4923-a1de-e3f98470ccf8` · `/home/work_bc/.claude/projects/-home-work-bc-srv-secretariat-common/a9f269c9-a9a4-4923-a1de-e3f98470ccf8.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-10-17T18:47 · commit · 6ae9b81

docs(decisions): reconcile DR-051 and DR-052 with the shipped eventually fix and the spec index

DR-051 item 4 still named Equivalence.verdict/3 as unchanged while item
2 replaces it with Verdict.read/1. DR-052 item 5 now says the failure
follows check_mode, as the shipped fix does, and its consequences say
the item shipped ahead of the record. The index of specs that cite
records gains the concurrency and eventual-consistency citations.

**Files:** `docs/decisions/DR-051-named-comparators.md`, `docs/decisions/DR-052-check-verdict-by-return.md`, `docs/decisions/README.md`, `openspec/specs/eventual-consistency/spec.md`

### 2026-10-17T18:40 · decision · review before push

The branch was rebased onto `main` after the hardening PR (#82) merged; none of its files had changed on `main`, so the rebase was a fast-forward. A consistency read found one contradiction (DR-051 item 4 named the old verdict reader as unchanged) and one drift against `main` (DR-052 item 5 had shipped in #82 under `check_mode:` handling without the record saying so); both fixed in commit 6ae9b81, with the spec citation index updated. The four earlier commits (f59529b, be2309f, ac77a6b, a1d49bc after the rebase) predate the ledger.

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

_Not yet written._
