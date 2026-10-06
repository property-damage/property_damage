# Differential Testing

PropertyDamage supports differential testing: `PropertyDamage.run/1` takes several
`targets:` and runs the same root sequence against all of them, comparing
what the model's `@compare` observations report. One target is an ordinary run;
two or more targets add the comparison.

## What is Differential Testing?

Differential testing answers: **"Do these implementations behave the same?"**

Instead of defining expected outcomes, you compare what two sources report
about the same operations. If they disagree, something is wrong. This is
particularly powerful when you have:

- A reference implementation (oracle) to compare against
- Two systems that should be equivalent
- Old vs new versions during migrations

## What Is Compared

PropertyDamage never compares the events an adapter returns. The targets are
compared only through **boundary observations**: public functions of your
projections, marked `@compare`. Each target folds its own events into its own
projection state, and after a root the framework evaluates the observation on
every target and judges each target's value against the reference's.

This puts the question "what must agree?" in the model, where you can answer
it once: an observation returns the part of the state that is part of the
contract, and leaves out what the two systems may legitimately differ on
(identifiers, timestamps, ordering). A check inside one target proves nothing
about the other target, so `@compare` is the whole cross-target oracle.

A run with two or more targets and no `@compare` in its model is an error at
run start, before any adapter is set up: nothing would ever be compared, and
the run would pass without testing anything. With one target the `@compare`
functions are not called.

## Use Cases

| Use Case | Description |
|----------|-------------|
| **Oracle Testing** | Compare SUT against a known-correct reference implementation |
| **Performance Comparison** | Measure latency across backends (`latency: true`) |
| **Regression Testing** | Compare old vs new versions of the same system |
| **Migration Validation** | Verify legacy and new systems produce identical results |
| **Environment Comparison** | Compare staging vs production behavior |

## Quick Start

### 1. Declare What Must Agree

A model for two implementations of a balance. The projection folds the balance
each target reports, and `@compare` makes it the observation:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule Bank.Events do
  defmodule Deposited do
    defstruct [:amount, :balance]
  end
end

defmodule Bank.Commands.Deposit do
  use PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:amount]

  @impl true
  def generator(overrides \\ %{}) do
    %{amount: StreamData.integer(1..10)}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Bank.Projections.Ledger do
  use PropertyDamage.Model.Projection

  alias Bank.Events.Deposited

  @impl true
  def init, do: %{balance: 0}

  @impl true
  def apply(state, %Deposited{balance: balance}), do: %{state | balance: balance}
  def apply(state, _), do: state

  # Compared after every root: both targets must report the same balance.
  @compare every: 1
  def balance(state, _root), do: state.balance
end

defmodule Bank.Model do
  @behaviour PropertyDamage.Model

  @impl true
  def commands, do: [Bank.Commands.Deposit]

  @impl true
  def command_sequence_projection, do: Bank.Projections.Ledger
end
```

### 2. Run Two Targets

One adapter module plays both targets. Each target's `config:` selects its
behavior, and the second target carries a seeded bug (a deposit of 7 is
credited as 6):

<!-- pd-doc-verify: runnable -->
```elixir
defmodule Bank.Adapter do
  use PropertyDamage.Adapter

  alias Bank.Commands.Deposit
  alias Bank.Events.Deposited

  @impl true
  def setup(config) do
    {:ok, balance} = Agent.start_link(fn -> 0 end)
    {:ok, %{balance: balance, bug: Map.get(config, :bug, false)}}
  end

  @impl true
  def teardown(%{balance: balance}) do
    Agent.stop(balance)
    :ok
  end

  @impl true
  def execute(%Deposit{amount: amount}, %{balance: balance, bug: bug}, _runtime) do
    credited = if bug and amount == 7, do: amount - 1, else: amount
    total = Agent.get_and_update(balance, fn b -> {b + credited, b + credited} end)
    {:ok, [%Deposited{amount: amount, balance: total}]}
  end
end

# The targets agree, so the run passes.
{:ok, stats} =
  PropertyDamage.run(
    model: Bank.Model,
    targets: [{Bank.Adapter, name: "reference"}, {Bank.Adapter, name: "candidate"}],
    max_runs: 20,
    max_commands: 8,
    seed: 1
  )

true = stats.compare_counts[{Bank.Projections.Ledger, :balance}].compared_at > 0

