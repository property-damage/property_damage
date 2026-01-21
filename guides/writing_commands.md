# Writing Commands

Commands are semantic operations that can be executed against the System Under Test (SUT). They define WHAT can happen, while Adapters define HOW it happens against specific targets.

## Command Architecture

Commands follow a pure generator pattern - they are decoupled from state shape and reusable across different Models.

### Command Responsibilities

Commands define:
- **Struct fields** - The data needed for the operation
- **`generator/1`** - How to generate valid field values
- **Metadata** - Optional callbacks like `read_only?/0`, `downstream_observables/0`

Commands do NOT define:
- When the command is valid (preconditions) - defined in Model via `when:`
- How to parameterize based on state - defined in Model via `with:`
- Expected events from execution - defined in Model via `simulate/2`

### Basic Command Example

```elixir
defmodule MyTest.Commands.CreateOrder do
  @behaviour PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:amount, :currency]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      amount: StreamData.positive_integer(),
      currency: StreamData.member_of(["USD", "EUR", "GBP"])
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  # Optional: events this command can produce
  def downstream_observables, do: [OrderCreated, OrderRejected]
end

# The corresponding event marks server-generated fields with external()
defmodule MyTest.Events.OrderCreated do
  import PropertyDamage, only: [external: 0]

  # order_id is server-generated, amount and currency come from the command
  defstruct [order_id: external(), :amount, :currency]
end
```

### State-Dependent Command Example

For commands that need state-dependent values (like selecting from existing refs):

```elixir
defmodule MyTest.Commands.ViewOrder do
  @behaviour PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:order_ref]

  @impl true
  def generator(overrides \\ %{}) do
    # Default to nil - Model provides actual refs via with:
    %{order_ref: nil}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  def read_only?, do: true
  def downstream_observables, do: [OrderViewed, OrderNotFound]
end
```

The Model wires this command with state:

```elixir
defmodule MyTest.OrderModel do
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  def commands do
    [
      CreateOrder,
      {ViewOrder,
        when: fn s -> map_size(s.orders) > 0 end,
        with: fn s -> %{order_ref: StreamData.member_of(Map.keys(s.orders))} end}
    ]
  end

  # Return self as the simulator module
  def simulator, do: __MODULE__

  # simulate/2 defines expected events (Simulator behaviour)
  def simulate(%ViewOrder{order_ref: ref}, state) do
    if Map.has_key?(state.orders, ref) do
      [%OrderViewed{order_ref: ref}]
    else
      [%OrderNotFound{order_ref: ref}]
    end
  end
end
```

## Model-Level Wiring

All state-dependent configuration lives in the Model:

### Command Specification Options

```elixir
def commands do
  [
    # Simple: always enabled, weight 1
    CreateOrder,

    # Weighted: {module, weight: n}
    {CreateOrder, weight: 3},

    # Full options
    {ViewOrder,
      weight: 2,
      when: fn state -> map_size(state.orders) > 0 end,
      with: fn state -> %{order_ref: StreamData.member_of(Map.keys(state.orders))} end}
  ]
end
```

| Option | Type | Description |
|--------|------|-------------|
| `weight:` | `pos_integer()` | Relative selection frequency (default: 1) |
| `when:` | `(state -> boolean)` | Precondition function |
| `with:` | `(state -> map)` | Override function for generation |

### Simulate Callback

Models that need symbolic execution implement the `PropertyDamage.Model.Simulator` behaviour
and return themselves (or a delegate module) via `simulator/0`:

```elixir
defmodule MyTest.OrderModel do
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  def commands, do: [CreateOrder, CancelOrder]
  def state_projection, do: MyTest.OrderProjection
  def extra_projections, do: []

  # Return self as the simulator module
  def simulator, do: __MODULE__

  # Simulator behaviour callback
  @impl PropertyDamage.Model.Simulator
  def simulate(%CreateOrder{amount: amount}, _state) do
    [%OrderCreated{amount: amount, order_ref: nil}]
  end

  def simulate(%CancelOrder{order_ref: ref}, state) do
    if Map.has_key?(state.orders, ref) do
      [%OrderCancelled{order_ref: ref}]
    else
      [%OrderNotFound{order_ref: ref}]
    end
  end

  # Catch-all for commands with no events
  def simulate(_command, _state), do: []
end
```

## Managing Model Verbosity

With many commands, Models can grow large. Here are patterns to keep them manageable:

### Pattern 1: Helper Modules for Wiring

Factor wiring functions into a helper module:

```elixir
defmodule MyTest.OrderModel do
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias MyTest.CommandWiring
  alias MyTest.Simulation

  def commands do
    [
      {CreateOrder, CommandWiring.create_order()},
      {ViewOrder, CommandWiring.view_order()},
      {CancelOrder, CommandWiring.cancel_order()}
    ]
  end

  def state_projection, do: MyTest.OrderProjection
  def extra_projections, do: []

  # Return self as the simulator (delegates to Simulation module)
  def simulator, do: __MODULE__

  # Delegate simulate/2 to helper module
  defdelegate simulate(command, state), to: Simulation
end

defmodule MyTest.CommandWiring do
  def create_order, do: [weight: 3]

  def view_order do
    [
      weight: 2,
      when: fn s -> map_size(s.orders) > 0 end,
      with: fn s -> %{order_ref: StreamData.member_of(Map.keys(s.orders))} end
    ]
  end

  def cancel_order do
    [
      weight: 1,
      when: fn s -> Enum.any?(s.orders, fn {_, o} -> o.status == :active end) end,
      with: fn s ->
        active = Enum.filter(s.orders, fn {_, o} -> o.status == :active end)
        %{order_ref: StreamData.member_of(Keyword.keys(active))}
      end
    ]
  end
end

defmodule MyTest.Simulation do
  @behaviour PropertyDamage.Model.Simulator

  @impl true
  def simulate(%CreateOrder{amount: amount}, _state) do
    [%OrderCreated{amount: amount, order_ref: nil}]
  end

  def simulate(%ViewOrder{order_ref: ref}, _state) do
    [%OrderViewed{order_ref: ref}]
  end

  def simulate(%CancelOrder{order_ref: ref}, _state) do
    [%OrderCancelled{order_ref: ref}]
  end
end
```

### Pattern 2: Shared Wiring Across Models

When multiple Models use the same commands with similar wiring:

```elixir
defmodule SharedWiring.Orders do
  @moduledoc """
  Reusable wiring for order-related commands.
  Parameterized by state key for flexibility.
  """

  def view_order_wiring(orders_key \\ :orders) do
    [
      when: fn s -> map_size(Map.get(s, orders_key, %{})) > 0 end,
      with: fn s ->
        orders = Map.get(s, orders_key, %{})
        %{order_ref: StreamData.member_of(Map.keys(orders))}
      end
    ]
  end

  def cancel_order_wiring(orders_key \\ :orders, status_field \\ :status) do
    [
      when: fn s ->
        orders = Map.get(s, orders_key, %{})
        Enum.any?(orders, fn {_, o} -> Map.get(o, status_field) == :active end)
      end,
      with: fn s ->
        orders = Map.get(s, orders_key, %{})
        active_refs =
          orders
          |> Enum.filter(fn {_, o} -> Map.get(o, status_field) == :active end)
          |> Enum.map(fn {ref, _} -> ref end)
        %{order_ref: StreamData.member_of(active_refs)}
      end
    ]
  end
end

# Model A uses standard state shape
defmodule ModelA do
  import SharedWiring.Orders

  def commands do
    [
      CreateOrder,
      {ViewOrder, view_order_wiring()},
      {CancelOrder, cancel_order_wiring()}
    ]
  end
end

# Model B uses different state key
defmodule ModelB do
  import SharedWiring.Orders

  def commands do
    [
      CreateOrder,
      {ViewOrder, view_order_wiring(:pending_orders)},
      {CancelOrder, cancel_order_wiring(:pending_orders, :state)}
    ]
  end
end
```

### Pattern 3: Command Documentation

Since behavior is split between Command and Model, document requirements in the Command:

```elixir
defmodule ViewOrder do
  @moduledoc """
  Views an order by reference.

  ## Generator Requirements

  Requires `order_ref` override - typically provided via Model's `with:`:

      {ViewOrder, with: fn s -> %{order_ref: StreamData.member_of(Map.keys(s.orders))} end}

  ## Expected Events

  Model's simulate/2 should return one of:
  - `[%OrderViewed{order_ref: ref}]` - if order exists
  - `[%OrderNotFound{order_ref: ref}]` - if order doesn't exist
  """

  defstruct [:order_ref]
  # ...
end
```

## Optional Command Callbacks

### `read_only?/0`

Mark commands that don't modify state (prioritized for removal during shrinking):

```elixir
def read_only?, do: true
```

### `downstream_observables/0`

Declare which event types this command can produce:

```elixir
def downstream_observables, do: [OrderCreated, OrderRejected]
```

### `label/2`

Provide human-readable labels for debugging:

```elixir
def label(_state, %__MODULE__{order_ref: ref}) do
  "view order #{inspect(ref)}"
end
```

### `semantics/0`

Declare execution semantics (`:sync`, `:probe`, `:async`, `:mock_config`):

```elixir
def semantics, do: :probe  # For read operations that may need retry/settle
```

## Summary

| Concern | Location |
|---------|----------|
| Struct fields | Command |
| Field generation | Command (`generator/1`) |
| Metadata | Command (optional callbacks) |
| When to enable | Model (`when:` option) |
| State-dependent params | Model (`with:` option) |
| Expected events | Simulator (`simulate/2` via `simulator/0`) |
| State shape | Model's projection |
