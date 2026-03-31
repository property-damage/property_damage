# Debugging Failures

When PropertyDamage finds a failing sequence, it provides powerful tools for
understanding and fixing the bug. This guide covers the debugging workflow.

## The Failure Report

When a test fails, PropertyDamage returns a failure report:

```elixir
{:error, failure} = PropertyDamage.run(
  model: MyModel,
  adapter: MyAdapter,
  max_runs: 100
)

IO.inspect(failure, label: "Failure")
```

The report includes:
- **seed** - Random seed for reproducibility
- **original_sequence** - Full command sequence that failed
- **shrunk_sequence** - Minimal reproduction (after shrinking)
- **shrink_info** - How much shrinking reduced the sequence
- **invariant_violated** - Which check failed
- **error_message** - Description of the failure
- **state_at_failure** - Model state when failure occurred

## Step 1: Reproduce the Failure

Use the seed to reproduce exactly:

```elixir
# Run with the same seed
result = PropertyDamage.run(
  model: MyModel,
  adapter: MyAdapter,
  seed: failure.seed
)
```

## Step 2: Understand the Shrunk Sequence

The shrunk sequence is the minimal reproduction. Every command in it is
necessary for the failure:

```elixir
# Print the shrunk sequence
failure.shrunk_sequence
|> Enum.with_index()
|> Enum.each(fn {cmd, idx} ->
  IO.puts("[#{idx}] #{inspect(cmd)}")
end)
```

Example output:

```
[0] CreateAccount{currency: "USD", initial_balance: 1000}
[1] CreateAuthorization{account_ref: @0, amount: 500}
[2] CreateCapture{authorization_ref: @1, amount: 600}
```

## Step 3: Explain the Sequence

Use `explain/1` to understand why each command matters:

```elixir
explanation = PropertyDamage.explain(failure)
IO.puts(explanation)
```

Output:

```
Command Analysis:

[0] CreateAccount{currency: "USD", initial_balance: 1000}
    Required: Creates the account referenced by later commands
    State change: Adds account with $10.00 balance

[1] CreateAuthorization{account_ref: @0, amount: 500}
    Required: Creates authorization referenced by capture
    State change: Holds $5.00 on account

[2] CreateCapture{authorization_ref: @1, amount: 600}
    Fails because: Capture exceeds authorization amount
    Expected: Capture should fail or be limited to $5.00
    Actual: Capture of $6.00 succeeded
```

## Step 4: Step-by-Step Replay

Replay the sequence step by step to observe state changes:

```elixir
{:ok, replay} = PropertyDamage.Replay.step_through(failure)

replay.steps
|> Enum.each(fn step ->
  IO.puts("=== Step #{step.index} ===")
  IO.puts("Command: #{inspect(step.command)}")
  IO.puts("Events: #{inspect(step.events)}")
  IO.puts("State after: #{inspect(step.state_after)}")
  IO.puts("")
end)
```

## Step 5: Isolate the Trigger

Find the specific field/value that causes the failure:

```elixir
{:ok, trigger} = PropertyDamage.isolate_trigger(failure)

IO.puts("Trigger: #{inspect(trigger)}")
# => %{command_index: 2, field: :amount, value: 600, threshold: 500}
```

## Step 6: Visual Debugging

### Sequence Diagrams

Generate visual diagrams of the failing sequence:

```elixir
# Mermaid diagram
diagram = PropertyDamage.Diagram.to_mermaid(failure)
File.write!("failure.mmd", diagram)

# PlantUML diagram
diagram = PropertyDamage.Diagram.to_plantuml(failure)
File.write!("failure.puml", diagram)
```

### Diff Debugging

Compare a passing run with the failing run:

```elixir
# Get a passing trace
{:ok, passing} = PropertyDamage.run(
  model: MyModel,
  adapter: MyAdapter,
  seed: 12345  # A known good seed
)

# Compare traces
diff = PropertyDamage.Diff.compare_traces(passing.trace, failure.trace)
IO.puts(PropertyDamage.Diff.format(diff, :terminal))
```

Output highlights where traces diverge:

```
Step 2: CreateCapture
  Passing: {:error, :exceeds_authorization}
  Failing: {:ok, [%CaptureCreated{amount: 600}]}
           ^^^^ BUG: Should have rejected
```

## Step 7: Livebook Exploration

For interactive debugging, use Livebook:

```elixir
alias PropertyDamage.Livebook

# Interactive failure explorer
Livebook.explore_failure(failure)

# Step through with UI controls
Livebook.command_stepper(failure)

# Compare expected vs actual state
Livebook.state_diff(failure)
```

## Step 8: Export for Sharing

### Generate ExUnit Test

Create a regression test:

```elixir
test_code = PropertyDamage.Export.to_exunit(failure)
File.write!("test/regression/capture_overflow_test.exs", test_code)
```

### Generate Reproduction Script

```elixir
# Curl script for API testing
script = PropertyDamage.Export.to_script(failure, :curl)
File.write!("debug/reproduce.sh", script)

# Elixir script
script = PropertyDamage.Export.to_script(failure, :elixir)
File.write!("debug/reproduce.exs", script)
```

### Generate Livebook

```elixir
notebook = PropertyDamage.Export.to_livebook(failure)
File.write!("debug/failure_analysis.livemd", notebook)
```