# The candidate drops a cent on a deposit of 7: the balances diverge.
{:error, report} =
  PropertyDamage.run(
    model: Bank.Model,
    targets: [
      {Bank.Adapter, name: "reference"},
      {Bank.Adapter, name: "candidate", config: %{bug: true}}
    ],
    max_runs: 50,
    max_commands: 8,
    seed: 1
  )

:diverged = report.kind
"candidate" = report.variant.name
{Bank.Projections.Ledger, :balance} = PropertyDamage.Failure.name(report.failure_reason)
```

The first target in the `targets:` list is the reference: its values are
treated as "correct", and a divergence names the other target. The call returns
`{:ok, stats}` when no run failed, or `{:error, report}` when a target diverged
or failed (see [Understanding Results](#understanding-results)). The framework
shrinks the failing sequence before it reports it.

### 3. Measure Latency

Compare implementations for latency with `latency:`. `latency: true` measures
and sets no bound; a keyword list adds a warm-up and a budget:

```elixir
{:ok, stats} = PropertyDamage.run(
  model: MyModel,
  targets: [
    {RedisAdapter, name: "redis", config: %{host: "localhost"}},
    {PostgresAdapter, name: "postgres", config: %{url: "postgres://localhost/db"}}
  ],
  latency: [warmup: 10, p95: [max_ratio: 1.5]],
  max_runs: 100
)

for {name, metrics} <- stats.metrics do
  IO.puts("#{name}: p50=#{metrics.p50}µs, p99=#{metrics.p99}µs")
end
```

The model still declares its `@compare` observations: `latency:` adds the
measurement, not a different kind of comparison. A run passes only if the
budget holds, as [Latency](#latency) describes.

### 4. Same Adapter, Different Configs

A powerful pattern is comparing the same adapter with different configurations:

```elixir
# Compare staging vs production
PropertyDamage.run(
  model: MyModel,
  targets: [
    {HTTPAdapter, name: "prod", config: %{base_url: "https://prod.example.com"}},
    {HTTPAdapter, name: "staging", config: %{base_url: "https://staging.example.com"}}
  ]
)

# Compare different database configurations
PropertyDamage.run(
  model: MyModel,
  targets: [
    {DBAdapter, name: "with-cache", config: %{cache: true}},
    {DBAdapter, name: "no-cache", config: %{cache: false}}
  ],
  latency: true  # Compare the observations and measure latency (no bound)
)
```

## Boundary Observations

An observation is a public function `def name(state, root)` in a projection
(the command-sequence projection or a check projection), marked `@compare`.
`state` is that target's projection state, `root` is the command that just ran.
Its key, `{Projection, name}`, names every failure it causes.

```elixir
@compare every: [ClearingReport, :end], using: &within_cent/2
def totals(state, _root) do
  if state.unsettled == %{},
    do: %{net: state.net, fees: state.fees},
    else: {:pending, unsettled: map_size(state.unsettled)}
end
```

### `every:`, the schedule

| Value | The observation is compared |
|-------|-----------------------------|
| `1` (default) | after every root |
| `N` | after every Nth root |
| `{N, Module}` | after every Nth root of that command module |
| `Module` or `[Modules]` | after the roots of those modules |
| `:end` or `[Modules, :end]` | at the final boundary, after every target finalized its run |

A key is compared once per boundary, even when two entries of the list match.
`every: N` and a module list bound the convergence cost by scheduling fewer
boundaries.

### `using:`, the agreement predicate

`using:` is a 2-arity function called `using.(reference_value, variant_value)`.
It returns `:match` (or `true`) when the values agree, and `false`,
`{:mismatch, "text"}` or `{:mismatch, exception}` when they do not. Without
`using:` the values agree under `==/2`. It may be any expression: a capture, an
`fn`, or a pipeline of helpers.

`PropertyDamage.Equivalence` has three helpers:

| Helper | Use |
|--------|-----|
| `by_key/1` | Compare `key.(left)` with `key.(right)`; a mismatch keeps both keys |
| `normalize/1` | Strip identifier and timestamp keys (`id`, `inserted_at`, `updated_at`, `created_at`, `timestamp`, `uuid`, `request_id`, `correlation_id`) at every depth; unwrap `{:ok, _}` and `{:error, _}` |
| `drop_keys/2` | Remove the given keys at every depth |

```elixir
import PropertyDamage.Equivalence

