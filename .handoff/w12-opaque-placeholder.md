# Handoff ledger: w12-opaque-placeholder

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seed this
from whatever produced it: a grill-me ledger, a campaign wave contract, a
ticket, or by hand.

Source: the maintainer's design rulings of 2026-11-09 for the placeholder (contracts recorded in the design record, section "opaque placeholder"), from the abstraction audit's finding that users already meet placeholders in `when:`, `overrides:` and simulator code while the type is undocumented, and that `resolved: nil` makes a system that answers `nil` for an `external()` field read as never answered.

Asked:

- A decision record: the placeholder is a public opaque type read through accessors; the unresolved state is an explicit marker and a system that answers `nil` resolves to `nil`; a producing event that lacks the field leaves the placeholder unresolved; the serialized shape changes, so the persistence version and the replay artifact format bump and older files are refused. Index row; the execution-engine, command and persistence specs amended.
- Locked before the move: an end-to-end run whose adapter answers an event with the `external()` field set to `nil`, consumed by a later root, resolves the value to `nil` and reports no unresolved placeholder (red at the base); the same through a setup command; a control where the producing event lacks the field stays unresolved; accessor contract tests for `id/1`, `position/1`, `path/1`, `event_module/1`, `event_index/1`, `resolved?/1`, `value/1` and `value!/1`; refusal fixtures written by the base code for the previous persistence version and the previous replay format, each with a loader refusal test; the assertions that pinned the old marker rewritten.
- The type: a moduledoc, `@opaque t`, the accessors as the only way the library reads a placeholder; the `resolved` field keeps its name and takes `:unresolved | {:resolved, term()}`; `External.fetch_at_path/2` distinguishes a missing path from a `nil` value and capture uses it; one resolution implementation in the registry with the executor leaf delegating; the guides show the accessors where user code touches a placeholder, with at least one runnable `when:` or `overrides:` example.
- Hygiene: persistence version bumped by one and replay artifact format `4`; loaders refuse older files with the existing error shapes; the comment blocks and moduledocs updated; the version-pinning tests keep reading one accessor; the tracked bench replay fixture regenerated and the bench suites run; the cycle count does not rise; residue sweep for the old marker across lib, test, guides, specs and docs; sweep of the placeholder, external, registry and executor moduledocs and the repository guidance line; CHANGELOG Breaking and Added; full gate and the two zero-infrastructure benches.

Acceptance criteria:

- A grep for struct literals of the placeholder with a field, and for `.resolved`, `.event_module` or `.event_index` on a variable receiver, over the library finds hits in the placeholder module only; a grep for the old marker over lib and test is empty apart from the tracked previous-format fixture.
- The nil-answering tests pass at the head and fail at the base; the missing-field control passes at both.
- The loaders refuse the two tracked previous-format fixtures with the existing error shapes; the accessor tests pass.
- The decision record exists and is indexed; the full local gate passes; the module cycle count does not rise.

Non-goals: changes to the registry's public status (it stays internal); the failure report, the load-test worker, the runner and the scheduler; the service-container benches (CI runs them).

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-09T23:07 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-09T23:07 · commit · 177081a

test(placeholder): lock the unresolved marker, the accessor contract and the format refusals

A system that answers nil for an external() field reads as unresolved, because
a nil value is also the marker of an unresolved placeholder. Lock the target
behavior: a nil answer resolves the placeholder, a missing field leaves it
unresolved, and a placeholder is read through accessors, never its fields.
The tests that need the change carry the known_defect tag, which the change
removes.

Rewrite the existing field reads to use the accessors so they hold before
and after the change, and add refusal tests for the saved report at version
20 and the replay artifact at format 3.

**Files:** `test/property_damage/persistence_format_version_test.exs`, `test/property_damage/placeholder_accessors_test.exs`, `test/property_damage/placeholder_nil_answer_test.exs`, `test/property_damage/placeholder_registry_test.exs`, `test/property_damage/placeholder_test.exs`, `test/property_damage/replay_artifact_loader_test.exs`

### 2026-11-09T23:15 · commit · a7239ca

refactor: read placeholders through their accessors

Readers matched placeholder fields directly, which ties them to the struct
layout that the opaque type now hides. Each reader calls the accessors of
PropertyDamage.Placeholder instead.

**Files:** `lib/property_damage/analysis.ex`, `lib/property_damage/executor/phases.ex`, `lib/property_damage/expansion.ex`, `lib/property_damage/export/common.ex`, `lib/property_damage/export/step_plan.ex`, `lib/property_damage/generator.ex`, `lib/property_damage/shrinker/graph.ex`

