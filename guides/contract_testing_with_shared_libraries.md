# Contract Testing with Shared Libraries

This guide covers advanced patterns for building reusable, composable test libraries with PropertyDamage. These patterns enable:

- Domain libraries that define events and other plain structs without depending on PropertyDamage
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
│  │ - Commands: none (in the models)     │                    │
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

Pass the sentinel to each run with the `external_markers:` option. The option is the only way to name atom markers; there is no application config for it.

```elixir
PropertyDamage.run(
  model: OrderModel,
  targets: [OrderAdapter],
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

### Runtime Options (Per-Run)

```elixir
PropertyDamage.run(
  model: MyModel,
  targets: [MyAdapter],
  external_markers: [:__external__, :server_generated]
)
```

### What Marks a Field as External

The three sources do not rank. Each one decides a different kind of value, and a
field is external when any one of them says so:

- A `%PropertyDamage.External{}` struct is always a marker.
- An atom is a marker when it is in the `external_markers:` list.
- Any other value is a marker when its `PropertyDamage.ExternalMarker`
  implementation returns `true`.

## Saved Test Case Compatibility

PropertyDamage tracks dependency versions in saved `.pd` files to help catch compatibility issues.

### Saving Failures

When you save a failure, version metadata is automatically captured:

```elixir
{:error, failure} = PropertyDamage.run(model: M, targets: [A])
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
    # Versions match, safe to replay (the targets are taken from the report;
    # pass targets: [{Adapter, config: map}] if you need to override a setup config)
    PropertyDamage.Replay.run(report)

  {:ok, report, warnings} ->
    # Version mismatch detected
    IO.warn("Version warnings: #{inspect(warnings)}")
    # Warnings might include:
    # {:property_damage_version_mismatch, "0.2.0", "0.2.1"}
    # {:dependency_version_mismatch, :company_domain, "2.1.0", "2.2.0"}
    # {:dependency_missing, :old_domain, "1.0.0"}
    # {:struct_shape_drift, [:missing_field], [:unexpected_field]}

  {:error, reason} ->
    IO.puts("Failed to load: #{inspect(reason)}")
end
```

`PropertyDamage.Replay.run/2` takes no `external_markers:` option. A model that
names atom markers through `external_markers:` and also defines `expansions/0`
therefore cannot replay those values through `Replay`. Replay it with
`PropertyDamage.run/1`, passing `only: [replay: path]` and the same
`external_markers:`. An exported test carries no `external_markers:` either, so
add the option to it by hand. The model in this guide defines no
`expansions/0`, so this limit does not apply to it.

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
    {:property_damage, "~> 0.2"}
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
tests from the saved failures:

```elixir
File.mkdir_p!("test/regressions")

for path <- Path.wildcard("failures/*.pd") do
  report =
    case PropertyDamage.load_failure(path) do
      {:ok, report} -> report
      {:ok, report, warnings} ->
        IO.warn("#{path}: #{inspect(warnings)}")
        report
    end

  name = Path.basename(path, ".pd")

  # A file name such as `bug-123` or a name `save_failure/2` writes has
  # hyphens, which a module name cannot hold. Replace every character that is
  # not a letter or digit before camelizing.
  module_part = name |> String.replace(~r/[^A-Za-z0-9]/, "_") |> Macro.camelize()

  source =
    PropertyDamage.Export.to_exunit(report,
      module_name: Module.concat(["Regression#{module_part}Test"])
    )

  File.write!(Path.join("test/regressions", "#{name}_test.exs"), source)
end
```

`Export.to_exunit/2` returns the test source as a string and writes nothing, so
the loop writes each string to a file itself. A file that loads with version
warnings is still exported; the loop prints the warnings so you can decide
whether to keep that test.

Regenerating rewrites the test text only. When the report has a replay artifact,
the generated test names that file by path, and regenerating does not refresh
the structs inside it. If an upgrade removes or renames a field of a command
struct, the artifact no longer loads: `only: [replay: path]` raises
`ArgumentError` with "cannot hold its fields". The artifact is not migrated.
Run the property again until it fails under the new structs, which writes a new
artifact, then export that failure again.

A `.pd` file has its own check. After a PropertyDamage upgrade that changes the
persistence version, `Persistence.load/1` refuses a file from an older version
with `{:error, {:unsupported_format_version, file_version, current}}` and a file
from a newer version with `{:error, {:incompatible_version, file_version,
current}}`. The loop above then raises `CaseClauseError` on that `{:error, _}`
return. Capture the failure again under the current version.

### Strategy 4: Local Seed Library

The seed library is an ephemeral, self-pruning working set of recently failing
seeds. It is a local replay aid, not something to share or commit across teams:
a seed reproduces its sequence only while the model's generators are
byte-stable, so it is a fragile, version-local pointer.

Enable it with the `seed_library:` option of `PropertyDamage.run/1`. The run
replays the library's seeds before random exploration and appends the seed of
any new failure:

```elixir
# Default file `property_damage_seeds.json`:
PropertyDamage.run(model: OrderModel, targets: [adapter], seed_library: true)

