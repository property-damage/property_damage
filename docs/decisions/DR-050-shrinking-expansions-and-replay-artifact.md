# DR-050: Shrinking Along the Expansion Axis, and the Replay Artifact

**Status:** Accepted
**Date:** 2026-10-07

## Context

DR-049 let targets run different commands for one root, and it shrank
conservatively: the shrinker removed roots and simplified their arguments, and
each target kept the expansion it was first given. A failure that only one
rewrite exposes therefore shrank to the smallest sequence around that rewrite,
and the report could not say whether the rewrite or the plain command was at
fault. DR-049 also left every path that runs a failure again (the shrinker,
`shrink_further/2`, `Replay`, `Analysis.isolate_trigger/2`, export) raising when
it needed a leaf the report did not hold.

Three questions follow.

- How does the shrinker move along the expansion axis, so that a failing
  multi-target run ends as a small root sequence plus the one rewrite that
  matters?
- How does a person (or a CI job) run a shrunk failure again without
  generating anything, and run one target of it alone?
- What do the paths that run a failure again read, once the report records
  every target's concrete commands?

## Decision

1. **The shrinker has four phases per cycle.** A cycle runs the phases in this
   order and repeats until a whole cycle makes no progress or the shrink
   budget (`max_time_ms:`, `strategy:`) is spent. Each phase starts from the
   candidate the previous phase left.
   1. Drop root subtrees (DR-017). A root's choices go with it, in every
      target.
   2. Collapse the reference target's expansion toward the identity. At each
      surviving root, in order, try the identity first (always legal, listed
      or not, by DR-049 decision 1), then each earlier entry of the root's
      list in order. Keep the first substitution that still fails the same
      way. Every `:reference` target moves with the reference. A `:random`
      target that copied the reference's choice at that root keeps what it ran
      there, so the reference can reach the identity alone.
   3. Collapse each `:random` target onto the reference's choice. At each
      root, substitute the reference's entry and copy the reference's leaves,
      as a `:reference` target does. Keep the substitution when the failure
      survives.
   4. Simplify arguments: the roots' arguments, then the leaves'. In a leaf,
      only fields the leaf's generator chose are simplified. An `overrides:` value and a placeholder are never touched;
      `overrides:` functions run again and aliases are rebuilt per candidate.

   The setup commands and the teardown are not shrunk. The teardown is
   generated again per candidate from the candidate's end state.

2. **Why this order attributes a divergence.** Phase 2 asks whether the
   reference needs its rewrite to fail. Phase 3 asks the same of each other
   target, against the reference's choice. If the failure survives with both
   targets on the same entry, the fault is in the implementation or the
   observation, not in a path: the report shows two targets on the same entry
   and the author reads a plain failure. If a target must keep an entry the
   reference does not run, the failure belongs to that path. The order matters
   because phase 2 moves the baseline: only after the reference is as plain as
   it can be does a surviving difference between two targets mean that the
   rewrite is the cause.

3. **"Identity, by shrinking."** A shrunk root that runs as itself and is not
   listed as an identity entry is recorded as `:identity` and printed
   "identity, by shrinking". It is the third value an entry takes beside a key
   (`Root[i]`) and `:forced` (DR-049 decision 7). `expansion_counts` count it
   per target and root module, and a passing run never has one.

4. **The shrunk failure's identity** is `{kind, name, variant}` at the same or
   an earlier root. A candidate that changes the failing target or the kind is
   rejected, whichever phase produced it, and so is one that fails at a later
   generated root.

5. **Two rules make a candidate invalid, and an invalid candidate never runs.**
   - An entry the expansion function no longer offers for the candidate's
     simulated state (DR-049 decision 11, unchanged and now applied in every
     phase). A failing leaf precondition is not this case: it forces the
     identity.
   - A candidate whose own replay artifact could not run it again. A
     placeholder that the candidate's commands hold must be one that
     simulating the shrunk roots mints. A shrink that dropped the root that
     minted a placeholder some later command consumes would write an artifact
     that reproduces nothing, so the shrinker refuses the candidate. Ids the
     starting sequence's own rebuild already missed are ignored.

