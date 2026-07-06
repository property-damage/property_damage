# Getting Started with PropertyDamage

This guide walks you through creating your first stateful property-based test
with PropertyDamage.

## What is Stateful Property-Based Testing?

Traditional property-based testing generates random inputs and verifies
properties hold. **Stateful** property-based testing goes further:

- Generate random **sequences of operations** (not just inputs)
- Maintain expected state throughout the sequence
- Verify **invariants** hold after every operation
- **Shrink** failing sequences to minimal reproductions

## Installation

Add PropertyDamage to your `mix.exs`:

```elixir
def deps do
  [
    {:property_damage, "~> 0.2"},
    {:stream_data, "~> 1.0"}
  ]
end
```

## Core Concepts

PropertyDamage has five key components:

| Component | Purpose |
|-----------|---------|
| **Commands** | Operations that can be executed (create, update, delete) |
| **Events** | Outcomes of operations (what happened) |
| **Projections** | State reducers that process events |
| **Model** | Ties commands and projections together |
| **Adapter** | Bridge between tests and your actual system |

## Step 1: Define Events

Events represent the outcomes of operations. They're simple structs.

For fields that are **server-generated** (like IDs returned by your system),
use `external()` to mark them:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyApp.Events do
  import PropertyDamage, only: [external: 0]

  defmodule UserCreated do
    # user_id is server-generated, email and name come from the command
    defstruct [:email, :name, user_id: external()]
  end

  defmodule UserUpdated do
    defstruct [:user_id, :name]
  end

  defmodule UserDeleted do
    defstruct [:user_id]
  end
end
```

The `external()` marker tells PropertyDamage that this field will be populated
by your System Under Test during execution. The framework handles tracking
these values automatically.

## Step 2: Define Commands

Commands represent operations. Each command implements the
`PropertyDamage.Command` behaviour, most simply via `use`:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyApp.Commands.CreateUser do
  use PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:email, :name]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      name: StreamData.string(:alphanumeric, min_length: 5),
      email: StreamData.map(
        StreamData.string(:alphanumeric, min_length: 5),
        &"#{&1}@example.com"
      )
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end
```

Note: The `user_id` is **not** in the command - it's server-generated and marked
with `external()` in the `UserCreated` event struct.

> The `UpdateUser` and `DeleteUser` commands (referenced by the model and adapter
> below) follow the same pattern and are left as an exercise.

### Key Command Surface

- **`generator/1`** - Generate command field values (returns `StreamData` of maps)
- **`command_spec/1`** (via `use` options) - Static metadata: `execution`, `shrink`
  (`:prefer_remove` for read-only commands), `observables`, `idempotent`, ...

## Step 3: Define Projections

Projections are state reducers. They process events and maintain state:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyApp.Projections.ModelState do
  use PropertyDamage.Model.Projection

  alias MyApp.Events.{UserCreated, UserUpdated, UserDeleted}

  @impl true
  def init, do: %{users: %{}}

  @impl true
  def apply(state, %UserCreated{user_id: id, email: email, name: name}) do
    put_in(state, [:users, id], %{email: email, name: name})
  end

  def apply(state, %UserUpdated{user_id: id, name: name}) do
    put_in(state, [:users, id, :name], name)
  end

  def apply(state, %UserDeleted{user_id: id}) do
    update_in(state, [:users], &Map.delete(&1, id))
  end

  def apply(state, _), do: state
end
```

## Step 4: Define Invariants

Invariants are checks that should always hold. Define them in assertion
projections using `@trigger` and `assert_*` functions:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyApp.Projections.UserInvariants do
  use PropertyDamage.Model.Projection

  alias MyApp.Events.UserCreated

  @impl true
  def init, do: %{emails: MapSet.new()}

  @impl true
  def apply(state, %UserCreated{email: email}) do
    update_in(state, [:emails], &MapSet.put(&1, email))
  end

  def apply(state, _), do: state

  # Assertions use @trigger to specify when to run
  # and assert_* naming convention
  @trigger every: 1
  def assert_emails_unique(_state, _cmd_or_event) do
    # In a real system, duplicate emails would be caught at creation time.
    # This is just an example of the pattern (see writing_invariants.md).
    :ok
  end
end
```

## Step 5: Define the Model

The model ties everything together:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyApp.TestModel do
  @behaviour PropertyDamage.Model

  alias MyApp.Commands.CreateUser
  alias MyApp.Projections.{ModelState, UserInvariants}

  @impl true
  def commands do
    [
      {CreateUser, weight: 5}
      # Add {UpdateUser, weight: 2} and {DeleteUser, weight: 1} once you define
      # those command modules and their adapter clauses (left as an exercise).
    ]
  end

  @impl true
  def command_sequence_projection, do: ModelState

  @impl true
  def assertion_projections, do: [UserInvariants]

  @impl true
  def injectable_events, do: []