### 2026-11-09T23:18 · commit · 0d6f885

docs: record the placeholder as a public opaque type

A placeholder was read by struct fields and marked unresolved with
`resolved: nil`, so a system that answered nil looked unanswered. DR-067
makes the type opaque, read through accessors, with an explicit
`:unresolved | {:resolved, term()}` marker, and records the format bumps.

**Files:** `docs/decisions/DR-067-opaque-placeholder.md`, `docs/decisions/README.md`, `openspec/specs/command/spec.md`, `openspec/specs/execution-engine/spec.md`, `openspec/specs/persistence/spec.md`

### 2026-11-09T23:22 · commit · d99cc9b

feat(persistence)!: bump the formats for the placeholder marker

A saved placeholder marks "unresolved" with nil, which the opaque
placeholder now reads as a resolved nil, so old files would load with the
wrong meaning. Persistence moves to version 21 and the replay artifact to
format 4; both loaders refuse older files with their existing errors. The
tracked bench artifact is regenerated at format 4.

BREAKING CHANGE: reports saved at version 20 or older and replay artifacts
of format 3 or older can no longer be loaded.

**Files:** `benches/cachex_bench/test/fixtures/Model_seed3.replay.exs`, `lib/property_damage/persistence.ex`, `lib/property_damage/replay_artifact.ex`, `test/property_damage/failure_identity_artifact_test.exs`, `test/property_damage/failure_identity_persistence_test.exs`, `test/property_damage/persistence_format_version_test.exs`, `test/property_damage/replay_artifact_loader_test.exs`, `test/property_damage/replay_artifact_test.exs`, `test/property_damage/replay_artifact_trust_test.exs`, `test/property_damage/replay_witness_test.exs`

### 2026-11-09T23:24 · commit · 9bb1365

docs: show placeholders read through accessors

The guides showed placeholders as structs and said nothing about reading
one. They now show the accessors, with a runnable example in the writing
commands guide, and the changelog lists the opaque type, the unresolved
marker and the format bumps.

**Files:** `CHANGELOG.md`, `CLAUDE.md`, `guides/debugging_failures.md`, `guides/quickstart.md`, `guides/static_regression_tests.md`, `guides/writing_commands.md`

### 2026-11-09T23:27 · commit · 7044b37

docs(changelog): link the placeholder type as a type reference

ex_doc warned about a function reference to Placeholder.t/0, which is a
type.

**Files:** `CHANGELOG.md`

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

_Not yet written._

Labeled reconstruction: assembled from the wave's on-disk reports after the commits, with verbatim quotes. It extends the Record and contradicts none of it.

- Three of the branch's nine commits have no Record entry (`23dd208` the refusal fixtures, `4be2c9f` the type and marker, `9e464f2` the specs); the hook did not capture them. Their messages are in the git log and the orchestrator's report (`evidence/w12/suborch_report_w12.md`) lists all nine.
- Re-pointed tests (same report, R1): the setup-command tests that used a fixture answering `id: nil` were "re-pointed" to a producing event that lacks the field, "because `id: nil` now resolves to nil".
- Old-format fixture (R2): "format_3 fixture keeps resolved: nil" because it is old-format data written by the base code; the residue grep excludes it.
- New function (R3): `Placeholder.retarget/2` was added for the registry's alias rewriting, which had rewritten struct fields directly; listed under CHANGELOG Added.
- Error wording (R4): the executor's message changed from "Unknown placeholder: " to "Unknown placeholder ID: " because "step delegates to the registry's single implementation" and the registry's tests lock that wording.
- Grep predicate (R5): the dot grep is "anchored on variable receiver" so that calls on the module itself (`Placeholder.event_module(...)`) and the mutation structs' own `event_index` do not count.
- Type-checker warnings (R6): the locked accessor test "emits type-checker 'comparison between distinct types' warnings (lines 104,108); amend in hardening"; the warnings are not errors and the locked file was left unchanged.
- Record order (R7): "DR-067 landed after the code"; the squash removes the ordering.
- Residue prose (R9): five library doc lines still say the placeholder is a struct; the orchestrator found them "still accurate (the placeholder is a struct internally), no edit".
- Red proof (same report): "exit 2, 104/131 passed, 27 failed incl. 3 nil-answer e2e (root id, root nested path, setup), accessors, refusals. Missing-field control GREEN at base and at head."
