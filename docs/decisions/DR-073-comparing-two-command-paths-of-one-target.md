# DR-073: A Model May State Paths, and Each Plan Then Runs Twice Against One Target

**Status:** Accepted
**Date:** 2026-11-23

## Context

A command can often reach the same outcome by more than one route. A refund
of 5 can be one refund of 5, or a refund of 2 and then a refund of 3. The
system should end in the same state either way. A bug where it does not (a
split refund is credited one unit short) cannot be seen by checking one
execution, because each execution on its own looks plausible. It shows only
when two executions that should agree are compared.

`PropertyDamage` compares command paths already, across two or more
targets, each running its own path. `PropertyDamage.Next` had no such
comparison: a run has one target, and a model that stated a second way to
run a command had nowhere to put it. This record adds the comparison to
`PropertyDamage.Next` for one target, run twice.

It covers how a model states paths, how a path draws values of its own,
what the journal holds, how the two executions run and are compared, how a
divergence is shrunk and replayed, and what the corpus shows.

## Decision

1. **The model states its paths.** `PropertyDamage.Next.Model` gains the
   optional callback `expansions/0`, a list of `{command module, fun/2}`
   pairs. Each module is the command module of some step spec, and none
   appears twice. The function receives the step's command as drawn, which
   may hold placeholders, and the predicted state the command's generator
   saw. It returns the list of paths. Element 0 must be the plain path,
   `[command]`. A statement that breaks these rules raises `ArgumentError`
   naming the model, when a plan is built or a run or replay loads the
   model.

2. **A path is a list of commands, or a draw and a builder.** A path is a
   non-empty list of command structs. A path that needs a value of its own,
   such as the size of the first part of a split, is `{generators,
   builder}`: `generators` is a plain map from an atom name to a generator,
   and `builder` is a function of the map of drawn values that returns the
   non-empty list of commands.

   This is the smallest form that lets the split refund draw its first
   part, and nothing more is designed around it. A path never reads the
   state during its draw, and a path never nests. A different way to state
   a command's expansion replaces this callback and decision 2 alone; the
   journal keys of decision 3, the two executions and the comparison do not
   depend on how a path is written.

3. **The journal gains keys, and no existing key moves.** For each step
   whose command module is listed, the pick is drawn under `{step_key,
   :path}` as `Gen.member_of/1` over the path indexes, so its entry is
   `{:member, index, index}`. Then each generator of a draw-form path is
   drawn under `{step_key, :path, name}`, names in ascending order. All of
   them come after the step's command fields and assigns and before its
   prediction. A step of a module that is not listed draws nothing, and a
   model without `expansions/0` draws nothing for any step.

   Because the keys are new and the draws come after the existing ones, no
   existing key, entry or draw order changes, and a journal of a model
   without `expansions/0` is byte-identical to what it was. That is the
   reason `:path` is a new entry atom and the journal format stays at
   version 3: a version bump would refuse journals that have no path in
   them. The step struct gains `path`, `nil` for a step with no listed
   module and `{index, commands}` otherwise, so the shrinker's test of
   whether two plans are the same sees a lowered pick.

4. **One target, two executions.** A model with `expansions/0` runs each
   plan twice, against two fresh `setup/2` contexts of the one adapter with
   the run's config, the reference first. The reference runs every step as
   drawn. The variant runs the commands of the step's picked path in order,
   each its own `execute/3` with the step's assigns, each folded into the
   projections and checked as a step is. The variant's events for a step are
   the concatenation of its commands' events, and later placeholders resolve
   against them. The two executions run in lockstep, one step at a time.
   Each has its own mint nonce, so a value minted per execution differs
   between them as it would between two runs. Both contexts are torn down. A
   failing setup of either execution fails the plan before any step.

   Rejected: two targets, with a list of targets on `run/1`. A target is a
   different system, and two copies of one adapter are not that. A list of
   targets would add an option to `run/1`, a way to say which target runs
   the variant path and a second set of configs, to express what
   `expansions/0` already states. One target, run twice, keeps `run/1` as it
   is.

5. **The comparison is per step.** After each step, every `@compare every:
   1` observation is evaluated on each execution's projection state, in
   projection order then declaration order. Its second argument is the
   step's plain command, made concrete in that execution. Two values agree
   when they are `==`, or when the relation named by `using:` answers `true`.
   The first observation that disagrees fails the plan with `{:diverged,
   name, step_key, reference_value, variant_value}` at that step, `name`
   being the observation function's name. An observation that raises fails
   the plan with `{:raise, exception}` at the step. A value `{:pending, _}`
   is compared as any value and is never waited for. A failure of either
   execution keeps its own reason at its step.

   Rejected: compare once at the end of the plan. A divergence would then
   show at the last step, whatever step caused it, and the shrinker's rule
   that a candidate must fail at the same step or an earlier one could not
   tell a shorter plan from a different failure. Per step, the failing step
   is the first step where the executions disagree.

