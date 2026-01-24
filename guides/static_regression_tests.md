# Static Regression Tests

PropertyDamage is designed for stateful property-based testing, but sometimes you need
static regression tests that run a specific command sequence. This guide covers two
approaches for creating regression tests from discovered failures.

## The Problem: Model Drift

Stateful property-based tests evolve over time. As your model expands to cover more
behaviors, the generated sequences change. This creates "model drift" where regression
tests may fail due to model changes, not actual SUT bugs.

For regression tests that need to verify **specific** sequences don't break, you need
a model-free approach.

## When to Use Each Approach

| Approach | Use When |
|----------|----------|
| Direct Adapter Calls | Asserting on command return values only |
| `PropertyDamage.execute/2` | Capturing full SUT behavior including injected events |

## Approach 1: Direct Adapter Calls

When you only need to assert on **command return values** (the events returned directly
by the adapter), call the adapter directly. This is the simplest approach for basic
regression tests.

```elixir
defmodule MyApp.RegressionTest do
  use ExUnit.Case

  alias MyApp.TestAdapter
  alias MyApp.Commands.{CreateUser, UpdateUser, DeleteUser}
  alias MyApp.Events.{UserCreated, UserUpdated, UserDeleted}

  describe "user lifecycle regression" do
    test "creating and deleting a user returns expected events" do
      # Setup adapter directly
      {:ok, adapter_ctx} = TestAdapter.setup(%{base_url: "http://localhost:4000"})

      try do
        # Execute commands and assert on return values
        {:ok, [%UserCreated{id: user_id, name: "alice"}]} =
          TestAdapter.execute(%CreateUser{name: "alice"}, adapter_ctx)

        # Chain commands using values from previous responses
        {:ok, [%UserUpdated{id: ^user_id, name: "alice_updated"}]} =
          TestAdapter.execute(%UpdateUser{id: user_id, name: "alice_updated"}, adapter_ctx)

        {:ok, [%UserDeleted{id: ^user_id}]} =
          TestAdapter.execute(%DeleteUser{id: user_id}, adapter_ctx)
      after
        TestAdapter.teardown(adapter_ctx)
      end
    end
  end
end
```

**Advantages:**
- Simple and direct
- No framework overhead
- Easy to understand and debug

**Limitations:**
- Cannot capture injected events (webhooks, callbacks)
- Must manually chain values between commands
- No automatic ref resolution

## Approach 2: PropertyDamage.execute/2

When you need to capture **full SUT behavior** including injected events (webhooks,
async callbacks, etc.), use `PropertyDamage.execute/2`. This sets up the full event
infrastructure without requiring a model.

```elixir
defmodule MyApp.RegressionTest do
  use ExUnit.Case

  alias PropertyDamage
  alias MyApp.TestAdapter
  alias MyApp.WebhookInjectorAdapter
  alias MyApp.Commands.{CreatePayment, ConfirmPayment}
  alias MyApp.Events.{PaymentCreated, WebhookReceived}

  describe "payment webhook regression" do
    test "payment confirmation triggers webhook" do
      commands = [
        %CreatePayment{amount: 1000, currency: "USD"},
        %ConfirmPayment{payment_id: {:ref, :payment_id}}  # Uses ref from first command
      ]

      {:ok, events} = PropertyDamage.execute(commands,
        adapter: TestAdapter,
        injector_adapters: [WebhookInjectorAdapter],
        adapter_config: %{base_url: "http://localhost:4000"}
      )

      # Assert on command events
      assert Enum.any?(events, fn entry ->
        entry.source == :command and
        match?(%PaymentCreated{amount: 1000}, entry.event)
      end)

      # Assert on injected webhook events
      assert Enum.any?(events, fn entry ->
        entry.source == :injector and
        match?(%WebhookReceived{payload: %{"status" => "confirmed"}}, entry.event)
      end)
    end
  end
end
```

**Advantages:**
- Captures all events including injector events
- Automatic ref resolution across commands
- Full infrastructure setup (event queue, injector adapters)
- Works with existing adapters without modification

**Limitations:**
- More setup than direct adapter calls
- Slightly more complex assertions

## Capturing Regression Test Sequences

When PropertyDamage finds a bug, the failure report contains the shrunk sequence.
Here's how to extract it for a regression test:

### From a Failure Report

```elixir
# Run property test
{:error, failure} = PropertyDamage.run(
  model: MyModel,
  adapter: MyAdapter,
  on_failure: fn report ->
    # Log the shrunk sequence for later use
    IO.puts("Shrunk sequence:")
    IO.inspect(Sequence.to_list(report.shrunk_sequence))
  end
)

# Or programmatically extract the sequence
commands = PropertyDamage.Sequence.to_list(failure.shrunk_sequence)
```

### From Generated Test Code

PropertyDamage can generate regression test code from failures:

```elixir
{:error, failure} = PropertyDamage.run(model: M, adapter: A)

# Generate ExUnit test code
test_code = PropertyDamage.generate_test(failure, format: :exunit)
IO.puts(test_code)
```

## Best Practices

### 1. Keep Regression Tests Focused

Each regression test should verify one specific bug fix. Don't combine multiple
failure scenarios into a single test.

### 2. Document the Original Bug

Include comments explaining what bug the regression test catches:

```elixir
test "regression: payment with zero amount caused divide-by-zero" do
  # Bug found 2024-01-15, seed: 512902757
  # Zero-amount payments caused division by zero in fee calculation
  commands = [%CreatePayment{amount: 0}]
  # ...
end
```

### 3. Use Descriptive Test Names

Name tests based on the behavior they verify, not the bug number:

```elixir
# Good
test "zero-amount payments return validation error"

# Less helpful
test "bug_1234_regression"
```

### 4. Consider Test Maintenance

As your SUT evolves, regression tests may need updates. Keep them simple enough
to maintain but complete enough to catch the original bug.

## API Reference

### PropertyDamage.execute/2

Execute a fixed command sequence without a model.

**Options:**

- `:adapter` - Adapter module (required)
- `:injector_adapters` - List of injector adapter modules (default: `[]`)
- `:adapter_config` - Config passed to `adapter.setup/1` (default: `%{}`)
- `:refs` - Initial ref resolution map (default: `%{}`)

**Returns:**

- `{:ok, event_log}` - List of `EventLog.Entry` structs
- `{:error, {:adapter_error, reason, partial_events}}` - Adapter execution failed
- `{:error, {:adapter_setup_failed, reason}}` - Adapter setup failed

**Example:**

```elixir
{:ok, events} = PropertyDamage.execute(commands,
  adapter: MyAdapter,
  injector_adapters: [WebhookAdapter],
  adapter_config: %{base_url: "http://localhost:4000"}
)
```

## See Also

- [Debugging Failures](debugging_failures.md) - Understanding failure reports
- [Integration Testing](integration_testing.md) - Full integration test setup
- [Writing Commands](writing_commands.md) - Command and ref patterns
