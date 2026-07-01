# Writing Commands

Commands are semantic operations that can be executed against the System Under Test (SUT). They define WHAT can happen, while Adapters define HOW it happens against specific targets.

## Command Architecture

Commands follow a pure generator pattern - they are decoupled from state shape and reusable across different Models.

### Command Responsibilities

Commands define:
- **Struct fields** - The data needed for the operation
- **`generator/1`** - How to generate valid field values
- **Static metadata** - declared on the single `command_spec/1` surface (via `use`
  options): `execution`, `shrink`, `observables`, `idempotent`, ...

Commands do NOT define:
- When the command is valid (preconditions) - defined in Model via `when:`
- How to parameterize based on state - defined in Model via `with:`
- Expected events from execution - defined in Model via `simulate/2`

### Basic Command Example

```elixir
defmodule MyTest.Commands.CreateOrder do
  # Events this command can produce are declared on the command_spec surface.
  use PropertyDamage.Command, observables: [OrderCreated, OrderRejected]
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
end

# The corresponding event marks server-generated fields with external()
defmodule MyTest.Events.OrderCreated do
  import PropertyDamage, only: [external: 0]

  # order_id is server-generated, amount and currency come from the command
  defstruct [:amount, :currency, order_id: external()]
end
```

### State-Dependent Command Example

For commands that need state-dependent values (like selecting from existing refs):

```elixir
defmodule MyTest.Commands.ViewOrder do
  # Read-only commands set shrink: :prefer_remove so they are pruned first.
  use PropertyDamage.Command,
    shrink: :prefer_remove,
    observables: [OrderViewed, OrderNotFound]

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:order_ref]

  @impl true
  def generator(overrides \\ %{}) do
    # Default to nil - Model provides actual refs via with:
    %{order_ref: nil}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
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

## Server-Generated Values

When a command creates a new entity (e.g., CreateOrder produces an order with a
server-generated ID), the framework needs to pass that ID to future commands. The
`external()` marker solves this "chicken-and-egg" problem.

### Why Placeholders Exist

During sequence generation, the SUT hasn't been contacted yet — there are no real IDs.
The framework mints placeholders for server-generated fields and resolves them to real
values during execution.

### External Field Markers

Mark server-generated fields in event structs with `external()`:

    defmodule OrderCreated do
      import PropertyDamage, only: [external: 0]
      defstruct [:amount, :currency, id: external()]
    end

The framework detects external fields automatically and captures their values during
execution.

### Lifecycle

    Generation phase:
      CreateOrder{amount: 100}       →  OrderCreated{id: <placeholder>}
      GetOrder{order_ref: <placeholder>}

    Execution phase:
      CreateOrder{amount: 100}       →  OrderCreated{id: "ord_abc123"}
      GetOrder{order_ref: "ord_abc123"}  ← placeholder resolved from event

1. **Generation**: each `external()` field in a simulated event becomes a `%Placeholder{}`
2. **Simulation**: the simulator predicts events carrying those placeholders
3. **State tracking**: projections store the placeholder as a value
4. **Execution**: after the adapter returns (or injects) real events, the framework
   captures the concrete value from each `external()` field by the producer's position
5. **Resolution**: subsequent commands have their placeholder fields replaced with the
   concrete values

### Dependency-Aware Shrinking

The shrinker respects placeholder dependencies: if command A produces a value consumed by
command B, command A cannot be removed while B remains in the sequence.

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
  def command_sequence_projection, do: MyTest.OrderProjection
  def assertion_projections, do: []

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

  def command_sequence_projection, do: MyTest.OrderProjection
  def assertion_projections, do: []

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

## Static Metadata (`command_spec/1`)

A command's static metadata is declared once, on the `command_spec/1` surface,
authored via `use PropertyDamage.Command, <opts>`:

```elixir
use PropertyDamage.Command,
  execution: :probe,                       # :sync (default) | :probe | :async
  shrink: :prefer_remove,                   # read-only commands are pruned first
  observables: [OrderCreated, OrderRejected], # event types this command can produce
  idempotent: false,                        # exclude from stutter testing (default true)
  acceptable_retry_events: [OrderAlreadyExists] # acceptable alternative stutter responses
```

Each key has a sensible default, so you only declare what differs from the defaults.

## Optional Per-Instance Callbacks

These take the command and/or state, so they stay function callbacks rather than
static spec keys.

### `label/2`

Provide a human-readable label for a command instance:

```elixir
def label(_state, %__MODULE__{order_ref: ref}) do
  "view order #{inspect(ref)}"
end
```

The label is computed lazily when a failure report is built (never during
generation or passing runs), against the command's `command_sequence_projection`
pre-state. It is rendered next to the command in the failure report (terminal,
markdown, JSON) and as a comment in every exported reproduction (ExUnit, scripts,
Livebook), so a minimal repro reads like `# view order ...` next to the offending
step. Return `nil` (or omit the callback) for no label.

### `idempotency_key/1`

Return the idempotency key passed to the adapter during stutter testing.

### `awaits/2`

Declare which inbound (injector) events this command correlates. See
`PropertyDamage.Await`.

## Execution Semantics

Commands declare their execution mode via the `:execution` key of `command_spec/1`.
The execution mode determines how the framework handles the command during testing.

### Sync (default)

Synchronous commands mutate the SUT and complete immediately. The adapter's `execute/3`
is called once and events are recorded.

    use PropertyDamage.Command, execution: :sync

Most commands are sync. Use for operations like create, update, delete.

### Probe

Probes are read-only queries that verify SUT state without mutation. The framework
applies settle/retry logic — re-executing the probe until it succeeds or times out.

    use PropertyDamage.Command, execution: :probe, shrink: :prefer_remove,
      settle: %{timeout_ms: 5_000, interval_ms: 200, backoff: :exponential}

Key behaviors:
- Retried automatically according to settle configuration
- Prioritized for removal during shrinking (read-only commands rarely contribute to bugs)
- Do not mutate SUT state — safe to retry
- Use for verifying eventual consistency (e.g., "does the order appear in search results?")

### Async

Async commands create a resource and wait for it to settle. The adapter handles
internal polling, optionally injecting intermediate events via `runtime.inject`.

    use PropertyDamage.Command, execution: :async

Use for operations that return "processing" status and require polling for completion.
Async commands whose refs are used by downstream commands are protected during shrinking.

### Settle Configuration

Probes and async commands use settle configuration for retry behavior:

    settle: %{
      timeout_ms: 5_000,     # Max wait time (default: 2000)
      interval_ms: 200,       # Time between retries (default: 300)
      backoff: :exponential   # :linear (constant interval) or :exponential (doubling)
    }

With `:linear` backoff, retries happen at fixed intervals. With `:exponential`, the
interval doubles after each retry (capped at the timeout).

## Summary

| Concern | Location |
|---------|----------|
| Struct fields | Command |
| Field generation | Command (`generator/1`) |
| Static metadata | Command (`command_spec/1` / `use` options) |
| When to enable | Model (`when:` option) |
| State-dependent params | Model (`with:` option) |
| Expected events | Simulator (`simulate/2` via `simulator/0`) |
| State shape | Model's projection |
