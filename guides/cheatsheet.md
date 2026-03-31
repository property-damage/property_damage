# PropertyDamage Cheatsheet

Compact syntax reference for all five core behaviours, run options, and common patterns.

## Command Template

```elixir
defmodule MyApp.Commands.CreateOrder do
  use PropertyDamage.Command
  # Optional use opts: execution: :probe, shrink: :prefer_remove, weight: 2

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

  # Metadata used by framework for shrinking/validation/debugging
  # def creates_ref, do: :order_ref           # DEPRECATED: use external() on events
  # def downstream_observables, do: [OrderCreated, OrderRejected]
  # def read_only?, do: false
  # def label(_state, %__MODULE__{amount: 0}), do: "zero amount"
  # def label(_state, _cmd), do: nil

  # Execution semantics (or set via use opts / command_spec)
  # def semantics, do: :sync                  # :sync | :probe | :async
  # def settle_config, do: %{timeout_ms: 5_000, interval_ms: 200, backoff: :exponential}

  # Idempotency testing
  # def idempotent?, do: true
  # def idempotency_key(%__MODULE__{} = cmd), do: cmd.idempotency_key
  # def acceptable_retry_events, do: [OrderCreated, OrderAlreadyExists]
end
```

## Model Template

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
        with: fn s -> %{order_ref: StreamData.member_of(Map.keys(s.orders))} end}
    ]
  end

  @impl true
  def command_sequence_projection, do: ModelState

  # --- All below are optional ---

  # @impl true
  # def assertion_projections, do: [BalanceInvariant, AuditLog]

  # @impl true
  # def simulator, do: __MODULE__  # or a separate module

  # @impl true
  # def injectable_events, do: [WebhookReceived]

  # Lifecycle hooks
  # @impl true
  # def setup_once(config), do: :ok
  # @impl true
  # def setup_each(config), do: :ok
  # @impl true
  # def teardown_each(config), do: :ok
  # @impl true
  # def teardown_once(config), do: :ok

  # Stop generation when condition is met
  # @impl true
  # def terminate?(_state, %Shutdown{}, _events), do: true
  # def terminate?(_state, _cmd, _events), do: false
end
```

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

  # Synchronous assertion
  @trigger every: 1
  def assert_total_matches_sum(state, _cmd_or_event) do
    sum = state.balances |> Map.values() |> Enum.sum()
    if sum != state.total do
      PropertyDamage.fail!("total mismatch", expected: sum, got: state.total)
    end
  end

  # Temporal assertion (eventual consistency)
  # @poll_state after: PaymentInitiated, timeout: 5, interval: {100, :milliseconds}
  # def payment_confirmed(_state, %PaymentInitiated{id: id}) do
  #   fn s -> s.payments[id] == :confirmed end
  # end
end
```

### @trigger Syntax

| Syntax | Fires when |
|--------|-----------|
| `@trigger every: 1` | After every step |
| `@trigger every: :command` | After any command |
| `@trigger every: :event` | After any event |
| `@trigger every: CreateOrder` | After `CreateOrder` command or event |
| `@trigger every: [Cmd1, Cmd2]` | After any listed module |
| `@trigger every: 10` | Every 10th step (sampling) |
| `@trigger every: {5, :command}` | Every 5th command |
| `@trigger every: {3, CreateOrder}` | Every 3rd `CreateOrder` |

### @poll_state Syntax

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
  def execute(%CreateOrder{amount: amt}, %{client: client} = ctx) do
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

### Execute Context Keys

| Key | Type | Description |
|-----|------|-------------|
| *(your setup keys)* | any | Whatever `setup/1` returned |
| `:inject` | `(event -> :ok)` | Inject event mid-execution into projections |
| `:start_poller` | `(keyword -> poller)` | Start background resource poller |
| `:stutter` | map or absent | Present only during retry executions |

Stutter context (when present): `%{attempt: 2, is_retry: true, idempotency_key: "abc" | nil}`

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
  adapter: MyAdapter,

  # Core options
  adapter_config: %{api_url: "http://localhost:4000"},
  max_commands: 50,          # default: 50
  max_runs: 100,             # default: 100
  seed: 12345,               # default: random
  verbose: true,             # default: false
  validate: true,            # default: true
  shrink: true,              # default: true
  injector_adapters: [],     # default: []

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
    comparison: :strict        # :strict | {:structural, fields} | {:custom, fun}
  },

  # Fault injection
  nemesis: [PartitionNetwork, InjectLatency],

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

### Assertion Modes

| Mode | Behavior |
|------|----------|
| `:halt` | Stop execution on first assertion failure (default) |
| `:record` | Record failures, continue execution, report all at end |
| `:log` | Log failures to console, continue execution |
| `:disabled` | Skip all assertions |

### Return Values from Adapter.execute/2

| Return | Meaning |
|--------|---------|
| `{:ok, [events]}` | Command succeeded, events applied to projections |
| `{:error, reason}` | Command failed, execution stops |

## Lifecycle Diagram

```
setup_once/1
├── Run 1
│   ├── Model.setup_each/1
│   ├── Adapter.setup/1
│   ├── [Adapter.execute/2 x N]
│   ├── Adapter.teardown/1
│   └── Model.teardown_each/1
├── Run 2
│   ├── Model.setup_each/1
│   ├── Adapter.setup/1
│   ├── [Adapter.execute/2 x N]
│   ├── Adapter.teardown/1
│   └── Model.teardown_each/1
├── ...
├── [On failure] Shrinking
│   ├── Shrink 1
│   │   ├── Model.setup_each/1
│   │   ├── Adapter.setup/1
│   │   ├── [Adapter.execute/2 x M]  (shorter sequence)
│   │   ├── Adapter.teardown/1
│   │   └── Model.teardown_each/1
│   └── ...
└── Model.teardown_once/1
```

## Common Patterns

**Conservation invariant** -- total in equals total out:

```elixir
@trigger every: 1
def assert_conservation(state, _) do
  if state.total_credits != state.total_debits + state.total_balance do
    PropertyDamage.fail!("conservation violated",
      credits: state.total_credits, debits: state.total_debits, balance: state.total_balance)
  end
end
```

**State machine invariant** -- valid status transitions:

```elixir
@trigger every: StatusChanged
def assert_valid_transition(state, %StatusChanged{id: id, new_status: new}) do
  old = state.statuses[id]
  valid = %{pending: [:approved, :rejected], approved: [:shipped], shipped: [:delivered]}
  unless new in Map.get(valid, old, []) do
    PropertyDamage.fail!("invalid transition", from: old, to: new)
  end
end
```

**Reference existence check** -- referenced entities exist:

```elixir
@trigger every: :command
def assert_refs_valid(state, cmd) do
  for {_field, ref} <- Map.from_struct(cmd), is_binary(ref), String.starts_with?(ref, "acc_") do
    unless Map.has_key?(state.accounts, ref) do
      PropertyDamage.fail!("dangling ref", ref: ref)
    end
  end
end
```

**Projection-only invariant** -- no state needed, just validates events:

```elixir
defmodule AmountValidator do
  use PropertyDamage.Model.Projection
  # No init/0 or apply/2 needed

  @trigger every: Credited
  def assert_positive_credit(_state, %Credited{amount: amt}) do
    if amt <= 0, do: PropertyDamage.fail!("non-positive credit", amount: amt)
  end
end
```
