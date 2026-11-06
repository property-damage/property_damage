# Handoff ledger: w0-guardrails

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the framework's abstraction audit (2026-11-03), guardrails section: a ratchet on module dependency cycles, tests that record four documented defects before their fixes, and a matrix over every reader of a projection's check metadata.

Asked:

- A CI step in the lint cell that fails when `mix xref graph --format cycles` counts more cycles than the count measured on the base commit. The count never rises; a change that removes cycles lowers the number in the same change.
- `test/test_helper.exs` excludes the `known_defect` tag; a tagged test fails on the base commit when included; the change that fixes the defect removes the tag.
- Tagged tests for: `Forensics.analyze/1` raising on a projection with an `@eventually` or `@check at:` check; `Sequence.Validator.valid_sequence?` rejecting the unshrunk generated sequence of a model keyed by a server-minted id with a `when:` guard on two ids; `LoadTest.Worker` sequence generation drawing degenerate values and ignoring the seed. An untagged test that a killed mutation's message equals `FailureReport.failure_message/1` of its report.
- A check-form matrix fixture under `test/support/` declaring every form the projection macros can emit, one test per reader of the check list, the reader list derived by `grep -rln '__checks__' lib`, crashing readers tagged.
- The matrix derives the set of forms from the macro module, not from a hand-written list.
- No change under `lib/`.

Acceptance criteria:

- `mix xref graph --format cycles --fail-above <N-1>` exits non-zero and `--fail-above <N>` exits zero, at the base commit and at the branch head, with N the number written in `ci.yml`.
- `mix test --include known_defect` over the five test files fails exactly the tagged tests, each for the reason its name states; nothing else fails.
- Deleting one form from the matrix fixture turns the matrix test red; restoring it turns it green.
- The full local gate passes with the tagged tests excluded.

Non-goals: fixing any of the four defects; editing any file under `lib/`; editing test files that mention the fault-injection subsystem (another branch removes it).

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-06T21:45 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-06T21:45 · commit · a261315

ci: describe the cycle gate as counting every module dependency cycle

The comment above the cycle gate said it counts compile-time cycles, but
mix xref graph --format cycles counts runtime cycles as well. Name what
the gate actually counts.

**Files:** `.github/workflows/ci.yml`

## Reconstruction

Written when the PR opened, from the agent reports kept outside the repo; labeled as reconstruction.

- The Record holds one of the seven commits; six were made by an implementing agent whose commits the hook did not capture, and the verifier re-derived every claim about them from the tree.
- The implementer reported: "Spec discrepancy: integer(-1000..1000) is size-independent, so the load-test assertion (a) passed today; I used StreamData.integer() and it now fails as intended."
- The implementer reported: "Gate ran once on the full tree, then committed per item (not re-run per commit)." The verifier then checked each commit compiles, is formatted and passes its own test files.
- The verifier reported a new finding: "Suggestions.analyze raises KeyError :trigger on an @eventually check, a fourth copy of the check-loop defect."
