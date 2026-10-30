# Path Equivalence Testing

Path equivalence testing checks that two different ways of doing the same thing
leave a system in states that agree. Many systems offer more than one path to
one meaning: `pay 100` and `authorize 100` then `capture 100`; `add 5` and `add
2` then `add 3`; one bulk import and the same rows inserted one by one. A model
states which command sequences mean the same as a command, each target of a run
picks one of them per command, and the framework compares the targets after
every command through the model's `@compare` observations. A disagreement is a
bug in a path.

This guide starts with a quickstart that runs in a fresh project with nothing
but the library, then explains each part: the model, the targets, the
observation, reading a divergence, reproducing it, triangulation and
determinism.

## What Path Equivalence Is

Property-based testing runs one system and checks properties of its state.
Differential testing runs the same commands against two systems and compares
them, so a disagreement is a difference in implementation. Path equivalence
testing runs different commands that mean the same thing, on one system or on
several, so a disagreement is a difference in path.

You never choose the kind of run with an option. The framework reads it from the
targets you pass:

| Targets | Kind of run |
|---------|-------------|
| One | Property-based: the checks run, nothing is compared |
| Two or more, every target after the first copies the first (`expansion: :reference`, or a model without `expansions/0`) | Differential: every target runs the same commands |
| Two or more, any target picks its own expansions (`expansion: :random`, the default, on a model with `expansions/0`) | Path equivalence |

One model serves all three. [Differential Testing](differential_testing.md)
covers the second row; this guide covers the third.

## Quickstart

The system under test is an in-memory counter in an `Agent`. Its one command,
`Add n`, adds `n`. The model says that `Add n` means the same as `Add 1`
followed by `Add (n - 1)`. Two targets run the same adapter on two separate
counters; each target picks, per command, the command itself or the two-step
form. After every command the targets' totals must agree.

### 1. Create a project

```bash
mix new counter_paths
cd counter_paths
```

Add the library to the `deps` in `mix.exs`, then fetch it:

```elixir
defp deps do
  [
    {:property_damage, "~> 0.2"}
  ]
end
```

```bash
mix deps.get
```

(To use a local checkout of PropertyDamage instead, write
`{:property_damage, path: "/path/to/property_damage"}`.)

### 2. Write the model

Create `lib/counter_paths.ex` with this content:

<!-- pd-example: lib/counter_paths.ex -->
<!-- pd-doc-verify: runnable -->
```elixir
defmodule Counter.Add do
  @moduledoc "Add `amount` to the counter."
  use PropertyDamage.Command

  defstruct [:amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{amount: StreamData.integer(2..9)}
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Counter.Added do
  @moduledoc "The counter's total after an `Add`, as the system reported it."
  defstruct [:amount, :total]
end

defmodule Counter.Adapter do
  @moduledoc """
  Runs commands against an `Agent` registered under `config.store`. Two
  targets with different stores never share a counter. `bug: true` plants a
  bug: an `Add 1` adds 2.
  """
  use PropertyDamage.Adapter

  @impl true
  def setup(%{store: store} = config) do
    {:ok, _pid} = Agent.start(fn -> 0 end, name: store)
    {:ok, %{store: store, bug: Map.get(config, :bug, false)}}
  end

  @impl true
  def teardown(%{store: store}), do: Agent.stop(store)

  @impl true
  def execute(%Counter.Add{amount: amount}, ctx, _runtime) do
    applied = if ctx.bug and amount == 1, do: 2, else: amount
    total = Agent.get_and_update(ctx.store, fn n -> {n + applied, n + applied} end)
    {:ok, [%Counter.Added{amount: amount, total: total}]}
  end
end

defmodule Counter.Projection do
  @moduledoc "Folds the reported total and compares it across targets."
  use PropertyDamage.Model.Projection

  @impl true
  def init, do: %{total: 0}

  @impl true
  def apply(state, %Counter.Added{total: total}), do: %{state | total: total}
  def apply(state, _event), do: state

  # Every target evaluates this after every root command; the totals must agree.
  @compare every: 1
  def total(state, _root), do: state.total
end

defmodule Counter.Model do
  @moduledoc "`Add n` may run as itself or as `Add 1` then `Add (n - 1)`."
  use PropertyDamage.Model

  alias Counter.Add

  @impl true
  def commands, do: [Add]

  @impl true
  def expansions, do: [{Add, &add_paths/2}]

  @doc "The ways to run `Add n`: the root itself first, then the two-step form."
  def add_paths(%Add{amount: n} = add, _state) do
    [
      [add],
      [{Add, overrides: %{amount: 1}}, {Add, overrides: %{amount: n - 1}}]
    ]
  end

  @impl true
  def command_sequence_projection, do: Counter.Projection

  @impl true
  def check_projections, do: [Counter.Projection]
end
```

