# Performance Tuning

This guide covers tuning PropertyDamage for different testing scenarios -- from
fast CI smoke tests to thorough pre-release runs.

## Key Parameters

The main knobs in `PropertyDamage.run/1`:

| Option | Type | Default | Description |
|---|---|---|---|
| `max_commands` | `pos_integer` | `50` | Maximum commands per test sequence |
| `max_runs` | `pos_integer` | `100` | Number of test sequences to run |
| `seed` | `pos_integer` | random | Seed for reproducibility |
| `verbose` | `boolean` | `false` | Print progress and configuration |
| `shrink` | `boolean` | `true` | Shrink failing sequences |
| `assertion_mode` | atom | `:halt` | `:halt`, `:disabled`, `:record`, `:log` |

## Testing Profiles

### Smoke Test (CI fast, under 30 seconds)

```elixir
PropertyDamage.run(
  model: MyModel,
  adapter: MyAdapter,
  max_commands: 20,
  max_runs: 30,
  shrinker_config: PropertyDamage.Shrinker.Config.new(
    max_iterations: 100,
    max_time_ms: 5_000
  )
)
```

### Standard (CI full)

```elixir
PropertyDamage.run(
  model: MyModel,
  adapter: MyAdapter,
  max_commands: 50,
  max_runs: 100,
  shrinker_config: PropertyDamage.Shrinker.Config.new(
    max_iterations: 500,
    max_time_ms: 30_000
  )
)
```

### Thorough (pre-release)

```elixir
PropertyDamage.run(
  model: MyModel,
  adapter: MyAdapter,
  max_commands: 200,
  max_runs: 1000,
  shrinker_config: PropertyDamage.Shrinker.Config.new(
    max_iterations: 2000,
    max_time_ms: 120_000
  )
)
```

## Shrinking Configuration

The `PropertyDamage.Shrinker.Config` struct controls how aggressively the
framework minimizes failing sequences.

| Option | Type | Default | Description |
|---|---|---|---|
| `granularity_threshold` | `pos_integer` | `8` | Sequence length below which hierarchical shrinking switches to linear. Linear is more thorough for short sequences; hierarchical is faster for long ones. |
| `max_iterations` | `pos_integer` | `1000` | Total shrink attempts before stopping. Higher values find more minimal reproductions. |
| `max_time_ms` | `pos_integer` | `30_000` | Time budget in milliseconds. Prevents shrinking from blocking CI indefinitely. |
| `shrink_arguments` | `boolean` | `true` | Enable Phase 2 argument shrinking. Disable for faster shrinking when argument values are not relevant to the failure. |

### Shrinking Strategy

Shrinking proceeds in two phases:

1. **Sequence shrinking** -- Remove commands to find the minimal failing
   sequence. Uses hierarchical bisection for sequences longer than
   `granularity_threshold`, then switches to linear (one-at-a-time) removal.

2. **Argument shrinking** -- Simplify arguments within the minimal sequence.
   Controlled by `shrink_arguments`.

For slow adapters (e.g., real HTTP calls), limit shrinking time:

```elixir
shrinker_config: PropertyDamage.Shrinker.Config.new(
  max_time_ms: 10_000,
  max_iterations: 200,
  shrink_arguments: false
)
```

## Scenario-Specific Models

Create focused models that bias generation toward specific behaviors. This is
more effective than increasing `max_runs` uniformly.

### Heavy Cancellation

```elixir
defmodule CancellationHeavyModel do
  @behaviour PropertyDamage.Model

  def commands do
    [
      {CreateOrder, weight: 1},
      {CancelOrder, weight: 5, when: &has_orders?/1},
      {RefundOrder, weight: 3, when: &has_cancelled_orders?/1}
    ]
  end

  def command_sequence_projection, do: OrderState

  defp has_orders?(state), do: map_size(state.orders) > 0
  defp has_cancelled_orders?(state), do: Enum.any?(state.orders, fn {_, o} -> o.cancelled end)
end
```

### High Concurrency

