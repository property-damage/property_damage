# Interview Protocol

The interview turns what the user knows about their system into a
`model_spec.md`. You are grilling for behavior, not filling a form: chase
vague answers until concrete, and reconcile contradictions the moment they
appear. Ask **one question at a time**. Translate everything into the user's
domain language; never ask a question that requires the user to know
PropertyDamage jargon.

Write the spec incrementally as sections close (see
[spec_format.md](spec_format.md)). The spec on disk, not this conversation,
is the session's memory.

## Phase 0 - Recon (no questions)

Read before asking: `mix.exs` (deps, umbrella?), existing `**/model_spec.md`,
existing model code, OpenAPI documents, the app's public API modules. Every
fact recon establishes is a question you must not ask. In an umbrella, note
which app owns which behavior; scoping (Phase 2) will need it.
Also check that `elixirc_paths(:test)` in `mix.exs` includes `"test/support"`
(see [SKILL.md](../SKILL.md)); the scaffold lives there.

## Phase 1 - Overview (shallow, minutes)

Goal: vocabulary, not depth. Elicit:

- What the system does, in a paragraph.
- The entities (nouns with lifecycles) and how they relate.
- One early fear question: "what is the worst bug this system could have?"
  (Captures the highest-value answer even if the session ends early; park the
  answer for Phase 5.)

Resist modeling here. If the user dives into detail, note it and steer back.

## Phase 2 - Scope: pick the model boundary

One model per bounded subsystem. A 50-command model is a bad model: shrinking
explodes, weights dilute, invariants smear. Ask which subsystem to model
first, biasing toward **the smallest one that carries an invariant the user
fears breaking** - the fastest path to a property test that matters.

- Large system → several models over several sessions; each gets its own
  directory and spec.
- Everything outside the boundary that came up in Phase 1 goes to the spec's
  not-modeled section as `deferred` (candidate future models).

## Phase 3 - Commands, per entity lifecycle

For each entity in scope, walk its lifecycle: how it comes to exist, what can
happen to it, how it ends. Each operation becomes a command. Per command
elicit, in domain terms:

- **What happens** when it succeeds - the observable outcomes. These become
  the expected events. Ask what the system reports back that it invented
  itself (IDs, timestamps, versions): those are `external()` fields on events.
- **Inputs** and their realistic shapes - "amount: positive cents, typically
  under 10^6" is a generator note; capture ranges, formats, and hostile edges
  the user mentions.
- **Failure outcomes** the system produces on purpose (rejections,
  validation errors). Deliberate rejections are events too.

Derive, never ask in jargon:

| You learn | You record |
|---|---|
| "It changes the system" | `execution: sync` (default) |
| "I call it just to look / it changes nothing" | `execution: probe`, plus `shrink: prefer_remove` in the command block (the shrinker drops it first) |
| "It kicks off work that completes later" | `execution: async` |

For an `async` command, ask: "how do you learn that it finished?" Two
answers are common. "I call something to look" means a probe command reads
the result: record it as `completion: poll` and capture that probe as a
command. "The system calls me back" (a webhook, a callback, a message) means
the finishing event does not come from any command: record `completion:
injected` and mark that event `source: injected` in the spec's Events
section. Ask what the callback carries, as you would for any event.

## Phase 4 - State and preconditions

