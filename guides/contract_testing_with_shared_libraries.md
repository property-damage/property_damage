# Contract Testing with Shared Libraries

This guide covers advanced patterns for building reusable, composable test libraries with PropertyDamage. These patterns enable:

- Domain libraries that define commands/events without depending on PropertyDamage
- Model libraries that compose domain concepts into testable specifications
- Version tracking for reproducible test failures

## Architecture Overview

A mature PropertyDamage setup typically has three layers:

```
┌─────────────────────────────────────────────────────────────┐
│  Test Projects                                               │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │ Payment Tests   │  │ Inventory Tests │                   │
│  │ - Adapters      │  │ - Adapters      │                   │
│  │ - Run config    │  │ - Run config    │                   │
│  └────────┬────────┘  └────────┬────────┘                   │
│           │                    │                             │
├───────────┼────────────────────┼─────────────────────────────┤
│  Model Libraries               │                             │
│  ┌────────┴────────┐  ┌───────┴────────┐                    │
│  │ PaymentModel    │  │ InventoryModel │                    │
│  │ - Projections   │  │ - Projections  │                    │
│  │ - Commands      │  │ - Commands     │                    │
│  │ - Invariants    │  │ - Invariants   │                    │
│  └────────┬────────┘  └───────┬────────┘                    │
│           │                   │                              │
├───────────┼───────────────────┼──────────────────────────────┤
│  Domain Library (company_domain)                             │
│  ┌────────┴───────────────────┴────────┐                    │
│  │ Pure Elixir structs                  │                    │
│  │ - Events: PaymentAuthorized, etc.    │                    │
│  │ - Commands: AuthorizePayment, etc.   │                    │
│  │ - NO PropertyDamage dependency       │                    │
│  └──────────────────────────────────────┘                    │
└─────────────────────────────────────────────────────────────┘
```

**Key principle**: Domain libraries define WHAT (the domain vocabulary), PropertyDamage-aware libraries define HOW (testing behavior). This separation enables:

- Same domain definitions across different SUT implementations
- Domain libraries usable in production code (no test dependencies)
- Multiple test approaches for the same domain

## Defining External Markers

When domain libraries don't depend on PropertyDamage, they can't use `external()` to mark server-generated fields. Instead, use atom sentinels.

### In the Domain Library

```elixir
# In company_domain (no PropertyDamage dependency)
defmodule CompanyDomain.Events.OrderCreated do
  @moduledoc "Event emitted when an order is created"

  @typedoc "Server-generated unique identifier"
  @type id :: String.t()

  # Use :__external__ as a sentinel for server-generated fields
  defstruct [
    id: :__external__,
    customer_id: nil,
    amount: nil,
    currency: nil,
    created_at: :__external__
  ]
end

defmodule CompanyDomain.Events.PaymentProcessed do
  defstruct [
    payment_id: :__external__,
    transaction_ref: :__external__,
    order_id: nil,
    amount: nil,
    status: nil
  ]
end
```

### In the Test Project

Configure PropertyDamage to recognize your sentinel:

```elixir
# In config/test.exs (applies to all tests)
config :property_damage, external_markers: [:__external__]

# Or per-test (overrides + combines with config)
PropertyDamage.run(
  model: OrderModel,
  adapter: OrderAdapter,
  external_markers: [:__external__]
)
```

### Using a Protocol (Advanced)

For more control, define a custom marker type:

```elixir
# In company_domain
defmodule CompanyDomain.ServerGenerated do
  @moduledoc "Marker for server-generated fields"
  defstruct [:description]

  def new(description \\ nil), do: %__MODULE__{description: description}
end

# In a test support library that depends on both
defimpl PropertyDamage.ExternalMarker, for: CompanyDomain.ServerGenerated do
  def external?(_), do: true
end

# Usage in domain library
defmodule CompanyDomain.Events.OrderCreated do
  alias CompanyDomain.ServerGenerated

  defstruct [
    id: ServerGenerated.new("unique order ID"),
    customer_id: nil,
    amount: nil
  ]
end
```

## Configuration Options

### App Config (Global)

```elixir
# config/test.exs
config :property_damage,
  external_markers: [:__external__, :server_generated]
```

### Runtime Options (Per-Test)

```elixir
PropertyDamage.run(
  model: MyModel,
  adapter: MyAdapter,
  external_markers: [:__external__]  # Combined with app config
)
```

