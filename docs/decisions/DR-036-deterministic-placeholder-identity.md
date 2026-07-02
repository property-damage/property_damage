# DR-036: Deterministic Symbolic Identity and Plan Fingerprint

**Status:** Accepted
**Date:** 2026-07-02

> Amends DR-021 (Placeholder Resolution Identity). Prerequisite for DR-033
> (RunTrace) and DR-035 (Run Comparison), whose comparability guard depends on
> two independently generated instances of the same plan being recognizably
> equal. Also resolves the determinism-audit finding that `make_ref/0`
> placeholder ids break structural plan equality.

## Decision

1. **Placeholder ids become deterministic.** A `%PropertyDamage.Placeholder{}`
   id is a pure function of the placeholder's generation-time coordinates —
   `(position, event_index, path)` — instead of `make_ref/0`. The id is an
   opaque comparable term (the coordinate tuple itself, or a stable hash of
   it); nothing may depend on its shape beyond equality and hashability.
   DR-021's split identity scheme is otherwise unchanged: consumers still
   resolve by id, producers still capture by structured position rebuilt per
   run. Only the *construction* of the id changes.

2. **Run-scoped mint markers use the same identity scheme.** The
   `mint_per_run` marker introduced by DR-034 is reified at generation time
   with the same `(position, field path)` coordinates, so a minted value's
   identity is deterministic for the same reasons (see DR-034 for how the
   value itself is derived).

3. **Plan identity is a canonical fingerprint.** `RunTrace.plan_fingerprint/1`
   (DR-033) computes a stable digest of a `%Sequence{}`: the branch-structured
   command list with all symbolic markers carrying their deterministic ids,
   and with the derived `registry` field excluded (it is rebuilt per run and
   is not part of the plan's meaning). The digest is
   `sha256(term_to_binary(canonical_plan, minor_version: 2))`, rendered as a
   hex string. Two plans are "the same plan" for run comparison (DR-035) iff
   their fingerprints are equal.

## Context

Generated sequences embed `%Placeholder{id: make_ref()}` structs — in every
consumer command that reads an `external()` value, and in the registry riding
on `Sequence.registry`. `make_ref/0` mints a globally unique reference per
call, so two generations of the *identical* plan (same effective seed, same
generators) produce sequences that are never `==`. This has three concrete
costs:

- **Run comparison is dead on arrival without it.** DR-035 refuses to compare
  traces whose plans differ. With ref-based ids, two `capture()` calls in the
  same VM — let alone traces persisted from separate CI jobs, the flagship
  use case of DR-033's trace persistence — would never satisfy the guard for
  any model that uses `external()`. The subsystem would be broken by
  construction, the same defect class that killed `PropertyDamage.Diff`.
- **Structural determinism is unauditable.** "The plan is a pure function of
  the effective seed" cannot be checked by generating twice and comparing,
  because the refs differ even when the plan is semantically identical.
- **Persistence carries process-scoped identity.** Refs survive
  `term_to_binary` round-trips within one artifact, but they encode a
  creation-time identity that is meaningless across artifacts.

Why this does not conflict with DR-021's rationale: DR-021 rejected its
"Option A" because it transported ids in an *out-of-band list*
(`command_ids` on `Sequence`) that every sequence-rebuilding operation
silently dropped. This decision transports nothing new — the id still lives
*inside* the `%Placeholder{}` struct, embedded in commands, exactly as today.
The generation-time coordinates are baked in when the placeholder is minted
and never need remapping afterward: the shrinker already preserves command
structs (and their embedded placeholders) verbatim, and the *capture-side*
position remapping DR-021 mandates is unaffected because capture continues to
key on current-run positions, not on the id.

Uniqueness argument: within one generated plan, `(position, event_index,
path)` uniquely names one external field of one simulated event of one
command — the same coordinates DR-021 already relies on for capture. Two
placeholders in one plan therefore cannot collide. Across plans, ids may
coincide, which is harmless and in fact desired: it is what makes two
generations of the same plan equal.

Encoding stability: `term_to_binary/2` with `minor_version: 2` is stable for
the types involved (atoms, integers, tuples, binaries, maps) across the OTP
releases this project supports. If OTP ever changes the external term format
incompatibly, fingerprints from old traces stop matching new ones — the
comparison then refuses, which is the safe failure mode.

## Consequences

- `Placeholder.new_at/4` (`lib/property_damage/placeholder.ex`) derives the id
  from its arguments instead of calling `make_ref/0`. The `id` field's type
  widens from `reference()` to an opaque term.
- Registry lookups (`PlaceholderRegistry.placeholders`, keyed by id) are
  unaffected: ids remain unique within a plan and hashable.
- Raw structural equality of two same-plan sequences becomes honest, which
  the determinism audit can rely on (`assert generate(seed) ==
  generate(seed)` now holds).
- `RunTrace` records `plan_fingerprint` at capture; `RunComparison` compares
  fingerprints, never raw sequences (belt and braces: the fingerprint also
  excludes the derived registry, so registry-only drift cannot poison the
  guard).
- A fingerprint intentionally changes when a command or event struct
  definition changes across commits: a plan generated by different generator
  code is a different plan, and comparison must refuse rather than
  misalign. This is correct behavior for the cross-commit regression use
  case — compare *traces captured on each commit*, whose plans either match
  (generators unchanged) or legitimately do not.
- DR-021 remains Accepted; its record gains an "Amended by DR-036" note on
  the id-construction point.

## References

- `openspec/specs/execution-engine/spec.md` (Deterministic Symbolic Identity
  requirement).
- Amends DR-021 (Placeholder Resolution Identity). Required by DR-033 (Run
  Trace as the Execution Record), DR-034 (Reproducible Run Inputs and
  Client-Minted Values), DR-035 (Run Comparison).
