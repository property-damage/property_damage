# Coverage and Invariant Catalogs

A property-based test that passes tells you less than it seems. If an assertion
never actually ran, or a command was never generated, the green result is
**vacuous** — it verified nothing. This guide covers PropertyDamage's
anti-vacuity tools: command/transition/state coverage, the invariant catalog,
and per-invariant coverage that tells you which guarantees your run truly
exercised. It ends with the seed-library workflow for replaying known failures
while you fix them.

> Assumes only general Elixir plus the basics of a PropertyDamage model
> (commands, a projection, `PropertyDamage.run/1`). Every snippet below is from a
> single runnable example.

## A runnable example

Save this as `coverage_demo.exs` and run it with `mix run coverage_demo.exs`
inside a project that depends on `property_damage`. It is a tiny bank: deposits
and withdrawals against an in-memory balance, with a projection that both tracks
state and asserts invariants.

<!-- pd-doc-verify: runnable -->
```elixir
defmodule Bank.Commands.Deposit do
  use PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]
  defstruct [:amount]
  @impl true
  def generator(overrides \\ %{}) do
    %{amount: StreamData.integer(1..100)} |> merge_overrides(overrides) |> StreamData.fixed_map()
  end
end

defmodule Bank.Commands.Withdraw do
  use PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]
  defstruct [:amount]
  @impl true
  def generator(overrides \\ %{}) do
    %{amount: StreamData.integer(1..100)} |> merge_overrides(overrides) |> StreamData.fixed_map()
  end
end

defmodule Bank.Events.Deposited do
  defstruct [:amount, :balance]
end

defmodule Bank.Events.Withdrawn do
  defstruct [:amount, :balance]
end

defmodule Bank.Events.WithdrawRejected do
  defstruct [:amount, :balance]
end

# Declared, but no command ever produces it — see anti-vacuity below.
defmodule Bank.Events.AccountClosed do
  defstruct [:balance]
end

defmodule Bank.Ledger do
  use PropertyDamage.Model.Projection
  alias Bank.Events.{Deposited, Withdrawn, AccountClosed}

  # The invariant catalog: the properties this projection upholds (DR-026).
  @invariant id: :balance_nonneg, description: "The balance never goes negative"
  @invariant id: :closed_balance_zero, description: "A closed account has a zero balance"

  @impl true
  def init, do: %{balance: 0}

  @impl true
  def apply(state, %Deposited{balance: b}), do: %{state | balance: b}
  def apply(state, %Withdrawn{balance: b}), do: %{state | balance: b}
  def apply(state, _event), do: state

  @trigger every: 1, validates: :balance_nonneg
  def assert_balance_nonneg(state, _step) do
    if state.balance < 0, do: PropertyDamage.fail!("balance went negative", balance: state.balance)
  end

  # Fires only on AccountClosed, which no command emits -> never exercised.
  @trigger every: AccountClosed, validates: :closed_balance_zero
  def assert_closed_balance_zero(_state, %AccountClosed{balance: b}) do
    if b != 0, do: PropertyDamage.fail!("closed with non-zero balance", balance: b)
  end
end

defmodule Bank.Model do
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator
  alias Bank.Commands.{Deposit, Withdraw}
  alias Bank.Events.{Deposited, Withdrawn, WithdrawRejected}

  @impl true
  def commands, do: [{Deposit, weight: 3}, {Withdraw, weight: 2}]
  @impl true
  def command_sequence_projection, do: Bank.Ledger
  @impl true
  def assertion_projections, do: [Bank.Ledger]
  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(%Deposit{amount: a}, _s), do: [%Deposited{amount: a, balance: nil}]
  def simulate(%Withdraw{amount: a}, _s),
    do: [%Withdrawn{amount: a, balance: nil}, %WithdrawRejected{amount: a, balance: nil}]
end

defmodule Bank.Adapter do
  use PropertyDamage.Adapter
  alias Bank.Commands.{Deposit, Withdraw}
  alias Bank.Events.{Deposited, Withdrawn, WithdrawRejected}

  @impl true
  def setup(config), do: {:ok, Map.put(config, :balance, :atomics.new(1, []))}
  @impl true
  def teardown(_config), do: :ok

  @impl true
  def execute(%Deposit{amount: a}, %{balance: ref}, _runtime) do
    {:ok, [%Deposited{amount: a, balance: :atomics.add_get(ref, 1, a)}]}
  end

  def execute(%Withdraw{amount: a}, %{balance: ref}, _runtime) do
    current = :atomics.get(ref, 1)
    if current >= a do
      :atomics.sub(ref, 1, a)
      {:ok, [%Withdrawn{amount: a, balance: current - a}]}
    else
      {:ok, [%WithdrawRejected{amount: a, balance: current}]}
    end
  end
end

{:ok, stats} =
  PropertyDamage.run(
    model: Bank.Model,
    adapter: Bank.Adapter,
    max_commands: 20,
    max_runs: 50,
    seed: 7,
    coverage: true,
    verbose: false
  )

IO.puts(PropertyDamage.Coverage.format(stats.coverage, :summary))
```

