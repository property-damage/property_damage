# DR-049: Expansions, Roots That Run as Several Commands

**Status:** Accepted
**Date:** 2026-10-07

## Context

DR-042 to DR-046 made one runner execute one or more targets over one
generated command sequence and compare them at every root through `@compare`
observations. Every target still ran the same commands. That covers
differential testing (the same commands on two systems) and nothing else.

A third kind of test needs targets that run different commands. A payment
service may offer `pay 100` and also `authorize 100` then `capture 100`. A
counter may offer `incr k 5` and also `incr k 3` then `incr k 2`. If the model
says the two forms mean the same once they are done, running one form in one
target and the other form in a second target (or the same system twice) is a
path-equivalence test: a divergence is a bug in a path.

Four questions follow.

- How does a model say that two command sequences mean the same?
- How does a target choose between them, so that a run is reproducible?
- What does a run count, report and shrink when a root is several commands?
- What do the existing checks, coverage and latency mean for the extra
  commands?

## Decision

1. **The contract.** An expansion of a root is a command sequence that means
   the same as the root once the root is done, under every `@compare` value of
   the model. A rewrite that cannot meet that under the model's observations
   is not an expansion of that model. The author either stops observing the
   field that differs, or leaves the rewrite out. The contract is absolute:
   the framework has no per-observation exception list, because a list of
   exceptions would turn "means the same" into "means the same except where it
   does not".

2. **Vocabulary.**
   - A **root command** is a module that `commands/0` lists.
   - A **root** is one occurrence of a root command in the generated sequence.
   - An **expansion** of a root is one command sequence the model lists for
     it. The root run as itself is the **identity**.
   - A **leaf** is a command a target executes for an expanded root.
   - A target's **entry** at a root is the expansion it chose, named
     `Root[i]` after the entry's index in the list the model returned.

3. **`expansions/0` and its grammar.** The model gains the optional callback
   `expansions/0`, returning `[{Root, fun}]` with one pair per root that has
   expansions.
   - `fun` takes the root as generated and the target's simulated state at
     that root, and returns a plain list of entries. An entry is a sequence or
     `{sequence, weight: n}` with `n` a positive integer, default 1.
   - A sequence is a list of command specs in the grammar `commands/0`,
     `setup_each/0` and `teardown_each/0` share: `Module | {Module, opts}`,
     with `overrides:` a map, a function of the state, or (inside a sequence
     only) a function of the state and the earlier leaves.
   - The identity is listed like any entry, as the received root struct alone:
     `[root]` or `{[root], weight: n}`. The struct may appear nowhere else in
     a sequence, and no other struct may stand for it. Nothing is chosen that
     is not listed, with one exception (decision 7).
   - A root absent from the list runs as itself. A module listed twice is a
     load error.
   - The list order is the shrink preference, simplest first, with the identity
     first by convention. The order of `commands/0` carries no meaning because
     roots shrink by deletion.
   - Types: `command_spec`, `sequence`, `identity` and `choices(item)` on
     `PropertyDamage.Model`. A command spec is `module | {module, opts}`.
     `commands/0` returns `choices(command_spec)`.

4. **The `expansion:` target option.** A target entry gains
   `expansion: :random | :identity | :reference`, default `:random` on every
   target, validated with the other target keys.

   | Value | Meaning |
   |-------|---------|
   | `:random` | pick an entry per root by weight, from a seed keyed on the run seed, this target's name and the root |
   | `:identity` | run the roots themselves, whatever the others run |
   | `:reference` | run what the first target ran, leaf for leaf |

   - The first target is the reference. `:reference` on it, or on the sole
     target of a one-target run, is an option error.
   - Any mix across the other targets is legal.
   - A model without `expansions/0` yields the same sequence for every value,
     so the option is accepted and inert.

   What each configuration tests:
   - Every other target on `:reference` is a differential run: every target
     executes the same concrete sequence, so a divergence is in the
     implementation.
   - A `:random` target (or `:identity` beside a `:random` reference) is a
     path-equivalence run: a divergence is in a path, or in the implementation
     when the targets also differ.
   - A `:random` reference with one `:reference` and one `:random` target is
     triangulation: the first two share a path and differ in implementation,
     the last two share an implementation and differ in path, so a failure that
     shows against only one of them points at the axis that differs.

   A differential run is therefore a path-equivalence run whose non-reference
   targets copy the reference.