# Ignore server-minted identifiers and the fee breakdown
@compare using: by_key(fn v -> v |> normalize() |> drop_keys([:fees]) end)
def orders(state, _root), do: state.orders
```

A mismatch is an exception: by default a `PropertyDamage.ComparisonMismatch`
holding both values (or the text you returned), so a failure report shows
exactly what differed.

A `@compare` function or a `using:` predicate that raises is a check failure in
the target where it ran, naming the key. It is never a divergence.

### `{:pending, reason}`

An observation returns `{:pending, reason}` when its target will reach a
comparable value with no further command, through asynchronous catch-up only (a
settlement still outstanding, a webhook not yet delivered). A pending side is
never a disagreement: the comparison waits for it. State that depends on a
*later command* in the sequence is a value, not a pending: both targets return
the same "not yet" value and agree.

A timeout is therefore always a finding: either the system is slower than the
convergence bound, or the function claims a readiness it cannot reach.

### What `==` does not do

`==` is what `assert a == b` uses, so it is the default. Five traps each give a
false divergence; the [Writing Invariants](writing_invariants.md#what--does-not-do)
guide lists them. In short: return a map when order is not the contract,
use `&===/2` when integer and float must differ, compare a key for value
structs such as `Decimal` and `DateTime`, and use a tolerance predicate for
floats.

## The Convergence Loop

Two systems rarely agree the instant a command returns. At every boundary where
an observation is scheduled the framework runs the **convergence loop**:

1. Evaluate every scheduled observation in every target.
2. If every side is ready and equal, the boundary is done.
3. Otherwise drain and fold every target's event queue, run the async checks,
   re-read the root in every target if it is a `:probe` command, and go to 1.

No boundary is skipped, and no target starts the next root before the loop at
this one has ended. The final boundary is compared after every target finalized
its run; a probe root is re-read there too, in the reference as well.

```
Target A: root r ──┐                       ┌── root r + 1
Target B: root r ──┼── evaluate ── agree? ──┤
                   │       ▲         │ no   │
                   │       └─ drain, fold, re-read a probe ─┘ (until the bound)
