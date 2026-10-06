# DR-045: One Runner for One or More Targets

**Status:** Accepted. Amended by DR-046: `Failure.Divergence` holds the `@compare` key, the two values and the mismatch instead of `reference_result` and `divergent_result`; `:execution_failed` is final, and `:did_not_converge` is now produced; `equivalence:` and `compare: :correctness | :performance | :both` are removed; persistence is version 10. Amended by DR-047: `metrics:`, `percentiles:` and `warmup_runs:` are removed (see the note under item 2) and `:latency_exceeded` is produced. Under `check_mode: :record`, a check failure at an earlier root, or at the same root in the same or an earlier target, is the primary failure and the divergence is listed in `other_failures`; it no longer replaces the divergence. Amended by DR-048: `setup_once/1`, `setup_each/1` and their teardowns are removed in favor of setup and teardown commands, `:setup_failed` carries a `Failure.Setup` with a cause, and persistence is version 11.
**Date:** 2026-10-06

## Context

DR-042 decided that a run is a root sequence executed by one or more
variants. DR-044 built the variant and the lockstep scheduler, but
`PropertyDamage.Differential.run/1` stayed as a second entry point on top
of them, and `PropertyDamage.run/1` kept its own loop for linear sequences.
Two entry points meant two result types (`Differential.Result` and the
failure report), two failure vocabularies, and two answers to the same
questions: does a divergence end the run, is it shrunk, and what does a
reader get back.

A divergence was only listed. Nothing shrank it or reproduced it, so a
reader of a differential run got a command sequence that could be long and
a note that two targets disagreed.

## Decision

1. **One entry point.** `PropertyDamage.run/1` takes one or more `targets:`.
   The first target is the reference. Its loop runs every linear sequence
   through `PropertyDamage.Scheduler`, one target exactly as several.
   `PropertyDamage.Differential` and `Differential.run/1` are deleted, not
   aliased. `Differential.Equivalence` is now `PropertyDamage.Comparison`
   (`equivalent?/3`, `normalize/1`, `ignore_fields/1`, `only_fields/1`).
   `Differential.Result` is gone: the failure report is the result.
2. **The run options.** `concurrency: :serial | :parallel` (default
   `:serial`), `compare: :correctness | :performance | :both` (default
   `:correctness`), `equivalence: :exact | :structural | fun` (default
   `:exact`), `metrics:`, `percentiles:` and `warmup_runs:` (default 0) are
   options of `run/1`. `execution:` is an option error that names
   `concurrency:`. `compare: :performance | :both` with
   `concurrency: :parallel` is an option error.
   *Amended by DR-047: `metrics:` and `percentiles:` were never applied and
   are removed, and `warmup_runs:` is `latency: [warmup: n]`.*
3. **The failure kinds.** The report's `kind` is one of:
   - `:check_failed`: a check failed in a variant. This includes
     `@eventually` timeouts and startup and finalization checks.
   - `:diverged`: a variant's observation of a root differs from the
     reference's under `equivalence:`.
   - `:setup_failed`: a variant's adapter setup returned an error or raised.
     An injector or mock setup that raised inside a target is also a setup
     failure.
   - `:execution_failed`: see item 4.

   `:did_not_converge` and `:latency_exceeded` are named in the type and
   documented for the features that will produce them. No run produces them
   yet.
   *Amended by DR-047: `:latency_exceeded` is now produced, when a
   `latency:` budget is breached at campaign end.*
4. **`:execution_failed` is provisional.** It covers an adapter raise at a
   root in any run, an adapter error answer in a one-target run, and the
   nemesis, stutter, placeholder and unknown failures. With two or more
   targets an adapter error answer is an observation, compared like any
   other, as DR-044 item 7 says. Whether an agreed adapter error is a
   comparable observation in every run, one-target runs included, is not
   decided.