### Priority

External marker recognition follows this priority:
1. `%PropertyDamage.External{}` struct (always recognized)
2. Protocol implementations
3. Explicit `:external_markers` option
4. App config `:external_markers`

## Saved Test Case Compatibility

PropertyDamage tracks dependency versions in saved `.pd` files to help catch compatibility issues.

### Saving Failures

When you save a failure, version metadata is automatically captured:

```elixir
{:error, failure} = PropertyDamage.run(model: M, adapter: A)
{:ok, path} = PropertyDamage.Persistence.save(failure, "failures/")
```

The saved file includes:
- PropertyDamage version
- Elixir version
- Versions of applications containing command/event structs

### Loading with Version Warnings

```elixir
case PropertyDamage.Persistence.load("failures/bug-123.pd") do
  {:ok, report} ->
    # Versions match, safe to replay (the adapter is taken from the report;
    # pass adapter_config: if you need to override its setup config)
    PropertyDamage.Replay.run(report)

  {:ok, report, warnings} ->
    # Version mismatch detected
    IO.warn("Version warnings: #{inspect(warnings)}")
    # Warnings might include:
    # {:property_damage_version_mismatch, "1.0.0", "1.1.0"}
    # {:dependency_version_mismatch, :company_domain, "2.1.0", "2.2.0"}
    # {:dependency_missing, :old_domain, "1.0.0"}

  {:error, reason} ->
    IO.puts("Failed to load: #{inspect(reason)}")
end
```

### Strict Loading

For CI environments where version mismatches should fail:

```elixir
# Raises ArgumentError on any version mismatch
report = PropertyDamage.Persistence.load!("failures/bug-123.pd")
```

## Version Coordination Strategies

### Strategy 1: Pin Versions in CI

Lock dependency versions in your CI environment:

```elixir
# mix.exs
defp deps do
  [
    {:company_domain, "~> 2.1.0"},  # Pin to specific version
    {:property_damage, "~> 1.0"}
  ]
end
```

### Strategy 2: Version Matrix Testing

Test against multiple versions:

```yaml
# .github/workflows/test.yml
matrix:
  domain_version: ["2.0.0", "2.1.0", "2.2.0"]
```

### Strategy 3: Regenerate on Upgrade

When upgrading dependencies that change struct definitions, regenerate ExUnit
tests from the saved failures with the current struct versions:

```elixir
for path <- Path.wildcard("failures/*.pd") do
  {:ok, report} = PropertyDamage.load_failure(path)
  PropertyDamage.generate_test(report, format: :exunit)
end
```

### Strategy 4: Shared Seed Library

Use a seed library to track known-interesting seeds:

```elixir
# load/1 returns {:error, :enoent} when the file does not exist yet, so start a
# fresh library on the first run:
library =
  case PropertyDamage.SeedLibrary.load("seeds.json") do
    {:ok, lib} -> lib
    {:error, :enoent} -> PropertyDamage.SeedLibrary.new()
  end

# Add a new failure (captures dependency versions automatically)
{:ok, library} = PropertyDamage.SeedLibrary.add(library, failure,
  tags: [:currency_bug],
  description: "Mismatch when capturing with different currency"
)

PropertyDamage.SeedLibrary.save(library, "seeds.json")
```

The seed library tracks `dependency_versions` for each entry, helping identify which seeds may need re-validation after upgrades.

## Complete Example

### Domain Library (company_domain)

<!-- pd-doc-verify: runnable -->
```elixir
# lib/company_domain/commands/create_order.ex
defmodule CompanyDomain.Commands.CreateOrder do
  defstruct [:customer_id, :amount, :currency]
end

# lib/company_domain/events/order_created.ex
defmodule CompanyDomain.Events.OrderCreated do
  defstruct [
    id: :__external__,
    customer_id: nil,
    amount: nil,
    currency: nil,
    created_at: :__external__
  ]
end
```

### Model Library (order_model)

The command and projection modules live in `order_model` and implement the
PropertyDamage behaviours. The **shared contract surface is the event struct**
(`CompanyDomain.Events.OrderCreated`): it flows through the projection and the
adapter without either side depending on PropertyDamage.

