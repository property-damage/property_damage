# DR-037: Generation Determinism Audit

**Status:** Accepted
**Date:** 2026-07-03

> Builds on DR-036 (Deterministic Symbolic Identity and Plan Fingerprint) and
> DR-034 (Reproducible Run Inputs and Client-Minted Values). DR-036 made the
> plan a structurally stable function of the seed at the framework level; this
> decision makes the *user-facing* half of that contract executable and
> documents the deterministic patterns that keep it true.

## Decision

1. **The generation-determinism contract is stated as an enforceable
   requirement.** Generation SHALL be a pure function of `(seed, model,
   generation options)`, including user code: command generators, `when:`/`with:`
   predicates, the `command_sequence_projection`, and the simulator. All
   nondeterminism (wall clock, `:rand`, `System.unique_integer/1`, client-minted
   identifiers, environment) belongs behind an execution-time seam, never in
   generation.

2. **The audit is `PropertyDamage.audit/2`, wrapped by `mix pd.audit`.** For a
   deterministically chosen set of seeds (default 100, or an explicit list), it
   realizes a model's generated sequence twice at the *same* seed through the
   seeded path (`Generator.generate_value/3`) and asserts the two are
   structurally equal (`==`). Raw equality is honest post-DR-036 because
   placeholder and mint-marker identities are deterministic; it covers the
   derived registry too (strictly stronger than the plan fingerprint). The
   audit threads `max_commands` and `branching` so branch generation is
   exercised, not only the linear path.

3. **The audit is generation-only.** No adapter, no SUT, no execution. It never
   resolves `mint_per_run` markers or `external()` placeholders — those are
   deterministic symbolic structs and part of the plan. The correctness
   boundary is the plan (the `%Sequence{}`), not the mid-generation symbolic
   state: impurity in a projection/simulator matters only insofar as it changes
   command selection, which surfaces as sequence divergence.

4. **Divergence is localized directly.** On the first diverging seed the audit
   walks `prefix`/`branches`/`suffix`, reports the first position whose command
   structs differ (or a structural mismatch when command counts/shape differ),
   the differing fields, and actionable guidance pointing at
   `guides/deterministic_generation.md`. It does NOT reach for a comparison
   module: `PropertyDamage.Diff` is deleted, and `RunComparison` compares
   executed traces, not two generated sequences. `mix pd.audit` exits non-zero
   on divergence so CI gates on it.

5. **The blessed seams are documented.** `guides/deterministic_generation.md`
   states the contract and the three deterministic patterns: a seeded relative
   time offset reified in the adapter (for timeliness-dependent values like a
   JWT `exp`), `mint_per_run/1` for client-minted uniqueness (DR-034), and
   `external/0` for server-assigned output (DR-021) — with the explicit note
   that `external/0` is not the seam for time or client-minted values.

## Context

Generation is a pure function of the seed *by contract*
(`Generator.generate_value/3` realizes through `StreamData.seeded/2` at a
constant size), but nothing enforced that contract for user code. A generator,
predicate, or projection that reads the clock, `:rand`,
`System.unique_integer/1`, or `UUID.uuid4/0` silently breaks it, with two
downstream symptoms: `mix ... seed: N` stops reproducing, and — since the
run-comparison campaign — `RunComparison`'s fingerprint guard (DR-035) refuses
every comparison for that model, because two "same seed" captures no longer
generate the same plan. The two most common triggers are SUTs with timeliness
requirements (users reach for `utc_now/0` in a generator) and client-minted
unique ids (users reach for `UUID.uuid4/0`); both now have framework-blessed
alternatives.

The audit and the comparability guard are two faces of one contract. The audit
proves a model's generation is pure (dev/CI-time, generation-only, N seeds); the
fingerprint guard refuses to compare two captured runs whose plans differ
(runtime, per comparison). An impure model fails the audit and, equivalently,
can never satisfy the guard — the audit is the actionable early warning for
exactly the failure the guard reports cryptically.

Why raw equality rather than the plan fingerprint as the primary check: the
fingerprint (`RunTrace.plan_fingerprint/1`, DR-036) deliberately excludes the
derived registry, so it is a necessary but not sufficient witness of plan
equality. Raw `==` on the whole `%Sequence{}` includes the registry (whose keys
are deterministic post-DR-036) and is strictly stronger, which is what an audit
that must catch *any* impurity wants.

## Consequences

- New: `PropertyDamage.Audit` and the `PropertyDamage.audit/2` entry point;
  `mix pd.audit` (mirrors `mix pd.validate`'s halt-on-error structure).
- New: `guides/deterministic_generation.md`, wired into ex_doc extras and
  cross-linked from `writing_commands`, `debugging_failures`, and the
  `Command`/`Generator`/`Adapter` moduledocs.
- No change to the generation pipeline or placeholder/mint minting (DR-036/034
  own that); the audit is a pure consumer of `Generator.generate_sequence/2`
  and `Generator.generate_value/3`.
- This is intra-version enforcement (impurity now), not cross-version drift
  detection. Detecting that a model edit changed what seed N generates between
  releases is adjacent machinery; the plan fingerprint is the natural
  stored-golden representation and `RunComparison`'s guard already refuses
  cross-commit comparisons when plans drift. Noted as future/adjacent in the
  guide, not built here.

## References

- `openspec/specs/execution-engine/spec.md` (Generation Determinism Audit
  requirement; sits next to Deterministic Symbolic Identity).
- Builds on DR-036 (Deterministic Symbolic Identity and Plan Fingerprint),
  DR-034 (Reproducible Run Inputs and Client-Minted Values), DR-021
  (Placeholder Resolution Identity). Complements DR-035 (Run Comparison).