5. **Every failure names the variant and the root.** The report carries
   `variant: %{index, name}` and `failed_at_index`, the failing root. The
   index is nil for a setup failure and a startup failure, which belong to
   no root.
6. **A divergence is a failure.** It ends the run, is shrunk and reproduced,
   and `run/1` returns `{:error, report}` with `kind: :diverged`. There is
   no list of divergences and no run after a divergence. `{:ok, stats}`
   means no run failed in any kind. Under `check_mode: :record`, a recorded
   check failure at or before the divergence root is reported instead of the
   divergence.
7. **The report.** `FailureReport` gains `kind`, `variant`, `targets` (the
   run's entries as `Target.to_entry/1` gives them, so
   `reproduction_command/1` prints the exact target list, including
   non-default `name:` and `config:`) and `concurrency` (a non-default value
   is printed too). It also records the run's `equivalence` (an atom, or the
   function as given), `stutter` (the normalized option, or nil) and
   `max_commands`. `reproduction_command/1` prints `equivalence:` when it is
   not `:exact` (a named function as its capture; any other function as the
   placeholder `<custom function>`, which does not compile until the reader
   replaces it), `stutter:` when it was set and `max_commands:` when it is not
   the default, so the printed command regenerates and judges the same run.
   `shrink_further/2` re-shrinks under the report's `equivalence` and
   `stutter`. `adapter` is removed. `kind_of/1`, `reference_target/1` and
   `targets_source/1` are new. A report's `kind` is always
   `kind_of(failure_reason)`: the scheduler derives every failure's kind from
   its reason with that one mapping, so a resource poller error found while
   the run finalizes is `:execution_failed`, not `:check_failed`.
8. **Shrinking is variant-aware.** The failure identity is
   `{kind, name, variant_index}`, from `Shrinker.failure_signature/2`. A
   candidate that fails in another variant or with another kind is
   rejected. A divergence's name is its root command's module (item 13), so
   a candidate that diverges in the same variant at a command of another type
   is rejected too: without that, dropping the command a diverging
   `CreateLabel` depends on can yield a candidate that diverges at a
   `CreateRepo` for an unrelated reason, and the shrinker would accept it. A
   candidate whose validation raises (the model's projection, simulator or
   `when:` predicate) is invalid and never a counterexample. A candidate is accepted only at the same or an earlier root,
   by truncation at the failing root. Every attempt runs `setup_each/1`,
   then the candidate through the scheduler with every target, each set up
   and torn down for that attempt, with the run's effective seed,
   `run_number: 0` and a fresh mint epoch. The reference's sequence is the
   shrink target; all targets run the same commands. The shrunk sequence is
   reproduced once, and if it does not reproduce, the report falls back to
   the original run. Setup failures are not shrunk. The seed-library replay
   and `shrink_further/2` use the same path; `shrink_further/2` defaults to
   `report.targets` and accepts a `targets:` override with one or more
   entries. Export file names hash the triple.
9. **Persistence version 9.** Failure reports (`.pd`) and traces
   (`.pdtrace`) are version 9. Loaders refuse version 8 and older.
   `export_json/1` writes `kind`, `variant` and `targets` instead of
   `adapter`, and `equivalence` (`custom` for a function), `stutter` and
   `max_commands`.
10. **Telemetry and progress name the variant.** The engine emits
    `[:property_damage, :command, :start | :stop]` and
    `[:property_damage, :check, :start | :stop]` with `variant` and
    `run_number`; shrink attempts and the reproduction use `run_number: 0`.
    `[:property_damage, :sequence, :stop]` gains `variant`, the failing
    target, nil when the run passed. `@eventually` polling emits no check
    events. `Progress.RunResult` gains `kind` and `variant`, and the verbose
    printer prints both. Run telemetry metadata carries
    `targets: [%{index, name, adapter}]` instead of `adapter:`. The
    `:differential` progress operation, `Progress.DifferentialUpdate`,
    `Progress.DifferentialResult` and the
    `[:property_damage, :differential, ...]` events are removed.
