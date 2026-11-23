# DR-069: The Shrinker Edits the Journal, and Generation Rebuilds Each Candidate

**Status:** Accepted
**Date:** 2026-11-22

## Context

The new engine under `PropertyDamage.Next` keeps the test case as a journal:
one entry per draw, keyed by where generation made the draw (DR-068). PD
rebuilds a plan by running generation again against the journal. A key with
an entry gives back the stored value, fitted to the domain generation offers
now; a key without one draws afresh from the key's seed.

A failing plan is rarely the smallest plan that fails. Take a run whose
twentieth plan fails at step 14 after a payment of 812 and three refunds.
The smallest plan that shows the same defect may be one payment of 2 and
one refund of 1. A shrinker searches for that smaller plan by trying
candidates and keeping each one that still fails the same way.

Today's engine shrinks the command list itself. A candidate built that way
can be a plan the model would never generate: a refund whose payment was
removed, or an amount that a `from/2` function would not offer. Each such
candidate either fails for a new reason or passes for a reason unrelated to
the defect, and both waste a run against the system under test.

StreamData shrinks a value through a tree. A generator drawn from one seed
at one size gives one value, the root, whose children are smaller values.
StreamData exposes this tree only through `StreamData.check_all/3`, which
offers a failing value's children to the property in order. The modules
that build the tree directly are private.

## Decision

1. **The shrinker edits only the journal.** A candidate is an edited
   journal. Generation rebuilds its plan, fitting every stored value to the
   domain it has now (decision 4), and the plan is executed. So every
   candidate is a plan the model can build: `when:` predicates, `from/2`
   functions and the simulator all run again.

2. **The moves.** The shrinker runs these passes, repeated until a round
   adopts nothing or the run budget is spent:

   1. Once, first: it writes the empty pick `{:empty}` at every slot after
      the failing step.
   2. It removes steps in blocks. The block size starts at half the number
      of steps and halves down to one step; at size one the pass repeats
      until it removes nothing. A step is removed by writing `{:empty}` at
      its pick key, `{{lane, slot}, :pick}`. Generation reads `{:empty}` as
      a slot that yields no step and draws nothing, and writes it back.
   3. It lowers each drawn value, later slots first and, within a slot, in
      the reverse of the draw order. Generation draws a `from/2` field
      after the fields it names, so a dependent value is lowered before its
      sources. The list of keys is read again after every adoption, since a
      rebuild can add or drop keys.
      - An integer tries its range's lower bound first, then bisects
        between the highest value known to pass and the lowest known to
        fail, until the two are adjacent.
      - A member tries each lower index of its list, from 0.
      - A StreamData value extends its path (decision 6). The shrinker tries
        the children of the node at the path in order and descends into
        the first child that fails the same way.

3. **Adoption.** A candidate is adopted when it fails the same way as the
   current best plan: the same kind of reason at the same step or an
   earlier one. The kind is the name of the failed check, the adapter's
   error reason (its tag when it is a tagged tuple), or the module of the
   raised exception. A candidate whose rebuilt plan has the same steps as
   the current best is not executed. A candidate whose rebuild raises is
   dropped and not executed, except for `DependentStreamDataError`, which
   stops the shrink as it stops a run (DR-068, amendment).

4. **Fitting on rebuild.** `Engine.Native` fits a stored value of the
   generator's kind to the domain generation offers now, and the entry it
   records holds that current domain:
   - An integer is kept if it lies in the current range, else clamped to
     the nearer bound. The entry records the current range.
   - A member is kept if the current list holds it, else the member at the
     stored index is taken, else the last member if the list got shorter.
     The entry records the index in the current list.
   - A StreamData value follows its stored path on the current generator
     (decision 6).

   A kept value can lose its place on a bound. Take a payment of 500, a
   refund of 200, then a second refund of 300 drawn from `1..300`, the
   whole balance. A candidate removes the first refund. The second
   refund's range becomes `1..500`, and 300 still fits, so it is kept; but
   it no longer refunds the whole balance, and the defect may no longer
   show. When the candidate that kept such a value is not adopted, the
   shrinker tries once more with each such value at its new bound, here
   500. A value sat on a bound when it equalled the stored range's first
   or last integer and that bound differs in the current range. The
   shrinker tries this once per candidate, right after it.

   To lower a member, the shrinker writes, at the member's key, a value
   that no list holds together with the wanted index. The engine then
   takes the member at the stored index, so the shrinker reaches index `i`
   without knowing the list.

