# DR-055: Failure Report Layout

**Status:** Accepted
**Date:** 2026-10-27

## Context

The terminal failure report grew one section per feature, and a reader now
has to reconcile the sections with each other to understand one failure. A
divergence between two targets shows the problems most clearly.

- Three numbering schemes for one run. The Failure section names the failing
  root by its root index (`Root: 1`). The reproduction listing numbers the
  failing target's executed commands in reading order (`[2]`). The event log
  numbers the commands by root again (`[1]`).
- Two counts that disagree. "Shrunk Commands: 2" counts roots, while
  "Minimal Reproduction (3 commands)" counts the failing target's leaves, and
  neither heading says which one it counts.
- Only one side of a comparison. The report keeps the failing target's trace
  and drops the reference's. A divergence says that two targets disagree, not
  which one is wrong, but the report shows evidence for only one of them.
- Prose that restates fields. "Why it failed" repeats the observation, the
  targets and the root printed just above it. Mismatch repeats Reference and
  Variant as `left:` and `right:`, also when the relation gave no reason of
  its own.
- Projection state cut short. State Transition prints values through a
  summary that stops after three elements (`limit: 3`) and turns lists into
  "N items", which hides the data a reader needs.
- Sections with little use for debugging. Run Number, Timestamp, Boundary
  Comparisons, Shrinking Statistics and Original Sequence answer questions
  about the campaign, not about the failure.
- Reproduction calls that cannot be pasted. Each call repeats the whole
  `targets:` list, a few hundred characters long, and a list that holds a pid
  prints as `#PID<0.213.0>`, which a new session cannot evaluate.
- Defects in the layout itself. Label values do not line up in a column. The
  right border of the colored banner is off by two characters. An "Also
  disagreed" line names its observation twice, and a multi-line mismatch
  breaks out of the line's indent.

DR-054 adds log lines tied to steps, and the layout has to give them a place.

## Decision

1. **Five sections, in this order:** banner, Failure, Minimal Reproduction,
   Projections, Reproduction. A Setup section (DR-054 decision 8) comes before
   Minimal Reproduction when the run was given `setup_log:`. The report still
   ends with the replay call (DR-050).

2. **The banner names the outcome; the seed follows it.** The banner says
   `BUG DETECTED!`, or `TEST CODE ERROR` with its hint for a failure in test
   code. Both banners have the same width, with or without color. The line
   under the banner is `Seed: <seed>`. The line that repeated the failure
   kind and name is removed, because the Failure section opens with them.

3. **One Failure section replaces Failure Location and What Failed.** It
   holds, as labeled fields in one aligned column:
   - the failure kind and its name (the observation or the check);
   - where it happened: the step label (decision 5) and the command;
   - the fields of that kind (for example, the poll timeout's predicate, the
     idempotency attempts, the latency budget);
   - for `:diverged` and `:did_not_converge`: the reference's and the
     variant's values, the `using:` relation as written (DR-051), and the
     time the comparison waited against the bound (`still differing after
     1001 ms (bound 1000 ms)`), which separates a real disagreement from a
     bound set too tight;
   - every other observation that disagreed at the same boundary, one line
     each, with its name and both values;
   - the other failures of the run, one line each.

   "Why it failed" is removed. Mismatch prints only when the relation failed
   with a reason (`{:fail, reason}` under DR-052); when it answered `false` or
   `nil`, the two values already say everything Mismatch would.

4. **Minimal Reproduction lists every compared side.** For `:diverged` and
   `:did_not_converge`, the section lists the reference and the failing
   variant, each under its own header (`Reference: target "a"`,
   `Variant: target "b"`). Other targets are not listed. A failure in a run
   with one target prints one listing without headers. The heading counts
   roots (`Minimal Reproduction (2 roots)`).