# Or an explicit file:
PropertyDamage.run(model: OrderModel, targets: [adapter], seed_library: "seeds.json")
```

Each entry is pruned after it passes enough consecutive replays (the
`seed_library_prune_after` option sets the threshold). To keep a regression,
export the failure to an ExUnit test (Strategy 3). If the report has a replay
artifact, the exported test replays that file by path. It runs the commands the
file records, so a generator change does not alter them, as long as you keep the
file. Without an artifact, the test re-runs the report's seed, and a generator
change can send that seed down a different sequence.

## Complete Example

### Domain Library (company_domain)

<!-- pd-doc-verify: runnable -->
```elixir
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

# lib/company_domain/events/order_shipped.ex
defmodule CompanyDomain.Events.OrderShipped do
  defstruct [:order_id]
end
```

### Model Library (order_model)

The domain library holds events only. Commands are PropertyDamage behaviours
(`use PropertyDamage.Command`), so they belong to the model library, which owns
the only `CreateOrder` and `ShipOrder` structs. The adapter matches on those.
The **shared contract surface is the event struct**
(`CompanyDomain.Events.OrderCreated`): it flows through the projection and the
adapter without either side depending on PropertyDamage.

The example has two commands so that it shows a server-generated id chaining:
the server mints the order `id` when it handles `CreateOrder`, and `ShipOrder`
must carry that same id. The model offers `ShipOrder` only after an order
exists, takes its `order_id` from the projection state, and implements
`PropertyDamage.Model.Simulator` so the run can predict each command's events
before the server answers.

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

# lib/order_model/commands/ship_order.ex
defmodule OrderModel.Commands.ShipOrder do
  use PropertyDamage.Command

  defstruct [:order_id]

  @impl true
  def generator(overrides \\ %{}) do
    # The model overrides order_id with an id from the projection state.
    %{order_id: StreamData.constant(nil)}
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

  @check every: OrderCreated
  def assert_orders_have_valid_amount(state, _event) do
    Enum.all?(state.orders, fn {_id, o} -> o.amount > 0 end) or
      PropertyDamage.fail!("All orders must have positive amounts")
  end
end

# lib/order_model.ex
defmodule OrderModel do
  use PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias CompanyDomain.Events.{OrderCreated, OrderShipped}
  alias OrderModel.Commands.{CreateOrder, ShipOrder}
  alias OrderModel.Projections.{OrderState, OrderInvariants}

  @impl true
  def commands do
    [
      {CreateOrder, weight: 1},
      {ShipOrder,
       weight: 2,
       when: fn state -> map_size(state.orders) > 0 end,
       overrides: fn state -> %{order_id: StreamData.member_of(Map.keys(state.orders))} end}
    ]
  end

  @impl true
  def command_sequence_projection, do: OrderState

  @impl true
  def check_projections, do: [OrderInvariants]

  @impl true
  def simulator, do: __MODULE__

  # The id and created_at keep their :__external__ default: the server mints them.
  @impl true
  def simulate(%CreateOrder{} = cmd, _state) do
    [%OrderCreated{customer_id: cmd.customer_id, amount: cmd.amount, currency: cmd.currency}]
  end

  def simulate(%ShipOrder{order_id: id}, _state), do: [%OrderShipped{order_id: id}]
end
```

### Test Project

```elixir
# test/order_test.exs
defmodule OrderTest do
  use ExUnit.Case

  test "orders maintain valid state" do
    # The run replays the seeds in the seed library file before it explores,
    # and appends the seed of a new failure to that file. The run creates the
    # seeds/ directory if it is missing. If the write still fails, the run logs
    # a warning with the path and the reason, whatever verbose: says.
    result = PropertyDamage.run(
      model: OrderModel,
      targets: [OrderHttpAdapter],
      external_markers: [:__external__],
      max_runs: 100,
      max_commands: 20,
      seed_library: "seeds/order_seeds.json",
      regression: [save_failures: "failures/"]
    )

    assert match?({:ok, _}, result)
  end
end

# lib/order_http_adapter.ex
# Uses HTTPoison as the HTTP client; add {:httpoison, "~> 2.0"} to your deps.
defmodule OrderHttpAdapter do
  use PropertyDamage.Adapter

  alias OrderModel.Commands.{CreateOrder, ShipOrder}
  alias CompanyDomain.Events.{OrderCreated, OrderShipped}

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

  def execute(%ShipOrder{order_id: id}, ctx, _runtime) do
    response = HTTPoison.post!("#{ctx.base_url}/orders/#{id}/ship", "")

    case response.status_code do
      200 -> {:ok, [%OrderShipped{order_id: id}]}
      status -> {:error, {:http_error, status}}
    end
  end

  def teardown(_ctx), do: :ok
end
```

## Best Practices

1. **Use consistent markers**: Pick one sentinel (`:__external__`) and use it across all domain libraries.

2. **Document markers**: Add `@moduledoc` explaining that fields with the marker are server-generated.

3. **Version your domain library**: Follow semantic versioning. Bump the version when struct definitions change.

4. **Regenerate tests after struct changes, then refresh the artifacts**: When you change event or command struct fields, regenerate the affected tests. Regenerating rewrites the test text only; if a changed struct makes a replay artifact refuse to load, run the property to a fresh failure and export again.

5. **Use load! in CI**: Strict loading catches version mismatches early in the CI pipeline.

6. **Export durable regressions, don't commit seed libraries**: The seed library is an ephemeral, self-pruning replay working set (seeds only reproduce while generators are byte-stable). To keep a regression, export the failure to an ExUnit test. With a replay artifact, the test replays the recorded commands by file path, so keep that file; without one, it re-runs the seed, which a generator change can send down a different sequence.
