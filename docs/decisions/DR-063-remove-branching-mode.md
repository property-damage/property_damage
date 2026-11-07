# DR-063: The Branching Mode Is Removed

**Status:** Accepted
**Date:** 2026-11-06

## Context

A sequence could carry parallel sub-sequences: a prefix, two or more
branches and a suffix (the `branching:` run option). DR-053 recorded what the
mode did: `Executor.Branching` ran the branches one after another on one
adapter context, and the `Linearization` checker judged the branch commands
against the simulator's predictions over the interleavings. The branches never
overlapped at the system under test, so the mode detected no race.

The mode cost a second run driver with its own state merge and the
`Linearization` checker. Five sites chose between the linear and the branching
path (`run/1`, reproduce, the shrinker, `RunTrace.Capture.capture/1` and `Analysis`),
and the generator, shrinker, trace, positions, failure vocabulary and event log
each carried branch cases. The mode could not use settle, `@compare` or
latency, so `Options` refused it beside `latency:`, a `check_mode:` other than
`:halt`, several targets and a model with `expansions/0`.

## Decision

1. The `branching:` run option, `PropertyDamage.Executor.Branching`,
   `PropertyDamage.Linearization` and the `:linearization` failure kind are
   removed. Every sequence is linear.
2. `Sequence` loses its branch fields and functions, including the `suffix`
   field: no linear path wrote it. `Sequence.Position` loses its `{:branch, _}`
   and `:suffix` sections. `Failure`, `EventLog.Entry` and the JSON export
   entries lose `branch_id`. The sequence start and stop telemetry metadata
   lose the `branching` and `branch_count` keys.
3. `run/1`, reproduce, the shrinker, `RunTrace.Capture.capture/1` and `Analysis` call
   the one linear path. The shrinker loses its branch strategies.
4. The refusals that existed only because `branching:` selected another
   engine are removed: its conflicts with `latency:`, with a `check_mode:`
   other than `:halt`, with several targets, with `only:` and with a model that
   defines `expansions/0`, and the check of `min_prefix_length:` against
   `max_commands:`. A caller that passes `branching:` gets the unknown-option
   error from `NimbleOptions`.
5. `mix pd.audit`, `mix pd.replay` and `PropertyDamage.IEx` lose their
   branching flags. The parallel testing guide, its `extras` entry, the
   branching passages of the other guides and specs, and the Redis bench's
   linearization test are removed. The concurrency spec keeps only the
   stutter requirements, which stay true of the linear engine.
6. The persistence format becomes version `18`. A file of version `1` to `17`
   is refused with `{:unsupported_format_version, version, 18}`, because the
   removed `Sequence` fields and `branch_id` no longer decode. The JSON export
   becomes version `2.0`. The replay artifact keeps its format: it records
   commands, and a command is unchanged.

## Alternatives

- **Build the concurrent mode first on `Scheduler` and `Variant`, then remove
  the old one.** Rejected: the old mode keeps its second driver and its
  refusals for as long as the redesign takes, and the redesign is not
  scheduled. DR-053 already records that the old mode proves nothing about
  races.
- **Keep the mode and document its limits.** Rejected: DR-053 did exactly
  that, and the cost stayed: five dispatch sites and branch cases in every
  subsystem.

## Consequences

- A future concurrent mode is built on `Scheduler` and `Variant`. It inherits
  settle, `@compare` and latency, so it needs none of the refusals this record
  removes.
- Users lose `branching:` and the `:linearization` failure kind. A user who
  needs a lost-update check writes it as an adapter that reports what the SUT
  returned, and checks it in a projection.
- Saved `.pd` and `.pdtrace` files of version 17 and earlier no longer load.
  The user captures the failure again.
- DR-053 is superseded. DR-044 and DR-045 carry a dated note.
