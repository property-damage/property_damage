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
- **shrink_iterations** / **shrink_time_ms** - How much shrinking it took
- **check_name** - Which assertion failed
- **failure_message** / **failure_reason** - Description of the failure
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
# Print the shrunk sequence (a %PropertyDamage.Sequence{}; flatten with to_list/1)
failure.shrunk_sequence
|> PropertyDamage.Sequence.to_list()
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
# explain/1 returns a map; format it for printing
explanation = PropertyDamage.explain(failure)
IO.puts(PropertyDamage.Analysis.format_explanation(explanation))
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
# replay/2 returns {:ok, [step]}; each step is
# %{index, command, command_name, events, projections}
{:ok, steps} = PropertyDamage.replay(failure)

Enum.each(steps, fn step ->
  IO.puts("=== Step #{step.index} ===")
  IO.puts("Command: #{inspect(step.command)}")
  IO.puts("Events: #{inspect(step.events)}")
  IO.puts("Projections after: #{inspect(step.projections)}")
  IO.puts("")
end)
```

If the failure was saved to a `.pd` file, you can replay it from the shell
without writing any code:

```bash
mix pd.replay failures/the-failure.pd --verbose
```

It prints each step and exits non-zero while the bug still reproduces (zero once
it is fixed), so the same command doubles as a regression check. Concretely it
exits `0` when the bug is fixed, `1` when it reproduces, and `125` when the
replay could not run at all (the project does not compile, the file fails to
load, it records no model/adapter, or the sequence is branching). That third
case is *indeterminate*, not a reproduction, which is exactly what `git bisect`
needs to treat as "skip".

### Finding the commit that introduced the bug

When you know a failure is new but not where it crept in, `mix pd.bisect` drives
`git bisect` for you, replaying the saved failure at each candidate commit:

```bash
mix pd.bisect failures/the-failure.pd --good v0.1.0 [--bad HEAD]
```

It validates a clean working tree, copies the `.pd` file outside the tree (so it
survives checkouts of commits where it is not tracked), bisects between `--good`
and `--bad`, and always restores your branch with `git bisect reset` at the end.
Each commit is classified from `mix pd.replay`'s exit code (the `0`/`1`/`125`
split above), so commits that predate the model/adapter or do not compile are
skipped rather than wrongly blamed.

Note `mix pd.bisect` replays the saved **concrete shrunk sequence**, not a
re-generation from the seed. This is deliberate (DR-023): the recorded command
structs are replayed verbatim, so the search stays correct even across commits
that changed generators, command weights, or `when:` predicates. Bisecting by
seed would silently produce a different sequence after any such drift, so it is
not offered.

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
diagram = PropertyDamage.Diagram.from_failure_report(failure, :mermaid)
File.write!("failure.mmd", diagram)

# PlantUML diagram
diagram = PropertyDamage.Diagram.from_failure_report(failure, :plantuml)
File.write!("failure.puml", diagram)
```

### Diff Debugging

Compare a passing run with the failing run:

```elixir
# run/1 does not expose a `.trace` field; build a Trace for each run from its
# commands, event-log entries, and per-command state snapshots:
#   PropertyDamage.Diff.create_trace(commands, events, states, result)
# where result is :pass or {:fail, reason}.
passing_trace = PropertyDamage.Diff.create_trace(commands, events, states, :pass)

failing_trace =
  PropertyDamage.Diff.create_trace(commands, events, states, {:fail, failure.failure_reason})

# Compare traces and print the divergence
diff = PropertyDamage.Diff.compare_traces(passing_trace, failing_trace)
IO.puts(PropertyDamage.Diff.format(diff, format: :terminal))
```

Output highlights where traces diverge:

```
Step 2: CreateCapture
  Passing: {:error, :exceeds_authorization}
  Failing: {:ok, [%CaptureCreated{amount: 600}]}
           ^^^^ BUG: Should have rejected
```

## Step 7: Export for Sharing

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

## Step 8: Save for Later

### Persist the Failure

```elixir
{:ok, path} = PropertyDamage.save_failure(failure, "failures/")
# => "failures/capture_overflow_20240115_143022.failure"
```

### Replay the failing seed first while you fix it

Enable the seed library: the failing seed is replayed before random exploration
on the next run, and new failures are appended automatically. It is an ephemeral,
self-pruning working set (the entry ages out once it passes a few times in a
row), not a durable corpus — for a durable regression, export the failure to an
ExUnit test, which freezes the concrete sequence.

```elixir
PropertyDamage.run(model: M, adapter: A, seed_library: "seeds.json")
```

## Step 9: Verify the Fix

After fixing the bug:

```elixir
# Run with the same seed - should pass now
assert {:ok, _stats} =
         PropertyDamage.run(
           model: MyModel,
           adapter: MyAdapter,
           seed: failure.seed
         )

# Use fix verification for a comprehensive check. The model is positional;
# :adapter and :max_variations go in the opts.
verification = PropertyDamage.FailureIntelligence.verify_fix(
  failure,
  MyModel,
  adapter: MyAdapter,
  max_variations: 50  # Test with seed variations
)

# verification.status is :verified | :still_failing | :partially_fixed | :flaky
if verification.status == :verified do
  IO.puts("Fix verified!")
else
  IO.puts("Fix incomplete (#{verification.status}): #{inspect(verification.failed_variations)}")
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
- Each generated command with field values and placeholders
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

If the failure was saved to a `.pd` file, re-shrink it from the shell without
writing any code:

```bash
mix pd.reshrink failures/the-failure.pd --strategy exhaustive
```

It prints the before/after command counts and, by default, writes nothing. Pass
`--output PATH` to save the smaller report, or `--overwrite` to replace the input
file in place. Re-shrinking re-runs the engine, so against a live SUT it exercises
the service repeatedly.

### Understanding Shrink Stats

The report carries the shrink effort directly; sequence lengths come from the
original and shrunk sequences:

```elixir
IO.puts("shrink iterations: #{failure.shrink_iterations}")
IO.puts("shrink time: #{failure.shrink_time_ms}ms")

original_len = failure.original_sequence |> PropertyDamage.Sequence.to_list() |> length()
shrunk_len = failure.shrunk_sequence |> PropertyDamage.Sequence.to_list() |> length()
IO.puts("#{original_len} -> #{shrunk_len} commands")
```

## Flakiness Detection

If a failure doesn't reproduce consistently:

```elixir
# check_determinism re-runs the seed and returns
# {:ok, :deterministic} | {:ok, :flaky, stats} | {:error, reason}
case PropertyDamage.check_determinism(MyModel, MyAdapter, failure.seed, runs: 10) do
  {:ok, :deterministic} ->
    IO.puts("Reproduces deterministically")

  {:ok, :flaky, stats} ->
    IO.puts("Flaky! #{inspect(stats)}")

  {:error, reason} ->
    IO.puts("Could not check: #{inspect(reason)}")
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