6. **`Expansion.for/5` regenerates a target's sequence.**
   `PropertyDamage.Expansion.for(model, seed, run, name, opts \\ [])` returns
   `{:ok, %{prefix:, roots:, choices:, sequence:}}` or `{:error, message}` and
   runs no target and no adapter. `sequence` is what the named target
   executed: the setup prefix, then every root's commands in order, without the
   teardown.
   - `run` is 1-based everywhere it is taken or printed. A failure report's
     `seed` is the seed its failing run generated from, so
     `Expansion.for(Model, report.seed, 1, name)` regenerates the failing run
     as it ran before shrinking.
   - The pick is keyed on the run seed, the target's name and the root
     (DR-049 decision 5), so the result depends on nothing else and is the same
     in any OS process. `opts` takes `targets:` (the name's `expansion:` mode
     and the reference are read from it) and `max_commands:`. Without
     `targets:`, the name is a `:random` target.

7. **`only:` runs part of a campaign, in two shapes.**
   - `only: [run: n, variants: names, with_reference: bool]` runs run `n`
     (default 1) of the seed and nothing else. `variants:` defaults to every
     target; the reference runs beside them unless `with_reference: false`,
     which is legal only for exactly one named non-reference target. That
     target then runs alone with the model's checks and no `@compare`, and its
     sequence is still the one generated under its own name.
   - `only: [replay: path]` runs the artifact (decision 8): every target
     executes the recorded commands, with no draw. Each target's `expansion:`
     is ignored. `targets:` must name exactly the targets the artifact
     records. `shrink:` defaults to false and may be set. `variants:` and
     `with_reference:` combine with it under the rules above.
   - Option errors name the rule: `run:` with `replay:`, an unknown key,
     `max_runs:` other than 1, `branching:`, `seed:` beside `replay:` (the
     artifact records the seed), a `variants:` name that is not a target, and
     `with_reference: false` with anything but one non-reference name. The
     seed library is not replayed under `only:`.
   - A replay that fails the way the artifact records returns the report, and
     its footer says the artifact reproduced. A replay that passes returns
     stats whose `:replay` is `:not_reproduced`.

8. **The replay artifact.** Every failure writes one file after shrinking, into
   the `replay_dir:` option (default `"property_damage_replays"`, created on
   demand; `false` writes nothing). The name is
   `<model last name segment>_seed<seed>.replay.exs`; a later failure of the
   same seed writes the same file. With `shrink: false` the file holds the run
   as it failed and the footer says so.
   - **What it holds:** the model, the seed, the run, the targets in order with
     their `expansion:` (the reference first), the failure as data (kind,
     name, variant index, root index), the setup commands with their arguments,
     the roots with their stable ids, and per target the choice at each root
     (root id, entry, commands as struct literals, aliases). Placeholders are
     `%PropertyDamage.Placeholder{}` literals holding their id tuples.
   - **What it never holds:** the exception or the mismatch of the failure
     (only its kind, name and indexes), the teardown commands (a replay generates
     them from the state the roots leave), a timestamp, or any value that is
     not data.
   - **One Elixir literal term, not JSON and not an Erlang binary.** A person
     reads the file, edits an argument and runs it again, so the format has to
     be text with structure. JSON loses atoms, tuples, structs and non-string
     keys, and the commands hold all of them. An Erlang binary cannot be read
     or edited, and decoding bytes from elsewhere can create atoms and
     functions without limit. A literal term round-trips every command field and is the form the
     commands already print in.
   - **Version header.** The first line is
     `# PropertyDamage replay artifact, format 1`. The term also holds
     `format: 1`. A missing header, a header for another format, or a term
     whose `format` disagrees with the header is refused naming both.
   - **A loader that evaluates no code.** The loader parses with
     `Code.string_to_quoted/2` and a walker accepts literals only: atoms,
     booleans, `nil`, numbers, strings, charlists, lists, tuples, maps and
     `%Module{}` struct literals whose module is loaded and is a struct.
     The loader never loads a module. A struct in a command's own place must
     also be a command module (or a placeholder or position); a struct inside
     a command's fields may be of any loaded module.
     Calls, captures, anonymous functions, pipes, sigils, module attributes,
     variables and a second term are refused, naming the node and its line.
     Loading a file from a bug report therefore cannot run anything.
   - **Deterministic bytes.** The same failure writes the same file: maps are
     in sorted key order and a comment names each root and its entry. Comments
     are for the reader; the loader ignores them.
   - **Generation refuses what a file cannot hold.** A command field (inside
     lists, tuples and maps, map keys included) that holds a function, pid,
     reference, port, improper list or non-binary bitstring gets no artifact.
     The report's `replay` is `{:refused, where}`, and the footer names the
     target, the root, the leaf and the field path. A refused map key is marked
     `{:key, text}` in the path. The failure itself is still reported and
     still reproduces from its seed.
   - A latency budget (judged over the whole campaign) and a branching
     sequence have no artifact: their `replay_status` is `:unavailable` and the
     footer says the failure replays from its seed only.

