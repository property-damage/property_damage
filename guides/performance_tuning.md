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
| `check_mode` | atom | `:halt` | `:halt`, `:disabled`, `:record`, `:log` |

## Testing Profiles

### Smoke Test (CI fast, under 30 seconds)

```elixir
PropertyDamage.run(
  model: MyModel,
  targets: [MyAdapter],
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
  targets: [MyAdapter],
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
  targets: [MyAdapter],
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
| `granularity_threshold` | `pos_integer` | `8` | Sequence length at or below which hierarchical shrinking switches to linear. Linear is more thorough for short sequences; hierarchical is faster for long ones. |
| `max_iterations` | `pos_integer` | `1000` | Total shrink attempts before stopping. Higher values find more minimal reproductions. |
| `max_time_ms` | `pos_integer` | `30_000` | Time budget in milliseconds. Prevents shrinking from blocking CI indefinitely. |
| `shrink_arguments` | `boolean` | `true` | Run the argument-simplifying phase of each shrink cycle (the fourth phase below). Disable for faster shrinking when argument values are not relevant to the failure. |

### Shrinking Strategy

The shrinker first cuts the sequence after the failing command. It then runs a
cycle of four phases, each on what the previous phase left:

1. **Drop roots** -- Remove commands to find the minimal failing sequence.
   Removal is hierarchical (commands grouped by dependency depth) for sequences
   longer than `granularity_threshold`, then linear (one command at a time).

2. **Collapse the reference's expansions** -- For a model with `expansions/0`,
   collapse the reference target's expansions toward the command itself.

3. **Collapse the other targets' expansions** -- Collapse the other targets'
   expansions onto the reference's.

4. **Simplify arguments** -- Simplify the arguments of the remaining commands.
   Controlled by `shrink_arguments`.

The shrinker repeats the cycle until a whole cycle adopts no smaller candidate,
or until `max_iterations` or `max_time_ms` runs out. A model without
`expansions/0` has nothing to do in phases 2 and 3.

For slow adapters (e.g., real HTTP calls), limit shrinking time:

```elixir
shrinker_config: PropertyDamage.Shrinker.Config.new(
  max_time_ms: 10_000,
  max_iterations: 200,
  shrink_arguments: false
)
```

### Measuring Shrink Time

A shrink emits three telemetry events, so you can see where its time goes
before you tune its budget:

- `[:property_damage, :shrink, :start]` once, with `original_length` in the
  metadata.
- `[:property_damage, :shrink, :iteration]` for each candidate it tries. The
  measurements are `iteration` and `duration` (native time units); the
  metadata is `current_length` and `success`, whether the shrinker adopted the
  candidate.
- `[:property_damage, :shrink, :stop]` once. The measurements are `duration`
  (native time units), `iterations`, and three totals in milliseconds:
  `candidate_ms` (the time spent running candidates), and `setup_ms` and
  `teardown_ms` (the time your adapter's `setup/1` and `teardown/1` took
  across all candidates). The metadata is `original_length`, `shrunk_length`
  and `stop`, why the shrink ended.

If `setup_ms` and `teardown_ms` are most of `candidate_ms`, the shrink spends
its time bringing your system up and down, not running commands. Lowering
`max_iterations` or `max_time_ms` bounds that cost; making `setup/1` cheaper
reduces it.

<!-- pd-doc-verify: runnable -->
```elixir
test_pid = self()

:telemetry.attach(
  "shrink-timing",
  [:property_damage, :shrink, :stop],
  fn _event, measurements, _metadata, _config ->
    send(test_pid, {:shrink_timing, measurements})
  end,
  nil
)

PropertyDamage.Telemetry.shrink_stop(System.system_time(), %{
  iterations: 12,
  candidate_ms: 840.0,
  setup_ms: 600.0,
  teardown_ms: 120.0
})

receive do
  {:shrink_timing, m} ->
    IO.puts("adapter share: #{round((m.setup_ms + m.teardown_ms) / m.candidate_ms * 100)}%")
end

:telemetry.detach("shrink-timing")
```

## Scenario-Specific Models

Create focused models that bias generation toward specific behaviors. This is
more effective than increasing `max_runs` uniformly.

### Heavy Cancellation

```elixir
defmodule CancellationHeavyModel do
  use PropertyDamage.Model

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

### Transfer-Heavy Models

```elixir
defmodule TransferHeavyModel do
  use PropertyDamage.Model

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

Weight `Transfer` above the other commands and gate it on two accounts, so
generated sequences spend most of their length moving money between accounts.

## Conditional Generation with `overrides:`

Use the `overrides:` option to bias generated values based on current state. This
creates more realistic and targeted test scenarios.

```elixir
def commands do
  [
    {CreateAccount, weight: 1},
    {Deposit, weight: 2,
     when: &has_accounts?/1,
     overrides: fn state ->
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

The `overrides:` option takes a map, or a function that receives the current
projection state and returns a map. Each map entry replaces the command's default
generator for that field. An entry value is either a `StreamData` generator or a
plain value, which the framework turns into a constant generator.

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

## Check Mode

The `check_mode` option controls how check failures are handled:

```elixir
# Initial exploration -- skip checks, focus on crashes
PropertyDamage.run(model: M, targets: [A], check_mode: :disabled)

# Record all failures without stopping
PropertyDamage.run(model: M, targets: [A], check_mode: :record)

# Log as warnings -- useful for development
PropertyDamage.run(model: M, targets: [A], check_mode: :log)

# Stop on first failure (default) -- use for CI
PropertyDamage.run(model: M, targets: [A], check_mode: :halt)
```

Use `:disabled` during initial development to find crashes before adding
invariant checks. Switch to `:halt` for CI.

## Memory Considerations

Large sequences consume memory for event logs and projection state. Strategies
for managing memory:

- **Limit `max_commands`** -- 200 commands with complex events can consume
  significant memory. Start with 50 and increase only if needed.
- **Know what `:disabled` check mode saves** -- Every projection, check
  projections included, still folds every event, so `:disabled` does not
  reduce projection memory. It skips running the checks, which saves time.
- **Keep projection state lean** -- Store only what checks need. Avoid
  accumulating full event histories in projection state.
- **Focus with targeted models** -- A model with 3 commands at 100 runs finds
  bugs faster than a model with 20 commands at 1000 runs.

## Putting It Together

A typical CI configuration that balances speed and coverage:

```elixir
# test/property/order_property_test.exs
defmodule OrderPropertyTest do
  use ExUnit.Case, async: false
  use PropertyDamage.ExUnit

  @tag timeout: 120_000

  property_damage "order lifecycle properties",
    model: OrderModel,
    targets: [OrderAdapter],
    max_commands: 50,
    max_runs: 100,
    stutter: [probability: 0.1],
    shrinker_config:
      PropertyDamage.Shrinker.Config.new(
        max_time_ms: 15_000,
        max_iterations: 500
      )
end
```

`property_damage/2` fails the test with the failure report when `run/1` returns
`{:error, report}`. A test that calls `PropertyDamage.run/1` and ignores its
return value passes even when the SUT has a bug. If you call `run/1`
yourself, match on the result:

```elixir
case PropertyDamage.run(model: OrderModel, targets: [OrderAdapter]) do
  {:ok, _stats} -> :ok
  {:error, report} -> flunk(PropertyDamage.ExUnit.format_failure(report))
end
```
