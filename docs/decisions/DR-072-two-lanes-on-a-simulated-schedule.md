# DR-072: A Plan May Have Two Lanes, Interleaved on a Schedule Drawn into the Journal

**Status:** Accepted
**Date:** 2026-11-23

## Context

A plan of `PropertyDamage.Next` ran its steps one after another. Two calls
to the system therefore never overlapped, and a check-then-act race stayed
out of reach. Take a refund made in two calls: the first checks the amount
against the balance, the second applies it. Two refunds that overlap can
both pass the check, and together they take more than the payment holds. A
plan that runs one refund to its end before it starts the next cannot show
that.

Real overlap needs real processes, and with real processes the order of
events is not PD's to choose. This record covers the smaller step: a plan
whose steps may overlap in a simulated order that PD draws, stores and
replays. The adapter says where a step can be interleaved, PD orders the
parts, and one process runs them all. Because PD owns the order, the order
can live in the journal, and a candidate of the shrinker still has one
verdict on an adapter that is deterministic.

This record covers the shape of such a plan, how the plan is generated,
run, shrunk and saved, and what the corpus shows.

## Decision

1. **A plan with lanes.** With the option `lanes: 2`, a plan holds the
   prefix and then two lanes. The prefix is the `max_steps` slots a plan
   always had, with keys `{0, slot}`. Lane 1 has `lane_steps` slots with
   keys `{1, slot}`, and lane 2 has `lane_steps` slots with keys
   `{2, slot}`. A step's lane is part of its key and is fixed by the slot
   it sits in. `plan.steps` lists the prefix steps, then lane 1's, then
   lane 2's, each in slot order. The new options are `:lanes` (1 or 2,
   default 1), `:lane_steps` (default 3 with two lanes) and `:yields`
   (decision 3, default 1 with two lanes). `plan/3`, `run/1` and
   `replay/2` take them; `:lane_steps` or `:yields` without `lanes: 2`
   raises `ArgumentError`. With a journal, an option the caller gives
   must equal what the journal recorded.

   Rejected: draw the lane of each slot. Every slot would then carry a
   drawn lane, and shrinking a lane draw would move a step to the other
   lane. That changes the state the step was generated from, its generation
   entries and the position it holds in the schedule, so one edit would
   change every later step. A lane in the key stays put while the plan
   shrinks. The cost is that a failure that needs no overlap keeps a lane
   label on a plan that runs serially: it shrinks to one empty lane or to a
   schedule of zeros (decision 4), not to a prefix step.

2. **Each lane is generated from a copy of the predicted state after the
   prefix.** Generation saves the state after the last prefix slot and
   starts each lane from it. A lane folds only its own steps' predicted
   events. A `when:` in a lane therefore holds when that lane runs alone
   after the prefix. A lane step can name a value that the prefix made or
   that an earlier step of its own lane made, and never a value of the
   other lane, since the other lane's events are not in its state. Both
   lanes can name one entity that the prefix made, and a mint marker that
   the model reads back from the prefix keeps its prefix stamp, so both
   lanes send the same value for it.

   Rejected: one state through lane 1 and then lane 2. Lane 2 would then
   see what lane 1 predicted, so it could never draw two requests that
   together exceed what the prefix made. That is the shape of a
   check-then-act race, and the one state would hide it. A model that
   needs to know what the other lane did cannot be written; a lane is
   independent by construction.

   Withdrawal works per lane slot, as for a prefix slot: a stored pick that
   the lane's state no longer offers withdraws that slot. Its entries,
   schedule entries included, stay in the journal during the search, and the
   final journal replaces them as it does for any withdrawn slot. The
   report counts lane steps like prefix steps for assigns and for
   never-drawn specs, and the eligible list is the union over every slot.

3. **The adapter may yield.** `execute/3` may return `{:yield,
   continuation}`, where `continuation` is a function of no arguments that
   answers as `execute/3` does. The work done so far stays done. A step is
   one or more parts: the call to `execute/3`, and one more part for each
   continuation. Another lane's part may run between two parts of a step,
   and nowhere else.
   - An adapter that never yields works unchanged: each of its steps is one
     part that nothing interleaves.
   - A continuation in the prefix, and in a plan with one lane, runs at
     once, with no cap.
   - A lane step may yield at most `:yields` times. One more yield fails the
     step with an `ArgumentError` that names the option. The cap lets
     generation know how many parts to schedule (decision 4).
   - A bad answer, from `execute/3` or from a continuation, fails the step
     with an `ArgumentError`; a raise, exit or throw in a continuation
     fails the step as one in `execute/3` does.
   - PD calls each continuation at most once, in the process that called
     `execute/3`. `Runtime.ack/2` sees the step whose part is running, so
     an acknowledgment counts for that step while two steps are open. A
     process that the adapter starts during a part, such as a `Task`, must
     acknowledge before the part returns or yields.
   - In a lane, the system may refuse a command that the lane's own state
     allowed, because the other lane got there first. The adapter reports
     that refusal as an event, so the projections fold it. `{:error,
     reason}` still fails the run.
   - When a lane step fails while the other lane has a step open, PD never
     calls the open continuation, and runs `teardown/1` once, as after any
     failure. The adapter's teardown releases whatever the open step held.

   Rejected: a separate callback for the second half of a step, or a step
   that returns a list of parts. Either would change every adapter, and the
   adapters that never overlap would pay for it. A return value that a
   plain adapter never produces leaves them as they were.

