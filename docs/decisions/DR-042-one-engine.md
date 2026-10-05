# DR-042: One Engine for Property-Based, Differential and Path-Equivalence Runs

**Status:** Accepted. Amended by DR-044: `Differential.run/1` stays as the multi-target entry point on top of the variant scheduler; `PropertyDamage.run/1` keeps its own loop for now.
**Date:** 2026-10-05

## Decision

1. **One runner.** `PropertyDamage.run/1` is the only entry point. A run has
   one generated root sequence and one or more variants; each variant is a
   target (adapter, options, injectors, mock services) running a concrete
   sequence through the per-command engine (`Executor.Stepping`), in its
   own process, with its own projections, event log and pollers.
   `PropertyDamage.Differential.run/1` and its separate loop are removed.
2. **Every root is a comparison boundary.** The model's `commands/0` lists
   root commands. After each root has run in every variant, the comparison
   evaluates the projections' `@compare` functions and compares each
   variant with the reference (the first target). There are no converge
   points and no per-root skip: a side that is not yet comparable waits up
   to `settle:` at every scheduled boundary.
3. **Expansion is a model property.** A root may declare equivalent
   command sequences through `expansions/0`; each target chooses how to
   expand (`expansion: :random | :identity | :reference`). The mode of a run
   (property-based, differential, path equivalence) is inferred from the
   variants and is never an option.
4. **One comparison vocabulary.** A comparison strategy is a 2-arity
   predicate under `using:`; a mismatch is an exception struct. The
   Stutter and Differential atom and field-list forms are removed.
5. **Lifecycle as commands.** `setup_each/0` and `teardown_each/0` return
   command prefixes and suffixes that run through the same engine;
   infrastructure setup stays in `Adapter.setup/1`, which must be
   idempotent.
6. **Pre-v1 clean break.** No option, callback or module is kept for
   compatibility; an old key is an option-validation error naming its
   replacement.

## Rationale

Two engines (`PropertyDamage.run/1` and `Differential.run/1`) duplicated
generation, execution and reporting, and every feature added to one was
missing from the other: differential runs had no checks, pollers,
injectors, mocks, stutter or shrinking. Comparing raw command events could
not express agreement between variants that ran different concrete commands
for the same intent, nor see events that arrive after a command ends. Making
every root a boundary removes converge markers and the lossy "skip and
count" alternative; waiting at every boundary makes the comparison complete
by construction.

## Alternatives considered

- **Keep two engines and port features across.** Rejected: every feature
  would be implemented twice, and the two had already drifted.
- **Converge points declared by the model (`at:`, converge commands).**
  Rejected: by the grammar's own rule every expansion means the same thing
  once its root is done, so every root is a boundary, and the markers were
  redundant.
- **Skip a boundary whose side is pending and compare later.** Rejected: a
  skipped verification is a verification the framework did not run;
  waiting bounded by `settle:` is explicit and complete.
- **Abstract commands for intents with several realizations.** Rejected: a
  root is a concrete command that may have expansions; an intent with no
  single call is a coarse concrete command.
- **A compatibility layer for the old options.** Rejected: pre-v1 with no
  external callers; shims would freeze the old vocabulary into the new
  engine.

## Consequences

- The Model keeps `commands/0`, `command_sequence_projection/0`,
  `simulator/0`, `check_projections/0`, `terminate_early?/3`, and gains
  `expansions/0`, `setup_each/0`, `teardown_each/0`.
- Projections gain `@compare`; `@trigger` is `@check` and `@poll_state` is
  `@eventually`.
- `targets:` is the only place a target is described.
- The shrinker gains the expansion axis; failures name the variant.
- Baseline (recorded-run) comparison is removed; it can return designed
  against the replay artifact format.
- The vocabulary renames land first, before any engine change: the
  "assertion" identifiers become "check" (`check_projections/0`,
  `check_mode:`, `PropertyDamage.CheckFailed`, `%Failure.Check{}`,
  `check_coverage/2`, `check_catalog/1`), the command-spec option `with:`
  becomes `overrides:`, and the persisted format moves to version 8.