```

### Vocabulary

| Term | Meaning |
|------|---------|
| settle | one system catching up with itself per adapter call (the per-command `settle:` map) |
| convergence, the convergence loop | the variants reaching agreement at a boundary |
| the convergence bound | `converge_within:` |
| time to converge | the measured duration |
| did not converge | a side still pending at the bound (`:did_not_converge`) |
| diverged | ready sides that differ at the bound (`:diverged`) |

### The bound, `converge_within:`

```elixir
PropertyDamage.run(
  model: MyModel,
  targets: [Reference, Candidate],
  compare: [converge_within: 30_000]   # integer milliseconds, default 5_000
)
```

The bound starts when the last target arrived at the boundary and is checked
between iterations. An iteration that started before the bound runs to its end
(a probe re-read runs to its own per-command settle), so the loop overshoots
the bound by at most one iteration, and every report states the time waited.

The loop evaluates again at most 50 ms after the last evaluation, and sooner
when a drain delivered an event. A probe root is re-read at most once per
50 ms. An observation that agrees at once costs no wait.

`compare: [settle: _]`, `compare: :correctness | :performance | :both` and
`equivalence:` are removed. Passing them is an option error that names the
replacement.

### Outcomes

The loop ends by convergence, by divergence, or by the bound expiring with a
side still pending; only the third is did not converge.

| Outcome | Report `kind` | When |
|---------|---------------|------|
| converged | none, the run continues | every side is ready and equal |
| diverged | `:diverged` | no side is pending and ready sides differ at the bound |
| did not converge | `:did_not_converge` | a side is still pending at the bound |

With several keys failing at one boundary the first in declaration order is
reported, and within a key a pending side before a difference. An `@eventually`
window that expires while the loop waits is a `:check_failed` at once; a
polling `@eventually` that has not expired does not block agreement.

### Settle, convergence and `@eventually`

Three waits, three bounds: `settle:` is one system catching up with itself for
one adapter call, `converge_within:` is two systems agreeing at one boundary,
and `@eventually` is a liveness predicate on one target. A report names which
bound expired. See
[Async and Eventual Consistency](async_and_eventual_consistency.md#settle-convergence-and-eventually).

### The counters

For every declared key the run counts `compared_at` (boundaries compared),
`waited_at` (boundaries at which the key did not agree at some evaluation) and
`waited_ms` (the time spent waiting). They are `stats.compare_counts` for a
passing run and `report.compare_counts` for a failed one, keyed by
`{Projection, function}`, and the reporter prints them. A key with
`compared_at: 0` was never scheduled: the observation did nothing.

## How a Run Executes

Each run generates one command sequence and runs it against every target in
**lockstep**. Every command is a root. Every target executes root `r`, the
scheduled observations are compared (through the
[convergence loop](#the-convergence-loop)), and only then does any target start
root `r + 1`:

```
Target A: cmd1 → cmd2 → cmd3
Target B: cmd1 → cmd2 → cmd3
         ↓       ↓       ↓
      compare compare compare   (the model's @compare observations)
```

Each target runs as a **variant**: its own process, with its own projections,
event queue, injectors, mocks and pollers. A variant runs the full engine, so
checks, settle, stutter and nemesis work as they do in `PropertyDamage.run/1`.

A run stops at the first boundary where a target's observation still differs
from the reference's at the convergence bound. That is a divergence, and it is a
failure like any other: it ends the campaign, the framework shrinks the sequence
and reproduces it, and `run/1` returns `{:error, report}` with `kind: :diverged`.
The report is the only record: no later run starts.

### Concurrency

`concurrency:` decides how the variants reach each boundary:

| Value | Behavior |
|-------|----------|
| `:serial` (default) | One variant at a time, in target order. Commands never overlap. |
| `:parallel` | All variants at once. The run takes about as long as its slowest target. |

Under `:parallel`, targets that share a system must isolate their slices of it
through `config:` (a tenant or a key prefix per target). Otherwise one target's
command changes what another observes.

```elixir
PropertyDamage.run(
  model: MyModel,
  targets: [...],
  concurrency: :parallel
)
```

`latency:` (any value but `false`) requires `concurrency: :serial`, because
overlapping targets would mix their load into each other's latency.

The `execution:` option is removed. Passing it raises an option error that
names `concurrency:`.

### Setup and teardown per run

Every run sets every target up and tears it down again. Each variant calls
`Adapter.setup/1` in its own process, one variant after another in target
order. No variant executes the first command before every setup has returned.
If a setup fails, the run ends with a `:setup_failed` report that names the
variant, and the variants already set up are torn down.

So `setup/1` runs once per run per target, and it may find state that an
earlier run left behind. Write it to be idempotent (see the `setup/1` notes in
`PropertyDamage.Adapter`).

### Pollers, injectors and mocks

An adapter may call `runtime.start_poller` in a multi-target run, and a target
may declare `injectors:` and `mocks:` in its `targets:` entry. Each belongs to
its own variant: its events reach that variant only, and its pollers stop when
the variant ends.

## Server-Generated Values (`external()`)

Sequences that chain a server-generated id work under differential testing. When
a command produces a value its event marks with `external()` (see the "External
Field Markers" section of the [Writing Commands](writing_commands.md) guide), the
captured concrete value is resolved into any later command that consumes it,
exactly as in `PropertyDamage.run/1`.

Each target captures its own values: the same consumer placeholder resolves to
whatever *that* adapter produced. This is the point under differential testing,
since two implementations legitimately hand out different ids for the same
operation. Keep those ids out of your `@compare` observations (return the part
of the state that does not hold them), or strip them with
`PropertyDamage.Equivalence.normalize/1` under `using:`, so they do not surface
as a divergence.

## Understanding Results

`run/1` returns `{:ok, stats}` when no run failed in any kind, and
`{:error, report}` (a `%PropertyDamage.FailureReport{}`) for the first run that did.

```elixir
case PropertyDamage.run(model: MyModel, targets: [ReferenceAdapter, NewAdapter], max_runs: 100) do
  {:ok, stats} ->
    # stats.targets is a list of %{index: i, name: n}; the first is the reference
    IO.puts("#{stats.runs} runs agreed across #{length(stats.targets)} targets")

  {:error, %PropertyDamage.FailureReport{kind: :diverged} = report} ->
    %{index: _, name: name} = report.variant
    IO.puts("#{name} diverged at root #{report.failed_at_index}")

    for command <- PropertyDamage.Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(report)) do
      IO.puts("  #{inspect(command)}")
    end

    IO.puts(PropertyDamage.FailureReport.reproduction_command(report))

  {:error, %PropertyDamage.FailureReport{kind: kind, variant: variant}} ->
    IO.puts("#{kind} in #{variant.name}")