5. **Withdrawn slots and the final journal.** An edit can leave a stored
   pick no longer offered: the payment a refund needs is gone, so the
   refund's `when:` fails. Generation then withdraws that slot: no step,
   and generation goes on. During the search a withdrawn slot keeps its
   pick and its field entries in the rebuilt journal, so a later edit that
   offers the command again brings it back with the values it had.

   The final journal drops what the search kept. Each withdrawn slot's
   pick becomes `{:empty}` and its other entries go. The final journal
   therefore holds exactly its plan's draws, and it replays to the
   identical plan. The empty pick is needed because every plan keeps its
   full number of slots and the journal has no length: a slot with no pick
   entry would draw a fresh pick on replay. The shrinker executes the plan
   that the final journal rebuilds once more, and that execution is the
   failure `run/1` returns.

6. **A StreamData value is stored as its path, reached by steering.**
   `Engine.Native` records a StreamData value as `{:stream_data, value,
   path}`. The path is a list of child indices from the root of the shrink
   tree that the generator, drawn from the key's seed at a fixed size,
   gives: `[]` is the root, `[2, 0]` the first child of the root's third
   child. A fresh draw is the root, with path `[]`.

   `PropertyDamage.Next.Steering` reaches the node at a path through the
   public `StreamData.check_all/3` alone. It runs one check with
   `max_runs: 1` and fails the root. `check_all/3` then offers the root's
   children in order. Steering passes each child until the one at the next
   index of the path, which it fails, so `check_all/3` descends into that
   child's children. When the walk reaches the node the path names,
   steering throws out of the property callback, so `check_all/3` builds
   no more values. A path that names a child a node does not have is cut
   at its longest prefix that exists, and the walk ends at the deepest
   node it reached. On a changed generator, the stored path is walked on
   the new tree and cut the same way, so the value reached belongs to the
   current generator.

   The shrinker uses that cut to find a node's last child. It asks for the
   child at index `i`; if the rebuilt journal records a shorter path, the
   node has no child `i`, and the search at that node ends without an
   execution.

7. **How steering counts a node's children.** `Steering.child_count/3`
   fails the nodes along the path and then passes every child of the node
   it counts. On the StreamData version in `mix.lock`, `check_all/3` offers a
   failing node's children in order, descends into the first that fails,
   and never returns to that child's later siblings. So the count is the
   number of values offered after failing the node, every one of them
   passed.

8. **Two canaries guard the steering.** StreamData documents neither
   behavior that steering relies on, so a test calls `check_all/3`
   directly, with no PD code, for each:
   - The visiting-order canary pins the order on the StreamData version in `mix.lock`:
     children offered in order, descent into the first that fails, no
     return to later siblings. It also proves that two runs along one path
     give one value. A StreamData release that changes the order fails
     this test before any shrink goes wrong.
   - The throw pin proves that `check_all/3` lets a throw from the property
     callback pass through to its caller, and pins how many values the
     generator builds before the throw. A release that catches throws, or
     builds children eagerly, fails this test.

9. **Saved format version 2.** The StreamData entry shape changes the saved
   journal, so the format version moves to 2. Version 2 may also hold the
   empty pick. The loader refuses version 1, and any other version, with a
   message that names the version found and the version it loads. The
   journal records no origin: no PD version, no model version, no module
   digest. `replay/2` refuses a journal whose spec list fingerprint no
   longer matches the model, and says nothing about a changed generator;
   the engine fits or walks the values stored for it.

10. **Checks of the command-sequence projection run.** An execution runs
    the `@check` functions of the model's check projections and of its
    command-sequence projection. A projection listed in both roles folds
    its state once and runs its checks once per trigger. Loading a model
    whose projections declare `@compare`, or a check form this engine does
    not run, raises `ArgumentError`, so no check is skipped without a word.

11. **Mint markers are stamped once, at generation.** Generation stamps
    each `mint_per_run/1` marker at its first draw with the step and the
    location of its key. A stamped marker keeps its stamp. A marker the
    model reads back from its predicted state therefore names the step
    that drew it: two steps that hold one marker send one value in an
    execution, and two separate `mint_per_run/1` calls give two values.
    The value stays fresh per execution. A member draw over stamped
    markers stores the stamped marker in the journal, and such a journal
    saves, loads in a fresh VM and replays.

12. **`shrink_runs` counts executed candidates.** Every execution after
    the plan that first failed counts as a shrink run, the final
    execution of the shrunk plan included. Candidates that are not
    executed, because their rebuild raised or equals the current plan, do
    not count. `max_shrink_runs` bounds the count, the final execution
    included. The same run gives the same final plan and the same count.

