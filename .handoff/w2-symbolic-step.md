# Handoff ledger: w2-symbolic-step

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seed this
from whatever produced it: a grill-me ledger, a campaign wave contract, a
ticket, or by hand.

Source: the design rulings of 2026-11-06 for the symbolic step: the shrink validator must mint placeholders the way generation does, command specs must resolve through one table, `mix pd.validate` must warn when a model has no simulator, and load-test workers must draw from a seed; plus the maintainer's ruling of 2026-11-07 that the load test gains a `seed:` option because it had no run seed to derive from.

Asked:

- `Sequence.Validator.valid_sequence?` takes the candidate `%Sequence{}` and folds each root through the generator's simulation, minting placeholders; the private fallback that skipped minting is deleted; the shrinker and Analysis pass the candidate sequence.
- One spec table, `Model.spec_table/1`, replaces the executor's private table and the shrinker's and Settle's own lookups; listing a module twice is a validation error at run time and in `mix pd.validate`, naming both entries.
- `mix pd.validate` warns when a model defines no `simulator/0`, and the message names the consequence.
- `LoadTest.Worker` draws sequences through the generator's sized, seeded path with a seed derived from the run seed and the worker index; the load test gains a `seed:` option, drawn at random when absent and recorded with the result.
- The two known-defect tags for the validator and the worker are lifted in this change.

Acceptance criteria:

- The validator test and the worker test that were checked in tagged as known defects pass with the tag removed, and fail at the base commit with the tag included.
- A seeded failing campaign on the id-keyed model shrinks to a three-command reproduction (it stuck at seven at the base commit).
- A model listing a command with `shrink: :prefer_keep` keeps that command through a real shrink; the same model without the option drops it.
- Two load-test runs with the same `seed:` send the same commands from each worker; draws cover the generator's whole range.
- The full local gate passes and the module cycle count does not rise.

Non-goals: replacing the load-test worker loop (a later change); the executor's expansion fallbacks; files the concurrent documentation change owned until it merged.

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-07T01:01 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-07T01:01 · commit · c4b3ef1

fix(validator): mint placeholders when checking a shrink candidate

The shrinker's validity check re-simulated a candidate without minting
placeholders, so every event carrying an external() field folded the same
unresolved marker. A state keyed by minted ids collapsed to one key, a
command whose when: needs two ids was judged invalid, and every candidate
holding it was rejected.

Sequence.Validator.valid_sequence?/3 now takes the candidate sequence and
walks its roots through Generator.simulate_root/6, linking each root's
events to the placeholders the registry holds for its position, as
generation does. The list form and the private simulation path are removed.

**Files:** `CHANGELOG.md`, `benches/gitea_bench/test/sequence_validity_test.exs`, `lib/property_damage/analysis.ex`, `lib/property_damage/sequence/validator.ex`, `lib/property_damage/shrinker.ex`, `test/property_damage/sequence/validator_test.exs`, `test/property_damage/shrink_minted_ids_test.exs`

### 2026-11-07T01:17 · commit · 031aa49

fix(model): resolve command specs through one model-level table

The shrinker and Settle read each command's own command_spec/1 and ignored
the options of its entry in commands/0, so a listed `shrink: :prefer_keep` or
`execution: :async` did not apply to shrinking. A module listed twice in
commands/0 silently kept only the last entry.

Model.spec_table/1 builds one module-to-spec table from the setup commands,
teardown commands and commands/0, and Model.spec_for/2 looks a command up in
it, falling back to the module's own spec for a module the table lacks. The
executor, shrinker, sequence validator and IEx read the table. Settle reads
spec maps only: its module and struct clauses and the private resolver are
removed. Listing a module twice in commands/0 raises at PropertyDamage.run/1,
Model.spec_table/1 and mix pd.validate, naming both entries.

**Files:** `CHANGELOG.md`, `lib/mix/tasks/pd.validate.ex`, `lib/property_damage/executor.ex`, `lib/property_damage/executor/settle.ex`, `lib/property_damage/iex.ex`, `lib/property_damage/model.ex`, `lib/property_damage/options.ex`, `lib/property_damage/sequence/validator.ex`, `lib/property_damage/settle.ex`, `lib/property_damage/shrinker.ex`, `lib/property_damage/validation.ex`, `test/property_damage/command_spec_surface_test.exs` (+6 more)

### 2026-11-07T01:23 · commit · b789d3e

feat(pd.validate): warn when a model has no simulator

A model without simulator/0 mints no placeholders during generation, so a
command whose when: depends on a value the system mints (an external() field)
is never generated, and nothing told the author.

mix pd.validate now warns about it, with and without an adapter, and
--strict fails on it.

**Files:** `CHANGELOG.md`, `lib/mix/tasks/pd.validate.ex`, `lib/property_damage/validation.ex`, `test/mix/tasks/pd_validate_simulator_test.exs`

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

_Reconstruction, written at PR open from the review record kept outside the repo (the agents that wrote the code ran as subagents whose transcripts are not listed under Sessions, so this tier quotes that record, not a transcript)._

- The Record's three commit shas are pre-rebase; after the rebase onto the merged documentation change they are `d65ea3e`, `dffe1ae` and `b71c14d`, followed by `9c8ae13` (load-test seed), `0ebf58f` (two executor lookups) and `146c2fd` (docs), which the hook did not capture; `git log` is the authority.
- The load-test seed was built on a side branch and cherry-picked into series position four; the record: "C33 built in a side worktree, cherry-picked in series position 4". Reason: the engine work and the seed work ran in parallel on disjoint files.
- The end-to-end shrink fixture weights its failing command low; the record: "e2e fixture weights Pair low so the failure lands late (equal weights passed on base through truncation at the failure index)". With equal weights the test could not fail at the base commit.
- Identical repeated listings were made an error as a convention for a silence in the contract, which named only listings "with different options".
- Two raw table lookups in the executor were found by the agent doing the table work outside its file set and switched after a scope ruling; the record: "off-table leaf keeps its own spec".
- The load test had no run seed to derive from; the record of the escalation: "LoadTest takes no `seed:` option (load-test schema has run_nonce only)"; the ruling added the option rather than deriving from the nonce, which "is documented (DR-034) as the knob to vary while holding the plan seed fixed".
