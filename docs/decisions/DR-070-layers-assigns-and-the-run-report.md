# DR-070: Layers Transform Specs, Faults Are Assigns That Ports Acknowledge, and One Report Holds What a Run Saw

**Status:** Accepted
**Date:** 2026-11-23

## Context

A model of `PropertyDamage.Next` lists step specs: a command, a weight, an
optional `when:` predicate, command options and changes to the command's
fields (DR-068). Two needs press on that list.

First, a second model often wants the first model's specs with one
difference: refunds that take most of a payment, or a payment drawn from a
smaller range. Copying the list lets the two drift apart.

Second, a test of failure handling needs faults: a refund endpoint that is
slow, a call that must be retried. A fault is not part of the command, and
the model must not predict it, since the model describes what the system
should do and a fault is what the environment does to it. Yet the adapter
that injects a fault can ignore it without a word. Take a model that draws
`:retry` at every refund, and an adapter that has no clause for it. Every
run passes, and nothing says that no retry was ever exercised.

Finally, a run learns facts that a pass or a failure does not show:
which specs were never drawn, how many steps set each fault, how many slots
were withdrawn. Without one place for them, each is a log line or lost.

## Decision

1. **A layer is a function from one spec to one spec.**
   `StepSpec.transform/2` applies a layer, or a list of layers in order, to
   every spec of a list. A layer matches a spec on its command module,
   weight, command options or assigns, and returns the spec it wants. The
   ids of the specs stay, so a model built from layers keeps the identity
   of the specs it reuses.

2. **A layer never changes `when:`.** A predicate is a function, and a
   function has no identity: two captures of one function are equal, but
   two closures with the same body are not, and PD cannot tell whether a
   replacement keeps or widens the steps that are eligible. A layer that
   returns a spec with a different `when:` raises `ArgumentError` at
   `transform/2`, naming the layer. A model that needs another predicate
   writes the spec again.

3. **Two cases that look alike are treated differently.** A layer that
   changes no spec is a mistake in the layer, often a match that never
   fires, but it breaks nothing, so it is reported and not raised:
   each spec records every layer applied to it, marked changed or
   unchanged, and the run report counts the specs each layer changed. A
   layer that returns something other than a `%StepSpec{}`, and a list
   given to `transform/2` that holds a non-spec, raise `ArgumentError`,
   since nothing downstream can use the value.

4. **A fault is an assign beside the command.** `StepSpec.assign/3` sets
   an assign from a generator, a mint marker or, through
   `StepSpec.assign_from_command/3`, from a function of the drawn command
   that returns a generator. The assign is drawn at the step under its own
   journal key (`{step_key, :assigns, key}`), after every other draw of the
   slot. The adapter's `execute/3` receives the assigns as its second
   argument. The model, the simulator and the projections never see an
   assign: the predicted state and the events fold without it, so a fault
   cannot leak into the prediction it is checked against.

5. **A port acknowledges an assign.** `Runtime.ack(runtime, key)` means
   that the port took the assign into account at this step: it retried, it
   delayed, it injected the fault. PD finds the running step through its
   own process dictionary key in the process that called `execute/3`, then
   through `$callers`; outside a step the call raises `ArgumentError`.
   Only a truthy assign counts as set. An assign whose drawn value is
   `nil` or `false` is off at that step.

6. **Two misuses raise and escape the run.**
   - Acknowledging a key the step did not set raises
     `AcknowledgedUnsetAssignError`, with the key and the keys the step did
     set.
   - Acknowledging a key the target lists in `ignored_assigns:` raises
     `AcknowledgedIgnoredAssignError`, with the key and the target.

   Both escape `run/1` and `replay/2` as raises. Each is a defect in the
   adapter's use of PD, not in the system under test, so neither is a
   `%Failure{}` and neither is shrunk: a shrink would run the same misuse
   against smaller plans and report it as a bug in the system.
   `DependentStreamDataError` (DR-068) is the precedent.

7. **`ignored_assigns:` belongs to the run's target.** A run has one target,
   an adapter with its config, and its entry keys are the run options
   `adapter:`, `config:` and `ignored_assigns:` (default `[]`). A key in
   the list is one this target does not act on, and the model may still
   set it for another. The load check runs before the first plan: a name
   that no spec of the model sets raises `ArgumentError`, naming the key,
   because a stale entry would silence a check for nothing. The check runs
   before the journal's fingerprint is compared.

8. **Counts.** Over the plans of the search, not the shrink candidates,
   the run counts per target, command and key two numbers: `set`, the
   executed steps whose drawn assign is truthy, and `acknowledged`, the
   `ack/2` calls for that command and key in the same executions. The
   counts are keyed by target even while a run has one.

9. **The unacknowledged assign fails the run.** After the search, a key
   with `set > 0` and `acknowledged == 0` over all commands of the target,
   and not in `ignored_assigns`, fails the run:
   `{:error, %Failure{reason: {:unacknowledged_assigns, rows}}}`, with
   `plan`, `journal` and `step` set to `nil` and the rows as in the report.
   The verdict is per key across commands, since one command's port acting
   on a key shows the adapter reads it; the rows still list each command.
   A plan that failed first wins, and its report still carries the counts.