## Command, transition, and state coverage

Passing `coverage: true` turns on whole-run accumulation across **every**
generated sequence (without it, a coverage tracker only sees one representative
sequence) and attaches the tracker to the success stats as `stats.coverage`.
`PropertyDamage.Coverage.format/2` renders it. From the run above:

```text
═══════════════════════════════════════════════════════════════
COVERAGE REPORT
═══════════════════════════════════════════════════════════════

Summary:
  Total runs: 50
  Total commands executed: 1000
  Failures found: 0

Coverage:
  Command coverage: 100.0% (2/2)
  Transition coverage: 100.0% (4 pairs)
  Unique states observed: 50

Top commands:
  Deposit: 582x
  Withdraw: 418x

Untested commands:
  (all commands tested)

Invariant coverage:
  Invariants exercised: 1/2
  Never exercised:
    - Ledger.closed_balance_zero
```

- **Command coverage** — fraction of the model's commands generated at least
  once. Below 100% means some command never ran.
- **Transition coverage** — fraction of ordered command pairs (A → B) seen.
- **State coverage** — count of distinct projection states (by hash).

`Coverage.format(tracker, :full)` adds a transition matrix and the untested
pairs; `Coverage.format(tracker, :matrix)` prints just the matrix.

`PropertyDamage.coverage/2` returns a tracker from a run result (it delegates to
`Coverage.from_result/2`). For a full multi-run you must enable coverage so the
result carries the merged tracker:

<!-- pd-doc-verify: runnable -->
```elixir
result = PropertyDamage.run(model: Bank.Model, adapter: Bank.Adapter, coverage: true)
tracker = PropertyDamage.coverage(result, Bank.Model)
```

`coverage/2` also accepts a single result — a `{:ok, %{sequence: ...}}` or an
`{:error, report}` failure — recording it into a fresh tracker. A multi-run
result **without** `coverage: true` carries no coverage data and raises, naming
the option to set.

## The invariant catalog (DR-026)

An **invariant** is a first-class, named property your model guarantees. You
declare invariants on a projection with `@invariant` and link assertions to them
with `validates:`:

```elixir
@invariant id: :balance_nonneg, description: "The balance never goes negative"

@trigger every: 1, validates: :balance_nonneg
def assert_balance_nonneg(state, _step), do: ...
```

Three ways to attach an assertion to an invariant:

- **`validates: :id`** — link to an invariant declared with `@invariant`.
- **Inline `id:`** on the `@trigger`/`@poll_state` — declares the invariant *and*
  registers this assertion as one of its checks, in one place.
- **Neither** — the assertion owns an invariant whose `id` is its own name with
  `assert_` stripped (so `assert_balance_nonneg` validates `:balance_nonneg` by
  default). Every existing assertion therefore already has an invariant.

`id` is unique per projection; the model-level catalog is the union across
projections, keyed `{projection, id}`. Structural mistakes are caught at compile
time: a duplicate `id` or a `validates:` pointing at an undeclared `id` is a
`CompileError`, and an invariant with no checks warns (static vacuity).

`PropertyDamage.assertion_catalog/1` returns the whole catalog, each entry
carrying the invariant and the checks (with their kind) that validate it:

<!-- pd-doc-verify: runnable -->
```elixir
for entry <- PropertyDamage.assertion_catalog(Bank.Model) do
  checks = Enum.map_join(entry.checks, ", ", fn c -> "#{c.name}/#{c.kind}" end)
  IO.puts("#{inspect(entry.projection)} #{entry.id}: #{checks}")
end
```

```text
Bank.Ledger balance_nonneg: balance_nonneg/synchronous
Bank.Ledger closed_balance_zero: closed_balance_zero/synchronous
```

Check kinds are `:synchronous` (`@trigger every:`), `:lifecycle` (`@trigger at:`),
and `:polling` (`@poll_state`). One invariant may have several checks of
different kinds. `mix pd.validate` prints this catalog and flags static-vacuity
entries.

## Anti-vacuity: which invariants actually fired

Naming invariants makes reports prettier; **coverage makes them trustworthy**.
The engine counts, per run, how many times each assertion fired (ran at all,
pass or fail) across every generated sequence. An invariant is *covered* when any
of its checks fired at least once. One that never fired is a **dynamic vacuity** —
a guarantee you declared but never tested.

