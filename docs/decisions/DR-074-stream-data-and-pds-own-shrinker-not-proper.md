# DR-074: PD Generates with StreamData and Shrinks with Its Own Journal Shrinker, Not with PropEr

**Status:** Accepted
**Date:** 2026-11-24

## Context

PropEr, the Erlang library, already generates and shrinks sequences of
commands against a state machine, and PropCheck wraps it for Elixir. Until
this record, nothing in the repository said why `PropertyDamage.Next` draws
with StreamData (DR-068, DR-071) and shrinks with a shrinker of its own
(DR-069) when that library exists. The question returns with each new
reader, so this record answers it once, with a measurement.

Three facts bear on the answer.

1. **License.** PD is published under Apache-2.0 (`mix.exs`). The hex.pm
   metadata of `proper` 1.5.0 and of `propcheck` 1.5.0 both read
   `GPL 3.0`. This record states the two fields as published and takes no
   position on what GPL 3.0 requires of a project that depends on PropEr
   for tests only.
2. **Who owns the loop.** PD counts every execution against the system and
   caps the executions a shrink may spend (`max_shrink_runs`, DR-069),
   because one execution can take seconds against a real system. PD can do
   that because its own code runs every candidate.
3. **What each shrinker edits.** PD's shrinker edits the journal of draws,
   so it removes steps and also lowers the values inside the steps that
   remain (DR-069). PropEr's state-machine generators wrap the command
   list in `noshrink` and shrink it with `shrink_list`
   (`proper_statem.erl`, 1.5.0), so a shrink removes commands and leaves
   every argument as first drawn.

### The measurement

Two entries of the corpus were written as a PropCheck state machine:
`lost_full_refund` and `offset_refund`. The system, the seeded bug, the
command weights, the value ranges and the check are those of
`corpus/next/support/scheme_model.exs`. Each PropEr command list holds
eight commands, as each PD plan holds eight slots, and each run stops
after 200 tests, PD's plan cap for these entries. Seeds are 1 to 100. A
shrink run is one execution of the system after the first failing one; for
PropEr a counter in the system counted them. The smallest plan is the
entry's hand-written one, compared by the entry's own rule.

| entry | engine | found | tests or plans until found, mean | shrink runs, mean | ends on the smallest plan |
|---|---|---|---|---|---|
| `lost_full_refund` | PropEr | 100 of 100 | 2.6 | 17.6 | 0 of 100 |
| `lost_full_refund` | `Engine.Native` | 100 of 100 | 3.1 | 71.5 | 42 of 100 |
| `lost_full_refund` | `Engine.StreamDataSource` | 100 of 100 | 2.8 | 49.6 | 100 of 100 |
| `offset_refund` | PropEr | 98 of 100 | 47.6 | 8.9 | 8 of 100 |
| `offset_refund` | `Engine.Native` | 97 of 100 | 48.7 | 30.1 | 97 of 100 |
| `offset_refund` | `Engine.StreamDataSource` | 93 of 100 | 58.6 | 34.1 | 93 of 100 |

What the table shows:

- **Finding is level.** With the same system, weights, ranges and length,
  PropEr and PD need about the same number of tests to meet each bug.
- **PropEr spends fewer shrink runs because it searches less.** It ends on
  the smallest plan only on the seeds whose first failing list already
  held the smallest values: never for `lost_full_refund`, whose bug needs
  a payment above 100, and on 8 seeds of 100 for `offset_refund`.
- **PD pays more runs and returns the smaller plan.** The 42 of 100 of
  `Engine.Native` on `lost_full_refund` comes from that model's
  hand-written `frequency`, a StreamData value that `Engine.Native` cannot
  fit after an edit (DR-068, amendment); `Engine.StreamDataSource` fits it.

Two limits of PropEr 1.5.0 were also observed. Its `max_shrinks` option
caps successful shrink steps, not executions, so no option bounds the
executions a shrink spends. It takes no seed option; seeding the `rand`
state of the calling process made runs repeat exactly.

The state machine is not in this repository, because the repository takes
no dependency on PropEr or PropCheck, not even for a measurement. PropEr's
own `commands/1`, whose list lengths grow with the test size, was measured
as well: it met `lost_full_refund` after 78.6 tests and found
`offset_refund` on 72 seeds of 100, and it ended on the smallest plan on 0
and 7 seeds. The fixed-length list above is the fairer comparison, since
it gives PropEr PD's plan shape; it was built on PropEr's public
`shrink_list`, so it shrinks as `commands/1` does.

## Decision

1. `PropertyDamage.Next` generates with StreamData and shrinks with its
   own journal shrinker. PD takes no dependency on PropEr or PropCheck.
2. The reasons, in the order they weigh:
   - PD must run every candidate itself to count and cap executions
     against the system. PropEr offers no cap on those executions.
   - PD's shrinker lowers values as well as removing steps. On the two
     entries measured, PD ends on the smallest plan on 42 to 100 seeds
     of 100, and PropEr on 0 and 8.
   - The published license fields differ, as stated above.
3. Finding gives no reason either way: the two libraries are level on it.

## Consequences

- PD carries the cost of its own shrinker: on these entries it spends
  about three to four times PropEr's shrink runs. The cap on shrink runs
  is how a user bounds that cost.
- A user who wants PropEr's vocabulary gets none of it from PD. PD's
  generators are StreamData's, plus the three descriptions of DR-068.
- The comparison covers two entries, one system and one PropEr version.
  A PropEr model written with argument shrinking of its own (for example
  through a custom type per command) was not measured.

## Alternatives considered

- **Build PD's command sequences on PropEr's state machines.** Rejected
  for the three reasons in the decision.
- **Offer PropEr as a further engine behind PD's engine interface.** Not
  taken up: nobody has asked for it, the engine interface is not public,
  and the engine would bring the license field with it.
- **Record the reasons without measuring.** Rejected: the record would
  then say PD shrinks well by its own count only, and say nothing of how
  the existing library does on the same bugs.
