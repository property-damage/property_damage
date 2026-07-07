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
- **shrunk_sequence(failure)** - Minimal reproduction (after shrinking), read via the accessor `PropertyDamage.FailureReport.shrunk_sequence/1` (it is not a struct field)
- **shrink_iterations** / **shrink_time_ms** - How much shrinking it took
- **failure_reason** - a `%PropertyDamage.Failure{}` describing what failed (see below)
- **`FailureReport.check_name/1`** / **`failure_message/1`** - accessors over `failure_reason`: which assertion failed and a human-readable description
- **state_at_failure** - Model state when failure occurred

### The `%Failure{}` reason

`report.failure_reason` is a `%PropertyDamage.Failure{}` — one structured type
for *why* the run stopped. It nests a class struct under `type` and records the
branch (if any) on the envelope:

```elixir
%PropertyDamage.Failure{
  type: %PropertyDamage.Failure.Assertion{kind: :assertion_failed, name: :balance_non_negative, detail: ...},
  branch_id: nil
}
```

There are three **classes** (`PropertyDamage.Failure.class/1` returns the atom):

- `:assertion` — a property or invariant did not hold (`:assertion_failed`,
  `:idempotency_violation`, `:linearization`, `:poll_timeout`, `:settle_timeout`,
  `:projection_violation`). This is the class you usually want: it means the SUT
  misbehaved.
- `:execution` — the machinery around the SUT failed to run a command
  (`:adapter_error`, `:nemesis_error`, `:stutter_execution_failed`,
  `:resource_poller_error`, `:poll_error`, ...). Often a test-harness or
  infrastructure problem rather than a SUT bug.
- `:framework` — PropertyDamage itself could not proceed
  (`:placeholder_resolution`, `:unknown`).

Read a failure with the accessors rather than matching the struct by hand:
`PropertyDamage.Failure.kind/1`, `name/1`, `detail/1`, `class/1`, `branch_id/1`,
`partial_events/1`. `FailureReport.failure_type/1` returns the kind and
`FailureReport.check_name/1` the name.

#### Idempotency failures

Idempotency violations (from stutter testing, see the
[idempotency guide](idempotency_testing.md)) have two dedicated accessors so you
do not have to reach into the `%Failure{}` by hand:

- `PropertyDamage.FailureReport.idempotency_failure?/1` — `true` when the failure
  kind is `:idempotency_violation`, `false` otherwise.
- `PropertyDamage.FailureReport.idempotency_violation/1` — the
  `%PropertyDamage.Stutter.Violation{}` for such a failure, or `nil` for any other
  failure kind.

The violation records `command`, `command_index`, `comparison_result`, and
`attempts`. `attempts` is the list you usually inspect: each entry is a map
`%{attempt: n, events: [...], is_retry: boolean}`, so you can compare the events
the SUT returned on the first execution against those from each retry.

```elixir
if PropertyDamage.FailureReport.idempotency_failure?(failure) do
  violation = PropertyDamage.FailureReport.idempotency_violation(failure)

  Enum.each(violation.attempts, fn attempt ->
    IO.puts("attempt #{attempt.attempt} (retry? #{attempt.is_retry}): #{inspect(attempt.events)}")
  end)
end
```

> **Triage note — tuning vs. bug.** A `kind in [:poll_timeout, :settle_timeout]`
> failure means the system did not reach the expected state *in time*. That is
> often a tuning question (the timeout is too tight, or the operation is slower
> than modeled), not necessarily a bug. Widen the timeout and re-run before
> assuming the SUT is broken.

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

> **If the seed does not reproduce**, generation is probably not a pure function
> of the seed — an impure generator, `when:`/`with:`, or projection. Confirm and
> localize it with `mix pd.audit MyModel`; see the
> [deterministic generation guide](deterministic_generation.md).

## Step 2: Understand the Shrunk Sequence

The shrunk sequence is the minimal reproduction. Every command in it is
necessary for the failure:

```elixir
# Print the shrunk sequence (a %PropertyDamage.Sequence{}; flatten with to_list/1)
PropertyDamage.FailureReport.shrunk_sequence(failure)
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
# %{index, command, command_name, events, projections, projections_before, result}
{:ok, steps} = PropertyDamage.replay(failure)

Enum.each(steps, fn step ->
  IO.puts("=== Step #{step.index} ===")
  IO.puts("Command: #{inspect(step.command)}")
  IO.puts("Events: #{inspect(step.events)}")
  IO.puts("Projections after: #{inspect(step.projections)}")
  IO.puts("")
end)
```

