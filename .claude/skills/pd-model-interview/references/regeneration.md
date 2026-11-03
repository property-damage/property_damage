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
   File missing: ask whether it moved; update the path if so. Never rerun
   `mix pd.scaffold` whole over a hand-owned adapter: it overwrites `adapter.ex`
   and `model.ex` unconditionally. Use `MIX_ENV=test mix pd.scaffold --from
   <openapi path> --output <dir> --namespace <Namespace> --dry-run` to see what
   changed, or `--commands-only --operations <ids>` to write only new
   commands, then add the class header lines to the new files.

## The delta interview

Shorter and sharper than the full protocol - you know the model, so ask about
change, not the world:

- Re-raise every `deferred` item from the not-modeled section. Never re-raise
  `declined` ones.
- "What changed in the system since this spec was written? What broke in
  production?" (New failure modes are invariant candidates.)
- New commands/events/invariants go through the same phase questions as the
  full interview (fields, execution, preconditions, classification), then
  into the spec.
- Removals: mark the spec item removed, but never delete files - report the
  affected file list for the user to delete.

Every answer updates the spec **before** any code is touched.

## File classes

| Files | Class | Regeneration may |
|---|---|---|
| `model.ex`, `simulator.ex`, `smoke.exs`, `commands/`, `events/`, `projections/` | regenerable | rewrite, via confirmed diff |
| `adapter.ex`, injector stubs | hand-owned | propose additions only |
| `model_spec.md` | source | edit as the interview dictates |

Generated files carry a header comment naming their class; keep it intact
when rewriting. They also carry the `@moduledoc` and `@doc` text written from
the spec's prose; regenerate that text from the spec too, because the failure
report prints it.

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
added guard, a tightened check - is a fork in the source of truth.
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

Same as first scaffold, every rung under `MIX_ENV=test` (the scaffold lives
in `test/support/`): `mix format` on touched generated files →
`MIX_ENV=test mix compile` → `MIX_ENV=test mix pd.validate <Namespace>.Model
<Namespace>.Adapter --strict` → bounded smoke run (`MIX_ENV=test mix run
<dir>/smoke.exs`, which checks that every command executed at least once),
only if adapter wiring is user-confirmed. A bare `mix pd.validate` prints
usage and exits 0, so always name the model and adapter. Compile or validate
failures on regenerated code are your bugs. A changed simulator, a new
command or a new guard can leave a command that never executes, so a green
smoke run without that check proves nothing. Close by summarizing: spec changes, files rewritten, adapter proposals
made, removals awaiting user deletion, deferred backlog.