6. **Load rules for `@compare`.** `@compare every: 1` loads only on a model
   that exports `expansions/0`. Every other `@compare` form raises on every
   model, and `every: 1` on a model without `expansions/0` raises: with one
   execution there is nothing to compare. A model with `expansions/0` and no
   `@compare` loads and runs both executions, so only a failure of either
   one fails a plan.

7. **Lanes are refused with paths.** Executing a plan with `lanes: 2` for
   a model that exports `expansions/0` raises `ArgumentError` in `run/1`
   and `replay/2`, naming `:lanes` and `expansions/0`. `plan/3` still
   builds such a plan, so the prefix of a two-lane plan stays the one-lane
   plan of the same seed for every model, this one included. Two executions of a
   schedule that interleaves one step's parts with another's would need a
   rule for how the variant's extra commands take part in the schedule, and
   this record does not make one.

8. **The report counts both executions.** `plans` counts plans, not
   executions. `withdrawn` comes from generation, once. The assign counts
   `set` and `acknowledged` count every `execute/3` call of both executions
   of the search plans, so a variant step with two commands counts two
   calls. The shrink's candidates stay uncounted, as before, and the
   unacknowledged rule runs on these counts.

9. **The shrinker classes a divergence by observation name.** The shrinker
   adopts a candidate when it fails the same way, which it tests by the
   failure's class, at the same step or an earlier one. A class is the
   reason itself, except for a check (its name), an adapter error and a
   raise. The shrinker gains one clause: `class({:diverged, name, _, _, _})
   -> {:diverged, name}`.

   Without it a divergence's class is the whole reason, including the step
   key and both observed values. Lowering a payment from 300 to 2 changes the
   two balances, so no candidate that lowers a value would be adopted, and a
   shrink would stop at the plan that was first found. With the clause, two
   divergences on one observation are one kind of failure whatever values
   they carry. No other reason reaches the clause, so every other shrink is
   as it was. The shrinker has no code for paths otherwise: lowering a pick
   moves a step toward its plain path, which is index 0, and the path's
   entries sit under the step's key, so removing a step removes them.

10. **Replay.** `replay/2` of a journal runs both executions for a model
    with `expansions/0` and rebuilds the same paths from the stored picks and
    draws. The plan and the verdict are the same in a second VM, on both
    engines.

## Alternatives

- **Two targets with a target list on `run/1`.** Rejected in decision 4.
- **Compare once at the end of the plan.** Rejected in decision 5.
- **No clause, and a wrapped `execute` function for the shrinker.** The run
  could hand the shrinker an `execute` that returns a stand-in reason of a
  class that is stable, and map the reason back at the end. It gives the
  effect of decision 9 with more code, and the code exists only to keep one
  clause out of the shrinker.
- **Whole-reason equality for a divergence.** The shrink stalls, as decision
  9 explains.

## Consequences

- A model gains a way to find a bug that only the difference between two
  routes shows, with one adapter and one target.
- A model with `expansions/0` costs about two executions per plan, plus the
  extra commands of a variant. Plans per second drop in proportion.
- A model that states `expansions/0` and compares no observation cannot
  fail on a divergence, only on a failure of either execution.
- The corpus gains `split_refund`. Its model checks no balance on one
  execution and compares the balances the scheme reported, per payment in
  payment order and never by payment id, so only the comparison sees the
  bug. On the next corpus, plan cap 200, seeds 1 to 20, run twice with
  identical tables:

  | engine | found | plans until found | shrink runs | reached the smallest plan |
  |---|---|---|---|---|
  | `Engine.Native` | 20 of 20 | 1.1 | 28.0 | 20 of 20 |
  | `Engine.StreamDataSource` | 20 of 20 | 1.1 | 30.1 | 20 of 20 |

  Every other row of the table is unchanged. The same model without
  `expansions/0` finds nothing on seeds 1 to 20, and with the bug off no
  seed fails and the bug never fires.
- The corpus engine writes a shrunk step that runs a path other than the
  plain one with `path:`, the path's commands as plain maps, so the smallest
  plan of `split_refund` is a payment of 2 and a refund of 2 whose path is a
  refund of 1 and a refund of 1.

## Known costs and limits

- A path does not read the predicted state during its draw, and a path
  cannot contain a path.
- The variant runs after the reference at each step, so an observation that
  depends on timing between the executions is not expressible.
- `{:pending, _}` is compared as a value. A system that settles later needs
  an observation that the model reads only after a step that settles it.
- Shrink candidates are not counted in the assign counts of the report.