13. **The corpus engine reads the fired bug from a replay.** A shrink
    executes many candidates after the failure, so the last system the
    adapter started need not be the one that ran the final plan. The
    corpus engine for `PropertyDamage.Next` therefore replays the final
    journal once with a fresh fire log and reads whether the bug fired
    there. That replay counts neither in `shrink_runs` nor in the seed's
    fire count.

## Alternatives

- **Shrinking the command list, as today's engine does.** Rejected: a
  candidate can be a plan the model would never build, so a run can fail
  or pass for a reason unrelated to the defect. Rebuilding by generation
  keeps every candidate valid, and the journal stays the one form of the
  test case.
- **Reading StreamData's shrink tree through its private modules.**
  Rejected: a private module can change in any release without notice.
  Steering uses only the public `check_all/3`, and the two canaries turn
  the undocumented behavior it relies on into a test failure.
- **Storing a StreamData value bare and shrinking it from the key's seed.**
  Rejected: a bare value cannot be placed in the tree of a changed
  generator, and every shrink step would have to rebuild the tree from the
  root without a way to name the step it reached. A path names a node on
  any generator, and replays it.
- **Counting a node's children from the values offered by two different
  walks.** An earlier StreamData release returned to a node's later
  siblings after descending into a child, so such a count held there.
  Rejected: on the release in `mix.lock`, `check_all/3` never returns, so the
  count must be the values offered after failing the node.
- **Removing a step by deleting its pick entry.** Rejected: every plan
  keeps its full number of slots, so a slot with no pick entry draws a
  fresh pick on replay. The empty pick names a removed step explicitly.
- **Dropping a withdrawn slot's entries as soon as it is withdrawn.**
  Rejected: a later edit that offers the command again would draw it
  afresh, so the search could not bring back a step with its values.
- **Recording the PD version or a module digest in the journal.**
  Rejected: a version check refuses journals that still replay correctly.
  The spec list fingerprint refuses the change that makes a stored pick
  ambiguous, and the engine fits or walks a changed generator's values.
- **Executing every candidate, including one whose plan equals the
  current best.** Rejected: such a run cannot change the best plan and
  only spends the budget.

## Consequences

- Every shrunk failure carries a journal that replays to its plan with
  `replay/2`, in another VM too.
- A candidate never names a value the model cannot draw, and a dependent
  integer or member is fitted when its source shrinks.
- A dependent value drawn through StreamData follows its stored path when
  its source shrinks, and is not fitted. The shrink may then stop at a
  larger plan; the kept list names each such site (DR-068, amendment).
- Journals saved in format version 1 cannot be loaded. Capture the
  failure again.
- `run/1` gains `shrink:` (default `true`), `max_shrink_runs:` (default
  1000) and `dependent_stream_data:`. A failure describes the final plan;
  `original` holds the plan that first failed, and `shrink_runs` counts
  the executed candidates.

## Known costs and limits

- The corpus engine spends one extra execution per failing seed on the
  replay of decision 13, outside `shrink_runs`.
- A candidate whose rebuild raises is dropped without a word. A defect in
  model code that shows only on such a value stays silent during the
  shrink.
- The early stop of a walk depends on `check_all/3` not catching throws.
  The throw pin fails first if a release changes that.
- A walk costs, in values the generator builds, the root plus `i + 1`
  children for each index `i` of the path. A long string or list value
  can cost many generator calls per shrink.
- The shrinker lowers one key at a time. A failure that needs two values
  to move together can stop at a local minimum.
- The value the shrinker writes to ask for a member by index must appear
  in no model's list.

## Amendment (2026-11-23)

The shrinker gains a fourth pass, which lowers two integer entries by the
same amount.

1. **Why.** Some failures need two values to keep a relation: a refund
   that must equal a payment, or two amounts whose difference must stay
   fixed. Lowering either value alone ends the failure, so every single
   edit of decision 2 is refused and the shrink stops at a local minimum
   with both values above the smallest plan's (the last limit of "Known
   costs and limits" above). Lowering both by the same amount keeps such a
   relation and reaches the smaller plan.

2. **The candidate.** A pair is two `{:integer, value, range}` entries of
   the current best journal, each above its range's first value. The pair
   first tries both values lowered by the largest amount both allow,
   `min(value_a - first_a, value_b - first_b)`. If that candidate is not
   adopted, the shrinker bisects between zero, which fails, and the
   smallest amount known not to fail the same way, for the largest amount
   that still does. Both entries are read again before each candidate,
   and a value that falls outside its current range is not tried.