end
```

### Divergences and failures to converge

A divergence is a report with `kind: :diverged`, and a failure to converge one
with `kind: :did_not_converge`. Both carry:

| Field | Meaning |
|-------|---------|
| `variant` | `%{index, name}` of the first target (in target order) that differed from the reference or was still pending |
| `failed_at_index` | 0-based index of the root where the loop ended |
| `failure_reason` | a `%PropertyDamage.Failure{}`. `Failure.Divergence` holds `key`, `root`, `command` (the root command), `reference_value`, `variant_value` and `mismatch`; `Failure.Convergence` holds `key`, `root`, `command`, `reason` (the `{:pending, reason}` term), the time waited and the bound. `Failure.name/1` is the `@compare` key `{Projection, function}` for both |
| `compare` | `[converge_within: ms]` |
| `compare_counts` | the counters per key |
| `other_failures` | the failures found in the run besides this one (see [Adapter errors](#adapter-errors)) |
| `targets` | the run's `targets:` entries, so the reproduction names the same targets |
| `concurrency` | `:serial` or `:parallel` |
| `seed` | the campaign seed |

```elixir
case PropertyDamage.run(model: MyModel, targets: [Reference, Candidate]) do
  {:error, %PropertyDamage.FailureReport{kind: :diverged} = report} ->
    %PropertyDamage.Failure.Divergence{key: {projection, function}, mismatch: mismatch} =
      report.failure_reason.type

    IO.puts("#{report.variant.name} diverged on #{inspect(projection)}.#{function}")
    IO.puts(Exception.message(mismatch))

  {:error, %PropertyDamage.FailureReport{kind: :did_not_converge} = report} ->
    IO.puts("#{report.variant.name} did not converge at root #{report.failed_at_index}")

  _ ->
    :ok
end
```

The framework shrinks a divergence before it reports it. Every shrink attempt
runs the candidate sequence on every target, each set up and torn down for that
attempt. A candidate counts only if the same target fails with the same kind on
the same `@compare` key, at the same or an earlier root; a candidate that
diverges on another observation is a different failure. The reference's
sequence is what shrinks, because all targets run the same commands. A failure
to converge is shrunk the same way, and each attempt waits the bound once at the
failing boundary.

`PropertyDamage.FailureReport.shrunk_sequence/1` returns the shrunk sequence, and
`PropertyDamage.FailureReport.reproduction_command/1` returns a command that
reruns the failure with the exact `targets:` entries (non-default `name:` and
`config:`) and a non-default `concurrency:`, `compare: [converge_within: ms]`,
`stutter:` or `max_commands:`.

Under `check_mode: :record`, a check failure recorded at an earlier root, or at
the same root in the same or an earlier target, becomes the primary failure. The
divergence is not replaced: it is listed in `other_failures`.

### Failure kinds

Every failed run is a report with a `kind`, the `variant` that failed and
`failed_at_index`, the failing root. `failed_at_index` is `nil` for a setup
failure and for a startup check, which belong to no command.

| Kind | Meaning |
|------|---------|
| `:check_failed` | A check failed in that target, at a command, at the `:startup` phase, or while the run finished (an `@eventually` timeout, a `:teardown` check). A raise in a `@compare` function or a `using:` predicate is one too. |
| `:diverged` | Ready sides of a `@compare` observation differ at the convergence bound. |
| `:did_not_converge` | A side of a `@compare` observation is still pending at the convergence bound. |
| `:setup_failed` | `setup/1` returned an error or raised. An injector or mock setup that raised inside the target counts too. A setup failure is not shrunk. |
| `:execution_failed` | The adapter raised at a root or answered `{:error, _}`, or a nemesis, stutter or placeholder step failed. |

### Adapter errors

An adapter that raises or answers `{:error, _}` at a root is an
`:execution_failed` failure in every run, with one target or several. It is
never an observation: a business rejection is an event, so an error answer
means the adapter could not do its job.

With several targets the run keeps an **active set** of targets:

- A failure of the reference stops the run.
- A failure of any other target retires that target at once: its pollers
  are finalized, its `:teardown` checks and `teardown/1` run before the next
  root starts, and the other targets go on, compared among themselves.
- The run stops when no target besides the reference remains.

Every run, with or without a retired target, orders its failures by one rule:
root, then target, then when it happened within that root and target (a check
recorded under `check_mode: :record` while the root was stepped, then the
comparison failure at that root's boundary, then a failure found while the target
finalized). A failure with no root found at the end of the run (a `:teardown`
check, a crash at finish) comes after every rooted failure, in target order.

The first failure is the **primary failure** and the only shrink target. Every
other one is in `report.other_failures` (each with the variant, the root and the
failure). A finalize-time repeat of a failure already found is listed once, and
nothing is dropped. Which failure is primary for two failures at one root depends
on target order, because the first target is the reference and the others are
compared in order.

### Latency

Latency is a measurement. It is never a boundary observation: projections do
not see timings, a per-command number is noise, and judging it at each
boundary would make runs flaky. The run times the wall-clock of each
`Adapter.execute/3` call, retries included, and leaves out the comparison's
re-reads and the setup and teardown commands.

`stats.metrics` maps each target name to its metrics in microseconds: `p50`,
`p95`, `p99`, `mean`, `min`, `max`, `commands` (the commands timed) and
`by_command` (the `p95` and `commands` per root command module). A target
with no timed command has `%{error: :no_data}` and is never judged.

```elixir
{:ok, stats} = PropertyDamage.run(model: MyModel, targets: targets, latency: true)

