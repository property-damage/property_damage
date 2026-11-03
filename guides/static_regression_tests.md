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

      # A no-op runtime handle for the now-required 3rd argument of execute/3.
      # When calling the adapter directly there is no framework to inject events
      # or start pollers, so both fields are no-ops.
      runtime = %PropertyDamage.Runtime{inject: fn _ -> :ok end, start_poller: fn _ -> nil end}

      try do
        # Execute commands and assert on return values
        {:ok, [%UserCreated{id: user_id, name: "alice"}]} =
          TestAdapter.execute(%CreateUser{name: "alice"}, adapter_ctx, runtime)

        # Chain commands using values from previous responses
        {:ok, [%UserUpdated{id: ^user_id, name: "alice_updated"}]} =
          TestAdapter.execute(%UpdateUser{id: user_id, name: "alice_updated"}, adapter_ctx, runtime)

        {:ok, [%UserDeleted{id: ^user_id}]} =
          TestAdapter.execute(%DeleteUser{id: user_id}, adapter_ctx, runtime)
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
- Cannot capture injected events (webhooks, callbacks): the `runtime` handle's
  `inject`/`start_poller` are no-ops here
- Must manually chain values between commands
- No automatic `external()` value resolution
- An adapter that writes log lines breaks when called directly (see below)

### Adapters that log

An adapter that calls `PropertyDamage.log/2` raises
`PropertyDamage.Log.NoScopeError` when a test calls it directly, because no run
has opened a log scope. Wrap the call in `PropertyDamage.Log.capture/1`. It opens
a scope, returns `{result, lines}`, and hands you the lines the adapter wrote:

```elixir
{{:ok, events}, lines} =
  PropertyDamage.Log.capture(fn ->
    TestAdapter.execute(%CreateUser{name: "alice"}, adapter_ctx, runtime)
  end)
```

An adapter that calls `PropertyDamage.Runtime.log/3` needs a runtime with a log
function. The hand-built runtime above has none (`log: nil`), so that call raises
`ArgumentError`, and `capture/1` does not change it. Use `PropertyDamage.execute/2`
for such an adapter.

## Approach 2: PropertyDamage.execute/2

When you need to capture **full SUT behavior** including injected events (webhooks,
async callbacks, etc.), use `PropertyDamage.execute/2`. This sets up the full event
infrastructure without requiring a model.

```elixir
defmodule MyApp.RegressionTest do
  use ExUnit.Case

  alias PropertyDamage
  alias PropertyDamage.Placeholder
  alias PropertyDamage.Sequence.Position
  alias MyApp.TestAdapter
  alias MyApp.WebhookInjectorAdapter
  alias MyApp.Commands.{CreatePayment, ConfirmPayment}
  alias MyApp.Events.{PaymentCreated, WebhookReceived}

  describe "payment webhook regression" do
    test "payment confirmation triggers webhook" do
      # CreatePayment produces a PaymentCreated event whose `payment_id` is
      # `external()` (server-generated). Build a placeholder for that producer
      # (command 0, its first event) and reuse it downstream; `PropertyDamage.execute/2`
      # captures the real value from that command's events and resolves it.
      payment_id = Placeholder.new_at(PaymentCreated, [:payment_id], Position.prefix(0), 0)

      commands = [
        %CreatePayment{amount: 1000, currency: "USD"},
        %ConfirmPayment{payment_id: payment_id}  # resolved to CreatePayment's id
      ]

      {:ok, events} = PropertyDamage.execute(commands,
        targets: [{TestAdapter,
          config: %{base_url: "http://localhost:4000"},
          injectors: [WebhookInjectorAdapter]
        }]
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
- Automatic `external()` value resolution across commands
- Full infrastructure setup (event queue, injector adapters)
- Works with existing adapters without modification

**Limitations:**
- More setup than direct adapter calls
- Slightly more complex checks

## Capturing Regression Test Sequences

When PropertyDamage finds a bug, it records what it found. Pick the capture that
matches how you want to replay it.

### From the Replay Artifact

Every failure writes a replay artifact, `<Model>_seed<n>.replay.exs`, into the
`replay_dir:` directory (default `property_damage_replays`). `<Model>` is the last
segment of the model's module name, so `MyApp.Model` gives
`Model_seed20.replay.exs`. The failure report ends with the call that replays it:

```elixir
PropertyDamage.run(
  model: MyModel,
  targets: [MyAdapter],
  only: [replay: "property_damage_replays/MyModel_seed3.replay.exs"]
)
```

The artifact records the setup commands and the commands of the shrunk failure, so
the replay generates nothing new. `targets:` must name the targets the artifact
records. See [Debugging Failures](debugging_failures.md) for the file
naming, the replay result and `shrink:` under replay.

To read the failure before you capture it, set `report_html: "some/dir"` (or the
`PD_REPORT_HTML` environment variable): a failing run then writes the report as an
HTML page into that directory.

### From a Failure Report, for execute/2

To keep a plain command list for `PropertyDamage.execute/2`, read the shrunk
sequence from the failure report:

```elixir
alias PropertyDamage.{FailureReport, Sequence}

{:error, report} = PropertyDamage.run(model: MyModel, targets: [MyAdapter])
sequence = FailureReport.shrunk_sequence(report)

commands =
  Sequence.setup_commands(sequence) ++
    Sequence.to_list(sequence) ++
    Sequence.teardown_commands(sequence)
```

`Sequence.to_list/1` returns the roots only (prefix, branches and suffix). The
model's `setup_each/0` and `teardown_each/0` commands live in separate fields of
the sequence, and `execute/2` runs exactly the list you give it. If you pass
`Sequence.to_list/1` alone, a model with `setup_each/0` loses its fixture commands.

A placeholder names the command that produces its value by position, and
`execute/2` captures a command's events under `Position.prefix(index)`, where
`index` is the command's place in the list you pass. After you prepend setup
commands, build each placeholder with the producer's new index.

### From Generated Test Code

PropertyDamage can generate regression test code from failures:

```elixir
{:error, failure} = PropertyDamage.run(model: M, targets: [A])

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

- `:targets` - A list with exactly one entry (required): the adapter module, or
  `{Module, config: map, injectors: [...]}`. `config:` is passed to
  `adapter.setup/1` (default: `%{}`). `execute/2` refuses `mocks:` on the entry and
  raises `NimbleOptions.ValidationError`; use `PropertyDamage.run/1` to run with
  mocks. It takes no other options, so `refs:` is rejected as an unknown option.
  To supply a server-minted value to a later command, build a placeholder with
  `PropertyDamage.Placeholder.new_at(event_module, path, position, event_index)`,
  as in Approach 2.

**Returns:**

- `{:ok, event_log}` - List of `EventLog.Entry` structs
- `{:error, %PropertyDamage.Failure{}}` - Adapter execution failed (an `:adapter_error`, whose `partial_events` hold the events captured before the error)
- `{:error, %PropertyDamage.Failure{type: %PropertyDamage.Failure.Setup{}}}` - Adapter setup failed

**Example:**

```elixir
{:ok, events} = PropertyDamage.execute(commands,
  targets: [{MyAdapter,
    config: %{base_url: "http://localhost:4000"},
    injectors: [WebhookAdapter]
  }]
)
```

## See Also

- [Debugging Failures](debugging_failures.md) - Understanding failure reports
- [Integration Testing](integration_testing.md) - Full integration test setup
- [Writing Commands](writing_commands.md) - Command patterns
