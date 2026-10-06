# DR-048: Setup and Teardown Commands, Fixtures as Commands

**Status:** Accepted. Amended by DR-049: setup and teardown commands are never expanded (stated here), and a sequence in `expansions/0` follows the same grammar and the same "ignored in a sequence" rule.
**Date:** 2026-10-06

## Context

A model had four side-effect lifecycle hooks: `setup_once/1`, `setup_each/1`,
`teardown_each/1` and `teardown_once/1`. They had three problems.

- **They received one target's config.** Every hook got the first target's
  `config:`, so a fixture that each target realizes its own way could not be
  written. An authenticated session is the example: OAuth for one target,
  Basic auth for another, an HTML form for a third. Only the adapter knows
  how, and only a command reaches the adapter.
- **Nothing a hook created reached the commands.** A user id the hook
  obtained could not flow into a generator, an `overrides:` function or a
  later command.
- **They were not part of the run's record.** A hook's effects were absent
  from the events, the projections, the report and the replay.

DR-042 named the answer ("lifecycle as commands") and left the design open.
This record settles it.

## Decision

1. **Fixtures are commands.** The model declares `setup_each/0` and
   `teardown_each/0`, both optional with the default `[]`. Each returns
   command specs in the grammar of `commands/0` (`Module` or
   `{Module, opts}`, with `overrides:`) and is typed
   `PropertyDamage.Model.sequence`. The model performs no side effect.
   - Setup commands run before every run and every shrink attempt, in every
     target, after the target's `Adapter.setup/1` and before the first root.
   - Teardown commands run after the roots.

   A root is a command the generator drew from `commands/0`.