for {name, metrics} <- stats.metrics do
  IO.puts("#{name}: p50=#{metrics.p50}µs, p99=#{metrics.p99}µs")
end
```

With `verbose: true` the run also prints the metrics of every target side by
side, one column per target, after the last run.

#### The grammar

```elixir
latency: [warmup: 5, p95: [max_ratio: 1.5], p99: [max: {800, :milliseconds}]]
```

- `warmup: n` leaves the first `n` runs out of the metrics (default `0`).
  Use it to skip cold caches and connection set-up.
- `p50`, `p95`, `p99` and `mean` each take a keyword list of bounds. A
  statistic may carry both.
- `max: {n, unit}` is an absolute bound for every target, the reference
  included. `unit` is `:milliseconds`, `:seconds` or `:minutes`, and `n` a
  positive integer. A bare integer is an option error, because this library
  reads a bare integer as seconds in adapter timeouts and as milliseconds in
  poller intervals.
- `max_ratio: r` bounds a target's statistic divided by the reference's. It
  applies to every target but the reference and needs at least two targets;
  with one target it is an option error at run start. Use `max:` to bound a
  single target.
- A statistic or a bound written twice, an empty bound list and any other key
  are option errors.

#### When the budget is judged

The budget is judged once, after the last run, on the metrics of all measured
runs. It is never judged per run or at a boundary. If a run fails for another
reason (a check, a divergence, a setup or execution failure), that failure
ends the campaign and the budget is not judged.

A breach returns `{:error, report}` with `report.kind == :latency_exceeded`.
The report names the target, the statistic, the measured value and the limit,
and for a ratio the reference's value. It also carries `metrics` and
`latency`:

```
variant postgres exceeded p95 max_ratio: 2.310 against 1.5 (reference p95 410.0 us)
```

If one bound is breached by several targets, or several bounds are breached,
the primary failure is the first in target order, then `p50`, `p95`, `p99`,
`mean`, and `max` before `max_ratio`. The others are in
`report.other_failures`.

A latency failure is not shrunk, not re-executed and has no replay artifact:
the finding is statistical, so no shorter sequence reproduces it. Run the
same `seed:` again to reproduce it. `on_failure` is still called once.

If the reference statistic is zero, a positive value of the same statistic
in another target breaches `max_ratio:` as infinity; two zeros do not breach.

### What stays one-target

Branching sequences run against one target: `branching:` with two or more
targets is an option error. `PropertyDamage.replay/2`,
`PropertyDamage.Analysis.isolate_trigger/2` and `PropertyDamage.RunTrace` work on
the report's reference target (with its name and config).
`PropertyDamage.shrink_further/2` re-shrinks with the report's `targets`,
`concurrency`, `compare` and `stutter` by default; pass `targets:` (one or
more entries), `concurrency:` or `compare:` to override. `equivalence:` is
removed.

## When the Model Has Expansions

A model can list, for a root command, other command sequences that mean the same
once the root is done (see [Expansions](writing_commands.md#expansions-one-root-several-commands)).
The `expansion:` option of each target then says which sequence the target
runs at each root:

| Value | The target runs |
|-------|-----------------|
| `:random` (default) | an entry it picks per root, keyed on the run seed, its name and the root |
| `:identity` | the roots themselves |
| `:reference` | what the first target ran, leaf for leaf |

A differential run is a path-equivalence run whose non-reference targets copy the
reference. Put `expansion: :reference` on every target after the first, and every
target executes the same concrete commands, so a divergence points at the
implementation:

```elixir
targets: [
  {LegacyAdapter, name: "legacy"},
  {NewAdapter, name: "new", expansion: :reference}
]
```

Leave the second target on `:random` and the two targets run different commands
for the same roots. A divergence then points at a path, or at the implementation
when the targets also differ. Put a third target on `:reference` beside a `:random`
one, and the failure shows which axis (implementation or path) it needs.

The first target is the reference, so `expansion: :reference` on it is an option
error. A model without `expansions/0` runs the same roots whatever the value.
Targets are still compared only at root boundaries: the comparison waits until
every target has run every leaf of the root.

## Options Reference

### Required Options

| Option | Description |
|--------|-------------|
| `:model` | Model module implementing `PropertyDamage.Model` |
| `:targets` | List of target specifications (one or more) |

### Target Specification

```elixir
AdapterModule                           # Bare module name
{AdapterModule, name: "display-name"}   # Explicit display name
{AdapterModule, config: %{key: value}}  # Configuration for setup/1
{AdapterModule, name: "name", config: %{key: value}}  # Both
{AdapterModule, expansion: :reference}  # Run what the first target ran
```

The **first entry in the `targets:` list is the reference oracle** (no special marker needed).
The `config:` option is a map of key-value pairs passed to the adapter's `setup/1` callback.
Each target may have the same adapter module with different configs for isolation
(e.g., distinct tenants).

A bare module takes its last module segment as its name (`MyApp.ReferenceAdapter`
is `"ReferenceAdapter"`). Two entries must not share a name, so give entries on the
same adapter distinct `name:` values.

`expansion:` is `:random` (the default), `:identity` or `:reference`; see
[When the Model Has Expansions](#when-the-model-has-expansions).

An entry may also carry `injectors:` (a list of injector adapter modules) and
`mocks:` (a list of `Mod` or `{Mod, config_map}`). Both are set up per run for that
target only.

### Isolating Targets on the Same System

When comparing two targets that run on the same system (for example, the same
database server), isolation is critical to avoid state leakage. The `config:` field
is your isolation boundary: pass a distinct tenant, schema, database name, or port
to each target so they do not collide. For example, when testing two database
configurations against the same PostgreSQL server, pass a different database name
to each:

```elixir
targets: [
  {DBAdapter, name: "replica-1", config: %{db: "test_db_1"}},
  {DBAdapter, name: "replica-2", config: %{db: "test_db_2"}}
]
```

The `mix pd.validate --targets "<list>"` command warns when two targets share the
same adapter module *and* an identical `config:`, since that usually signals a
configuration mistake. Fix it by giving each target its own config.

### Optional Options

| Option | Default | Description |
|--------|---------|-------------|
| `:max_commands` | 50 | Maximum commands per sequence |
| `:max_runs` | 100 | Number of test sequences |
| `:seed` | random | Random seed for reproducibility |
| `:concurrency` | `:serial` | `:serial` or `:parallel` (see [Concurrency](#concurrency)) |
| `:compare` | `[converge_within: 5_000]` | `converge_within:`, the convergence bound in integer milliseconds (see [The bound](#the-bound-converge_within)) |
| `:latency` | `false` | `true` measures each target's latency per command; a keyword list adds `warmup: n` and a budget (see [Latency](#latency)); requires `concurrency: :serial` |
| `:check_mode` | `:halt` | How a failing check is handled |
| `:verbose` | false | Print progress |
| `:on_progress` | nil | Progress consumer (see [Monitoring Progress](#monitoring-progress)) |

## Monitoring Progress

Pass an `on_progress` function to observe a run as it happens. It receives a
`%PropertyDamage.Progress{}` projection (DR-022): the same `RunUpdate` and
`RunResult` payloads as a one-target run. `RunResult` carries the failure `kind`
and the failing `variant`, and the verbose printer prints the failure kind and
the target name. The same stream drives `verbose:`.

The engine also emits `[:property_damage, :command, :start | :stop]` and
`[:property_damage, :check, :start | :stop]` telemetry events with
`variant: %{index, name}` and `run_number`, and
`[:property_damage, :sequence, :stop]` carries the `variant` the run failed in
(`nil` when it passed). Shrink attempts and the reproduction use `run_number: 0`.
Nothing is emitted unless a handler is attached.

```elixir
alias PropertyDamage.Progress
alias PropertyDamage.Progress.RunResult