5. **One label per step, used in every section.** Roots are `[i]`, and the
   leaves of an expanded root are `[i.j]`, listed under their root, which
   names its expansion entry. Setup and teardown commands are
   `[setup i]` and `[teardown i]`, and a branching run labels a branch command
   `[branch b.i]`. The label comes from the step's `Sequence.Position`, so the
   Failure section, the listing and the Projections heading always agree.
   The failing step carries the marker `►` and the outcome
   (`◄── diverged`, `◄── failed`) in each listing where it ran.

6. **Events and log lines sit under the step that produced them.** The Event
   Log section is removed. Under each step, the report prints the step's
   events and its log lines (DR-054) in timestamp order, each with its offset
   from the target's run start. An event from a source other than the
   command keeps its source badge (nemesis, mock, stutter, resource poller).
   Entries tied to no command (injector and telemetry events) are printed
   after the listing, under "Not tied to a command".

7. **Projections shows full state, one attribute per line.** For each
   projection, the section names the last event applied and prints every
   attribute on its own line, with values printed in full.
   - For `:diverged` and `:did_not_converge`, it compares the reference's
     state with the variant's at the failing boundary. Equal attributes print
     once; a differing attribute prints a `-` line for the reference and a
     `+` line for the variant.
   - For every other failure, it compares the state before the failing step
     with the state after it, with the same markup.

8. **Reproduction binds the targets once.** The section prints
   `targets = [...]` first, then the seed call, the call that regenerates the
   failing variant, and last the replay call, each with `targets: targets`.
   When `targets` holds a value that no source code can rebuild (a pid, a
   reference, a port or a function), a line under the binding names where
   each one sits (`config.server`) and says to rebuild the list as the test
   does.

9. **Sections removed from the terminal and markdown formats.** Run Number,
   Command Index, Timestamp, State Transition (replaced by decision 7), Event
   Log (replaced by decision 6), Boundary Comparisons (its wait time moves
   into Failure), Shrinking Statistics and Original Sequence. One shrink fact
   stays: when the shrinker stopped because its time or iteration budget ran
   out, the Failure section says so and warns that the reproduction may not
   be minimal. When a shrunk run did not reproduce the failure, the listing
   already shows the original run, so removing Original Sequence loses
   nothing.

10. **One way to print a value.** Commands, events, Failure values, log lines
    and projection attributes are all printed with `inspect(value, pretty:
    true)`, with `syntax_colors:` when the report is colored (DR-054
    decision 12). Diff lines keep their red and green and get no syntax
    colors, so the side a line belongs to stays visible.

11. **The terminal and markdown formats share the layout; JSON keeps every
    field.** The markdown format follows decisions 1 to 10 without color. The
    JSON format keeps every field, the removed ones included, and gains the
    reference's trace and state.