9. **The report footer and fields.** `FailureReport` gains `run`,
   `replay_path`, `replay` (the term, `{:refused, where}` or nil) and
   `replay_status` (written, disabled, write failed, refused, unavailable,
   reproduced or not reproduced). The printed report ends, in this order, with
   the seed reproduction command, "Regenerate the failing variant:" and the
   `Expansion.for/5` call, then "Replay the shrunk failure:" and the
   `only: [replay: path]` call, which is the last line. When there is no file,
   the last lines say why (`replay_dir: false`, refused naming the value, write
   error). `reproduction_command/1` is unchanged; `replay_command/1` and
   `expansion_command/1` return the two new calls.
   - `targets_source/1` prints a target's non-default `expansion:`. Before, a
     pasted reproduction re-ran a `:reference` or `:identity` target as
     `:random`, which is a different sequence.

10. **Every path that runs a failure again reads the recorded data.** One
    loader seam (`ReplayArtifact`) gives each path a target's concrete
    commands from the report's `replay` term, or from the choices the trace
    records when the report has no term. None raises for a target that ran
    leaves.
    - The shrinker's candidate loop is phase-aware (decision 1).
    - `shrink_further/2` works for every recorded target. It raises, naming
      `replay_dir:`, only when the report has neither a term nor choices. It
      recounts the expansions for the shrunk run and writes its smaller
      artifact over the incoming report's file, which is the same seed's file,
      so the footer never points at the stale larger run.
    - `Replay.run/2` and `Replay.start/2` replay any recorded target, each leaf
      a step.
    - `Analysis.isolate_trigger/2` on a reference that ran leaves varies one
      concrete command of the reference's sequence and re-runs the reference
      alone. A non-reference target is still refused (single-target engine).
    - Export emits the reference's concrete leaves. The ExUnit export emits
      `only: [replay: path]` when the report has a file and the seed path
      otherwise.
    - The seed-library replay and `RunTrace.capture/1` recompute from the seed
      and record the choices, unchanged.
    - The report's `expansions` and `expansion_counts` describe the shrunk run,
      for the report `run/1` returns and for `shrink_further/2`.

11. **Persistence is version 14.** The report envelope gains the replay term,
    the path and the run. Loaders refuse version 13 and older. `.pdtrace`
    files share the version.

## Limitations

- Argument simplification (phase 4) may move an argument below its
  generator's range, which on some seeds lets the shrink collapse a path bug
  onto the reference, until argument simplification respects generator ranges.
- `RunComparison` aligns two runs at root level, not leaf level.
- The replay artifact of a failure first found on the branching engine and
  converted to linear cannot re-execute placeholders minted in a parallel
  branch.
- `Analysis.isolate_trigger/2` re-runs one target alone, so it cannot isolate
  a trigger that needs the comparison: on a `:diverged` or `:did_not_converge`
  report it returns `{:error, :not_applicable}`.

## Consequences

- A failure that only a rewrite exposes shrinks to a small root sequence and
  the one rewrite that matters. A failure that survives with every target on
  the same entry points at the implementation.
- A shrunk failure is a file. It can be attached to a ticket, committed as a
  regression fixture, edited and run again, with no seed and no model change
  in between. A model change that alters what a command means can make an old
  artifact not reproduce; the footer then says so.
- A report is bigger than before: it holds every target's recorded commands.
- Phase 3 copies leaves, so a leaf-level difference is visible only while the
  two targets still run different entries.
- Persistence version 14 refuses older files.

## Alternatives considered

- **JSON.** Rejected, see decision 8: it cannot hold the command structs.
- **An Erlang binary (`term_to_binary`).** Rejected: not readable, not
  editable, and unsafe to decode for a file that came from elsewhere.
- **Evaluating the file as Elixir.** Rejected: loading an attachment would run
  its code.
- **Shrinking all targets at once.** Rejected: a candidate that changes two
  targets cannot say which change the failure survived.
- **Replaying from the seed only.** Rejected: a shrunk run is not a function
  of its seed, so the shrunk failure needs the recorded commands.
- **Raising on a target whose leaves are not recorded.** Rejected: every
  target's leaves are recorded now, so no path has a reason to raise.

## Open questions

- Argument simplification that respects generator ranges (see Limitations).
- A mix task that runs an artifact.
- Whether a failure in one non-reference target should retire only that
  target (the active-set rule, as in DR-048 and DR-049).