2. **A setup list is a sequence, not a pick list.** Entries run in the order
   written, every one, with no `when:` filter and no weighted draw. A
   `when:` or `weight:` on an entry draws a validation warning ("ignored in a
   sequence"). `terminate_early?/3` and `max_commands` apply to roots only.
   The same holds for the teardown list.

3. **Generation.**
   - The generator draws setup commands from the run seed before the roots.
     An `overrides:` function sees the simulated state so far.
   - It simulates them before the roots, so the roots' `when:` and
     `overrides:` see the fixture state, and a server-assigned id
     (`external()`) flows into later commands.
   - Seed stability: adding a setup command re-draws the roots for a given
     seed, so a seed is stable for a fixed model. A model without setup
     commands draws exactly what it drew before.
   - The generator draws teardown commands against the simulated state after
     the last root, so their `overrides:` can reference anything the run
     created. Every shrink attempt re-draws them against that attempt's
     roots.

4. **Setup commands are not roots.**
   - They are never compared. The end of the setup commands is no boundary,
     and a `@compare every: Module` that names a setup command's module does
     not fire on it.
   - They are never expanded, and the shrinker never drops, reorders or
     simplifies them.
   - A module may appear in both `setup_each/0` and `commands/0`. Each
     instance follows its own rules.

5. **Engine rules during setup commands.**
   - These stay on: placeholder resolution (into that target's registry),
     folding events into that target's projections, pollers, injectors, the
     per-command settle and adapter retry, and checks (`@check`,
     `@eventually`).
   - `every: N` sampling counters start at the first root. Setup commands
     never advance them. Events an injector delivers while the setup
     commands run are not setup commands and do count.
   - Stutter is off and nemesis faults are off, because they would test the
     fixture, not the property. Because faults are off, a nemesis module
     listed in either callback is a validation error.
   - No latency sample is recorded.
   - Coverage reports setup commands under a `setup` key.

6. **Completion rule.** When a target's last setup command has stepped,
   drained and settled, every `external()` the setup commands produced must
   be resolved in that target. An unresolved one is a setup failure that
   names the command, the field and the target. This also covers a command
   whose adapter answered with a different event than the simulator
   predicted, because the predicted event never arrives.

7. **Setup failure (`:setup_failed`).** Its causes are:
   - the adapter's `setup/1` returning `{:error, _}` or raising;
   - a setup command answering `{:error, _}` or raising;
   - a check failing on a setup command's event;
   - the completion rule.

   `%PropertyDamage.Failure.Setup{}` carries `cause`, `command`,
   `setup_index`, `field` and `detail`. The report's `failed_at_index` is
   `nil`.

   A check failure whose triggering event belongs to a setup command is a
   setup failure wherever it is detected. The case to name is an
   `@eventually` window that a setup command's event opened and that times
   out after the roots started. It is the one place a setup failure is
   detected after the first root.

   Which targets go on:
   - A setup failure in the first target (the reference) ends the run before
     any root.
   - A setup failure in another target, detected before the first root,
     retires only that target. Its pollers stop, its `:teardown` checks run,
     its teardown commands run, and its adapter's `teardown/1` runs, all
     before any target starts the first root.
   - The one setup failure detected after the first root (the eventual
     window above) ends the run with that report, every target torn down,
     as a check failure after the first root does. Whether that late case
     should retire only its target is open, together with the scope of the
     retire rule for check failures.
   - The other targets go on. The run ends when no target other than the
     reference is left.
   - Setup failures are never shrunk.
   - During shrinking, an attempt in which a setup failed is not a
     reproduction. The shrinker rejects the candidate, and the attempt
     counts against the budget.

8. **Teardown commands.**
   - Order per target per run:
     1. `Adapter.setup/1`;
     2. the `:startup` checks;
     3. setup commands;
     4. the roots;
     5. the final boundary;
     6. `@check at: :teardown`;
     7. teardown commands;
     8. `Adapter.teardown/1`.
   - Teardown commands run after every execution: pass or fail, after a
     setup failure (with whatever the setup commands created), after a target
     is retired, and after every shrink attempt. They do not run for a target
     whose `Adapter.setup/1` failed, because it has no adapter context, or
     whose process was killed.
   - Engine rules: stutter, nemesis and checks are off. Placeholder
     resolution is on. Events go to the event log only and are not folded
     into projections. No latency sample is recorded.
   - Teardown is best effort. A teardown command whose placeholder never
     resolved is skipped with a warning, and an error or a raise is logged.
     Neither changes the verdict.
   - They earn their place on shared or non-resettable targets, where
     `Adapter.setup/1` cannot wipe and `Adapter.teardown/1` does not know the
     run's ids.

9. **Infrastructure reset stays in `Adapter.setup/1`.** It runs before every
   run, shrink attempt and replay, for every target, so it must be
   idempotent. The runner serializes it across targets and completes it for
   all of them before any target executes a command.

10. **Isolation is the target's `config:`.** This is documentation, not a
    feature. When targets share one system, each target's `config:` scopes
    its slice (a tenant, an account, a path prefix), because the generated
    values, fixtures included, are shared across targets. `mix pd.validate`
    already warns when two targets use the same adapter with identical
    `config:`; this record adds no new warning.

11. **Why there is no `setup_once/0`.** A fixture that runs once per campaign
    would conflict with the per-run reset in `Adapter.setup/1`, which would
    wipe what the fixture created. Its recorded events and placeholder
    values would also have to be folded into every run's initial state and
    replayed. The design is deferred until a real model has a fixture too
    slow to run per run. Until then, an idempotent `Adapter.setup/1` or the
    caller's own wrapper around `PropertyDamage.run/1` covers
    once-per-campaign infrastructure.

12. **Removed.**
    - `setup_once/1`, `setup_each/1`, `teardown_each/1`, `teardown_once/1`
      and the `lifecycle_config` type. A model that defines any of them, or
      `setup_once/0` or `teardown_once/0`, fails at run start with an error
      that names the replacement.
    - The `%{setup_once_failed: _}` and `%{setup_each_failed: _}` error
      maps. The `:setup_failed` report replaces them.
    - Persistence is version 11. Loaders refuse older files.

13. **Report and replay.**
    - `FailureReport.setup_commands` and `teardown_commands` hold the
      reported sequence's commands, so a report is reproducible without
      re-drawing.
    - `stats` and the report count setup and teardown commands separately
      from `total_commands`, which counts roots.
    - `PropertyDamage.replay/2` and `Analysis.isolate_trigger/2` execute the
      report's setup commands before the sequence and its teardown commands
      after it. `RunTrace.capture/1` draws them from its seed, as a run does.
      All three stay single-target.
    - A branching run (single target) executes the setup commands before its
      own prefix segment and the teardown commands after its suffix segment.
    - Exported scripts emit the setup steps first.
    - Telemetry command events carry `phase: :setup | :root | :teardown`.

## Consequences

- A fixture reaches the adapter, so each target realizes it its own way. The
  `Login` command is one model command. An OAuth adapter fetches a token and
  keeps it in its context. A Basic-auth adapter's `execute/3` for `Login` does
  nothing.
- A fixture's events and ids are part of the run: they fold into projections,
  resolve into the placeholder registry and appear in the report, the replay
  and exported scripts.
- A setup failure is a distinct, unshrunk failure kind with its own report
  shape, so a broken fixture is never mistaken for a property failure.
- Adding or removing a setup command changes which roots a seed draws.
- The model has no hook for once-per-campaign work.

## Alternatives considered

- **Keep side-effect hooks.** Rejected: a hook cannot reach the adapter, and
  nothing it creates reaches later commands.
- **Derive fixture values per target.** Rejected: it hides a coupling in the
  shared plan, and it is easy to misuse.

## Open questions

- `setup_once/0` and `teardown_once/0` are deferred (decision 11).