12. **The report keeps the reference's trace for comparison failures.** For
    `:diverged` and `:did_not_converge`, `FailureReport` gains
    `reference_trace` (the reference target's `RunTrace` of the reported run)
    and the reference's projection state at the failing boundary. The
    scheduler already holds every target's result, so nothing new is
    captured; the report keeps a result it used to drop. Other failures leave
    both fields `nil`. The report also records why the shrinker stopped
    (`:done`, `:max_iterations` or `:max_time`) for decision 9. A saved report
    carries the new fields, so the persistence version is bumped, unless the
    current version is still unreleased (as in DR-051).

## Example

A divergence between two targets of a ledger model, without color. The text below was
regenerated from a real run when DR-058 added the "What this checks" section:

```
╔══════════════════════════════════════════════════════════════════════╗
║                            BUG DETECTED!                             ║
╚══════════════════════════════════════════════════════════════════════╝

Seed: 1234

## Failure

Failure        diverged
Observation    MyApp.Balances.balance_of_bob
At             [0] %MyApp.Transfer{amount: 1}
Reference      "direct"  1
Variant        "split"  0
Compared       using ==, still differing after 51 ms (bound 50 ms)
Also differed  MyApp.Balances.fees  "direct"  0  "split"  2

## What this checks

  Diverged      Two targets ran the same plan separately and disagreed. They may
                have taken different but equivalent paths, and an observation
                settled to different values in the reference target and in the
                variant target. Either the system treats equivalent histories
                differently, or the test's claim that the paths are equivalent
                is wrong.

  Model         MyApp.Model
                The MyApp ledger model.

  Observation   MyApp.Balances.balance_of_bob/2
                The balance of bob after the transfer.

                Every route to the same transfer must leave bob with the same amount.

  Also differed MyApp.Balances.fees/2
                The fees alice paid for the transfer.

  Projection    MyApp.Balances
                Keeps the balance of bob.

  Path          "split" ran Transfer as steps [0.0],[0.1]
                send the amount in two halves

  Command       MyApp.Transfer
                Moves money from alice to bob.

## Minimal Reproduction (1 root)

Reference: target "direct"
► [0] %MyApp.Transfer{amount: 1}  ◄── diverged
        +0.00s event %MyApp.Transferred{amount: 1, fee: 0}

Variant: target "split"
► [0] %MyApp.Transfer{amount: 1}  as Transfer[1]  ◄── diverged
    [0.0] %MyApp.Part{amount: 0, last: false}
        +0.00s event %MyApp.Transferred{amount: 0, fee: 1}
    [0.1] %MyApp.Part{amount: 1, last: true}
        +0.00s event %MyApp.Transferred{amount: 0, fee: 1}

## Projections at [0]   (- reference "direct", + variant "split")

MyApp.Balances   last applied: Transferred
  - bob: 1
  + bob: 0
  - fees: 0
  + fees: 2

## Reproduction

targets = [{MyApp.Adapter, name: "direct", expansion: :identity}, {MyApp.Adapter, name: "split", config: %{lossy: true}}]

# Rerun from the seed:
PropertyDamage.run(model: MyApp.Model, targets: targets, compare: [converge_within: 50], max_commands: 1, seed: 1234, max_runs: 1)

# Regenerate the failing variant:
PropertyDamage.Expansion.for(MyApp.Model, 1234, 1, "split", targets: targets, max_commands: 1)

# Replay the shrunk failure:
PropertyDamage.run(model: MyApp.Model, targets: targets, compare: [converge_within: 50], only: [replay: "property_damage_replays/Model_seed1234.replay.exs"])
```

## Consequences

- A reader sees both sides of a comparison failure, under one numbering, with
  each step's events and log lines next to it.
- A report for a run with one target gets the same layout with one listing,
  and its Projections section shows the failing step's state before and after.
- The report for a comparison failure holds a second trace and a second
  projection state, at most double the trace of a run with one target, and
  only for those two kinds.
- Tests that assert on the removed sections or labels change; the guides that
  show a failure report are regenerated from a real run.
- The terminal output no longer shows the campaign statistics. A reader who
  wants them reads the JSON format.

## Alternatives considered

- **Keep only the failing target's trace.** Rejected: a divergence does not say
  which side is wrong, the Projections diff of decision 7 needs the
  reference's state, and the reference's log lines (DR-054) are the record of
  the side that behaved as expected.
- **Keep every target's trace.** Rejected: targets other than the reference and
  the failing variant agreed at the failing boundary, so their traces add
  length without evidence.
- **Hide the removed sections behind a `verbose:` option.** Rejected: they carry
  little signal for debugging, a second layout doubles what the tests must
  cover, and the JSON format keeps every field for a reader who needs one.
- **Keep Mismatch on every comparison failure.** Rejected: without a reason from
  the relation it prints the two values a second time.
- **Number leaves in reading order across the whole run.** Rejected: that number
  matches nothing in the Failure section, which names roots.
- **Truncate large projection values.** Rejected: the truncated values are the
  ones a reader came for, and DR-054 rejected truncation for log lines on the
  same grounds.