10. **One report.** `PropertyDamage.Next.Report` is the single place for
    what a run saw, for a passing run and for a failing one
    (`{:ok, report}`, or `failure.report`):
    - `plans`: the plans executed.
    - `withdrawn` and `kept`: the withdrawn slots and the sites where a
      dependent StreamData value could not be fitted (DR-068, DR-069).
    - `layers`: `%{layer, specs_changed}` in application order, named
      `"Mod.fun/arity"` for a captured function.
    - `never_drawn`: the specs no search plan drew, each with the reason
      `:never_eligible` (its `when:` was false at every slot evaluated) or
      `:never_chosen` (it held at some slot and the weights never picked
      it). The two have different remedies, a model that cannot reach the
      state or a weight too low, so the report does not merge them. The
      option `never_drawn: :fail` turns a passing run with such a spec into
      a failure (`{:never_drawn, rows}`); the default is `:report`.
    - `assigns`: `%{target => [%{command, key, set, acknowledged}]}`.

    `Report.format/1` renders the report as text. A layer line holds the
    name and `specs changed: n`; the assigns section opens with the header
    `Assigns` and the wording `every assign a port acts on`; a never-drawn
    line holds the command and its reason.

11. **Retries stay in the model.** PD adds no function that emits events
    from a port. To test that a retry changes nothing visible, the adapter
    keeps a catch-all clause that runs the call twice when the step sets
    `:retry` (acknowledging it), and returns a `Retried` event next to the
    normal events. The model's check compares what the second call
    returned with the first. The comparison is the model's statement of
    what idempotency means for the command; PD only carries the assign and
    counts the acknowledgment.

12. **Journal and fingerprint.** An assign is a draw under its own key, so
    a journal that records layered assigns saves, loads in a fresh VM and
    rebuilds to the identical plan, assigns included, and `replay/2` of the
    binary reproduces the failure. The spec list fingerprint covers each
    spec's command, id, weight, the keys of its command options and
    changes, and the keys of its assigns. Observed on a journal recorded
    on a layered base model:
    - A model that adds an assigns-only layer, adds a layer that changes a
      weight, or removes a layer that set assigns, raises
      `ModelChangedError` before the adapter is called.
    - A model that adds a layer that changes only the value of an option
      the spec already has (`max_share: 0.9` where `0.5` stood) replays as
      built: the fingerprint holds keys, not values, and the engine fits
      the stored draws to the domain it offers now (DR-069).
    - No journal replays with assign draws newly made under fresh keys,
      because a changed set of assign keys is refused first.

## Alternatives

- **A layer that may replace `when:`.** Rejected: see decision 2. A
  replaced predicate changes which steps are eligible without a trace in
  the fingerprint, which holds no function.
- **Raising when a layer changes no spec.** Rejected: a layer applied to a
  list of specs that its match skips is legitimate, for one shared layer
  list over several models. The report's per-layer count shows the case.
- **Faults as commands, or as fields of the command.** Rejected: the model
  would predict them, and the simulator and projections would fold events
  for something the system should have hidden. An assign beside the
  command reaches only the port.
- **Counting an assign as acknowledged when the adapter reads it.** Rejected:
  reading a key does not show that the port acted on it. A port calls
  `ack/2` at the point it acts.
- **Making the two ack misuses a failure.** Rejected: see decision 6.
- **A per-command unacknowledged verdict.** Rejected: an adapter can act on
  a key for one command and have no use for it in another; a fault the
  adapter never acts on for any command is the case worth failing.
- **An emit function that lets a port add events.** Rejected: events that
  the port invents would reach the projections and blur what the system
  did with what the test did. The `Retried` event is an event of the
  adapter's result, compared by the model.
- **Recording the layers in the journal.** Rejected: a function cannot be
  saved or compared. The fingerprint names the effect (weights and keys),
  and a changed layer that leaves them alone replays through fitting.

## Consequences

- A model that reuses another model's specs states the difference as
  layers, and the report shows what each layer did.
- A fault the adapter ignores fails the run instead of passing silently,
  unless the target lists the key as one it ignores.
- Counts come from search plans only, so a shrink never changes them.
- A layer that changes a weight or the assign keys makes the base model's
  saved journals unreplayable; the failure has to be captured again.

## Known costs and limits

- The fingerprint holds keys, not values, so a layer that changes an
  option's value, or an assign's generator, replays an old journal as
  built, with the stored draws fitted to the new domain; the replay may
  then not fail.
- `ack/2` locates the step through the calling process and its callers. A
  port that acknowledges from a process with neither in its chain
  raises `ArgumentError`.
- The unacknowledged verdict runs after the whole search, so a run with a
  failing plan reports that failure first and the unacknowledged assign
  only through the report's counts.
- A run has one target. Counts are keyed by target already, and a run of
  several targets would add keys without changing a row.