```elixir
defmodule HighConcurrencyModel do
  @behaviour PropertyDamage.Model

  def commands do
    [
      {CreateAccount, weight: 1},
      {Deposit, weight: 2, when: &has_accounts?/1},
      {Transfer, weight: 3, when: &has_two_accounts?/1}
    ]
  end

  def command_sequence_projection, do: AccountState

  defp has_accounts?(state), do: map_size(state.accounts) > 0
  defp has_two_accounts?(state), do: map_size(state.accounts) >= 2
end
```

Run the concurrency-focused model with parallel branches:

```elixir
PropertyDamage.run(
  model: HighConcurrencyModel,
  adapter: AccountAdapter,
  branching: [max_branches: 3, max_branch_length: 5]
)
```

## Conditional Generation with `with:`

Use the `with:` option to bias generated values based on current state. This
creates more realistic and targeted test scenarios.

```elixir
def commands do
  [
    {CreateAccount, weight: 1},
    {Deposit, weight: 2,
     when: &has_accounts?/1,
     with: fn state ->
       if state.total_balance > 10_000 do
         # Small amounts when balance is high -- test near limits
         %{amount: StreamData.integer(1..100)}
       else
         # Larger amounts when balance is low -- build up state faster
         %{amount: StreamData.integer(100..5_000)}
       end
     end}
  ]
end
```

The `with:` function receives the current projection state and returns a map of
field overrides. Each override value is a `StreamData` generator that replaces
the command's default generator for that field.

## Command Weights for Coverage

Weights control the probability of selecting each command. Use them to ensure
rare but important code paths get tested:

```elixir
def commands do
  [
    # Setup commands -- low weight, needed to establish state
    {CreateUser, weight: 1},
    {CreateOrganization, weight: 1},

    # Core operations -- high weight, primary test targets
    {AddMember, weight: 5, when: &has_org_and_user?/1},
    {RemoveMember, weight: 5, when: &has_members?/1},

    # Edge cases -- moderate weight, ensures coverage
    {TransferOwnership, weight: 3, when: &has_multiple_members?/1},
    {DeleteOrganization, weight: 2, when: &has_org?/1}
  ]
end
```

Strategies:

- **Setup commands**: Low weight. They are only needed to build prerequisite
  state.
- **Target commands**: High weight. These exercise the behavior under test.
- **Edge case commands**: Moderate weight. Enough to appear regularly without
  dominating sequences.
- **Multiple models**: For distinct scenarios, create separate models rather
  than one model with many low-weight commands.

## Assertion Mode

The `assertion_mode` option controls how assertion failures are handled:

```elixir
# Initial exploration -- skip assertions, focus on crashes
PropertyDamage.run(model: M, adapter: A, assertion_mode: :disabled)

# Record all failures without stopping
PropertyDamage.run(model: M, adapter: A, assertion_mode: :record)

# Log as warnings -- useful for development
PropertyDamage.run(model: M, adapter: A, assertion_mode: :log)

# Stop on first failure (default) -- use for CI
PropertyDamage.run(model: M, adapter: A, assertion_mode: :halt)
```

Use `:disabled` during initial development to find crashes before adding
invariant checks. Switch to `:halt` for CI.

## Memory Considerations

Large sequences consume memory for event logs and projection state. Strategies
for managing memory:

- **Limit `max_commands`** -- 200 commands with complex events can consume
  significant memory. Start with 50 and increase only if needed.
- **Use `:disabled` assertion mode for exploration** -- Assertion projections
  maintain their own state. Disabling them during initial exploration reduces
  memory overhead.
- **Keep projection state lean** -- Store only what assertions need. Avoid
  accumulating full event histories in projection state.
- **Focus with targeted models** -- A model with 3 commands at 100 runs finds
  bugs faster than a model with 20 commands at 1000 runs.

## Putting It Together

A typical CI configuration that balances speed and coverage:

```elixir
# test/property/order_property_test.exs
defmodule OrderPropertyTest do
  use ExUnit.Case, async: false

  @tag timeout: 120_000

  test "order lifecycle properties" do
    PropertyDamage.run(
      model: OrderModel,
      adapter: OrderAdapter,
      max_commands: 50,
      max_runs: 100,
      branching: [max_branches: 2, max_branch_length: 3],
      stutter: [probability: 0.1],
      shrinker_config: PropertyDamage.Shrinker.Config.new(
        max_time_ms: 15_000,
        max_iterations: 500
      )
    )
  end
end
```