For each command: "when would calling this make no sense, or be a user
error?" Answers become `when:` guards, and whatever the guard must inspect
becomes state the projection tracks. State is motivated by real gating, never
modeled speculatively. Also elicit relative frequency ("is deleting rare
compared to reading?") → weights.

## Phase 5 - Invariants

Now that commands and state are concrete, elicit what must always hold /
never happen. Start from the Phase 1 fear answer. For each invariant:

- Attach it to state and events by name ("a cancelled order never ships" →
  needs cancelled-set and ship events in the projection).
- Derive the classification: "if this went wrong, would you see it
  immediately or only after the dust settles?" Immediately → `kind: check`
  (`every:` a step or a named event); eventually → `kind: eventually`
  (elicit a tolerable settling time, and ask which states mean "not yet"
  and which mean "never", so the predicate can answer for every state and
  never raise on one that has not caught up).
- Ask the safety question: "is there something that must never happen too
  much, such as a payment applied twice or a total that overshoots?" Record
  it as `kind: check` with `at: teardown`: the check runs once on the
  settled final state. Its projection must accumulate evidence (a count, a
  maximum, a sticky flag), so ask what the system must remember about each
  occurrence for the check to see an overshoot that later healed.
- Elicit severity: is a violation a bug or a catastrophe? (Goes in prose;
  informs how hard the model should hunt it.) Write the prose in the
  domain's words: the scaffold copies it into the check's `@doc`, and the
  failure report prints it under "What this checks".

If the user defers invariants entirely: proceed (see SKILL.md hard rules),
derive 2-4 concrete suggestions from their own entities and fears, explain
what implicit checks still catch, and record the suggestions as `deferred`.

## Phase 6 - Failure modes and fears

"Where do you suspect bugs today? What part of the system do you trust
least?" Answers steer weights (hit the scary paths more) and generator
hostility (boundary values where blood is expected). Record in the spec's
`Known failure modes` section.

## Phase 7 - Runtime (three questions, then two optional offers)

1. **Transport**: how does a test process invoke the system - in-process
   function calls, HTTP, something else?
2. **Reset**: what can the test do on its own to give a run a clean
   instance - Ecto sandbox, docker restart, TRUNCATE, app restart? This is
   for side effects that need no knowledge of the system's data. The
   adapter does it in `setup/1`, which runs once per run in every target, so
   ask whether doing it twice in a row is safe (it must be idempotent).
3. **Fixtures**: "what must exist before anything can happen - a user, a
   session, a configured account? And what must be cleaned up afterward?"
   Each answer becomes a setup (or teardown) command, captured like any
   command in Phase 3 with `role: setup` or `teardown`, and listed in the
   spec's Setup and teardown section in the order it runs. A fixture is
   never adapter code: only the adapter knows how each target realizes it,
   and that is what the command's adapter clause does.

Then offer two optional features, once each, in the user's words:

- **Comparing targets**: "do you have two versions or two implementations
  of this (old and new, primary and replica, two providers) that should
  behave the same?" A yes becomes the spec's `targets:` and `compare:`
  entries: ask which observations must match, and when.
- **Equivalent routes**: "is there an operation that can be done in several
  ways that should end the same (one payment step versus authorize then
  capture)?" A yes becomes `expansions:`.

If the user declines either, record it as `declined` with the reason. If
they postpone it, record it as `deferred`.

Then adapter wiring: for in-process SUTs, read the user's public API and
draft execute clauses; present each for confirmation. Never write wiring the
user has not confirmed - unconfirmed clauses become TODO stubs. For
HTTP-with-OpenAPI, `mix pd.scaffold` provides the adapter surface; run it
once, with the exact command in [SKILL.md](../SKILL.md), before the adapter
becomes hand-owned.

## Phase 8 - Not-modeled sweep

Read back everything mentioned but not modeled - entities, operations,
invariants, whole subsystems. Each item gets modeled now, marked `deferred`
(re-raise next session), or marked `declined` with the user's reason (never
raise again). Every "no" in the whole interview must already be recorded;
this sweep catches the ones that slipped.

## Closure criterion

The interview is complete when the cross-reference graph closes:

- every entity from the overview is touched by ≥1 command or listed in
  not-modeled;
- every event is produced by ≥1 command, except events marked
  `source: injected`, which arrive through an injector; every command's
  expected events exist in the events section;
- every invariant references state/events that exist;
- runtime is answered; the sweep is confirmed by the user.

**Checkpoint exit** (the user is tired, time is up): legal whenever the
captured subset is internally closed - captured commands' events exist and
captured invariants attach to captured state. Write `interview: checkpoint`
plus what is missing into the spec header, and scaffold the partial model if
the user wants (a 3-command model that runs beats an exhaustive interview
that never produced code). Deferred items carry the backlog.