4. **The schedule is drawn at generation and stored in the journal.** After
   both lanes are generated, and only when each lane holds a step,
   generation draws, for each lane-1 step in slot order and each part `i`
   of that step from 1 to `yields + 1`, one integer under the key `{{1,
   slot}, :schedule, i}`, through the engine like any other value. The
   generator is `integer(0..lane_steps * (yields + 1))`. The value names a
   position in lane 2. The part `j` of the lane-2 step in slot `s` sits at
   position `(s - 1) * (yields + 1) + (j - 1)`. The plan holds the values
   in `plan.schedule`, which maps each lane-1 step key to its list of values
   and is `%{}` for a plan that has one lane or an empty lane.

   Execution runs the prefix, each step to its end. It then repeats one
   rule: when each lane has a part left, the lane-1 part runs if the
   position of lane 2's next part is at or after the value drawn for the
   lane-1 part, and the lane-2 part runs otherwise. When one lane has no
   part left, the other lane runs. All values 0 therefore run lane 1 to its
   end and then lane 2. The top value means after all of lane 2.

   - **Why draw at generation.** The journal is the test case. A schedule
     in the journal replays exactly, travels in a saved file, and is
     adopted or refused by the shrinker as any other edit. A candidate then
     has one verdict on a deterministic adapter, and execution needs no
     path back into the journal to record a choice it made on the way. A
     schedule drawn at run time would need that path, and a different
     number of keys at each run.
   - **Why a position by slot.** Positions count lane-2 slots, whether or
     not a slot holds a step. Removing a step of either lane leaves every
     other value in place: a lane-1 step's values go with it, and a lane-2
     step's removal changes no position number. A value is an integer, so
     both engines fit it the same way, by clamping into a range that the
     journal fixes.
   - **Rejected: positional choices.** A choice such as "the third ready
     part" shifts when a step before it is removed, so a shrunk plan would
     meet a different interleaving than the one it failed on.
   - **Rejected: a member naming a lane-2 step.** `Engine.StreamDataSource`
     fits a member by its index, not by what it names, so the value would
     point at another step after a removal on that engine.

5. **Execution is one process, and checks follow completion.** One process
   runs every part, with no timer and no extra process. A step's events fold
   into the projections and the checks run when the step completes, which
   is when a part answers `{:ok, events}`. Steps of two lanes therefore fold
   in the order they complete, and every check sees the real events only.

   A model for lanes states bounds over the folded state, such as "refunds
   never exceed the payment". Such a check holds at every completion and
   fails at the completion that breaks it. Two kinds of comparison break on
   a correct system. A check that compares a step's result with its lane's
   prediction fails when the other lane changed the system in between. A
   check that reads a value in a second call can also see the other lane's
   change. Neither belongs in a model for lanes. The engine adds no check
   form that runs when both lanes are done, because a bound checked at each
   completion catches the race at the completion that breaks it.

6. **Shrinking.** The shrinker keeps its passes and edits the same journal.
   Three rules change.
   - **The same test case.** A candidate whose rebuilt plan has the steps
     and the schedule of the plan it shrinks is not executed. The old test
     compared steps only, so a candidate that changed only the schedule
     never ran, and no schedule value could be lowered. With one lane the
     schedule is `%{}` on both sides, so one-lane shrinks, run counts
     included, are as they were.
   - **The cut after a failure.** After a failure in a lane step, only the
     later slots of that lane are emptied, because the other lane's later
     steps may have run before the failure. After a failure in a prefix
     step, every lane slot is emptied together with the later prefix slots,
     since every lane step runs after the prefix.
   - **Same step or an earlier one.** Adoption (DR-069, decision 3) needs a
     total order over step keys. A prefix step is earlier than every lane
     step, and two lane steps, of one lane or of two, compare by slot. A
     failure can move from lane 2 to lane 1 when a shrink changes which step
     completes the failing check, and the order allows that move when the
     slot does not rise. Slot numbers only fall during a shrink, so a chain
     of adopted candidates cannot drift to later steps.

   Schedule keys are drawn last, so the lowering pass reaches them first.
   Each value tries 0 and then bisects, on both engines. Removing steps
   toward one empty lane also removes the schedule. A race keeps two lanes
   and a schedule other than zeros.

   No move that removes the same position from both lanes is needed. Such a
   move would matter if removing a step of one lane shifted that lane
   against the other. Here it does not, as decision 4 shows: lane-1 values
   leave with their step and lane-2 positions count slots.