5. **The pick is keyed on the target's name.**
   - The pick seed is `{run_seed, target name, root id}`. The framework hashes
     the term with SHA-256 and seeds the pick from the first 64 bits, so the
     pick is the same in any process on any machine.
   - The run seed of run 0 is the campaign seed. A failure report's `seed` is
     the seed of its own run, so `seed: report.seed, max_runs: 1` picks the
     same entries again.
   - Reordering `targets:` changes which target is the reference and so what a
     `:reference` target copies, and changes nothing else: every named
     `:random` target keeps its sequence.
   - Renaming a target picks again. The name is a generation input, as a seed
     is for a fixed model. Two targets with the same name are the existing
     duplicate-name error, so two `:random` targets never share a sequence by
     accident.
   - Every target generates its concrete sequence before any target is set up,
     by walking the roots in order against its own simulated state, as the
     generator walks them for the shared sequence.

6. **Root placeholders and the arity-2 `overrides:`.**
   - A leaf's `overrides:` function of arity 2 receives `(state, prior_leaves)`:
     the earlier leaves of the same sequence as
     `%{command: leaf, events: simulated events}`, with `external()` fields as
     placeholders. A value taken from a sibling is the sibling's placeholder,
     resolved from real events at execution like any placeholder (DR-021).
     Arity 2 in `commands/0`, `setup_each/0` or `teardown_each/0` is a load
     error that names the command and says the form is legal only inside an
     expansion sequence.
   - Later roots consume the placeholders the earlier roots' simulation
     minted. In a target whose entry at a root is not the identity, each
     placeholder the root's simulation minted is aliased, in that target's
     registry, to the placeholder of exactly one leaf whose simulated events
     hold the same event module at the same field path. Zero matches or
     several matches (several leaves, or several events of one leaf) are a
     generation error that names the root, the entry, the field and the
     candidates, raised before any `Adapter.setup/1`. The rule gives the
     author no syntax to learn: where it fails, it fails loudly, and the fix
     is usually to make the leaves' events agree with the root's.
   - All leaves of root `i` run before the first leaf of root `i + 1`, so an
     aliased leaf has always run before any consumer of its value.

7. **The fallback: "identity, forced".** A leaf whose module has a
   `commands/0` entry with a `when:` that is false at the leaf's position
   withdraws its entry, and the pick is made again among the rest with the same
   pick state. When no entry remains, or the function returns `[]`, the root
   runs as itself: the root's own `when:` held when it was generated, so this
   is valid. The run counts the root as `:forced` for that target. A root that
   is forced in every sampled state shows up in `mix pd.validate --seeds`.

8. **The inventory comes from generation.**
   - The commands a run can execute are `commands/0`, the leaf modules the
     expansions produced, and the setup and teardown modules.
   - Coverage starts from `commands/0` and adds each leaf module when a run
     produces it, so an executed command is never unknown. It counts each
     expanded root module by entry (`Root[i]` and `:forced`) apart from the
     executed modules.
   - A leaf module is validated the first time a process realizes it
     (`validate_command_callbacks!/1`), cached per module per process, and the
     cache keeps only passes. A failure names the root, the entry, the leaf and
     the missing callback. The `overrides:` key check runs at every
     realization, because it depends on the entry and not on the module. The
     event `[:property_damage, :expansion, :leaf_validated]` reports each
     validation.
   - `Validation` checks the shape of `expansions/0` statically (a function of
     the wrong arity, a key that is not a root, a duplicate key). It cannot see
     inside a function, so a sequence's `when:` and `weight:` (both ignored in
     a sequence) and a leaf's bad `overrides:` key surface through
     `mix pd.validate --seeds` and at the first realization.
   - `mix pd.validate` gains `--seeds N` (default 100) and `--seed S`. It
     generates N root sequences (seeds `S`, `S + 1`, and so on, or N fresh
     seeds it prints), realizes every target's expansions on each, and
     reports the leaf modules realized, every entry key with its count, the
     entries never realized ("`Incr[1]` not realized in 100 seeds") and the
     roots forced in every sampled state. The counts sum over the targets
     that pick (`:random`); a `:reference` copy is not counted twice, and the
     task says so, and says when no target picks. `--seed S --seeds 1` samples
     exactly what `seed: S, max_runs: 1` runs.
   - The consumers that read `commands/0` as the full inventory fall into two
     groups. Coverage and the orphan-event and downstream-observable warnings
     in `pd.validate` consider leaves. `Sequence.Validator`, `Mutation.Runner`,
     `Suggestions.Analyzer` and the IEx hints read the root list on purpose
     (a shrink candidate is a list of roots, a mutant targets a root, leaf
     events are not analyzed) and say so in their docs.

