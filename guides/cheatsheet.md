# PropertyDamage Cheatsheet

Compact syntax reference for all five core behaviours, run options, and common patterns.

## Command Template

<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyApp.Commands.CreateOrder do
  use PropertyDamage.Command
  # Optional use opts (all static metadata lives here, DR-028):
  #   execution: :probe,                 # :sync (default) | :probe | :async
  #   shrink: :prefer_remove,            # read-only commands pruned first
  #   weight: 2,
  #   observables: [OrderCreated],       # event types this command produces
  #   idempotent: false,                 # exclude from stutter (default true)
  #   settle: %{timeout_ms: 5_000, interval_ms: 200, backoff: :exponential}

  defstruct [:amount, :currency]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      amount: StreamData.positive_integer(),
      currency: StreamData.member_of(["USD", "EUR"])
    }
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  # --- All below are optional ---

  # Override command_spec/1 for dynamic specs (replaces use opts)
  # def command_spec(overrides \\ []) do
  #   PropertyDamage.Command.build_spec(__MODULE__, [execution: :probe], overrides)
  # end

  # Optional per-instance callbacks (take the command/state, so they stay functions):
  # def label(_state, %__MODULE__{amount: 0}), do: "zero amount"
  # def label(_state, _cmd), do: nil
  # def idempotency_key(%__MODULE__{} = cmd), do: cmd.idempotency_key
  # def awaits(_state, %__MODULE__{id: id}),
  #   do: [%PropertyDamage.Await{match: &match?(%Webhook{id: ^id}, &1)}]
end
```

## Model Template

<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyApp.TestModel do
  @behaviour PropertyDamage.Model

  @impl true
  def commands do
    [
      CreateOrder,                                          # always, weight 1
      {ViewOrder, weight: 2},                               # always, weight 2
      {CancelOrder,
        weight: 1,
        when: fn s -> map_size(s.orders) > 0 end,
        overrides: fn s -> %{order_ref: StreamData.member_of(Map.keys(s.orders))} end}
    ]
  end

  @impl true
  def command_sequence_projection, do: ModelState

  # --- All below are optional ---

  # @impl true
  # def check_projections, do: [BalanceInvariant, AuditLog]

  # @impl true
  # def simulator, do: __MODULE__  # or a separate module

  # @impl true
  # def injectable_events, do: [WebhookReceived]

  # Setup and teardown commands (sequences: every entry runs, in order)
  # @impl true
  # def setup_each, do: [{CreateUser, overrides: %{name: "fixture"}}, Login]
  # @impl true
  # def teardown_each, do: [DeleteUser]

  # Command sequences a root may run as, per target (see Expansions below)
  # @impl true
  # def expansions, do: [{CreateOrder, &create_order_expansions/2}]

  # Stop generation when condition is met
  # @impl true
  # def terminate_early?(_state, %Shutdown{}, _events), do: true
  # def terminate_early?(_state, _cmd, _events), do: false
end
```

### Setup and teardown commands

`setup_each/0` and `teardown_each/0` take no argument and return command specs,
written as in `commands/0` (`Module` or `{Module, opts}`, with `overrides:`).
Both default to `[]`.

| Rule | Behavior |
|------|----------|
| Sequence | every entry runs, in order; `when:` and `weight:` are ignored (`mix pd.validate` warns) |
| Setup commands | run in every target after `Adapter.setup/1`, before the first root, in every run and shrink attempt |
| Teardown commands | run after the roots, pass or fail, before `Adapter.teardown/1`; best effort, never change the verdict |
| Not roots | never compared, expanded, or shrunk; `terminate_early?/3` and `max_commands` count roots only |
| Engine | stutter, nemesis and latency samples are off; a nemesis module in either callback is an error |
| Seeds | adding a setup command re-draws the roots for a given seed |
| Old hooks | a model that defines a side-effect lifecycle hook (arity 1, or a `_once` hook) fails at run start |

```elixir
@impl true
def setup_each do
  [
    {CreateUser, overrides: %{name: "fixture"}},
    {Login, overrides: fn state -> %{user_id: state.user} end}
  ]
end
```

