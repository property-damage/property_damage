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
| "It changes the system" | `semantics: sync` (default) |
| "I call it just to look / it changes nothing" | `semantics: probe` |
| "It kicks off work that completes later" | `semantics: async` |

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
  immediately or only after the dust settles?" Immediately → `@trigger`;
  eventually → `@poll_state` (elicit a tolerable settling time).
- Elicit severity: is a violation a bug or a catastrophe? (Goes in prose;
  informs how hard the model should hunt it.)

If the user defers invariants entirely: proceed (see SKILL.md hard rules),
derive 2-4 concrete suggestions from their own entities and fears, explain
what implicit checks still catch, and record the suggestions as `deferred`.

## Phase 6 - Failure modes and fears

"Where do you suspect bugs today? What part of the system do you trust
least?" Answers steer weights (hit the scary paths more) and generator
hostility (boundary values where blood is expected). Record in the spec's
`Known failure modes` section.

## Phase 7 - Runtime (exactly two questions)

1. **Transport**: how does a test process invoke the system - in-process
   function calls, HTTP, something else?
2. **Reset**: how does a run get a clean instance - Ecto sandbox, docker
   restart, TRUNCATE, app restart?

Then adapter wiring: for in-process SUTs, read the user's public API and
draft execute clauses; present each for confirmation. Never write wiring the
user has not confirmed - unconfirmed clauses become TODO stubs. For
HTTP-with-OpenAPI, `mix pd.scaffold` provides the adapter surface.

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
- every event is produced by ≥1 command; every command's expected events
  exist in the events section;
- every invariant references state/events that exist;
- runtime is answered; the sweep is confirmed by the user.

**Checkpoint exit** (the user is tired, time is up): legal whenever the
captured subset is internally closed - captured commands' events exist and
captured invariants attach to captured state. Write `interview: checkpoint`
plus what is missing into the spec header, and scaffold the partial model if
the user wants (a 3-command model that runs beats an exhaustive interview
that never produced code). Deferred items carry the backlog.