9. **Load rules.** At run start, before any `Adapter.setup/1`:
   - A model that defines `expansions/0` must declare at least one `@compare`
     whose schedule reaches the final boundary (`every: 1`, the default, or a
     schedule that names `:end`). One target is no exception: a one-target
     path-equivalence run is legal and needs the observation. Without it,
     targets that ran different commands have nothing to compare.
   - A module listed in `expansions/0` that is not in `commands/0` is an error
     naming the module. A setup or teardown command is not a root, and
     expansion is one level deep, so the entry would be dead.
   - A root with `execution: :probe` in `expansions/0` is an error: a probe is
     re-read inside the convergence loop by re-executing the root, and a
     subtree cannot be re-read.
   - `branching:` together with `expansions/0` is an option error naming both.
   - A positive integer `n` in `{Module, n}` anywhere a command spec is
     accepted is an error that says to write `{Module, weight: n}`
     (decision 13).

10. **Accounting.** Leaves are ordinary executed commands.
    - A `@check every: Module` fires on a leaf of that module.
    - A `@check every: N` counts steps per target, leaves included, so the
      count differs between targets that ran different leaves.
    - A `@compare` schedule, `max_commands` and `total_commands` count roots.
    - Coverage counts leaves under their own module.
    - Latency samples are per leaf, `by_command` is keyed by the leaf module,
      and setup and teardown commands stay out of the samples.
    - Stutter, nemesis, per-command settle and adapter retry apply per leaf as
      they apply per command.
    - `terminate_early?/3` is consulted after roots and never after a leaf.
    - Setup and teardown commands are never expanded (DR-048).
    - The scheduler's boundaries, the convergence loop, the probe re-read and
      the active-set rule are per root and unchanged: a target steps every
      leaf of root `r` before the comparison at `r`.
    - A leaf has a position of its own, `{:leaf, root_id}` with the leaf's
      offset, so placeholder ids never collide with a root's, a setup
      command's or a branch segment's.
    - Telemetry `[:property_damage, :command, :start | :stop]` metadata gains
      `root_index` and `leaf_index` (`nil` for setup and teardown commands;
      `leaf_index` is `nil` for a root that runs as itself).