A failure in `Adapter.setup/1`, in a setup command, in a check on a setup
command's event, or an `external()` a setup command left unresolved is kind
`:setup_failed` (`failed_at_index` is `nil`) and is never shrunk. See
[Writing Commands](writing_commands.md#setup-and-teardown-commands).

### Expansions

`expansions/0` lists, for a root, command sequences that mean the same as the
root once it is done. Each target picks one per root by its `expansion:` option.

```elixir
@impl true
def expansions, do: [{Incr, &incr_expansions/2}]

# fun.(root, state): a plain list of entries, simplest first
def incr_expansions(%Incr{key: k, amount: n} = incr, _state) do
  [
    {[incr], weight: 2},                 # the identity, listed like any entry
    [{Incr, overrides: %{key: k, amount: div(n, 2)}},
     {Incr, overrides: fn _state, [%{events: [e]}] -> %{key: k, amount: n - e.amount} end}]
  ]
end
```

| Rule | Behavior |
|------|----------|
| Contract | every expansion means the same as the root once it is done, under every `@compare` value of the model |
| Entry | a sequence, or `{sequence, weight: n}`; default weight 1; list order is the shrink preference |
| Identity | the received root struct alone: `[root]` or `{[root], weight: n}`; nothing is chosen that is not listed |
| `overrides:` | a map, `fn state -> map end`, or (in a sequence only) `fn state, prior_leaves -> map end` |
| `target expansion:` | `:random` (default), `:identity` or `:reference` (copy the first target, leaf for leaf; error on the first target) |
| Pick | keyed on the run seed, the target's name and the root; renaming a target picks again |
| Nothing fits | the root runs as itself, counted `:forced` |
| Load errors | no `@compare` that reaches the end; a listed module not in `commands/0`; a probe root; `branching:` |
| Counts | leaves are commands; `@compare`, `max_commands` and `total_commands` count roots |
| Retired | `{Module, 3}` is an error: write `{Module, weight: 3}` |

Full guide: [Path Equivalence Testing](path_equivalence_testing.md).

Check which entries a seed range reaches with
`mix pd.validate MyApp.Model --targets "[MyApp.Adapter]" --seeds 100`, and
sample a failing seed with `--seed S --seeds 1`, which samples exactly what
`seed: S, max_runs: 1` runs. See
[Writing Commands](writing_commands.md#expansions-one-root-several-commands).

## Projection Template

```elixir
defmodule MyApp.Projections.BalanceInvariant do
  use PropertyDamage.Model.Projection

  # State tracking (both optional; defaults: init -> %{}, apply -> passthrough)
  def init, do: %{balances: %{}, total: 0}

  def apply(state, %AccountCreated{id: id}) do
    put_in(state, [:balances, id], 0)
  end
  def apply(state, %Credited{id: id, amount: amt}) do
    update_in(state, [:balances, id], &(&1 + amt))
    |> Map.update!(:total, &(&1 + amt))
  end
  def apply(state, _), do: state

  # Synchronous check
  @check every: 1
  def assert_total_matches_sum(state, _cmd_or_event) do
    sum = state.balances |> Map.values() |> Enum.sum()
    sum == state.total or PropertyDamage.fail!("total mismatch", expected: sum, got: state.total)
  end

  # Temporal check (eventual consistency); the predicate is total
  # @eventually after: PaymentInitiated, timeout: 5, interval: {100, :milliseconds}
  # def payment_confirmed(_state, %PaymentInitiated{id: id}) do
  #   fn s -> get_in(s, [:payments, id]) == :confirmed end
  # end
end
```

### The Verdict Grammar (DR-052)

| A check, predicate or `using:` returns | `@check` | `@eventually` predicate | `using:` relation |
|----------------------------------------|----------|-------------------------|-------------------|
| truthy | pass | satisfied | agree |
| `nil`, `false` | fail | not yet | disagree, both values |
| `{:fail, "text"}` / `{:fail, %Exception{}}` | fail with it | never: fail now | disagree with it |
| raise | fail | fail now | fail in that variant |
| bare exception struct, `{:error, _}` | fail with a nudge | same | same |

Three forms of `@check`: a predicate (`state.net >= state.fees`),
`condition or fail!("...", ...)`, or a body that ends with a truthy value
(`:ok`, the result of `Enum.each/2`). A check ending in `if` or `unless`
without `else` does not compile. A verdict is not a boolean: `&&` and
`Enum.all?/2` treat `{:fail, _}` as truthy, so compose with
`with true <- a(s), true <- b(s), do: true`.

### The Three Kinds of Check

| Kind | Options | Fails when |
|------|---------|------------|
| `@check` | `every:` (`1`, `N`, `:command`, `:event`, `Module`, `[Modules]`, `{N, target}`) or `at:` (`:startup`, `:teardown`), never both | the function returns `nil`, `false` or `{:fail, reason}`, or raises |
| `@eventually` | `after:` (module or list), `timeout:`, `interval:` (all required; bare integer = seconds) | the predicate is still falsy at `timeout:`, returns `{:fail, reason}`, or raises |
| `@compare` | `every:` (`1`, `N`, `{N, Module}`, `Module`, `[Modules]`, `:end`), `using:` (2-arity, default `&==/2`); a return of `{:pending, reason}` waits | ready sides differ (`:diverged`), or a side is pending at `converge_within:` (`:did_not_converge`) |

A function carries one kind. Details: [Writing Invariants](writing_invariants.md#the-three-kinds-of-check)
and [Differential Testing](differential_testing.md#boundary-observations).

### @check Syntax

| Syntax | Fires when |
|--------|-----------|
| `@check every: 1` | After every step |
| `@check every: :command` | After any command |
| `@check every: :event` | After any event |
| `@check every: CreateOrder` | After `CreateOrder` command or event |
| `@check every: [Cmd1, Cmd2]` | After any listed module |
| `@check every: 10` | Every 10th step (sampling) |
| `@check every: {5, :command}` | Every 5th command |
| `@check every: {3, CreateOrder}` | Every 3rd `CreateOrder` |


### @compare Syntax

A boundary observation compares the targets of a run with two or more `targets:`.
It is a public `def name(state, root)` in a projection (one `@compare`, above the first clause), and a run with two or
more targets and no `@compare` is an error at run start.

| Syntax | Meaning |
|--------|---------|
| `@compare every: 1` | Compare after every root (the default) |
| `@compare every: 5` | Compare after every 5th root |
| `@compare every: {3, CreateOrder}` | Every 3rd `CreateOrder` root |
| `@compare every: [ClearingReport, :end]` | After those roots, and at the final boundary |
| `@compare using: &within_cent/2` | Agreement predicate `fn reference, variant -> verdict end`: truthy agrees; `false` or `{:fail, reason}` disagrees (default `&==/2`) |
| `{:pending, reason}` (a return value) | The target is still catching up; waited for, never a disagreement |

Helpers: `PropertyDamage.Equivalence.by_key/1`, `normalize/1`, `drop_keys/2`.
The wait at a boundary is bounded by `compare: [converge_within: ms]`.

### @eventually Syntax

| Option | Type | Description |
|--------|------|-------------|
| `after:` | module or `[modules]` | Event(s) that spawn the poller |
| `timeout:` | integer or `{int, unit}` | Max poll time (bare integer = seconds) |
| `interval:` | integer or `{int, unit}` | Poll frequency (bare integer = seconds) |

Time units: `:milliseconds`, `:seconds`, `:minutes`

## Adapter Template

```elixir
defmodule MyApp.TestAdapter do
  use PropertyDamage.Adapter
  # Optional: use PropertyDamage.Adapter, default_timeout: 30

  @impl true
  def setup(config) do
    {:ok, client} = HTTPClient.start(base_url: config[:api_url])
    {:ok, %{client: client}}
  end

  @impl true
  def teardown(%{client: client}) do
    HTTPClient.stop(client)
    :ok
  end

  @impl true
  def execute(%CreateOrder{amount: amt}, %{client: client} = _ctx, _runtime) do
    case HTTPClient.post(client, "/orders", %{amount: amt}) do
      {:ok, %{status: 201, body: body}} ->
        {:ok, [%OrderCreated{id: body["id"], amount: amt}]}
      {:ok, %{status: 400, body: body}} ->
        {:ok, [%OrderRejected{reason: body["error"]}]}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Override timeout for slow commands
  # def timeout(%CreateAuthorization{}), do: 120
  # def timeout(_), do: 30

  # Delegation for complex adapters
  # delegate_execution for: [CreateOrder, ViewOrder], to: OrdersSubAdapter
  # delegate_execution for: [CreatePayment], to: PaymentsSubAdapter
end
```

### Execute Signature

`def execute(command, user_context, runtime)`

- `user_context` is exactly what `setup/1` returned (no framework keys mixed in).
- `runtime` is a `%PropertyDamage.Runtime{}` handle providing the framework hooks.

### Runtime Handle Fields

| Field | Type | Description |
|-------|------|-------------|
| `runtime.inject` | `(event -> :ok)` | Inject event mid-execution into projections |
| `runtime.start_poller` | `(keyword -> poller)` | Start background resource poller |
| `runtime.stutter` | map or `nil` | `nil` on first (non-retry) execution; a map during retries |

Stutter map (when present): `%{attempt: 2, is_retry: true, idempotency_key: "abc" | nil}`.
Prefer `PropertyDamage.Runtime.stuttering?(runtime)` to detect a retry.

## Nemesis Template

```elixir
defmodule MyApp.Nemesis.PartitionNetwork do
  @behaviour PropertyDamage.Nemesis

  defstruct [:partition_type, :duration_ms]

  @impl true
  def inject(%__MODULE__{partition_type: type}, ctx) do
    :ok = Toxiproxy.partition(ctx.proxy, type)
    {:ok, [%NetworkPartitioned{type: type}]}
  end

  @impl true
  def restore(%__MODULE__{partition_type: type}, ctx) do
    Toxiproxy.restore(ctx.proxy, type)
    {:ok, [%NetworkRestored{type: type}]}
  end

  @impl true
  def precondition(_state), do: true
end
```

## Run Options

```elixir
PropertyDamage.run(
  # Required
  model: MyModel,
  targets: [{MyApp.Adapter,
    config: %{api_url: "http://localhost:4000"},
    injectors: [MyApp.WebhookInjector],
    mocks: [],
    expansion: :random       # :random (default) | :identity | :reference
  }],

  # Core options
  max_commands: 50,          # default: 50
  max_runs: 100,             # default: 100
  seed: 12345,               # default: random
  verbose: true,             # default: false
  validate: true,            # default: true
  shrink: true,              # default: true

  # Branching (parallel execution)
  branching: [
    branch_probability: 0.2, # probability of branch point
    max_branches: 3,         # max parallel branches
    max_branch_length: 5,    # max commands per branch
    min_prefix_length: 3     # min commands before branching
  ],

  # Stutter (idempotency testing)
  stutter: %{
    probability: 0.1,        # probability of stuttering each command
    max_repeats: 2,           # max retries per stuttered command
    delay_ms: {0, 100},       # delay between retries (min, max) or integer
    commands: :all,            # :all or [Module1, Module2]
    using: &==/2               # fn original_events, retry_events -> verdict end (truthy, false, {:fail, reason})
  },

  # Several targets (compared through the model's @compare observations)
  concurrency: :serial,      # :serial | :parallel
  compare: [converge_within: 5_000], # ms a boundary waits for agreement
  latency: false,            # true measures; [warmup: n, p95: [max_ratio: r]] adds a budget (:serial only)

  # Callbacks
  on_failure: fn report -> IO.inspect(report) end,

  # Regression
  regression: [
    save_failures: "failures/",
    seed_library: "seeds.json",
    generate_tests: "test/generated/",
    tags: [:auto_detected],
    dedup: false
  ]
)
```

## Reference Tables

### `targets:` Entry Keys

An entry is `Adapter` or `{Adapter, keyword}`. The first entry is the reference.

| Key | Default | Meaning |
|-----|---------|---------|
| `name:` | last segment of the adapter module | Label in reports; must be unique in the list |
| `config:` | `%{}` | Map passed to `Adapter.setup/1` unchanged; use it to isolate two targets on one system |
| `injectors:` | `[]` | Injector adapter modules for this target |
| `mocks:` | `[]` | Mock services: `Mod` or `{Mod, config}` |
| `expansion:` | `:random` | `:random`, `:identity` or `:reference` (copy the first target; an error on the first entry) |

The kind of run is inferred, never set: one target is a property-based run; two
or more targets that copy the reference (`expansion: :reference`, or a model
without `expansions/0`) are a differential run; a target that picks its own
expansions is a path-equivalence run.

### Several-Target Run Options

| Option | Default | Meaning |
|--------|---------|---------|
| `concurrency:` | `:serial` | `:serial` steps targets one at a time; `:parallel` steps all at once |
| `compare:` | `[converge_within: 5_000]` | Integer milliseconds a boundary waits for agreement; `settle:` here is an error |
| `latency:` | `false` | `true` measures; `[warmup: n, p95: [max_ratio: r]]` adds a budget; needs `:serial` |

### Execution Semantics

| Semantics | Behavior | Settle | Shrinking |
|-----------|----------|--------|-----------|
| `:sync` | Mutates SUT, completes immediately | None | Normal |
| `:probe` | Queries SUT, retries until settled | Configurable timeout/interval/backoff | Prefer remove (read-only) |
| `:async` | Creates resource, polls for completion | Configurable timeout/interval/backoff | Protected if ref is used downstream |

### Shrink Hints

| Hint | Behavior |
|------|----------|
| `:prefer_remove` | Prioritized for removal during shrinking (read-only commands) |
| `:neutral` | Default shrinking behavior |
| `:prefer_keep` | Resistant to removal (important setup commands) |

### Check Modes

| Mode | Behavior |
|------|----------|
| `:halt` | Stop execution on first check failure (default) |
| `:record` | Record failures, continue execution, report all at end |
| `:log` | Log failures to console, continue execution |
| `:disabled` | Skip all checks |

### Return Values from Adapter.execute/3

| Return | Meaning |
|--------|---------|
| `{:ok, [events]}` | Command succeeded, events applied to projections |
| `{:error, reason}` | Command failed, execution stops |

## Lifecycle Diagram

```
Run 1
├── Adapter.setup/1          (every target, one after another)
├── @check at: :startup
├── Model.setup_each/0       setup commands, in order
├── [roots x N]              Adapter.execute/3, compared at each boundary
├── final boundary
├── @check at: :teardown
├── Model.teardown_each/0    teardown commands, in order
└── Adapter.teardown/1
Run 2
├── (same order)
├── ...
[On failure] Shrinking
├── Shrink 1                 same order, with a shorter sequence of roots
│                            (setup commands re-run; teardown commands regenerated)
└── ...
```

The order holds per target. A failure in setup (`:setup_failed`) skips the roots
and still runs the teardown commands, except for a target whose
`Adapter.setup/1` failed.

## Common Patterns

**Conservation invariant** -- total in equals total out:

```elixir
@check every: 1
def assert_conservation(state, _) do
  state.total_credits == state.total_debits + state.total_balance or
    PropertyDamage.fail!("conservation violated",
      credits: state.total_credits,
      debits: state.total_debits,
      balance: state.total_balance
    )
end
```

**State machine invariant** -- valid status transitions:

```elixir
@check every: StatusChanged
def assert_valid_transition(state, %StatusChanged{id: id, new_status: new}) do
  old = state.statuses[id]
  valid = %{pending: [:approved, :rejected], approved: [:shipped], shipped: [:delivered]}
  new in Map.get(valid, old, []) or PropertyDamage.fail!("invalid transition", from: old, to: new)
end
```

**Reference existence check** -- referenced entities exist:

```elixir
@check every: :command
def assert_refs_valid(state, cmd) do
  for {_field, ref} <- Map.from_struct(cmd), is_binary(ref), String.starts_with?(ref, "acc_") do
    Map.has_key?(state.accounts, ref) or PropertyDamage.fail!("dangling ref", ref: ref)
  end
end
```

**Projection-only invariant** -- no state needed, just validates events:

```elixir
defmodule AmountValidator do
  use PropertyDamage.Model.Projection
  # No init/0 or apply/2 needed

  @check every: Credited
  def assert_positive_credit(_state, %Credited{amount: amt}) do
    amt > 0 or PropertyDamage.fail!("non-positive credit", amount: amt)
  end
end
```