<!-- pd-doc-verify: runnable -->
```elixir
# lib/order_model/commands/create_order.ex
defmodule OrderModel.Commands.CreateOrder do
  use PropertyDamage.Command

  defstruct [:customer_id, :amount, :currency]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      customer_id: StreamData.string(:alphanumeric, min_length: 8),
      amount: StreamData.positive_integer(),
      currency: StreamData.member_of(["USD", "EUR", "GBP"])
    }
    |> PropertyDamage.Generator.merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

# lib/order_model/projections/order_state.ex
defmodule OrderModel.Projections.OrderState do
  use PropertyDamage.Model.Projection

  # OrderCreated is the shared struct from company_domain
  alias CompanyDomain.Events.OrderCreated

  @impl true
  def init, do: %{orders: %{}}

  @impl true
  def apply(state, %OrderCreated{} = event) do
    put_in(state, [:orders, event.id], %{
      customer_id: event.customer_id,
      amount: event.amount,
      currency: event.currency
    })
  end

  def apply(state, _), do: state
end

# lib/order_model/projections/order_invariants.ex
defmodule OrderModel.Projections.OrderInvariants do
  use PropertyDamage.Model.Projection

  alias CompanyDomain.Events.OrderCreated

  @impl true
  def init, do: %{orders: %{}}

  @impl true
  def apply(state, %OrderCreated{} = event) do
    put_in(state, [:orders, event.id], %{amount: event.amount})
  end

  def apply(state, _), do: state

  @trigger every: OrderCreated
  def assert_orders_have_valid_amount(state, _event) do
    unless Enum.all?(state.orders, fn {_id, o} -> o.amount > 0 end) do
      PropertyDamage.fail!("All orders must have positive amounts")
    end
  end
end

# lib/order_model.ex
defmodule OrderModel do
  @behaviour PropertyDamage.Model

  alias OrderModel.Commands.CreateOrder
  alias OrderModel.Projections.{OrderState, OrderInvariants}

  @impl true
  def commands, do: [{CreateOrder, weight: 1}]

  @impl true
  def command_sequence_projection, do: OrderState

  @impl true
  def assertion_projections, do: [OrderInvariants]
end
```

### Test Project

```elixir
# config/test.exs
config :property_damage, external_markers: [:__external__]

# test/order_test.exs
defmodule OrderTest do
  use ExUnit.Case

  test "orders maintain valid state" do
    result = PropertyDamage.run(
      model: OrderModel,
      adapter: OrderHttpAdapter,
      max_runs: 100,
      max_commands: 20,
      regression: [
        save_failures: "failures/",
        seed_library: "seeds/order_seeds.json"
      ]
    )

    assert match?({:ok, _}, result)
  end
end

# lib/order_http_adapter.ex
# Uses HTTPoison as the HTTP client; add {:httpoison, "~> 2.0"} to your deps.
defmodule OrderHttpAdapter do
  use PropertyDamage.Adapter

  def setup(_config) do
    {:ok, %{base_url: "http://localhost:4000"}}
  end

  def execute(%CreateOrder{} = cmd, ctx, _runtime) do
    response = HTTPoison.post!(
      "#{ctx.base_url}/orders",
      Jason.encode!(%{
        customer_id: cmd.customer_id,
        amount: cmd.amount,
        currency: cmd.currency
      }),
      [{"content-type", "application/json"}]
    )

    case response.status_code do
      201 ->
        body = Jason.decode!(response.body)
        {:ok, [%OrderCreated{
          id: body["id"],
          customer_id: cmd.customer_id,
          amount: cmd.amount,
          currency: cmd.currency,
          created_at: body["created_at"]
        }]}

      status ->
        {:error, {:http_error, status}}
    end
  end

  def teardown(_ctx), do: :ok
end
```

## Best Practices

1. **Use consistent markers**: Pick one sentinel (`:__external__`) and use it across all domain libraries.

2. **Document markers**: Add `@moduledoc` explaining that fields with the marker are server-generated.

3. **Version your domain library**: Follow semantic versioning. Bump the version when struct definitions change.

4. **Regenerate tests after struct changes**: When you change event/command struct fields, regenerate affected saved tests.

5. **Use load! in CI**: Strict loading catches version mismatches early in the CI pipeline.

6. **Export durable regressions, don't commit seed libraries**: The seed library is an ephemeral, self-pruning replay working set (seeds only reproduce while generators are byte-stable). To keep a regression, export the failure to an ExUnit test, which freezes the concrete shrunk sequence and survives generator changes.