3. **When it runs.** Only after a round in which block removal and single
   lowering adopted nothing. The pairs come from the integer entries in
   draw order, and are tried as (first, second), (first, third), and so
   on, then (second, third): the order is fixed by the plan, so one seed
   gives one shrink. The first pair adopted ends the pass and the rounds
   start again from block removal, so the pairs are read again from the
   rebuilt journal, which can add or drop keys. A round in which no pair
   is adopted ends the search.

4. **No new path.** Each candidate is an edited journal that goes through
   the adoption rule of decision 3, the same-plan skip, and the run budget
   of decision 12, and every executed candidate counts as a shrink run.
   The journal format and the meaning of its entries do not change.

5. **Engines.** The pass reads only the integer entries of `Engine.Native`.
   The source entries of `Engine.StreamDataSource` (DR-071) are not paired,
   so that engine's shrinks do not change. The next amendment extends the
   pass to them.

6. **Measured effect.** On the next corpus, both engines, plan cap 200,
   rows for `Engine.Native`; every `Engine.StreamDataSource` row is
   unchanged:

   | entry | reached minimum | mean shrink runs |
   |---|---|---|
   | `offset_refund` | 0/20 to 19/20 | 25.8 to 29.8 |
   | `racing_refunds` | 18/20 to 19/20 | 73.0 to 77.0 |
   | `ledger` (no smallest plan) | - | 34.2 to 38.5 |

   Every other row is unchanged. A shrink whose journal holds fewer than
   two integers above their range's first value makes exactly the runs it
   made before. Where a pair exists but no pair is kept, the pass costs
   the candidates it tries: two extra runs on a two-step stock fixture.

**Known costs and limits.**

- Before a search ends, it tries each pair of lowerable integers: one
  candidate for the largest amount, then the bisection's candidates. The
  number of pairs grows with the square of the number of lowerable
  integers.
- The pass lowers by the same amount only. A relation that needs two
  values to move by different amounts, or three values to move together,
  can still stop at a local minimum.
- Bisection assumes that a smaller amount keeps the failure when a larger
  one does. Where that does not hold, the pass can stop above the
  smallest amount that fails.

## Amendment (2026-11-23): pairs on the second engine

The fourth pass also pairs the recorded positions of `Engine.StreamDataSource`
source entries (DR-071).

1. **Why.** On that engine every value is a source entry
   `{:source, value, positions}`, an integer field included, so a pass that
   reads only `{:integer, value, range}` entries never fires there. A refund
   one below its payment stops at a local minimum on that engine for the
   reason the previous amendment gives.

2. **The unit.** The pass lowers values. A value is an integer entry above
   its range's first value, or one recorded position of a source entry
   whose value is above its recorded lower bound. A position is the
   smallest integer the engine lets the shrinker edit, and the one the
   single-lowering move of DR-071 already lowers, so the pair is that move
   applied to two values at once. Two positions of one entry also form a
   pair, so a relation inside one nested value, such as two linked amounts
   in a `fixed_map`, can fall together; both edits go to that entry in turn.

3. **Order and count.** The values are listed in draw order: keys in the
   order they were drawn, and within a source entry its positions in the
   order `positions/1` returns them. Pairs are tried in the order of the
   previous amendment. On `Engine.Native` the list holds only integer
   entries, so its candidates are the ones the previous amendment tries.
   The list holds only values still above their lower bound after a round
   of single lowering kept nothing, and a list's length is bounded by the
   draw size, so the count of pairs is bounded. No cap is applied beyond
   `max_shrink_runs`: a cap by position, by key or by count would miss a
   relation in some shape of value.

4. **No new path.** A candidate is the current journal with one or two
   source entries replaced by `put_position/3` results. Each position is
   read again before each candidate, and a value outside its current
   bounds is not tried. Generation rebuilds the plan and fits each
   position, and the candidate goes through the adoption rule, the
   same-plan skip and the run budget. The journal format, the entry layout
   and the engine do not change.

5. **When it runs.** Unchanged: after a round in which block removal and
   single lowering adopted nothing; the first pair adopted restarts the
   rounds.

6. **Measured effect.** On the next corpus, both engines, plan cap 200,
   rows for `Engine.StreamDataSource`; every `Engine.Native` row is
   unchanged:

   | entry | reached minimum | mean shrink runs |
   |---|---|---|
   | `offset_refund` | 5/20 to 19/20 | 29.0 to 31.9 |
   | `racing_refunds` | 19/20 to 20/20 | 58.2 to 62.5 |
   | `nested_price` | 0/20 to 0/20 | 21.7 to 23.3 |
   | `ledger` (no smallest plan) | - | 35.6 to 40.1 |
   | `long_note` | 20/20 to 20/20 | 103.5 to 165.8 |
   | `lost_full_refund` | 20/20 to 20/20 | 43.4 to 54.4 |
   | `fifth_refund` | 19/20 to 19/20 | 33.1 to 40.4 |
   | `double_credit` | 20/20 to 20/20 | 12.8 to 13.6 |

   `nested_price` stays at 0/20 because its smallest plan fails with a
   different reason from the first failure (DR-071), which the adoption
   rule refuses whatever edit produces it.

