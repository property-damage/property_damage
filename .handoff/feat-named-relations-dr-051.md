# Handoff ledger: feat/named-relations-dr-051

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

What was asked, the acceptance criteria, and the explicit non-goals. Seeded by
hand from the orchestrator's dispatch brief
(`threads/pd_check_contracts_build/dispatch_dr051.md` in the secretariat vault).

This branch implements DR-051 (`docs/decisions/DR-051-named-comparators.md`):
`@compare` is a plain module attribute, and `using:` names the relation as
`:fun`, `{Mod, :fun}` or `{Mod, :fun, args}`, checked at compile time,
dispatched by a generated `__compare_using__/1`, recorded on a divergence and
printed in its report. Every numbered decision (1 to 8) is a contract. The
branch is based on `feat/verdict-grammar-dr-052` (DR-052), which already
carries `PropertyDamage.Verdict.read/1`, the retired `:match`/`{:mismatch, _}`
grammar and the removal of `Equivalence.verdict/3`. Non-goals: a persistence
version bump (15 stays while unreleased), any change to DR-052's grammar.

Acceptance criteria:

- B1 `CompareAttribute` gone; `Kernel.@/1` in scope in a projection; a
  projection importing another `@/1` registers `@compare` (test).
- B2 The three forms work; an unknown form, a missing or wrong-arity local
  function, a remote module that does not export the function and a function
  value in `args` are each a `CompileError` naming the observation, the
  `using:` term and the expected arity; `__MODULE__` private functions are
  accepted.
- B3 A `:diverged` failure carries and prints the `using:` term as written;
  persistence version unchanged at 15.
- B4 `stutter: [using:]` accepts named forms and a function.
- B5 Zero `using: &`, `using: fn` outside `stutter:` runtime data and
  CHANGELOG history.
- B6 `Equivalence.within/3` present with doctests.
- B7 Gauntlet on the final commit: `mix test`, `mix format --check-formatted`
  for root and each touched bench, `mix credo --strict`, each exit 0.
- B8 CHANGELOG, OpenSpec, guides and README updated; changed snippets executed.
- B9 This Contract section.