`step.projections` is the projection state after the command; `projections_before`
is the state just before it, so you can diff the two around the failing step.

#### Step results

`step.result` records how each command's execution and checks turned out. It is
a replay-local outcome vocabulary (distinct from the run-level `failure_reason`)
with three shapes:

- `:ok` — the command executed and every check that ran passed.
- `{:check_failed, name, exception}` — an assertion failed. `name` is the check
  name (an atom, e.g. `:balance_non_negative`) and `exception` is the exception
  struct the assertion raised. Only `:assertion_failed` failures take this shape.
- `{:error, reason}` — any other failure: an adapter/execution error, or a
  non-assertion failure (a poll/settle timeout, linearization, framework error).
  `reason` is the underlying value.

So the failing step is the one whose `result` is not `:ok`:

```elixir
{:ok, steps} = PropertyDamage.replay(failure)

Enum.each(steps, fn step ->
  case step.result do
    :ok -> :ok
    {:check_failed, name, _exception} -> IO.puts("[#{step.index}] check failed: #{name}")
    {:error, reason} -> IO.puts("[#{step.index}] error: #{inspect(reason)}")
  end
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
# => %{trigger_index: 0, trigger_command: %Withdraw{...}, likely_cause: "...", changes: [%{field: ..., original: ..., fixed: ...}]}
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

### Comparing Runs

A `FailureReport` tells you *that* one run failed. When you have a passing run
and a failing run of the **same plan**, run comparison tells you *where* the two
executions diverge, and ranks the field differences by how strongly they
discriminate the outcomes (DR-035). The two use cases:

- **Regression localization** — a plan passed on one revision of the SUT and
  fails on another. Where do the runs diverge?
- **Flakiness localization** — a plan fails one time in N. What differs between
  the passing and failing executions?

Both need full, unshrunk runs of the same plan, which is exactly what a
`FailureReport` is *not* (it holds a shrunk sequence). Capture those runs with
`PropertyDamage.RunTrace.capture/1` and feed them to
`PropertyDamage.RunComparison.compare/1`. Neither runs a SUT during comparison:
capture records the runs, `compare/1` is pure data-in/data-out.

For regression localization, capture one trace per revision of the SUT at the
same seed (same seed and model ⇒ same plan ⇒ comparable):

```elixir
alias PropertyDamage.{RunTrace, RunComparison}

# Same model and seed on both sides: identical plan, different SUT behavior.
before = RunTrace.capture(model: MyModel, adapter: MyAdapter.Fixed, seed: failure.seed)
after_ = RunTrace.capture(model: MyModel, adapter: MyAdapter.Buggy, seed: failure.seed)

comparison = RunComparison.compare([before, after_])
```

`compare/1` refuses rather than emit a misleading diff when the traces are not
the same plan (unequal plan fingerprint or model). Always check the guard, then
read the ranking (most discriminating field first):

```elixir
if comparison.comparable? do
  # Runs are partitioned by outcome into passing/failing groups (by index).
  IO.inspect(comparison.groups, label: "groups")

  Enum.each(comparison.ranking, fn field ->
    IO.inspect(%{
      where: field.location,          # {:command, position, path} | {:event, ...} | {:state, position, projection, path}
      class: field.classification,    # :discriminating | :incidental | :weak | ...
      values: field.values            # %{trace_index => value}
    })
  end)
else
  IO.inspect(comparison.guard_violations, label: "not comparable")
end
```

A `:discriminating` field is stable within each outcome group but differs
between groups: it is the ranking's subject, the difference most likely to
explain the failure. `:incidental` fields (e.g. run-scoped correlation ids) vary
even within the passing group and are down-ranked automatically.

For flakiness, use `RunComparison.investigate/1`, which captures the traces for
you. Its capture options are nested under a `capture:` sub-keyword; a fresh
`run_nonce` is drawn per capture so client-minted values never collide on a
shared SUT:

```elixir
{_traces, comparison} =
  RunComparison.investigate(
    runs: 10,
    capture: [model: MyModel, adapter: MyAdapter, seed: failure.seed]
  )
```

To sweep a whole corpus of seeds instead of one suspect, `RunComparison.scan/1`
runs each seed N times and returns a per-seed `%RunComparison.Verdict{}` map. It
keeps memory bounded by discarding a seed's traces before the next, retaining the
full comparison only for the flaky ones:

```elixir
verdicts =
  RunComparison.scan(
    seeds: Enum.to_list(1..100),
    runs: 5,
    capture: [model: MyModel, adapter: MyAdapter]
  )