**Known costs and limits.**

- A string records, for each character, a choice position whose value
  does not reach the string. Lowering such a position alone rebuilds the
  same plan, which costs no run, so the position stays above its lower
  bound. Paired with a value that matters, such as the string's length, it
  gives candidates that are executed and refused. `long_note`, whose
  failing note holds 41 characters, has the largest rise; this cost was
  seen on a one-string fixture and is not separated from the others in
  the corpus numbers.
- The limits of the previous amendment hold on this engine too.

## Amendment (2026-11-23): values that change nothing alone leave the pair list

The pass of pairs leaves out every value whose single lowering, in the
round just ended, rebuilt only the plan already held, because a pair with
such a value is in effect a single lowering of the other value and costs
runs that single lowering has already spent.

1. **Why.** On `Engine.StreamDataSource` a string records, for each
   character, a position whose value does not reach the string (the first
   limit of the previous amendment). Every such position stays above its
   lower bound, so the pair list holds one per character, and each pair of
   one with the string's length executes candidates that differ from the
   plan held only in the length. On `long_note` every run of the pass of
   pairs went to such pairs: 62.3 runs per seed on average, over a list of
   17.4 values of which 16.4 changed nothing alone.

2. **The rule.** During single lowering the shrinker notes, for each
   integer entry and each recorded position it lowers, whether every
   candidate rebuilt the plan already held, or whether one was executed or
   could not be rebuilt. The pass of pairs reads these notes and leaves out
   the values of the first kind. It runs only after a round that adopted
   nothing, so the notes describe the plan it pairs from, and reading them
   costs no run. A value with no note, or one whose lowering executed a
   candidate, stays in the list. The rule applies to integer entries of
   `Engine.Native` and to source positions alike; on the next corpus it
   leaves values out only on `Engine.StreamDataSource`, and every
   `Engine.Native` row is unchanged.

3. **Measured effect.** On the next corpus, both engines, plan cap 200,
   seeds as recorded per entry, run twice with identical tables; rows for
   `Engine.StreamDataSource` that moved. No row changed its found count or
   its count of seeds that reach the smallest plan, and no seed changed
   either flag.

   | entry | mean shrink runs |
   |---|---|
   | `long_note` | 165.8 to 103.5 |
   | `fifth_refund` | 40.4 to 33.1 |
   | `lost_full_refund` | 54.4 to 49.6 |
   | `double_credit` | 13.6 to 12.8 |

**Known costs and limits.**

- A value can change nothing alone and still matter in a pair, when the
  other value's change makes it reach the plan. Such a pair is no longer
  tried. No entry of the corpus has one.
- Under a cap of 64 shrink runs, `long_note` spends its whole budget on
  single lowering of the note, before the payment's amount is lowered and
  before the pass of pairs starts, so the rule does not change that row.

## Amendment (2026-11-23): a divergence is classed by its observation name

The shrinker gains one clause in the class of a failure, for the reason a
model that states paths can fail with (DR-073).

1. **Why.** A candidate is adopted when its failure has the class of the
   best failure so far, at the same step or an earlier one. The class of a
   reason is the reason, except for a check (its name), an adapter error and
   a raise. A divergence is `{:diverged, name, step_key, reference_value,
   variant_value}`, and as a whole term it changes with every value the
   plan carries. Lowering an amount changes both observed values, so no
   candidate that lowers a value would be adopted and the shrink would stop
   at the plan first found.

2. **The rule.** `class({:diverged, name, _, _, _})` is `{:diverged, name}`:
   two divergences on one observation are one kind of failure, whatever
   values they carry. The step test is unchanged, so a candidate must still
   diverge at the same step or an earlier one. No other reason takes the
   clause, so every other shrink is as it was.

3. **Paths need nothing else.** A step's path pick is a member entry that
   lowers toward index 0, the plain path. The entries of a path sit under the
   step's key, so removing a step removes them, and a withdrawn slot keeps
   them until the final journal replaces them.

4. **Model loading.** `@compare` is still refused at load, except
   `@compare every: 1` on a model that exports `expansions/0`.