PropertyDamage.run(
  model: MyModel,
  targets: [OracleAdapter, {SUTAdapter, name: "new-impl"}],
  on_progress: fn
    %Progress{data: %RunResult{kind: kind, variant: variant}} when not is_nil(kind) ->
      IO.puts("#{kind} in #{variant.name}")

    %Progress{} ->
      :ok
  end
)
```

The authoritative result is the return value of `run/1`.

## Example: Migration Validation

Testing a database migration from PostgreSQL to CockroachDB. The model's
observation compares the order totals and leaves the auto-generated ids out:

```elixir
defmodule OrderModel.Projections.Orders do
  use PropertyDamage.Model.Projection
  import PropertyDamage.Equivalence

  # ... init/0 and apply/2 fold OrderPlaced and OrderShipped events ...

  @compare every: 1, using: by_key(&drop_keys(&1, [:id, :inserted_at]))
  def orders(state, _root), do: state.orders
end

defmodule MigrationTest do
  def validate_migration do
    result = PropertyDamage.run(
      model: OrderModel,
      targets: [
        {SQLAdapter, name: "postgres",
         config: %{url: "postgres://localhost/orders"}},
        {SQLAdapter, name: "cockroach",
         config: %{url: "postgres://localhost:26257/orders"}}
      ],
      latency: [warmup: 5, p95: [max_ratio: 2.0]],
      max_runs: 500,
      verbose: true
    )

    case result do
      {:ok, stats} ->
        IO.puts("Migration validated! The observations agree.")
        IO.puts("Performance comparison:")

        for {name, metrics} <- stats.metrics do
          IO.puts("#{name}: p50=#{metrics.p50}µs, p99=#{metrics.p99}µs")
        end

      {:error, %PropertyDamage.FailureReport{kind: kind} = report}
      when kind in [:diverged, :did_not_converge] ->
        IO.puts("#{kind} in #{report.variant.name}!")
        IO.puts(PropertyDamage.FailureReport.reproduction_command(report))

      {:error, %PropertyDamage.FailureReport{kind: kind, variant: variant}} ->
        IO.puts("#{kind} in #{variant.name} before the comparison finished.")
    end
  end