11. **One-target features stay one-target.** Branching sequences keep the
    linear engine for their run, shrink and reproduction, and
    `branching:` with two or more targets is an option error.
    `PropertyDamage.replay/2`, `Analysis.isolate_trigger/2` and `RunTrace`
    work on the report's reference target, with its name and config.
12. **Setup failures return as values.** `run/1` returns a `:setup_failed`
    report. `execute/2`, `Replay.start/2` and `shrink_further/2` return
    `{:error, %Failure{type: %Failure.Setup{}}}`, and `mix pd.replay` prints
    it. The `{:error, %{adapter_setup_failed: _}}` map and the
    `{:adapter_setup_failed, reason}` tuples are removed. Setup reports go
    through `on_failure`, the regression handler and the seed-library
    append. `setup_once/1`, `setup_each/1` and their teardowns receive the
    reference target's config.
13. **Two failure types.** `Failure.Divergence` holds `root`, `command`
    (the root command), `name`, `reference_result`, `divergent_result` and
    `results` keyed by target name; its kind is `:diverged`.
    `Failure.diverged/5` takes the root command, and `Failure.name/1` of a
    divergence is the root command's module: the key of the default root
    observation, what the target answered to that command type. A later
    comparison feature that names its own observations will supply that name
    instead. `Failure.Setup` holds
    the error term or exception; its kind is `:setup_failed`.
14. **Engine behavior now shared.** `check_mode:` reaches the engine (before,
    `run/1` accepted it without effect). `teardown_each/1` runs at the end of
    each run (before, every teardown ran after the last run, in reverse).
15. **Scheduler result.** `Scheduler.run/1` has no `divergence` key. Its
    `failure` is `nil` or `%{kind, variant, run, root, reason}`, with
    `reason` always a `%Failure{}`. It takes the new options `mint_epoch:`
    and `placeholder_registry:`. `Progress.Printer.consumer/3` and
    `print_header/3` take the target list instead of an adapter.
    `Shrinker.shrink/2` takes `targets:`, `variant_index:`, `concurrency:`,
    `compare:`, `equivalence:` and `check_mode:` in place of `target:`,
    `event_queue:` and `mock_registry:`. `equivalent_failures?/2` takes
    `{reason, variant_index}` pairs.

## Consequences

- A reader of a divergence gets a shrunk command sequence, the variant and
  root, and a reproduction command, as for any other failure.
- `{:error, report}` is the one failure shape. A caller branches on
  `report.kind`, not on a separate result type.
- Code that matched `Differential.Result`, `adapter_setup_failed` or
  `report.adapter`, or that read a 2-tuple failure signature, must change.
  The CHANGELOG lists each removed name.
- Persisted version 8 reports and traces are refused. Re-run to regenerate
  them.
- A one-target run goes through the scheduler. Its per-run setup and
  teardown now follow the scheduler's rules (DR-044 item 5).
- A target's failing run costs more to shrink with several targets, because
  every attempt sets up and tears down every target.

## Alternatives considered

- **Keep `Differential.run/1` as a thin wrapper.** Rejected: pre-v1 clean
  break. A second name for the same call keeps two vocabularies alive.
- **Keep listing divergences and continue the campaign.** Rejected: an
  unshrunk divergence is the least useful form of the finding, and a
  campaign that continues hides which run to reproduce first.
- **Shrink each target separately.** Rejected: a divergence exists only
  between targets, so a candidate must run in all of them to keep the
  failure.
- **Match shrink candidates on kind and name only.** Rejected: the same
  check can fail in two variants for different reasons; the variant index
  keeps the shrink on the failure that was found.

## Open questions

- Whether an agreed adapter error is a comparable observation in every run
  is not decided, so `:execution_failed` stays provisional (item 4).
- Branching sequences run with one target only. Running them across several
  targets is not decided.