end
```

## Step 6: Define the Adapter

The adapter executes commands against your actual system:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule MyApp.TestAdapter do
  use PropertyDamage.Adapter

  alias MyApp.Commands.CreateUser
  alias MyApp.Events.UserCreated

  @impl true
  def setup(_config), do: {:ok, %{}}

  @impl true
  def teardown(_ctx), do: :ok

  # In-memory SUT: mints a server-side user_id so this guide runs with no
  # external service. To drive a real system, call it here instead -- see the
  # "Adapter Variations" section below for HTTP/gRPC shapes.
  @impl true
  def execute(%CreateUser{email: email, name: name}, _ctx, _runtime) do
    user_id = "user_#{System.unique_integer([:positive])}"
    {:ok, [%UserCreated{user_id: user_id, email: email, name: name}]}
  end

  # execute/3 clauses for UpdateUser and DeleteUser are left as an exercise;
  # they follow the same shape as the CreateUser clause above.
end
```

> #### Where adapter state lives
>
> Each command is run under the adapter's `timeout/1` as a hard wall-clock bound,
> which means `execute/3` runs in a short-lived child process (so a hung command
> fails with `PropertyDamage.CommandTimeoutError` instead of hanging the run).
> Keep your SUT state in the SUT and your adapter state in `user_context` (what
> `setup/1` returns) and the `runtime`, never in the run process's process
> dictionary or keyed on `self()`. Ecto's `SQL.Sandbox` and `Mox` keep working
> unchanged (they resolve access through `$callers`, which is propagated). See
> the `PropertyDamage.Adapter` module docs, "Execution process and the
> per-command timeout", for the full contract.

### Adapter Variations

The example above uses HTTP, but adapters can target any transport:

**In-memory** — Call application functions directly for fast tests:

    def execute(%CreateOrder{amount: amt}, _ctx, _runtime) do
      case MyApp.Orders.create(%{amount: amt}) do
        {:ok, order} -> {:ok, [%OrderCreated{id: order.id, amount: amt}]}
        {:error, reason} -> {:ok, [%OrderRejected{reason: reason}]}
      end
    end

**gRPC** — Use a gRPC channel:

    def setup(config) do
      {:ok, channel} = GRPC.Stub.connect(config.grpc_host)
      {:ok, %{channel: channel}}
    end

    def execute(%CreateOrder{amount: amt}, %{channel: ch}, _runtime) do
      {:ok, reply} = OrderService.Stub.create(ch, %CreateRequest{amount: amt})
      {:ok, [%OrderCreated{id: reply.id, amount: amt}]}
    end

**Testing in IEx** — Test your adapter manually:

    iex> {:ok, ctx} = MyAdapter.setup(%{base_url: "http://localhost:4000"})
    iex> runtime = %PropertyDamage.Runtime{inject: fn _ -> :ok end, start_poller: fn _ -> nil end}
    iex> {:ok, events} = MyAdapter.execute(%CreateOrder{amount: 100}, ctx, runtime)
    iex> MyAdapter.teardown(ctx)

See the [Cheatsheet](cheatsheet.md) for complete adapter templates.

## Step 7: Run the Tests

### Basic Run

<!-- pd-doc-verify: runnable -->
```elixir
PropertyDamage.run(
  model: MyApp.TestModel,
  adapter: MyApp.TestAdapter,
  max_runs: 100,
  max_commands: 50
)
```

### In ExUnit

```elixir
defmodule MyApp.PropertyTest do
  use ExUnit.Case

  test "system maintains invariants" do
    assert {:ok, _stats} =
             PropertyDamage.run(
               model: MyApp.TestModel,
               adapter: MyApp.TestAdapter,
               max_runs: 100
             )
  end
end
```

### Verbose Mode

To see what PropertyDamage generates, add `verbose: true`:

    PropertyDamage.run(
      model: OrderModel,
      adapter: OrderAdapter,
      verbose: true
    )

This prints a run-configuration summary and a per-run progress line (commands
executed, pass/fail). For per-command detail (each command, its result, and the
assertion checks) use step-by-step replay; see the
[Debugging Failures](debugging_failures.md) guide.

## Understanding Results

When tests pass:

```
Run 1/100: 23 commands, PASSED
Run 2/100: 18 commands, PASSED
...
100/100 runs passed!
```

When tests fail:

```
Run 42/100: 31 commands, FAILED!

Shrinking...
Minimal failing sequence (3 commands):
  [0] CreateUser{email: "test@example.com", name: "Alice"}
      => user_id: "user_123"
  [1] CreateUser{email: "test@example.com", name: "Bob"}
      => FAILED: duplicate email

Invariant violated: UserInvariants.emails_unique

Seed: 987654321 (use this to reproduce)
```

## Next Steps

- [Writing Effective Invariants](writing_invariants.md)
- [Debugging Failures](debugging_failures.md)
- [Chaos Engineering with Nemesis](chaos_engineering.md)
- See `benches/` for complete, CI-gated working examples against real software
