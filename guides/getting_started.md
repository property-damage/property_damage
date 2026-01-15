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
    {:property_damage, "~> 0.1.0"},
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

Events represent the outcomes of operations. They're simple structs:

```elixir
defmodule MyApp.Events do
  defmodule UserCreated do
    defstruct [:user_id, :email, :name]
  end

  defmodule UserUpdated do
    defstruct [:user_id, :name]
  end

  defmodule UserDeleted do
    defstruct [:user_id]
  end
end
```

## Step 2: Define Commands

Commands represent operations. Each command must implement the
`PropertyDamage.Command` behaviour:

```elixir
defmodule MyApp.Commands.CreateUser do
  @behaviour PropertyDamage.Command
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

  # Optional: this command creates a user ref
  def creates_ref, do: :user_id
end
```

### Key Command Callbacks

- **`generator/1`** - Generate command field values (returns `StreamData` of maps)
- **`creates_ref/0`** (optional) - Field name for entity ref this command creates
- **`read_only?/0`** (optional) - Whether command only reads state

## Step 3: Define Projections

Projections are state reducers. They process events and maintain state:

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
  def assert_emails_unique(state, _cmd_or_event) do
    # In a real system, duplicate emails would be caught at creation time
    # This is just an example of the pattern
    :ok
  end
end
```

## Step 5: Define the Model

The model ties everything together:

```elixir
defmodule MyApp.TestModel do
  @behaviour PropertyDamage.Model

  alias MyApp.Commands.{CreateUser, UpdateUser, DeleteUser}
  alias MyApp.Projections.{ModelState, UserInvariants}

  @impl true
  def commands do
    [
      {CreateUser, weight: 5},   # Higher weight = more likely
      {UpdateUser, weight: 2},
      {DeleteUser, weight: 1}
    ]
  end

  @impl true
  def state_projection, do: ModelState

  @impl true
  def extra_projections, do: [UserInvariants]

  @impl true
  def injectable_events, do: []
end
```

## Step 6: Define the Adapter

The adapter executes commands against your actual system:

```elixir
defmodule MyApp.TestAdapter do
  @behaviour PropertyDamage.Adapter

  alias MyApp.Commands.{CreateUser, UpdateUser, DeleteUser}
  alias MyApp.Events.{UserCreated, UserUpdated, UserDeleted}

  @impl true
  def setup(config) do
    base_url = Map.get(config, :base_url, "http://localhost:4000")
    {:ok, %{base_url: base_url}}
  end

  @impl true
  def teardown(_ctx), do: :ok

  @impl true
  def execute(%CreateUser{email: email, name: name}, ctx) do
    case post(ctx.base_url, "/users", %{email: email, name: name}) do
      {:ok, %{status: 201, body: body}} ->
        events = [%UserCreated{
          user_id: body["id"],
          email: body["email"],
          name: body["name"]
        }]
        {:ok, events}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ... implement execute for other commands
end
```

## Step 7: Run the Tests

### Basic Run

```elixir
PropertyDamage.run(
  model: MyApp.TestModel,
  adapter: MyApp.TestAdapter,
  adapter_config: %{base_url: "http://localhost:4000"},
  max_runs: 100,
  max_commands: 50
)
```

### In ExUnit

```elixir
defmodule MyApp.PropertyTest do
  use ExUnit.Case

  test "system maintains invariants" do
    result = PropertyDamage.run(
      model: MyApp.TestModel,
      adapter: MyApp.TestAdapter,
      adapter_config: %{base_url: "http://localhost:4000"},
      max_runs: 100
    )

    assert result.success, "Property test failed: #{inspect(result.failure)}"
  end
end
```

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
      => user_ref: "user_123"
  [1] CreateUser{email: "test@example.com", name: "Bob"}
      => FAILED: duplicate email

Invariant violated: UserInvariants.emails_unique

Seed: 987654321 (use this to reproduce)
```

## Next Steps

- [Writing Effective Invariants](writing_invariants.md)
- [Debugging Failures](debugging_failures.md)
- [Chaos Engineering with Nemesis](chaos_engineering.md)
- See `example_tests/` for complete working examples
