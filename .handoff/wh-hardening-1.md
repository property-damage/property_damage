# Handoff ledger: wh-hardening-1

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the hardening wave's status line and its table of filed findings in the campaign's design and tracking files (not in this repository); this is the first of up to three pull requests and carries the text-only findings plus the whole-tree sweeps.

Asked:

- Remove process language left on reviewer-visible surfaces (planning and audit ids in comments, test names, the changelog and two decision records), so a reader meets the code's own words.
- Reword comments that describe deleted code (the load-test wrapper in the executor timeout, the replay entry in the verification moduledoc) and reflow over-wide comment lines.
- Rename the concurrency spec after what it still holds (stutter and idempotency) and leave no reference to the old path.
- Cite the record that removed the branching mode on the citation line of every spec that changed under it, and drop the branch wording those specs kept.
- Close the overview gaps in CLAUDE.md and the `PropertyDamage` moduledoc: the `at:` check point, glosses for the terms used before they are defined, the `injectors:` target option.
- Make `openspec validate --all` pass by strengthening the load-testing requirements that are implemented to SHALL, each backed by a test.
- Run the whole-tree sweeps for retired names and process language and record what remains with a reason.

Acceptance criteria:

- The process-id predicate over lib, test, guides, openspec, docs, benches, the changelog, the README and CLAUDE.md finds nothing at the head and finds hits at the base.
- The old spec directory is gone, the new one exists, and no file in the tree references the old path.
- Every changed spec's citation line in the decision-record index names the branching-removal record.
- `openspec validate --all` exits zero; each requirement strengthened to SHALL cites a test that exercises it.
- The full local gate passes; the module cycle count equals the gate in the CI workflow.

Non-goals: behavior changes (the one new test pins existing behavior); the explain prompt's wording (deferred by ruling: its hash and version pin make any change a versioned event); the shrinker's per-candidate idempotency key (deferred to the generator-aware shrinking wave); the code findings of the next two pull requests.

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-10T00:22 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-10T00:22 · commit · 21fbcd0

docs(spec): rename the concurrency spec and use SHALL in its requirements

The concurrency spec holds only stutter and idempotency requirements, so rename it after them. Four requirements used MAY or SHOULD and failed validation: ramp-down, progress callback and think time are implemented, so state them with SHALL.

**Files:** `docs/decisions/README.md`, `openspec/specs/load-testing/spec.md`, `openspec/specs/stutter-and-idempotency/spec.md`

### 2026-11-10T00:22 · commit · dd77e78

docs(spec): drop the removed branching mode from the specs

Six specs still described parallel branches, branch-aware positions and branch progress info after the mode was removed. State the sequence behavior without them and cite the removal record in the three specs it changes.

**Files:** `docs/decisions/README.md`, `openspec/specs/command/spec.md`, `openspec/specs/differential-testing/spec.md`, `openspec/specs/execution-engine/spec.md`, `openspec/specs/export/spec.md`, `openspec/specs/failure-analysis/spec.md`, `openspec/specs/observability/spec.md`

## Reconstruction

Assembled afterwards by the orchestrating session from the on-disk reports of the wave (campaign evidence, outside this repository). Labeled as reconstruction; the Record above wins where they disagree.

- The implementer's progress log on the explain prompt: "D priv/explain/instructions.md: NOT done. Changing the prose changes the prompt hash; explanation_pin_test pins sha256 and requires @prompt_version bump. Contract decision left to orchestrator." The sub-orchestrator escalated it; the orchestrator ruled it deferred to the next prompt revision.
- The implementer's progress log on the index citations: "E docs/decisions/README.md DR-063 citations: NOT added. The four specs do not cite DR-063; failure-analysis (lines 328, 515) and observability (line 186) still carry branch wording the DR says to remove." A second implementer then dropped the branch wording from six specs and added the citations; the orchestrator's verify controls found three more specs and three residue lines in two decision records, added in the fifth commit.
- The sub-orchestrator's report on the strengthened requirements: "RAT.2 (SHALL; tests at 1bbdaf8: Ramp Down load_test_test.exs:1370,1414; Progress Callback :1113; Think Time had none, test added 5db8a29 with mutation control think_mut.log, RED when maybe_think removed)."
- The sub-orchestrator's report on the sweeps: "K1 hits remaining are valid names, the legacy failure_type load path in seed_library.ex, decision records and CHANGELOG history; K2 remaining are English 'orchestrate' and orchestrate/4 identifiers in pd.bisect (not process language)."
- The sub-orchestrator's report on a process deviation: "implementer could not commit; sub-orchestrator staged by name and committed."
- The hook's Record lists only the commits made from sessions it observed; the first two commits of the branch (comments and tests residue; glosses in the top-level texts) and two later ones (citations and record residue; the think-time test) were committed by an agent the hook did not capture, so they appear in `git log` and not above. The seventh commit (the decision-record path fix) was made by the orchestrating session after its own verify found the dangling path.
