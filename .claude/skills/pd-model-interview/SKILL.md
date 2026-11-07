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
  simulator.ex      # generated (from each command's events: list)
  commands/         # generated
  events/           # generated
  projections/      # generated
  smoke.exs         # generated (the bounded smoke run)
  adapter.ex        # hand-owned after first scaffold
  <injector>.ex     # hand-owned stub, only when the spec has injected events
```

## Entry states

Run recon BEFORE asking anything: read `mix.exs`, glob `**/model_spec.md`,
look for existing PD model code and OpenAPI specs. Never ask what the code
already answers. Check that `elixirc_paths(:test)` in `mix.exs` includes
`"test/support"`: Mix compiles only `lib` by default, and the scaffold lives
under `test/support/`. If it does not, propose the change (a clause
`defp elixirc_paths(:test), do: ["lib", "test/support"]` beside
`defp elixirc_paths(_), do: ["lib"]`, and `elixirc_paths:
elixirc_paths(Mix.env())` in `project/0`) and apply it only after the user
confirms. Then branch:

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
the spec header. The command is:

```
MIX_ENV=test mix pd.scaffold --from <openapi path> --output test/support/pd/<slug>/ --namespace <Namespace> --dry-run
```

Run it with `--dry-run` first, show the user the list, then run it again
without `--dry-run`. Run it once, before the adapter becomes hand-owned. A
rerun refuses: it exits 1, names every existing target file, and writes
nothing unless you pass `--force`. `--force` overwrites those files, so it
destroys every hand edit in `adapter.ex`, `model.ex`, `projections/state.ex`
and any command or event file it regenerates. Never pass `--force` to a whole
run over a hand-owned adapter. When the OpenAPI document drifts later, never
rerun it whole; use `--dry-run` to see the difference. To add operations,
`--commands-only --operations <ids>` writes each named operation's command
(`commands/create_user.ex`) and its event file. It refuses the same way if
either file already exists, and you do not need `--force` for new files. The
event name comes
from the operationId: `create`, `update`, `delete`, `get` and `list` prefixes
give `<Resource>Created`, `Updated`, `Deleted`, `Retrieved` and `Listed`
(`createUser` gives `UserCreated`, file `events/user_created.ex`); `find` and
`search` also strip the prefix but give `<Resource>Completed`, so `findUser`
and `searchUser` share `UserCompleted`; any other operationId gives
`<OperationId>Completed`. Run `--dry-run` first and turn each command and
event module it lists into its file path. The dry run lists an event module
only for an operation with a 200, 201 or 202 response, and the run writes
that event file only when the response has a JSON schema (`application/json`).
The dry run does not show the schema, so look it up in the OpenAPI document.
Leave out an operation if its command file already exists, or if its success
response has a JSON schema and its event file already exists (an event file
that another operation shares counts). Ignore the event module of an
operation without a JSON schema: the run neither writes that file nor touches
a file of that name.
What it writes differs from the layout above: it writes `commands/`,
`events/` (named as above), `adapter.ex`, `model.ex` and
`projections/state.ex`, but no `simulator.ex`. Its `model.ex` returns
`Projections.State` from `command_sequence_projection/0`. That projection
starts empty and ignores every event, so do not write a new projection file:
edit `projections/state.ex` to track the state the spec needs, and add the
spec's check projections beside it. The files carry no class header. Add the
class header lines from
[scaffold_templates.md](references/scaffold_templates.md) to each file
afterwards, then write the simulator and `@moduledoc` text from the spec as
for any model.

Every command file the scaffold writes ends with a stub `events/3` that
returns `[]`, and the scaffolded adapter builds each `{:ok, events}` result
through it. Left as is, every command returns no events and the smoke run
proves little. After the scaffold, fill each command's `events/3` from the
spec's `events:` list: one clause per status, including the deliberate
rejections, each returning the event structs for that response. Report any
command you leave stubbed in the handover. Then set each command's
`observables:` to every event module its `events/3` can return, rejections and
schema-less operations included. The scaffold lists `observables:` only for the
events of a 200, 201 or 202 response with a JSON schema, and
`mix pd.validate --strict` fails a command that declares none.

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
5. **Verify**, in order, stopping at the first rung that cannot proceed.
   Run every rung under `MIX_ENV=test`, because the scaffold lives in
   `test/support/`:
   1. `mix format` on the generated files;
   2. `MIX_ENV=test mix compile`;
   3. `MIX_ENV=test mix pd.validate <Namespace>.Model <Namespace>.Adapter --strict`
      (a bare `mix pd.validate` prints usage and exits 0, so it proves
      nothing);
   4. only if adapter wiring was user-confirmed, the bounded smoke run
      (`MIX_ENV=test mix run <dir>/smoke.exs`), which also checks that every
      command executed at least once.

   Compile or validate failures are your bugs; fix them before handover.
6. **Hand over**: what was scaffolded, adapter TODOs, the exact command for
   the first real run (with `report_html:` set, so a failure leaves an HTML
   page to read), the smoke check result, and anything deferred.

## Hard rules

- Every "no" is a write: declined suggestions go to the spec's
  `Explicitly not modeled` section; postponed ones are marked `deferred`.
  Deferred items are re-raised next session; declined ones never are.
- Adapter wiring is proposed and confirmed, never silently written. Derive
  execute clauses from the user's code where possible, present them, and
  TODO-stub what the user does not confirm.
- Invariants are elicited always, blocked never: if the user defers them,
  scaffold anyway, explain what the implicit checks still catch (crashes,
  error tuples, and, with the `branching:` option and a simulator,
  linearization) and what they are blind to (domain wrongness),
  and write concrete context-specific invariant suggestions to the spec as
  deferred.
- Never delete files on regeneration; report removals for the user to delete.
- A checkpointed spec with no scaffold is a valid session outcome; the spec
  header's interview state lets the next session resume cold.