for {seed, v} <- verdicts, v.flaky? do
  IO.puts("seed #{seed}: #{v.partition.passing} passed / #{v.partition.failing} failed")
  # v.comparison is the ranked divergence for this flaky seed (nil when consistent).
end
```

Render any comparison as a single self-contained HTML report (inline CSS/JS, no
external hosts) for sharing:

```elixir
File.write!("comparison.html", RunComparison.to_html(comparison))
```

> Run comparison needs a plan that is a **pure function of the seed**, so both
> sides regenerate the identical plan. If the guard reports differing plan
> fingerprints for what should be one plan, your generation is impure: see the
> [deterministic generation guide](deterministic_generation.md) and
> `mix pd.audit`.

### Projection state over time

A failure report keeps two authoritative state snapshots
(`state_before_failure`, `state_at_failure`). For every *other* step, projection
state is **derived** from the run — nothing is captured per command. Ask a
`RunTrace` (a report embeds one as `failure.trace`) for the state at any step:

```elixir
alias PropertyDamage.RunTrace

# The projection state after each command, in reading order.
RunTrace.state_timeline(failure.trace)
#=> [{%Sequence.Position{...}, %{MyProjection => %{...}, ...}}, ...]

# The state right after (or right before) one command.
step = PropertyDamage.FailureReport.failure_step(failure)
RunTrace.state_at(failure.trace, step.position)
RunTrace.state_before(failure.trace, step.position)
```

This is the *faithful* timeline: it replays the run's real fold order, so
late-settling async events land exactly where they folded.

### Checking projection purity

A projection's `apply/2` must be a pure function of `(state, event)`. If it reads
a clock, a counter, or the environment, re-deriving the state no longer matches
what the run actually had. `verify_projections/1` catches exactly that — it
re-derives the state at the failing step and compares it to the runtime
snapshot:

```elixir
PropertyDamage.FailureReport.verify_projections(failure)
#=> :ok
#=> {:non_pure_projections, [MyApp.ImpureProjection]}
```

Because it replays the real fold order, a *pure* projection whose events settle
asynchronously does not false-positive. For an ahead-of-time (no failure needed)
check across many seeds, `mix pd.audit` also runs
`PropertyDamage.audit_projections/2`, which folds each generated plan twice and
names any projection that disagrees with itself. See the
[deterministic generation guide](deterministic_generation.md).

## Step 7: Export for Sharing

### Generate ExUnit Test

Create a regression test:

```elixir
test_code = PropertyDamage.Export.to_exunit(failure)
File.write!("test/regression/capture_overflow_test.exs", test_code)
```

### Generate Reproduction Script

```elixir
# Curl script for API testing (script/livebook exports need a :base_url)
script = PropertyDamage.Export.to_script(failure, :curl, base_url: "http://localhost:4000")
File.write!("debug/reproduce.sh", script)

# Elixir script
script = PropertyDamage.Export.to_script(failure, :elixir, base_url: "http://localhost:4000")
File.write!("debug/reproduce.exs", script)
```

### Generate Livebook

```elixir
notebook = PropertyDamage.Export.to_livebook(failure, base_url: "http://localhost:4000")
File.write!("debug/failure_analysis.livemd", notebook)
```

## Step 8: Save for Later

### Persist the Failure

```elixir
{:ok, path} = PropertyDamage.save_failure(failure, "failures/")
# => "failures/capture_overflow_20240115_143022.pd"
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
shrunk_len = PropertyDamage.FailureReport.shrunk_sequence(failure) |> PropertyDamage.Sequence.to_list() |> length()
IO.puts("#{original_len} -> #{shrunk_len} commands")
```

## Flakiness Detection

If a failure doesn't reproduce consistently, run the plan many times and let run
comparison tell you *whether* the seed is flaky and *where* the passing and
failing runs diverge (see [Comparing Runs](#comparing-runs) above):

```elixir
{_traces, comparison} =
  PropertyDamage.RunComparison.investigate(
    runs: 10,
    capture: [model: MyModel, adapter: MyAdapter, seed: failure.seed]
  )

summary = PropertyDamage.RunComparison.outcome_summary(comparison)

if summary.passing > 0 and summary.failing > 0 do
  IO.puts("Flaky: #{summary.passing} passed / #{summary.failing} failed")
  IO.inspect(comparison.ranking, label: "most discriminating fields")
else
  IO.puts("Reproduces consistently (#{summary.failing}/#{comparison.traces |> length} failed)")
end
```

To sweep many seeds at once, use `PropertyDamage.RunComparison.scan/1` (per-seed
verdicts, bounded memory).

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