## Step 9: Save for Later

### Persist the Failure

```elixir
{:ok, path} = PropertyDamage.save_failure(failure, "failures/")
# => "failures/capture_overflow_20240115_143022.failure"
```

### Add to Seed Library

Track for regression testing:

```elixir
{:ok, library} = PropertyDamage.load_seed_library("seeds.json")
{:ok, library} = PropertyDamage.add_to_seed_library(
  library,
  failure,
  tags: [:bug, :capture, :overflow]
)
PropertyDamage.save_seed_library(library, "seeds.json")
```

## Step 10: Verify the Fix

After fixing the bug:

```elixir
# Run with the same seed - should pass now
result = PropertyDamage.run(
  model: MyModel,
  adapter: MyAdapter,
  seed: failure.seed
)

assert result.success, "Fix didn't work!"

# Use fix verification for comprehensive check
{:ok, verification} = PropertyDamage.FailureIntelligence.verify_fix(
  failure,
  model: MyModel,
  adapter: MyAdapter,
  variations: 50  # Test with seed variations
)

if verification.verified do
  IO.puts("Fix verified!")
else
  IO.puts("Fix incomplete: #{inspect(verification.still_failing)}")
end
```

## Verbose Output Mode

Enable verbose output to see what PropertyDamage generates and executes:

    PropertyDamage.run(
      model: MyModel,
      adapter: MyAdapter,
      verbose: true
    )

Verbose mode shows:
- Each generated command with field values and symbolic refs
- Execution results (events returned by the adapter)
- Assertion checks (which triggers fired, pass/fail)
- Projection state updates

This is useful when:
- Commands aren't being generated as expected (check `when:` predicates)
- You want to understand what sequences look like before failures
- Debugging adapter issues (seeing exact command values sent)

## Shrinking Deep Dive

### How Shrinking Works

PropertyDamage shrinks by:

1. **Removing commands** - Try removing each command
2. **Simplifying values** - Try smaller numbers, shorter strings
3. **Simplifying refs** - Try using earlier refs

### Shrinking in Action

Here's what a shrinking run looks like in practice. Suppose a test fails at command
index 15 in a 23-command sequence:

    Original sequence: 23 commands, failure at index 15

    Phase 1: Sequence Shrinking

    Step 1 — Drop unexecuted (commands 16-22):
      18 commands remaining, failure still at index 15 ✓

    Step 2 — Hierarchical shrinking (by dependency depth):
      Try removing depth-3 group (commands 10, 13, 14): failure at index 12 ✓
      15 commands remaining
      Try removing depth-2 group (commands 6, 8): no failure ✗ (rejected)
      Try removing depth-1 group (commands 3, 5): failure at index 10 ✓
      13 commands remaining

    Step 3 — Linear shrinking (one at a time):
      Try removing command 0: no failure ✗
      Try removing command 1: failure at index 9 ✓ → 12 commands
      Try removing command 2: no failure ✗
      ...
      Try removing command 7: failure at index 5 ✓ → 8 commands
      ...done, no more removable

    Result: 4 commands (from original 23)

    Phase 2: Argument Shrinking

      command 0: amount 4827 → 1 ✓
      command 1: currency "GBP" → "A" ✓
      command 2: amount 391 → 0, no failure ✗ → try 195, failure ✓
      ...

    Final: 4 commands with simplified arguments

Each candidate is only accepted if it reproduces the **same failure** — same failure
type and same check name. If removing a command causes a different failure, it's
rejected. This ensures the minimal sequence demonstrates the original bug, not a
different one.

### When Shrinking Gets Stuck

If the shrunk sequence is still large:

```elixir
# Try harder with exhaustive strategy
{:ok, smaller} = PropertyDamage.shrink_further(
  failure,
  strategy: :exhaustive,
  max_iterations: 1000
)
```

### Understanding Shrink Info

```elixir
IO.inspect(failure.shrink_info)
# => %{
#   original_length: 47,
#   shrunk_length: 3,
#   iterations: 156,
#   strategy: :default
# }
```

## Flakiness Detection

If a failure doesn't reproduce consistently:

```elixir
flakiness = PropertyDamage.Flakiness.detect(
  model: MyModel,
  adapter: MyAdapter,
  seed: failure.seed,
  iterations: 10
)

if flakiness.is_flaky do
  IO.puts("Flaky! Passes #{flakiness.pass_rate * 100}% of the time")
  IO.puts("Likely causes: #{inspect(flakiness.likely_causes)}")
end
```

## Common Issues

### 1. Can't Reproduce

- Check that the SUT is in the same state (database reset)
- Verify no external dependencies changed
- Check for time-dependent behavior

### 2. Shrunk Sequence Too Long

- Add more command preconditions
- Use `shrink_further/2` with `:exhaustive` strategy
- Check for hidden dependencies between commands

### 3. Multiple Failures

- Focus on one at a time
- Use `PropertyDamage.FailureIntelligence.cluster/1` to group similar failures

## Next Steps

- [Writing Invariants](writing_invariants.md) - Improve your checks
- [Chaos Engineering](chaos_engineering.md) - Test resilience
- See `PropertyDamage.FailureIntelligence` for pattern detection
