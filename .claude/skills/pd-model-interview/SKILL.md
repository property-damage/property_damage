---
name: pd-model-interview
description: Interview the user about their system's behavior to produce a durable model spec (model_spec.md) and scaffold a PropertyDamage model from it - Events, Commands, Projections, Invariants, and an adapter skeleton. Use when the user wants to property-test a system with PropertyDamage, set up property tests, model their system, create or extend a PD model, add commands or invariants to an existing model, or update a model after behavior changes. Runs in the user's application repository, next to the system under test.
license: Apache-2.0
compatibility: Requires the property_damage dependency in the host project.
---

# PD Model Interview

Build a PropertyDamage model by interviewing the user about their system's
behavior. The interview produces a durable spec file, `model_spec.md`, which is
the **source of truth**; generated code is derived from it and regenerable.
One model per bounded subsystem, one directory per model:

```
test/support/pd/<model_slug>/
  model_spec.md     # source of truth (human + agent edited)
  model.ex          # generated
  commands/         # generated
  events/           # generated
  projections/      # generated
  adapter.ex        # hand-owned after first scaffold
```

## Entry states

Run recon BEFORE asking anything: read `mix.exs`, glob `**/model_spec.md`,
look for existing PD model code and OpenAPI specs. Never ask what the code
already answers. Then branch:

1. **No spec anywhere** → full interview
   ([interview_protocol.md](references/interview_protocol.md)).
2. **Spec(s) exist** → ask which model (or a new one), then run a **delta
   interview** and regenerate
   ([regeneration.md](references/regeneration.md)).
3. **Model code without a spec** → full interview *seeded* by reading the
   code: the code informs your questions ("I see CreateOrder and ViewOrder -
   what am I missing?"), but never becomes spec content without the user
   confirming each fact. Do not reverse-engineer a spec from code alone; code
   may itself be wrong, and a spec inheriting its blind spots regenerates them
   with confidence.

If an OpenAPI spec is present and the SUT is that API: `mix pd.scaffold`
supplies the mechanical layer (operations, fields, adapter surface) and the
interview narrows to what OpenAPI cannot express - invariants, preconditions,
state, weights, expected events. Record the OpenAPI path and content hash in
the spec header.

## Workflow spine

1. **Recon** (above), then a shallow whole-system overview - entities and
   seams only, minutes not an hour.
2. **Scope**: pick the model boundary - "which subsystem, and what is the
   scariest thing that could break in it?" Bias toward the smallest subsystem
   carrying an invariant the user actually fears breaking.
3. **Interview** within that boundary, writing the spec incrementally as you
   go (see [interview_protocol.md](references/interview_protocol.md) for the
   question order, derivation rules, and the closure criterion; see
   [spec_format.md](references/spec_format.md) for the file schema).
4. **Scaffold** directly from the spec - write the files yourself using the
   templates in
   [scaffold_templates.md](references/scaffold_templates.md); do not drive
   `mix pd.gen.*` (their flag surface cannot carry the spec).
5. **Verify**, in order, stopping at the first rung that cannot proceed:
   `mix format` on generated files → `mix compile` → `mix pd.validate` →
   (only if adapter wiring was user-confirmed) a bounded smoke run.
   Compile or validate failures are your bugs; fix them before handover.
6. **Hand over**: what was scaffolded, adapter TODOs, the exact command for
   the first real run, and anything deferred.

## Hard rules

- Every "no" is a write: declined suggestions go to the spec's
  `Explicitly not modeled` section; postponed ones are marked `deferred`.
  Deferred items are re-raised next session; declined ones never are.
- Adapter wiring is proposed and confirmed, never silently written. Derive
  execute clauses from the user's code where possible, present them, and
  TODO-stub what the user does not confirm.
- Invariants are elicited always, blocked never: if the user defers them,
  scaffold anyway, explain what the implicit checks still catch (crashes,
  error tuples, linearization) and what they are blind to (domain wrongness),
  and write concrete context-specific invariant suggestions to the spec as
  deferred.
- Never delete files on regeneration; report removals for the user to delete.
- A checkpointed spec with no scaffold is a valid session outcome; the spec
  header's interview state lets the next session resume cold.
