# DR-047: Latency Is a Measurement with a Campaign-End Budget

**Status:** Accepted
**Date:** 2026-10-06

## Context

DR-046 replaced `compare: :performance | :both` with `latency: true`, which
measures each target's latency per command. Three things were left open or
wrong.

- `latency: true` measured, but nothing could fail on a number. A team that
  wants "the new system is no more than 1.5 times slower at p95" had to read a
  table by hand.
- The options around it were half-built. `metrics:` and `percentiles:` were
  accepted but never applied (the four statistics are fixed), and `warmup_runs:`
  sat beside `latency:` instead of under it. `error_count` and `error_rate`
  were always zero, because an adapter error fails the run in every mode.
- A latency number can look like a boundary observation, so the question
  "should a slow answer be a divergence?" needed an explicit answer.

## Decision

1. **Latency is a measurement, never a boundary observation.** There are three
   reasons. Projections do not see timings, so no `@compare` function can
   read one. A per-command number is noise: one slow call proves nothing.
   Judging latency at each boundary would make runs flaky, because a single
   garbage-collection pause would fail a run that is otherwise fine.
2. **The grammar.**

   ```elixir
   latency: false | true | [
     warmup: n,
     p50 | p95 | p99 | mean: [max: duration, max_ratio: ratio]
   ]
   ```

   `false` is the default and measures nothing. `true` measures and sets no
   bound. A keyword list measures and adds `warmup: n` (a non-negative integer,
   default `0`) and a budget: any of `p50`, `p95`, `p99` and `mean`, each a
   keyword list with `max:` and/or `max_ratio:`. Anything else is an option
   error at run start. Duplicate statistic keys and duplicate bound keys are
   option errors. A statistic with no bound (`p95: []`) is an option error.
3. **Warm-up.** The first `n` runs execute but are left out of the metrics.
4. **What is timed.** The wall-clock time of each `Adapter.execute/3` call,
   retries included, as a client sees it. The comparison's re-reads at a
   boundary are not timed. Setup and teardown commands are excluded from the
   samples: the measurement covers the commands of the generated sequence only.
5. **The metrics.** Each target gets `p50`, `p95`, `p99`, `mean`, `min` and
   `max` in microseconds, `commands` (the number of timed commands) and
   `by_command` (`p95` and `commands` per root command module). Percentiles
   use linear interpolation. A target with no timed command has
   `%{error: :no_data}` and is never judged. `stats.metrics` holds them keyed
   by target name.
6. **The budget is judged once, at campaign end.** The check runs on the
   aggregates of all measured runs after the last run passed. It is never
   judged per run and never at a boundary. A failure of another kind in any
   run ends the campaign first; the budget is then not judged, and the report
   carries the metrics measured so far.
7. **`max:` and `max_ratio:`.**
   - `max:` is absolute and applies to every target, the reference included.
   - `max_ratio:` is the target's statistic divided by the reference's
     statistic. It applies to every target but the reference and needs at
     least two targets. With one target it is an option error at run start,
     before any adapter setup.
   - A statistic may carry both bounds.
8. **The duration is a tuple.** `{n, :milliseconds | :seconds | :minutes}`
   with a positive integer `n`. A bare integer is rejected: this repo reads
   one as seconds in adapter timeouts and as milliseconds in poller
   intervals, so a bare number would be read wrongly by someone. The option
   error shows the tuple to write.
9. **The zero-reference rule.** A positive statistic against a zero
   reference breaches a `max_ratio:` bound as infinity. Both zero is no
   breach.
10. **Failure kind `:latency_exceeded`.** A breach is a `%Failure{}` of kind
    `:latency_exceeded` (a `Failure.Latency`). It names the target, the
    statistic, the bound, the measured value, the limit and, for a ratio,
    the reference's value. When several bounds are breached the report names
    one primary breach and lists the rest in `other_failures`. The order is:
    target order, then `p50`, `p95`, `p99`, `mean`, then `max` before
    `max_ratio`. The failure has no root, so `failed_at_index` is `nil`.
11. **Never shrunk, never re-executed, no replay artifact.** The finding is
    statistical, so no shorter sequence reproduces it. It reproduces by
    running the seed again. `on_failure` is still called once, with the
    report.
12. **`concurrency: :serial` is required.** Under `:parallel` the targets
    execute at the same time and their load would mix into each other's
    samples. The combination is an option error.
13. **Deleted options and keys.**

    | Removed | Why | Replacement |
    |---------|-----|-------------|
    | `metrics:` | accepted, never applied | none: the metrics are fixed |
    | `percentiles:` | accepted, never applied | none: `p50`, `p95`, `p99` are fixed |
    | `warmup_runs:` | belongs to the measurement | `latency: [warmup: n]` |
    | `error_count`, `error_rate` | always zero: an adapter error fails the run in every mode | none |
    | the `latency_` key prefix (`latency_p95`) | the metrics already sit under `latency:` | `p95` |
    | `total_commands` in a target's metrics | a per-target count is `commands`; the run's `stats` still hold `total_commands` | `commands` |
14. **Persistence format version 12.** A report carries `latency` (the option
    as given, `false` when off) and `metrics` (per target name, `nil` when
    `latency:` is off). Loaders refuse version 11 and older.

## Consequences

- A team can state a latency requirement in the run options and get a failing
  run with the numbers, one finding per breach.
- A latency finding cannot be shrunk or replayed from an artifact. It is
  evidence about the whole campaign, so the way to confirm it is to run the
  seed again.
- A model's correctness checks and `@compare` observations are unchanged: a
  slow system still passes them.
- This is a clean break with no shim. Code that passed `metrics:`,
  `percentiles:` or `warmup_runs:`, or that read `latency_p95`,
  `error_count` or `error_rate`, must change. The CHANGELOG lists each
  removed name with its replacement.
- Persisted version 11 reports and traces are refused.

## Alternatives considered

- **Judge latency per boundary as a `@compare` observation.** Rejected for
  the three reasons in item 1.
- **Judge each run and fail on the first slow one.** Rejected: one run is a
  small sample, and a campaign of fifty runs would fail on its noisiest.
- **Shrink a latency failure.** Rejected: a shorter sequence has fewer
  samples and a different distribution, so "the same failure" has no meaning.
- **Accept a bare integer for `max:`.** Rejected (item 8).
