# Regeneration and the Delta Interview

Applies when a `model_spec.md` already exists: the user changed the spec, the
system changed, or a checkpointed interview resumes. The spec is the source of
truth; generated code is derived. Regeneration is agent-mediated judgment, not
a mechanical transform - you read the spec, decide what the change implies,
and show your work.

## Opening moves

1. Glob `**/model_spec.md`; several hits → ask which model (or a new one).
2. Read the chosen spec fully, including not-modeled markers and header state.
3. `interview: checkpoint` → resume the interview at the recorded gap before
   any regeneration.
4. OpenAPI-composed spec → hash the referenced document. Mismatch: diff the
   operations against the spec's commands and delta-interview the difference.
   File missing: ask whether it moved; update the path if so.

## The delta interview

Shorter and sharper than the full protocol - you know the model, so ask about
change, not the world:

- Re-raise every `deferred` item from the not-modeled section. Never re-raise
  `declined` ones.
- "What changed in the system since this spec was written? What broke in
  production?" (New failure modes are invariant candidates.)
- New commands/events/invariants go through the same phase questions as the
  full interview (fields, semantics, preconditions, classification), then
  into the spec.
- Removals: mark the spec item removed, but never delete files - report the
  affected file list for the user to delete.

Every answer updates the spec **before** any code is touched.

## File classes

| Files | Class | Regeneration may |
|---|---|---|
| `model.ex`, `commands/`, `events/`, `projections/` | regenerable | rewrite, via confirmed diff |
| `adapter.ex` | hand-owned | propose additions only |
| `model_spec.md` | source | edit as the interview dictates |

Generated files carry a header comment naming their class; keep it intact
when rewriting.

**Regenerable files**: compute what the spec change implies, show a per-file
diff, apply on confirmation. Batch related confirmations sensibly; do not ask
40 questions for one renamed field.

**Adapter**: after the first scaffold it belongs to the user. New command →
propose the new execute clause (derived from their code where possible,
confirmed like all wiring). Existing clauses are never rewritten, even if
they look wrong - report drift instead.

## Fold-back: hand-edits to generated code

Before regenerating, diff each regenerable file against what the current spec
implies. Divergence that regeneration would destroy - a tuned generator, an
added guard, a tightened assertion - is a fork in the source of truth.
Resolve it explicitly with the user, per divergence:

- **Adopt**: fold the edit's intent into the spec (usually a generator note,
  weight, or `when:` prose), then regenerate - the code survives because the
  spec now demands it.
- **Revert**: the spec is right, the edit was a mistake; regeneration
  overwrites it.

Never regenerate over unexplained divergence. Silent loss of a hand-tuning is
how generators die - the user regenerates once, loses their work, and never
trusts the skill again.

## Invariants on re-run

Regeneration never drops to zero invariants silently. If the spec still has
none, re-offer the deferred suggestions (they are in not-modeled) - once, not
naggingly - and proceed either way.

## Exit ladder

Same as first scaffold: `mix format` on touched generated files → `mix
compile` → `mix pd.validate` → bounded smoke run only if adapter wiring is
user-confirmed. Compile or validate failures on regenerated code are your
bugs. Close by summarizing: spec changes, files rewritten, adapter proposals
made, removals awaiting user deletion, deferred backlog.