7. **Saved journals.** A `Journal` gains the field `lanes`: `nil` for a plan
   with one lane, and `%{count: 2, steps: lane_steps, yields: yields}` for
   a plan with two. `to_binary/1` writes the field only when it is not
   `nil`, so a one-lane journal saves the content it saved before lanes
   existed. The format version stays 3, and a binary without the field
   loads as a one-lane journal. The loader validates the field and refuses
   any other shape. The atoms `:schedule`, `:lanes`, `:count`, `:steps` and
   `:yields` join the journal's atom list, so a fresh VM creates them before
   the safe decode of a saved journal. A replay takes its lanes from the
   journal and runs the journal's schedule.

   Equal journals are proved equal on decoded terms. `:erlang.term_to_binary/1`
   without the `:deterministic` option does not give the same bytes for a
   large map in two VMs: a map of more than 32 entries can encode in another
   key order, while the two terms are equal. A check of saved bytes across
   VMs therefore decodes both and compares the terms, or encodes both in one
   VM.

8. **The racing refunds entry is the measure.** `corpus/next/racing_refunds.exs`
   pays an amount, then refunds it in two overlapping calls. The scheme
   (`corpus/support/scheme.exs`) checks the amount against the balance in the
   first call and applies the refund in the second without checking again,
   when the bug is on; with the bug off the second call checks again, and the
   adapter reports a refused refund as an event. The model's one check bounds
   the refunds of a payment by what it paid. The entry runs with
   `lanes: 2, lane_steps: 3, yields: 1` and four prefix slots. The smallest
   failing plan is a payment of 1 and a refund of 1 in each lane.

   Seeds 1 to 20, a plan cap of 200, measured at commit `51dec93`:

   | engine | found | plans until found | shrink runs | reached minimum |
   |---|---|---|---|---|
   | `Engine.Native` | 20/20 | 4.1 | 73.0 | 18/20 |
   | `Engine.StreamDataSource` | 20/20 | 4.6 | 58.2 | 19/20 |

   With the bug off, no seed fails on either engine. With the bug on and
   `lanes: 1`, no seed fails either, though the adapter still yields: PD
   runs the continuation at once, and one refund ends before the next starts.

   **Known limit.** The shrinker misses the smallest plan on 3 of 40 rows
   (2 on `Engine.Native`, 1 on `Engine.StreamDataSource`). The misses
   share two causes.
   - A lane step whose schedule value holds back the other lane cannot be
     removed without raising another value, so the plan keeps a step that
     the minimum lacks.
   - Linked amounts that must fall together cannot be lowered one at a time:
     lowering one refund alone ends the failure, so the shrinker stops with
     amounts above 1.

   Nothing was tuned to these numbers.

9. **What this record does not decide.**
   - Real processes. Here PD orders every part in one process, and the order
     is a pure function of the plan, the schedule and where the adapter
     yields. With real processes the order belongs to the system, a
     candidate may need several runs for one verdict, and the schedule can
     be provoked but not drawn.
   - Delays at ports, which would be how real processes are provoked into an
     order.
   - More than two lanes.
   - A part that runs after the lanes, such as a check of the end state or a
     settle step.
   - A trace of the points that ran. A failure carries its plan and
     schedule, which replay the interleaving on a deterministic adapter, but
     it does not record the sequence of points as a history.

## Alternatives

- **A drawn lane per slot.** Rejected in decision 1.
- **One state through both lanes.** Rejected in decision 2.
- **A schedule drawn at run time.** Rejected in decision 4.
- **Positional or member schedule values.** Rejected in decision 4.
- **A second step struct for lane steps, or a schedule field on `Step`.**
  Rejected: saved plans compare their `%Step{}` structs, so a new field
  would make every saved plan compare unequal to a rebuilt one. The
  schedule lives in the plan and the journal, and the shrinker's same-test
  comparison reads it there (decision 6).
- **A move that removes the same position of both lanes.** Not needed
  (decision 6).
- **A check form that runs when both lanes are done.** Not added
  (decision 5).

## Consequences

- A one-lane plan generates, runs, shrinks and saves as before. Its journal
  keeps its keys, entries and saved content, and the shrinker's run counts
  for one-lane entries are unchanged.
- The adapter contract grows one return value. An adapter that never yields
  needs no change.
- A model for lanes writes bound checks over the folded state, not
  comparisons with a lane's prediction (decision 5).
- A failure found in a lane that needs no overlap shrinks to a plan that
  runs serially and keeps its lane label.
- The step that fails first is reported, in either lane, by its key.
- A saved journal of a plan with two lanes is not readable by a PD that
  predates the field: that PD would drop it and rebuild a plan with one
  lane.

## Known costs and limits

- The schedule has `yields + 1` integers for each lane-1 step, so a plan
  with long lanes and many yields draws many values, and the shrinker
  spends runs lowering them.
- A lane is independent, so a model cannot express a command that depends
  on what the other lane did.
- The shrinker misses the smallest racing plan on 3 of 40 rows (decision 8).
- The order is simulated. It finds a bug that needs a given interleaving of
  parts the adapter marks, and finds nothing about interleavings inside a
  part.

## Amendments

- **DR-069, decision 2 (moves, pass 1).** The first pass empties every slot
  that runs after the failing step: later slots of its lane after a lane
  failure, and every lane slot after a prefix failure (decision 6 here).
- **DR-069, decision 3 (adoption).** A candidate is the same test case when
  its steps and its schedule equal the current best's, and "the same step
  or an earlier one" uses the order of decision 6 here.