### 3. Run it

Create `run.exs` in the project root:

<!-- pd-doc-verify: runnable -->
```elixir
{:ok, stats} =
  PropertyDamage.run(
    model: Counter.Model,
    targets: [
      {Counter.Adapter, name: "left", config: %{store: :left}},
      {Counter.Adapter, name: "right", config: %{store: :right}}
    ],
    max_runs: 20,
    max_commands: 10,
    seed: 42,
    compare: [converge_within: 100]
  )

IO.inspect(stats.expansion_counts, label: "entries")
```

```bash
mix run run.exs
```

The run passes, and the counts show that both targets ran both forms:

```text
entries: %{
  "left" => %{Counter.Add => %{"Add[0]" => 97, "Add[1]" => 103}},
  "right" => %{Counter.Add => %{"Add[0]" => 101, "Add[1]" => 99}}
}
```

`Add[0]` is the first entry `add_paths/2` returned (the root itself) and
`Add[1]` the second (the two-step form). The two targets picked independently,
so at many roots one target ran `Add n` while the other ran `Add 1, Add (n -
1)`, and their totals agreed every time. `compare: [converge_within: 100]`
shortens the time a comparison waits for agreement; an in-memory counter
answers at once, so 100 ms is plenty (see
[The Observation](#the-observation-compare)).

### 4. Plant a bug and watch it fail

Turn on the planted bug in the second target only. No root ever sends `Add 1`
(the generator picks 2 to 9), so only the two-step form can reach the bug.
Create `bug.exs`:

<!-- pd-example: bug.exs -->
<!-- pd-doc-verify: runnable -->
```elixir
{:error, report} =
  PropertyDamage.run(
    model: Counter.Model,
    targets: [
      {Counter.Adapter, name: "left", config: %{store: :left}},
      {Counter.Adapter, name: "right", config: %{store: :right, bug: true}}
    ],
    max_runs: 20,
    max_commands: 10,
    seed: 42,
    compare: [converge_within: 100]
  )

IO.inspect(report, pretty: true)
```

```bash
mix run bug.exs
```

The run fails, shrinks the failure and prints the report. The offsets (`+0.00s`)
and the waited time vary from run to run:

<!-- pd-report-excerpt: mix run bug.exs; seed 42 -->
```text
#FailureReport<
╔══════════════════════════════════════════════════════════════════════╗
║                            BUG DETECTED!                             ║
╚══════════════════════════════════════════════════════════════════════╝

Seed: 42

## Failure

Failure      diverged
Observation  Counter.Projection.total
At           [0] %Counter.Add{amount: 0}
Reference    "left"  0
Variant      "right"  1
Compared     using ==, still differing after 101 ms (bound 100 ms)

## What this checks

  Diverged      Two targets ran the same plan separately and disagreed. They may
                have taken different but equivalent paths, and an observation
                settled to different values in the reference target and in the
                variant target. Either the system treats equivalent histories
                differently, or the test's claim that the paths are equivalent
                is wrong.

  Model         Counter.Model
                `Add n` may run as itself or as `Add 1` then `Add (n - 1)`.

  Observation   Counter.Projection.total/2
                (no description: add @doc to Counter.Projection.total/2)

  Projection    Counter.Projection
                Folds the reported total and compares it across targets.

  Path          "left" ran Add as steps [0]
                (no description: add doc: "..." to the first entry that Counter.Model.add_paths/2 returns for Add)

  Path          "right" ran Add as steps [0.0],[0.1]
                (no description: add doc: "..." to the second entry that Counter.Model.add_paths/2 returns for Add)

  Command       Counter.Add
                Add `amount` to the counter.

## Minimal Reproduction (1 root)

Reference: target "left"
► [0] %Counter.Add{amount: 0}  as Add[0]  ◄── diverged
        +0.00s event %Counter.Added{amount: 0, total: 0}

Variant: target "right"
► [0] %Counter.Add{amount: 0}  as Add[1]  ◄── diverged
    [0.0] %Counter.Add{amount: 1}
        +0.00s event %Counter.Added{amount: 1, total: 2}
    [0.1] %Counter.Add{amount: -1}
        +0.00s event %Counter.Added{amount: -1, total: 1}

## Projections at [0]   (- reference "left", + variant "right")

Counter.Projection   last applied: Added
  - total: 0
  + total: 1

## Reproduction

targets = [{Counter.Adapter, name: "left", config: %{store: :left}}, {Counter.Adapter, name: "right", config: %{store: :right, bug: true}}]

# Rerun from the seed:
PropertyDamage.run(model: Counter.Model, targets: targets, compare: [converge_within: 100], max_commands: 10, seed: 42, max_runs: 1)

# Regenerate the failing variant:
PropertyDamage.Expansion.for(Counter.Model, 42, 1, "right", max_commands: 10)

# Replay the shrunk failure:
PropertyDamage.run(model: Counter.Model, targets: targets, compare: [converge_within: 100], only: [replay: "property_damage_replays/Model_seed42.replay.exs"])
>
```

Read it from the top. The Failure section says the observation
`Counter.Projection.total` diverged at root `[0]`: the reference `"left"`
read 0 and the variant `"right"` read 1. `Compared` names the relation (`==`)
and the wait: the comparison waited 101 ms against a bound of 100 ms before it
called the difference real.

The "What this checks" section prints the docs of the model, the observation,
its projection and the command. Its `Path` items say how each target ran the
root (here `"left"` as step `[0]`, `"right"` as steps `[0.0],[0.1]`) and print
the `doc:` of the entry that target ran. The `(no description: ...)` lines
here say to add that `doc:` to the entry.

Minimal Reproduction lists both sides of the comparison, each under its own
header, and marks the diverging root `►` in both. The reference ran the root
itself (`as Add[0]`). The variant ran the second entry (`as Add[1]`), so its
leaves `[0.0]` and `[0.1]` follow the root, each with the events it produced.
The shrinker cut ten roots down to one, kept the reference on the plain
command, and could not move `"right"` onto it without losing the failure. The
one difference left between the targets is the path: a path bug.

The Projections section shows the same boundary: `total` is 0 for the
reference and 1 for the variant. The leaves `Add 1` and `Add -1` should add up
to 0, but the planted bug makes `Add 1` add 2, as the first leaf's event
shows (`total: 2`).

The shrunk root is `Add 0`, below the generator's range of 2 to 9, and its
second leaf is `Add -1`. Argument simplification shrinks a number toward 0
without regard to the generator's range. The rewrite still means the same
(`1 + -1 = 0`), and the bug still shows, because the first leaf is still `Add 1`.
For the other sections of the report, see
[Reading the report](debugging_failures.md#reading-the-report).

### 5. Replay the failure

The run also wrote the shrunk failure to
`property_damage_replays/Model_seed42.replay.exs`. Create `replay.exs`:

<!-- pd-doc-verify: runnable -->
```elixir
{:error, replayed} =
  PropertyDamage.run(
    model: Counter.Model,
    targets: [
      {Counter.Adapter, name: "left", config: %{store: :left}},
      {Counter.Adapter, name: "right", config: %{store: :right, bug: true}}
    ],
    compare: [converge_within: 100],
    only: [replay: "property_damage_replays/Model_seed42.replay.exs"]
  )

IO.inspect({replayed.kind, replayed.variant, replayed.replay_status}, label: "replayed")
```

```bash
mix run replay.exs
```

```text
replayed: {:diverged, %{index: 1, name: "right"}, :reproduced}
```

The replay generates nothing: each target runs the commands the artifact
records. The call above is the report's last line. It names the run's
convergence bound (`compare: [converge_within: 100]`), as the reproduction line
does, so the replay waits as long as the run did at the failing root.

That is the whole loop: a model that lists equivalent paths, two targets that
pick independently, one observation, a shrunk divergence that names the path,
and a file that replays it. The rest of this guide explains each part.

## The Model: `expansions/0`

A **root** is one command the generator put in the sequence, from the modules
`commands/0` lists. An **expansion** of a root is a command sequence the model
lists for it, and the commands of an expansion are **leaves**. The optional
callback `expansions/0` returns one `{RootModule, function}` pair per root
module that has expansions:

```elixir
def expansions, do: [{Add, &add_paths/2}]
```

The function takes the root as generated and the target's simulated state at
that root, and returns a list of **entries**. An entry is a sequence, or
`{sequence, weight: n, doc: "..."}`: `weight:` is a positive integer (default 1)
and `doc:` is a string that describes the whole route. The failure report shows
it in the Path item, and a `doc:` on a leaf is ignored with a warning. Entries
are named after their index in the returned list: `Add[0]`, `Add[1]`.

**The contract.** Every entry must mean the same as the root once the root is
done, under every `@compare` observation of the model. The framework cannot
check this; it trusts the model. A rewrite that does not mean the same produces
a divergence that is a false positive, and the fix is in the model: observe
something else, or drop the rewrite.

**The identity.** The root run as itself is the identity. You list it like any
entry, as the received struct alone: `[add]` or `{[add], weight: 2}`. Put it
first: the list order is the order the shrinker prefers, simplest first. A root
module that is not in `expansions/0` always runs as itself.

**Leaves are command specs.** A sequence uses the grammar `commands/0` uses:
`Module` or `{Module, opts}`. Fix a leaf's fields with `overrides:`:

| `overrides:` form | Evaluated with |
|-------------------|----------------|
| a map | nothing: the values are used as they are |
| `fn state -> map end` | the target's simulated state before the leaf |
| `fn state, prior_leaves -> map end` | the state, and the earlier leaves of the same sequence (`%{command:, events:}` each); legal only inside an expansion sequence |

A field `overrides:` does not set is generated by the leaf's own generator. A
leaf module need not appear in `commands/0`: without an entry it always runs at
its position. Listing it there also makes it a root the generator may pick on
its own, and that entry's `when:` is then the leaf's precondition: when it is
false at the leaf's position, the entry is withdrawn and the target picks again
among the rest (see
[When Nothing Fits](writing_commands.md#when-nothing-fits-identity-forced)).
When nothing is left, or the function returns `[]`, the root runs as itself and
the run counts it as `:forced`. For the full grammar, root placeholders and the
load rules, see
[Writing Commands](writing_commands.md#expansions-one-root-several-commands).

## The Targets: `targets:` and `expansion:`

A target is an adapter plus its configuration. The quickstart runs two targets
on one adapter:

```elixir
targets: [
  {Counter.Adapter, name: "left", config: %{store: :left}},
  {Counter.Adapter, name: "right", config: %{store: :right}}
]
```

- `config:` is a map that reaches `Adapter.setup/1` unchanged. Two targets on
  one system must not share state, so give each its own `config:` (here, its
  own `Agent` name; in a real system, a tenant, a namespace or a database).
- `name:` labels the target in reports and keys every per-target result. It
  defaults to the last segment of the adapter module, so two targets on one
  adapter need distinct names.
- The first target is the **reference**: every other target's observation is
  compared against its value.
- `expansion:` says how a target picks at each root:

| `expansion:` | The target runs |
|--------------|-----------------|
| `:random` (default) | one entry per root, picked by weight from a seed keyed on the run seed, the target's name and the root |
| `:identity` | every root as itself |
| `:reference` | what the first target ran, leaf for leaf (an error on the first target) |

The default widens the test. With two `:random` targets, each pair of entries
meets at some root over enough runs: root against rewrite, rewrite against root,
and one rewrite against another when a root has several. A run with an
`:identity` reference and one `:random` target only ever compares a rewrite
with the root.

## The Observation: `@compare`

The targets are compared only through boundary observations: public functions
`def name(state, root)` in a projection, marked `@compare`. After a root, every
target evaluates the function on its own projection state, and each value is
judged against the reference's value. Events are never compared across targets.

```elixir
@compare every: 1
def total(state, _root), do: state.total
```

- `every:` is the schedule: `1` (the default, after every root), `N` (every Nth
  root), `{N, Module}` (every Nth root of that module), `Module` or `[Modules]`
  (after those roots), and `:end` alone or in a list (the final boundary). One
  list may mix modules and `:end`: `every: [Report, :end]` compares after every
  `Report` root and at the final boundary. A model with `expansions/0` needs at
  least one `@compare` whose schedule reaches the end of the run (`every: 1` or
  one that names `:end`).
- Values agree under `==` unless `using:` names another relation: `:fun` (a
  function of the projection, public or private), `{Mod, :fun}` or
  `{Mod, :fun, args}`, called with the reference's value and the variant's
  value first and returning a verdict: truthy to agree, `false` or
  `{:fail, reason}` to disagree (DR-051). Normalize in the observation body
  with `PropertyDamage.Equivalence.normalize/1` (drops id and timestamp keys)
  and `drop_keys/2`, and keep `using:` for relations that are not equalities,
  such as `{PropertyDamage.Equivalence, :within, [0.01]}`.
- A function returns `{:pending, reason}` when its target is still catching up
  and will reach a comparable value without a further command (a webhook not
  yet delivered). A pending side is never a disagreement.
- `@compare` is a plain module attribute, read like `@check` and
  `@eventually`, so a projection module may import its own attribute macros.

At each scheduled boundary the framework runs the **convergence loop**: it folds
each target's waiting events, evaluates again, and repeats until the sides
agree or the **convergence bound** expires. The bound is
`compare: [converge_within: ms]`, an integer of milliseconds, default 5000. A
side still pending at the bound fails the run as `:did_not_converge`; ready
sides that differ fail it as `:diverged`. When several observations disagree
at the bound, the first in declaration order names the failure, and the others
are listed in its detail's `other_keys` and in the printed report. A divergence waits the full bound
before it is reported, which is why the quickstart sets a short one for a
counter that answers at once. The convergence bound is not the per-command
`settle:` wait, which is one system catching up with itself after one adapter
call (see [Async and Eventual Consistency](async_and_eventual_consistency.md)).

A run with two or more targets whose model declares no `@compare` is an error
at run start, before any adapter is set up: nothing would be compared, and the
run would pass without testing anything. With one target, no `@compare`
function is called.

## Reading a Divergence

A failure report names its kind and the target it happened in:

| `report.kind` | Meaning |
|---------------|---------|
| `:diverged` | a target's observation differed from the reference's |
| `:did_not_converge` | a target's observation was still pending at the bound |
| `:check_failed` | a `@check` or `@eventually` failed in one target |
| `:execution_failed` | an adapter raised or returned `{:error, _}` |
| `:setup_failed` | a target could not be set up |
| `:latency_exceeded` | a `latency:` budget was breached (judged once at the end, never shrunk) |

`report.variant` is `%{index: i, name: name}`, the failing target.
`report.failed_at_index` is the failing root, and `report.expansions` maps each
target name to what it ran at every root up to the failure:
`%{root: i, entry: "Add[1]", leaves: [Counter.Add, Counter.Add]}`. The printed
report lists the reference's and the failing variant's commands at the failing
root, with the entry each one ran.

**How the shrinker attributes a divergence.** A shrink cycle runs four phases
and repeats until nothing changes:

1. Drop roots.
2. Move the reference toward the identity at each root: the identity first, then
   each earlier entry, keeping the first that still fails the same way.
3. Move each other target onto the reference's choice at each root.
4. Simplify arguments, the roots' and then the generated fields of the leaves
   (never an `overrides:` value).

A failure keeps its identity through the shrink: the same kind, the same
observation and the same target, at the same root or an earlier one. Read the
shrunk report this way:

- The failing target still runs another entry than the reference at the failing
  root: the failure needs that path. This is a path bug.
- Both targets run the same entry: the failure does not need a path difference.
  The fault is in the implementation or in the observation.

`report.expansion_counts` counts, per target and root module, how often each
entry ran up to the failure. An entry recorded as `:identity` is a root that
ran as itself in place of an entry: the shrinker moved it there when the model
does not list the identity, or the entry realized was one leaf equal to the
root. The report prints it as "identity, by shrinking". A run that passes has
one only for an entry realized as one leaf equal to its root.

## Reproducing a Failure

The report ends with three calls you can paste:

1. **The reproduction command**, `PropertyDamage.run(..., seed: s, max_runs: 1)`:
   generates the failing run again from its seed with the same targets and
   options, then fails and shrinks again.
2. **Regenerate the failing variant**, `PropertyDamage.Expansion.for/4`: returns
   the concrete sequence one target ran before shrinking, without running
   anything:

<!-- pd-doc-verify: runnable -->
```elixir
{:ok, regenerated} =
  PropertyDamage.Expansion.for(Counter.Model, 42, 1, "right", max_commands: 10)

regenerated.choices
|> Enum.map(& &1.entry)
|> IO.inspect(label: "entries")
```

```text
entries: ["Add[1]", "Add[1]", "Add[1]", "Add[0]", "Add[0]", "Add[0]", "Add[0]", "Add[0]",
 "Add[1]", "Add[0]"]
```

   The arguments are the model, the report's `seed`, the run number (1-based)
   and the target name. `regenerated.sequence` is every command the target
   executed, in order. The pick is keyed on the target's name, so the result
   does not depend on the other targets. A root that ran as itself has no entry
   key: its `entry` is `nil` when no expansion applied (its module is not
   listed, the model has no `expansions/0`, or the target runs `:identity`),
   `:forced` when no listed entry could be realized, and `:identity` when the
   entry realized was one leaf equal to the root (or, after a shrink, when
   shrinking replaced a listed entry by the root itself).

3. **Replay the shrunk failure**, `only: [replay: path]`: runs the replay
   artifact. Each target executes the commands the artifact records, with no
   new pick, so each target's `expansion:` is ignored, and `targets:` must name
   exactly the targets the artifact records. `seed:` is an error beside it,
   because the artifact records the seed.

**The replay artifact** is one Elixir term in a `.replay.exs` file, readable
and diffable, with a comment header naming the model, seed, run and targets.
It holds the shrunk roots and, per target, the entry and the concrete commands
it ran at each root. The loader reads it as data and evaluates no code. A
failing run writes it to `replay_dir:` (default `"property_damage_replays"`)
as `<model last segment>_seed<seed>.replay.exs`; `replay_dir: false` writes
none. A later failure of the same seed under other `targets:` (or another
failure) never replaces that file: it is written as
`<model last segment>_seed<seed>_2.replay.exs` (then `_3`, and so on), and its
report prints the path it wrote. A command that holds a value no file can hold (a function, a pid) gets
no artifact, and the report says which field refused.

**Running part of a campaign.** `only: [run: n, variants: names,
with_reference: bool]` runs run `n` of the seed and nothing else. `variants:`
picks the targets that run, and the reference runs beside them unless
`with_reference: false`, which runs exactly one named target alone, with the
model's checks and no `@compare`:

<!-- pd-doc-verify: runnable -->
```elixir
{:ok, _stats} =
  PropertyDamage.run(
    model: Counter.Model,
    targets: [
      {Counter.Adapter, name: "left", config: %{store: :left}},
      {Counter.Adapter, name: "right", config: %{store: :right, bug: true}}
    ],
    seed: 42,
    max_commands: 10,
    replay_dir: false,
    only: [run: 1, variants: ["right"], with_reference: false]
  )
```

The buggy target passes alone: it runs the same commands as in the failing run,
but the counter has no `@check`, so nothing in one target can see that `Add 1`
added 2. A path bug of this kind is visible only by comparison.

## Triangulation

When you port a system (a legacy service and its replacement), one run can tell
a path bug from a port bug. Give it three targets: the legacy system as the
reference on `:random`, the new system on `:reference`, and the new system
again on `:random`:

<!-- pd-doc-verify: runnable -->
```elixir
{:error, report} =
  PropertyDamage.run(
    model: Counter.Model,
    targets: [
      {Counter.Adapter, name: "legacy", config: %{store: :legacy}},
      {Counter.Adapter, name: "port_same_path", expansion: :reference, config: %{store: :port_a, bug: true}},
      {Counter.Adapter, name: "port", config: %{store: :port_b, bug: true}}
    ],
    max_runs: 20,
    max_commands: 10,
    seed: 42,
    compare: [converge_within: 100],
    replay_dir: false
  )

IO.inspect(report.variant, label: "variant")
```

```text
variant: %{index: 2, name: "port"}
```

`legacy` and `port_same_path` run the same commands on two implementations;
`port_same_path` and `port` run one implementation on two paths. Read the
failing target:

- `port_same_path` diverges: the new system disagrees with the legacy one on
  the same commands. That is a port bug.
- Only `port` diverges: the new system agrees with the legacy one on the same
  path and disagrees on its own. That is a path bug in the new system.

Here only `port` diverges: the planted bug is reached only through the two-step
form.

## Determinism

- The pick of each `:random` target is keyed on the run seed, the target's name
  and the root, so a seed reproduces in any process on any machine. Renaming a
  target picks again; reordering `targets:` changes only which target is the
  reference. See [Deterministic Generation](deterministic_generation.md).
- When an `overrides:` function picks an existing key from projection state,
  sort the keys first: `StreamData.member_of(Enum.sort(Map.keys(state.accounts)))`.
  A map's iteration order can differ between VMs, so an unsorted pick breaks
  seed reproduction across machines (see the seams in
  [Deterministic Generation](deterministic_generation.md)).
- `mix pd.validate` samples the entries seeds reach. For the quickstart:

```bash
mix pd.validate Counter.Model --targets '[{Counter.Adapter, name: "left", config: %{store: :left}}, {Counter.Adapter, name: "right", config: %{store: :right}}]' --seed 42 --seeds 20
```

  It prints each entry key with how often it was realized over the sampled
  seeds, and names an entry no seed realized. `--seed S --seeds 1` samples
  exactly what `seed: S, max_runs: 1` runs. On the quickstart's model it also
  warns that `Counter.Add` declares no `:observables` and that the model has
  one command; both are expected for a model this small.

A known limit:

- Argument simplification can move a value below its generator's range (the
  quickstart's `Add 0`), and on some seeds that lets the shrink move the
  failing target onto the reference's entry, which then reads as an
  implementation bug. Re-run the reproduction command with `shrink: false` to
  see what each target ran before shrinking.

## Next Steps

- [Writing Commands](writing_commands.md#expansions-one-root-several-commands):
  the full expansion grammar, root placeholders, forced roots and the load rules
- [Differential Testing](differential_testing.md): targets, `@compare`, the
  convergence loop and isolation in depth
- [Debugging Failures](debugging_failures.md): the failure report and the
  replay artifact
- [Deterministic Generation](deterministic_generation.md): what keeps a seed
  reproducible
