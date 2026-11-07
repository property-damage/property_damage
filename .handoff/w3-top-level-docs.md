# Handoff ledger: w3-top-level-docs

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seed this
from whatever produced it: a grill-me ledger, a campaign wave contract, a
ticket, or by hand.

Source: the design ruling of 2026-11-06 that the top-level documentation is rewritten to describe the framework as it is after the removals of the fault-injection subsystem and the branching mode, from the codebase brief's summary rather than by patching sentences.

Asked:

- Rewrite the `PropertyDamage` moduledoc overview: the user contracts (Command, Model, Projection, Adapter, Target), the two phases, one engine, how symbolic values are represented, where checks run; no `Refs`, no `Tier 0` to `Tier 3`, no nemesis, no branching.
- Sweep `lib`, `guides`, `README.md` and `CLAUDE.md` for `Refs` and `Tier 0` to `Tier 3`, triage every hit, fix those that describe the old design in the files this branch owns, and file the rest with file and line.
- Refresh the CLAUDE.md architecture section so it matches main after the two removals: the behaviours, the execution flow, a subsystem list naming no removed module.

Acceptance criteria:

- A reader given only the moduledoc and CLAUDE.md answers correctly: which contracts a user writes, how many engines exist, how symbolic values are represented, where checks run, and whether a branching mode or a nemesis exists.
- `grep -rn -i -E '\bRefs?\b|Tier [0-3]' lib/property_damage.ex CLAUDE.md README.md guides` returns no hit that describes the old design.
- `mix docs --warnings-as-errors` reports no warning and the documentation gate passes.

Non-goals: code changes of any kind; guides' code examples that a concurrent engine change will alter; any file outside `lib/property_damage.ex` (moduledoc), `CLAUDE.md`, `README.md` and `guides/`.

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-07T00:47 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-07T00:47 · commit · 0f7b76e

docs: refresh the architecture notes in CLAUDE.md

The architecture notes named the adapter callback as execute/2 and described
a single executor, with no mention of the scheduler, variants or the failure
records. Correct the callback arity, describe the lockstep execution flow, and
list the scheduler, variant, stepping seam, run trace, run comparison, failure
report and persistence modules.

**Files:** `CLAUDE.md`

### 2026-11-07T00:49 · commit · f9f17e7

docs: drop the old-design wording from the guides and README

The README architecture section described a Tier 0 to 3 layout and a
guide mentioned a removed refs: option. Replace the tree with a layer
list that matches the moduledoc, and drop the stale sentence.

**Files:** `README.md`, `guides/static_regression_tests.md`

### 2026-11-07T00:56 · commit · c3916aa

docs: use a colon after the new subsystem names in CLAUDE.md

The subsystem entries added to the architecture notes used em-dashes
where the style guide asks for a colon. Replace them.

**Files:** `CLAUDE.md`

### 2026-11-07T01:00 · commit · f5635f1

docs: align the overview and the architecture notes on contracts, roots and compare timing

The moduledoc and CLAUDE.md disagreed, and two statements were wrong: Target
is a struct built from a targets: entry, not a behaviour the user writes, and
the scheduler compares targets after each root, not after each command. Say
so in both files, drop the "engine" label from the Executor line, and gloss
root, expansion, differential run and path-equivalence run where each first
appears.

**Files:** `CLAUDE.md`, `lib/property_damage.ex`

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

_Reconstruction, written at PR open from the review record kept outside the repo (the agents that wrote the text ran as subagents whose transcripts are not listed under Sessions, so this tier quotes that record, not a transcript)._

- The Record above misses the first commit, `ea4d21f` (docs: rewrite the PropertyDamage overview), which the hook did not capture; `git log` is the authority.
- The sweep triage (136 hits at the base) is recorded in the review evidence: "ORDINARY 133, OLD-DESIGN-FIXED 3, OLD-DESIGN-FILED 0"; the three fixed hits were the README's tier tree and a stale `refs:` sentence in the static-regression guide.
- A clean-context read of the moduledoc and CLAUDE.md after the third commit answered the five acceptance questions correctly but found two statements wrong and three terms drifting between the files; the record: "Target as a module the user writes; `@compare` after each command instead of each root". The last commit aligned both files and glossed root, expansion, differential and path-equivalence at first use.