`PropertyDamage.assertion_coverage/2` joins the run's firings against the catalog
with no re-execution:

<!-- pd-doc-verify: runnable -->
```elixir
for inv <- PropertyDamage.assertion_coverage({:ok, stats}, Bank.Model) do
  IO.puts("#{inv.id}: covered?=#{inv.covered?} fire_count=#{inv.fire_count} kinds=#{inspect(inv.kinds)}")
end
```

```text
balance_nonneg: covered?=true fire_count=4000 kinds=[:synchronous]
closed_balance_zero: covered?=false fire_count=0 kinds=[:synchronous]
```

The `closed_balance_zero` invariant never fired because no command emits
`AccountClosed`. That is exactly the vacuous-pass this feature is built to
surface: without it, the run is green and you would never know the guarantee was
untested. Each entry is a map with `:projection`, `:id`, `:name`, `:description`,
`:kinds`, `:fire_count`, and `:covered?`.

The whole-run tracker exposes the same facts:

<!-- pd-doc-verify: runnable -->
```elixir
PropertyDamage.Coverage.uncovered_invariants(stats.coverage)
#=> [{Bank.Ledger, :closed_balance_zero}]
```

When a run is verbose, a terse footer reports the headline count through the
progress reporter:

```text
  Invariants:     1/2 exercised
```

## Failing CI on low coverage

`Coverage.meets_threshold?/2` turns coverage into a pass/fail gate. It checks
command, transition, `min_commands`, and `assertion_coverage` thresholds
together:

<!-- pd-doc-verify: runnable -->
```elixir
PropertyDamage.Coverage.meets_threshold?(stats.coverage, command: 100)
#=> true
PropertyDamage.Coverage.meets_threshold?(stats.coverage, assertion_coverage: 100)
#=> false  (closed_balance_zero was never exercised)
```

`assertion_coverage: 100` is strict anti-vacuity: it fails unless every catalog
invariant fired. Wire it into a test or a CI script:

```elixir
{:ok, stats} = PropertyDamage.run(model: Bank.Model, adapter: Bank.Adapter, coverage: true)

unless PropertyDamage.Coverage.meets_threshold?(stats.coverage,
         command: 100, transition: 80, assertion_coverage: 100) do
  raise "coverage below threshold:\n" <> PropertyDamage.Coverage.format(stats.coverage, :full)
end
```

Failing a run on uncovered invariants is opt-in — declaring a rare invariant
does not by itself break your build; the `assertion_coverage:` threshold is how
you choose to enforce it. `Coverage.to_json/1` serializes the metrics if you
prefer to gate in a separate CI step.

## Replaying known failures: the seed library

Coverage tells you what a run exercised; the **seed library** helps you rediscover
a specific failure fast while you fix it. It is an ephemeral, self-pruning set of
recently-failing seeds that `PropertyDamage.run/1` replays *before* random
exploration (DR-023), so you do not wait for random generation to re-find the bug
between edits. Enable it with a run option:

<!-- pd-doc-verify: runnable -->
```elixir
# Default file; a new failure's seed is appended, and stored seeds replay first.
PropertyDamage.run(model: Bank.Model, adapter: Bank.Adapter, seed_library: true)

# Or an explicit path
PropertyDamage.run(model: Bank.Model, adapter: Bank.Adapter, seed_library: "seeds.json")
```

You rarely touch `PropertyDamage.SeedLibrary` directly. Each entry tracks a
consecutive-pass streak and is pruned once it passes enough times in a row
(default 3), so genuinely-fixed seeds age out on their own and flaky ones retain
themselves.

Crucially, **the seed library is not a durable regression corpus.** A seed only
reproduces its sequence while the model's generators are byte-stable; changing a
generator, weight, `when:`, or the command set makes a stored seed replay a
*different* sequence. For anything you want to keep, freeze the concrete shrunk
sequence into an ExUnit test with `PropertyDamage.Export` (see *Static Regression
Tests*) — that survives generator changes.

For end-to-end management around failures — save `.pd` files, add to the seed
library, generate ExUnit tests, deduplicate similar failures — use the
`regression:` option, which composes these handlers for you:

<!-- pd-doc-verify: runnable -->
```elixir
PropertyDamage.run(
  model: Bank.Model,
  adapter: Bank.Adapter,
  regression: [
    save_failures: "failures/",
    seed_library: "seeds.json",
    generate_tests: "test/regressions/",
    tags: [:auto_detected],
    dedup: true
  ]
)
```

See `PropertyDamage.Regression` for composing custom `on_failure` handlers.

## Where to go next

- **Writing Effective Invariants** — designing assertions that catch real bugs.
- **Static Regression Tests** — freezing failures into durable ExUnit tests.
- **Debugging Failures** — reading, replaying, and exporting a failure.