Open point for the orchestrator: DR-051 item 6 says `stutter: [using:]`
accepts "the same named forms", but the `:fun` form names a function of the
projection module, and a run option has no projection module. The branch
implements `{Mod, :fun}`, `{Mod, :fun, args}` and a function, and rejects a
bare atom with the option error; the ruling on `:fun` is pending.

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-10-26T12:13 · `a5198fba-9199-4087-8540-25375c6e631e` · `/home/work_bc/.claude/projects/-home-work-bc-srv-secretariat-common/a5198fba-9199-4087-8540-25375c6e631e.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-10-26T12:13 · commit · 508e33c

feat(projection)!: read @compare as a plain attribute that names its relation

A projection replaced Kernel.@/1 with its own macro so that `using:` could
hold a capture or a closure, which no report can print and which blocked
any other @/1 import. `@compare` is now read at @on_definition like @check
and @eventually, and `using:` names the relation: `:fun`, `{Mod, :fun}` or
`{Mod, :fun, args}` (DR-051 items 1 to 4).

- Remove CompareAttribute, the @/1 replacement and its compile-time guard.
- Check the named function at compile time: an unknown form, a function
  value, a missing local or remote function and a wrong arity are each a
  CompileError naming the observation, the term and the expected arity.
- Generate `__compare_using__/1` from the named form, so a local name may
  call a private function; `__compares__/0` records the term as written.

BREAKING CHANGE: `using:` no longer takes a capture or a closure. Write
`&local/2` as `:local`, `&Mod.fun/2` as `{Mod, :fun}`, and a closure as a
named private function.

**Files:** `lib/property_damage/model/projection.ex`, `lib/property_damage/model/projection/compare_attribute.ex`, `test/property_damage/compare_declaration_test.exs`, `test/property_damage/compare_divergence_test.exs`, `test/property_damage/compare_predicate_test.exs`, `test/property_damage/compare_schedule_test.exs`, `test/property_damage/lockstep_run_test.exs`, `test/support/compare_fixtures.ex`

### 2026-10-26T12:15 · commit · 9eef7bf

feat(compare): record the using: term on a divergence and print it

A divergence report showed both values but not the relation that judged
them, so a reader could not tell a tolerance from an equality. The
`Failure.Divergence` struct now carries the observation's `using:` term as
written (`nil` under `==`), and the terminal report prints it on a `Using:`
line beside the two values (DR-051 item 5). The persistence version stays
at 15, which is unreleased.

**Files:** `lib/property_damage/comparison.ex`, `lib/property_damage/failure.ex`, `lib/property_damage/failure_report/formatter.ex`, `test/property_damage/compare_divergence_test.exs`

### 2026-10-26T12:18 · commit · 45ec7c5

feat(stutter): accept a named relation for stutter: [using:]

`stutter: [using:]` took only a function, so a retry relation could not be
written the way `@compare` names one. It now accepts `{Mod, :fun}` and
`{Mod, :fun, args}` beside a 2-arity function (DR-051 item 6). The option
check refuses a function the module does not export and a function value
inside args, and its error, the stutter docs and the retired-key messages
teach the named form first.

**Files:** `lib/property_damage/command.ex`, `lib/property_damage/model/projection.ex`, `lib/property_damage/options.ex`, `lib/property_damage/stutter.ex`, `test/property_damage/stutter_using_test.exs`, `test/support/compare_fixtures.ex`

### 2026-10-26T12:20 · commit · 3cbe66c

feat(equivalence): add within/3 and name the remaining relations

A tolerance is a relation, not an equality, so it cannot move into the
observation body the way normalization does. `Equivalence.within/3` is the
first data-parametrized relation, named as
`{PropertyDamage.Equivalence, :within, [tolerance]}`; it compares numbers
within the tolerance at every depth of maps, lists and tuples, with
doctests (DR-051 item 7).

The stutter default becomes `{Kernel, :==}`, and the remaining captures
in the tests become named forms, so a stutter config prints its relation.

**Files:** `lib/property_damage.ex`, `lib/property_damage/equivalence.ex`, `lib/property_damage/stutter.ex`, `test/property_damage/command_spec_surface_test.exs`, `test/property_damage/equivalence_test.exs`, `test/property_damage/stutter_test.exs`

### 2026-10-26T12:26 · commit · 35193a4

docs(compare): teach normalization in the observation and named relations

The guides taught normalization through `using:` closures, which DR-051
retires: a reader copying them now gets a compile error. The projection
moduledoc describes the three attributes together, each above a 2-arity
function of the state that returns a verdict, a predicate or the value
compared (DR-051 item 8). The `Equivalence` moduledoc, the differential,
path-equivalence, dual-transport, writing-invariants, idempotency and
debugging guides, the cheatsheet and the README return the canonical value
from the observation, keep `using:` for relations that are not equalities,
and show the three named forms (item 7).

**Files:** `README.md`, `guides/cheatsheet.md`, `guides/debugging_failures.md`, `guides/differential_testing.md`, `guides/dual_transport_testing.md`, `guides/idempotency_testing.md`, `guides/path_equivalence_testing.md`, `guides/writing_invariants.md`, `lib/property_damage/comparison.ex`, `lib/property_damage/comparison_mismatch.ex`, `lib/property_damage/equivalence.ex`, `lib/property_damage/error.ex` (+6 more)

### 2026-10-26T12:27 · commit · d239d81

docs(openspec): specify the named relations of DR-051

The projection, differential-testing, concurrency, command and
execution-engine specs still described `using:` as any expression that
evaluates to a function. They now specify `@compare` as a plain attribute,
the three named forms and their compile-time checks, the `using:` term a
divergence records, `Equivalence.within/3`, and the named forms of
`stutter: [using:]`, with scenarios that reference DR-051.

**Files:** `openspec/specs/command/spec.md`, `openspec/specs/concurrency/spec.md`, `openspec/specs/differential-testing/spec.md`, `openspec/specs/execution-engine/spec.md`, `openspec/specs/projection/spec.md`

### 2026-10-26T12:28 · commit · 2236196

docs(changelog): record the DR-051 named relations as breaking

The unreleased DR-046 entries described `using:` as any expression. They
now name the relation, and a BREAKING entry gives the three forms, the
compile-time checks and a table that maps each capture or closure to its
named form. `Equivalence.within/3` and the recorded `using:` term on a
divergence are listed under Added.

**Files:** `CHANGELOG.md`

## Reconstruction

Written when the PR opens, and labeled as such. May extend the Record; may not
contradict it.

_Not yet written._