end
```

## Example: API Version Comparison

Comparing v1 and v2 of an API. v2 returns additional fields, so the predicate
compares only the fields v1 has:

```elixir
defmodule UserModel.Projections.Users do
  use PropertyDamage.Model.Projection

  # ... init/0 and apply/2 fold the users each target reports ...

  @compare using: &__MODULE__.common_fields?/2
  def users(state, _root), do: state.users

  def common_fields?(v1_users, v2_users) do
    if Map.take(v2_users, Map.keys(v1_users)) == v1_users,
      do: :match,
      else: {:mismatch, "v2 users differ from v1 on the fields they share"}
  end
end

PropertyDamage.run(
  model: UserModel,
  targets: [
    {HTTPAdapter, name: "v1",
     config: %{base_url: "https://api.example.com/v1"}},
    {HTTPAdapter, name: "v2",
     config: %{base_url: "https://api.example.com/v2"}}
  ]
)
```

## Best Practices

1. **Use fixed seeds** - Makes comparisons reproducible

2. **Observe the contract, not the payload** - Return the part of the state
   that must agree and leave out auto-generated fields, instead of
   comparing everything

3. **Warm up for latency measurement** - `latency: [warmup: n]` discards the
   first runs, so cold caches do not enter the metrics

4. **Keep `concurrency: :serial` for latency** - Overlapping targets mix
   their load into each other's latency

   Bound the percentile that matches the claim: `p95` or `p99` for
   user-facing delay, `mean` for throughput. One target takes `max:`; two or
   more can take `max_ratio:` against the reference.

5. **Make `setup/1` idempotent** - Every run calls it again, and a crashed run
   may have left state behind

6. **Compare in CI** - Catch regressions before they reach production

7. **Check `compared_at`** - A key whose count stays 0 was never scheduled,
   so it compared nothing

8. **Use `:pending` for asynchronous catch-up only** - Return it when the
   target will become comparable with no further command; a state that
   needs a later command is a value

## What Differential Testing Detects

- Implementation bugs (oracle testing)
- Performance regressions (with a `latency:` budget)
- Behavior changes between versions
- Environment-specific bugs
- Race conditions (with `concurrency: :parallel`, when the targets are isolated)
- Data migration errors

## Next Steps

- [Writing Commands](writing_commands.md#expansions-one-root-several-commands) for `expansions/0`, the callback that lets targets run different commands
- See the `PropertyDamage.run/1` docs for the full API, and `PropertyDamage.FailureReport` for the report
- [Writing Invariants](writing_invariants.md#comparing-targets-with-compare) for `@compare` and the `==` traps
- [Async and Eventual Consistency](async_and_eventual_consistency.md) for settle, convergence and `@eventually`
- Read about [Chaos Engineering](chaos_engineering.md) for fault injection
- Use [Integration Testing](integration_testing.md) for live service testing