11. **Shrinking keeps DR-017 at the root level.**
    - The shrinker deletes roots and simplifies root arguments. It never
      deletes, reorders or simplifies a leaf on its own.
    - A failing run carries, per target name, the choice at every root: the
      entry, the leaf sequence, the aliases and the leaf pick seed. Roots carry
      a stable id, their index at generation.
    - A candidate realizes each surviving root's carried entry again, against
      the candidate's simulated state, with the same leaf seed and no new pick.
      `overrides:` of arity 1 and 2 are evaluated again and the aliases are
      rebuilt. A simplified root goes through the same entry and seed. A
      `:reference` target copies the reference's candidate sequence.
    - A candidate whose leaf precondition fails runs that root as itself in
      that target ("identity, forced").
    - A candidate is invalid, and never runs, when the function raises (the
      framework reports any exception from an expansion function as a
      generation error naming the root) or no longer returns the carried entry
      for the simplified root. A vanished entry is not "identity, forced": the
      fallback is reserved for a failing leaf precondition, and silently
      switching a target from a rewrite to the root would let argument
      shrinking change which path failed.
    - The failure identity stays `{kind, name, variant_index}` with the root
      index as the index.
    - The shrinker does not yet substitute one expansion for another. Replacing
      the entry a target ran at a root (collapsing the reference toward the
      identity, then each `:random` target toward the reference's choice) is
      the next step. The contract of decision 1 is what makes that move legal.

12. **Report, persistence and re-execution paths.**
    - `FailureReport.expansions` maps each target name to one element per
      executed root, up to the failing root:
      `%{root: index, entry: "Root[i]" | nil | :forced, leaves: [modules]}`.
      The reporter prints, beside a failure at root `r`, the entry each target
      ran at `r`, with the reference marked. `failed_at_index` stays the root
      index, and the failing leaf is named by its index within the root.
    - `FailureReport.expansion_counts` and `stats.expansion_counts` count, per
      target and root module, how often each entry was realized and how often
      a root was forced. A failure report's counts stop at the failing root, so
      the counts and the `expansions` field describe the same executed roots.
      An `:identity` target counts nothing; a `:reference` target counts the
      entries it copied.
    - Persistence is version 13. Loaders refuse version 12 and older.
    - Paths that run a failure again carry each target's choices:
      the shrinker, `shrink_further/2`, `Replay`, the seed-library replay
      (which recomputes from the seed) and export. `RunTrace.capture/1`
      recomputes from the seed and records the choices. `shrink_further/2` and
      `Replay` raise when a target's choices are not recorded.
      `Analysis.isolate_trigger/2` raises for a target that ran leaves,
      because it varies one command and re-runs through the single-target
      executor, which runs roots as themselves.
    - Export emits the reference target's concrete leaves as the steps, with a
      header line saying so, and binds a root placeholder from the step of the
      leaf it was aliased to. The exported ExUnit test and
      `reproduction_command/1` are unchanged: the seed and the target names
      pick the same entries.

13. **The weight shorthand is retired.** `{Module, 3}` as a command spec is
    gone. Write `{Module, weight: 3}`. The error names `weight:` and the
    module, in `commands/0` and in every sequence, and `Validation.validate!/3`,
    `pd.validate` and `run/1` raise it before any `Adapter.setup/1`. The
    shorthand meant a second spelling for one option, and a sequence has no
    weight, so a bare integer there reads as a mistake.

14. **Why a root is never a non-executed placeholder.** An intent with no single call (a
    payment on an acquirer that only offers authorize and capture) is a coarse
    concrete command: its `execute/3` makes the calls and returns their events,
    and its `simulate/2` yields what the leaves' simulators would. The two must
    agree, which every simulator already owes its adapter. One kind of command
    keeps the executor free of a never-executed case, keeps the identity "the
    command itself" and keeps expansion one level deep.

15. **Why relations across roots are out of scope.** An expansion's leaves stay
    inside the root's subtree: all leaves of root `i` run before root
    `i + 1`. Two properties then hold by construction. A root that consumes a
    value an earlier root produced always runs after the leaf that produces it.
    Every target has run every leaf of every earlier root before a comparison.
    A relation such as "pay, then refund, equals nothing" spans roots. It would
    need a schedule that lets leaves drift past later roots, a dependency
    graph to keep a consumer behind its producer, per-target schedule data and
    a third shrink axis. The relation "pay 100 equals pay 110, then other
    commands, then refund 10" is therefore not exercised; the adjacent form is.

## Consequences

- A model states what its commands mean once, in `expansions/0`, and the same
  model serves property-based, differential, path-equivalence and
  triangulation runs by the targets it is given.
- The contract rests on the author. A rewrite that does not mean the same
  produces a divergence that is a false positive, and the only repair is in
  the model (a different observation or a different rewrite).
- A seed is stable for a fixed model, fixed target names and a fixed
  `expansions/0` function. Renaming a target or changing a function picks
  again.
- `@check every: N` fires at different steps in targets that ran different
  leaves. That is the design: checks are per step.
- A failure that only a rewrite exposes shrinks the roots and the arguments
  around it and keeps the rewrite. It does not shrink toward the identity yet,
  so the minimal reproduction can be larger than the smallest rewrite that
  fails.
- A divergence whose root and leaf are already named in the report needs no
  replay of the unshrunk sequence: the report carries what each target ran.
- A mutant of a root that every run expands is never applied, and
  `Mutation.Runner` reports it as survived.
- Persistence version 13 refuses older files.

## Alternatives considered

- **An implicit identity.** Rejected: a root that cannot run as itself (it has
  no single-call form on some target) would still be offered, and the author
  would have no way to withdraw it.
- **A bare multi-clause function, a wiring flag, or named entries.** Rejected:
  a plain list with keys derived from the index and the leaf modules counts
  how often each entry was chosen, and an entry that is never chosen shows up.
- **Per-observation exceptions to the contract (`except:`).** Rejected, see
  decision 1.
- **A run-level `expansion:` option.** Rejected: a target is where a variant's
  differences live, and a mix across targets is legal.
- **Keying the pick on the target's index.** Rejected: reordering `targets:`
  would change every target's sequence and a named target's failure would not
  reproduce.
- **Shrinking `commands/0` toward the start of the list.** Rejected: a
  substituted root is a different test, so delta debugging's guarantee that a
  removal is a sub-case is lost. Only the expansions of one root are
  substitutable, by the contract.
- **Letting leaves drift to the next root.** Rejected, see decision 15.
- **Treating a vanished carried entry as "identity, forced".** Rejected, see
  decision 11.

## Open questions

- The shrinker's expansion axis (decision 11).
- A replay artifact that holds the concrete leaves of a shrunk failure, and a
  way to run one target alone from it. The report carries the data.
- Whether a failure in one non-reference target should retire only that
  target (the scope of the active-set rule, as in DR-048).
- Whether the mutation runner should target sampled leaf modules.
