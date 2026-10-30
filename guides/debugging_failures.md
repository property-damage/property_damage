# Debugging Failures

When PropertyDamage finds a failing sequence, it provides powerful tools for
understanding and fixing the bug. This guide covers the debugging workflow.

## Reading the report

A failed run prints a report. This section reads one section by section. The
example is the bank of the [log lines guide](log_lines.md): an in-memory bank
with a planted bug, run with `mix run bug.exs` and seed 20. Its adapter logs
each request and answer with `PropertyDamage.log/2`, which is why the listing
below shows `log` lines beside the events.

<!-- pd-report-excerpt: the bank example of log_lines.md: mix run bug.exs; seed 20 -->
```text
#FailureReport<
╔══════════════════════════════════════════════════════════════════════╗
║                            BUG DETECTED!                             ║
╚══════════════════════════════════════════════════════════════════════╝

Seed: 20

## Failure

Failure     check failed
Check       never_negative
Projection  MyApp.Balances
At          [1] %MyApp.Withdraw{account: "alice", amount: 5}
Message     check `never_negative` returned `false`; a check passes by returning a truthy value: a predicate, `condition or fail!(...)`, or a body that ends with `:ok`

## What this checks

  Check failed  A property did not hold. After the marked step, a check judged
                the projection state (built from the events observed so far) and
                found that it violates the property.

  Model         MyApp.Model
                Deposits and withdrawals on two accounts.

  Check         MyApp.Balances.never_negative/2
                (no description: add @doc to MyApp.Balances.never_negative/2)

  Projection    MyApp.Balances
                Folds the balances the bank reported and checks that none is negative.

  Command       MyApp.Withdraw
                Withdraw `amount` from `account`.

## Minimal Reproduction (2 roots)

  [0] %MyApp.Deposit{account: "alice", amount: 5}
        +0.00s log   [http url] POST /accounts/alice/deposit
        +0.00s log   [http headers] %{"authorization" => "[REDACTED]"}
        +0.00s log   [http body] %{"amount" => 5}
        +0.00s log   [http status] -> 200
        +0.00s log   [http response] %{"balance" => 5}
        +0.00s event %MyApp.BalanceChanged{account: "alice", balance: 5}
► [1] %MyApp.Withdraw{account: "alice", amount: 5}  ◄── failed
        +0.00s log   [http url] POST /accounts/alice/withdraw
        +0.00s log   [http headers] %{"authorization" => "[REDACTED]"}
        +0.00s log   [http body] %{"amount" => 5}
        +0.00s log   [http status] -> 200
        +0.00s log   [http response] %{"balance" => -1}
        +0.00s event %MyApp.BalanceChanged{account: "alice", balance: -1}

## Projections at [1]   (- before, + after)

MyApp.Balances   last applied: BalanceChanged
  - "alice" => 5
  + "alice" => -1

## Reproduction

targets = [MyApp.Adapter]

# Rerun from the seed:
PropertyDamage.run(model: MyApp.Model, targets: targets, seed: 20, max_runs: 1)

# Regenerate the failing variant:
PropertyDamage.Expansion.for(MyApp.Model, 20, 1, "Adapter")

# Replay the shrunk failure:
PropertyDamage.run(model: MyApp.Model, targets: targets, only: [replay: "property_damage_replays/Model_seed20.replay.exs"])
>
```

`IO.inspect(report, pretty: true)` prints the report like this, wrapped in
`#FailureReport<` and `>`, without color. A failure in a
`property_damage` ExUnit test prints the same layout through
`PropertyDamage.ExUnit.format_failure/2`, with ANSI color. Only that one prints
color; the text is the same either way. Plain `inspect(report)`, without
`pretty: true`, prints a one-line summary.

### Banner and seed

The banner says `BUG DETECTED!`. A failure in the test's own code says
`TEST CODE ERROR` and adds a hint. The line under it, `Seed: 20`, is the seed
the failing run generated from, so the failing run is run 1 of that seed.

### Failure

The Failure section holds labeled fields in one aligned column. `Failure` names
the kind in words, and `Check` (or `Observation`, for a comparison) names what
failed. `At` is the step label and the command where it happened. The fields
after those depend on the kind: a poll timeout adds its predicate, an
idempotency violation adds one line per attempt, a latency budget adds the
statistic, bound and measured value. A run with other failures adds one
`Other failure` line each. A shrinker that ran out of time or iterations adds a
`Shrink` line that warns the reproduction may not be minimal. A run with a log
filter adds a `Log filter` line (see the [log lines guide](log_lines.md#filtering-by-tag)).

### Setup

A Setup section appears between Failure and Minimal Reproduction when the run
was given `setup_log:`. It holds the lines a test captured while it prepared
the system, before the run started. See
[Work done before the run](log_lines.md#work-done-before-the-run).

### Minimal Reproduction

The heading counts roots: `(2 roots)`. Each step has one label, used in every
section of the report:

| Label | Step |
|-------|------|
| `[i]` | root `i`, counted from 0 in reading order |
| `[i.j]` | leaf `j` of root `i`, listed under that root |
| `[setup i]`, `[teardown i]` | a setup or teardown command |
| `[branch b.i]` | command `i` of branch `b` in a branching run |

`►` marks the failing step and `◄── failed` names the outcome (`diverged` and
`did not converge` for comparison failures). Under each step, the events the
command produced and the log lines its code wrote print in the order they
happened. Each line starts with its offset from the start of the target's run
(`+0.00s`), then `log` or `event`. A log line shows its tags in brackets. An
event from another source keeps a badge for it (`NEM` for a nemesis, `POL` for
a resource poller, and so on). Entries tied to no command print after the
listing under "Not tied to a command". For log lines, see the
[log lines guide](log_lines.md).

### Projections

The heading names the failing step: `Projections at [1]`. Each projection
prints the event it folded last, then every attribute on its own line, in full.
An attribute that did not change prints once. One that changed prints a `-`
line and a `+` line. For most failures the two sides are the state before and
after the failing step. Here, `alice` held 5 before the withdrawal and -1 after
it.

### Reproduction

The section binds `targets = [...]` once, then prints three calls, each
passing `targets: targets`:

1. Rerun from the seed: generates the failing run again, then fails and
   shrinks again.
2. Regenerate the failing variant: `PropertyDamage.Expansion.for/5` returns the
   sequence one target ran before shrinking, without running anything.
3. Replay the shrunk failure: runs the replay artifact the failure wrote.
   Step 1 below explains it.

When `targets` holds a value no source code can rebuild (a pid, a reference, a
port or a function), a line under the binding says where it sits and tells you
to rebuild the list as your test does. None of the three calls carries the
run's `log:` filter: add it back if you want the same lines.

### A comparison failure

A divergence between two targets prints the same sections, with two changes.
Minimal Reproduction lists two sides, each under its own header
(`Reference: target "left"` and `Variant: target "right"`), and marks the
failing root in both. Projections compares the reference's state with the
variant's at the failing boundary. For a real report, see the excerpt in the
[path equivalence guide](path_equivalence_testing.md#4-plant-a-bug-and-watch-it-fail).

## The Failure Report

The report is a `%PropertyDamage.FailureReport{}`. A failing run returns it.

The steps below run on the bank of the [log lines guide](log_lines.md#2-write-the-system-the-adapter-and-the-model):
create its `lib/my_app.ex` first. The fences that use `MyApp.Model` and
`MyApp.Adapter` run in order against that bank. A fence that names `MyModel`,
`MyAdapter` or another `My` module has no bank equivalent here: replace the
name with your own module.

<!-- pd-doc-verify: include guides/log_lines.md lib/my_app.ex -->
<!-- pd-doc-verify: runnable -->
```elixir
{:error, failure} = PropertyDamage.run(
  model: MyApp.Model,
  targets: [MyApp.Adapter],
  max_runs: 50,
  seed: 20
)

IO.inspect(failure, pretty: true)
```

Read it through its fields and accessors:

- **seed** - Random seed for reproducibility
- **original_sequence** - Full command sequence that failed
- **shrunk_sequence(failure)** - Minimal reproduction (after shrinking), read via the accessor `PropertyDamage.FailureReport.shrunk_sequence/1` (it is not a struct field)
- **shrink_iterations** / **shrink_time_ms** / **shrink_stop** - How much shrinking it took, and why it stopped (`:done`, `:max_iterations` or `:max_time`)
- **failure_reason** - a `%PropertyDamage.Failure{}` describing what failed (see below)
- **`FailureReport.check_name/1`** / **`failure_message/1`** - accessors over `failure_reason`: which check failed and a human-readable description
- **state_before_failure** / **state_at_failure** - Projection state before and after the failing step
- **`FailureReport.steps/1`**, **`failure_step/1`**, **`failure_index/1`** - the run as a list of steps, the failing step, and its reading-order index
- **reference_trace** / **reference_state_at_failure** - for `:diverged` and `:did_not_converge`, the reference target's run and its state at the failing boundary (`nil` for every other kind)
- **setup_log** / **log_filter** - the lines `setup_log:` carried and the run's log filter (see the [log lines guide](log_lines.md))

"Reading the report" above reads the report of seed 20, and the run above
produces it. The steps below use `failure`, the report of that run. A run
without `seed:` picks a random seed, so your own report differs from the
walkthrough.

### The `%Failure{}` reason

`report.failure_reason` is a `%PropertyDamage.Failure{}` — one structured type
for *why* the run stopped. It nests a class struct under `type` and records the
branch (if any) on the envelope:

```elixir
%PropertyDamage.Failure{
  type: %PropertyDamage.Failure.Check{kind: :check_failed, name: :balance_non_negative, detail: ...},
  branch_id: nil
}
```

There are three **classes** (`PropertyDamage.Failure.class/1` returns the atom):

- `:check` — a property or invariant did not hold (`:check_failed`,
  `:idempotency_violation`, `:linearization`, `:poll_timeout`, `:settle_timeout`,
  `:projection_violation`). This is the class you usually want: it means the SUT
  misbehaved.
- `:execution` — the machinery around the SUT failed to run a command
  (an adapter raise or `{:error, _}` answer is `:adapter_error` in every run,
  never compared as an observation; `:adapter_error`, `:nemesis_error`, `:stutter_execution_failed`,
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

The violation records `command`, `command_index`, `mismatch` (the exception the
`using:` relation of `stutter:` produced), and `attempts`. `attempts` is the list you usually inspect: each entry is a map
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

Every failure writes a replay artifact: a file named
`<model>_seed<seed>.replay.exs` in the `replay_dir:` directory (default
`property_damage_replays`; `replay_dir: false` writes nothing). `<model>` is the
last segment of the model's module name, so `MyApp.Model` gives
`Model_seed20.replay.exs`. A file another failure of the same seed wrote (under
other `targets:`, say) is kept: the new one is named
`<model>_seed<seed>_2.replay.exs`, and the report prints the path it wrote. The report ends
with a paste-ready call that runs the shrunk failure again without generating
anything:

```elixir
# Replay the shrunk failure:
PropertyDamage.run(model: MyModel, targets: [MyAdapter], only: [replay: "property_damage_replays/MyModel_seed3.replay.exs"])
```

Every target executes the commands the file records, so the replay needs the
same `targets:` the report printed. `shrink:` defaults to false under
`only: [replay: path]`. A replay that reproduces the failure returns
`{:error, report}`, the same shape as a failing run. A replay that does not
fail the way the file records returns `{:ok, stats}` with `stats.replay` set to
`:not_reproduced`. The bank's replay file is
`property_damage_replays/Model_seed20.replay.exs`:

<!-- pd-doc-verify: runnable -->
```elixir
{:error, replayed} =
  PropertyDamage.run(
    model: MyApp.Model,
    targets: [MyApp.Adapter],
    only: [replay: "property_damage_replays/Model_seed20.replay.exs"]
  )

# The replay fails the same way as the original run.
true =
  PropertyDamage.FailureReport.failure_type(replayed) ==
    PropertyDamage.FailureReport.failure_type(failure)
```

The artifact is one Elixir literal term, so you can read it and edit an
argument before you run it again. This is the start of a real one:

```elixir
# PropertyDamage replay artifact, format 1
# model: CachexBench.Model
# seed: 3
# run: 1 (the run this seed generates)
# target "cachex" (reference), expansion: :random
# target "second", expansion: :random
%{
  choices: %{
    "cachex" => [
      # root 0: Incr[0] = [Incr]
      %{
        aliases: %{},
        commands: [%CachexBench.Commands.Incr{amount: 3, key: :alpha}],
        entry: "Incr[0]",
        root_id: 12
      }
    ],
    ...
```

The loader evaluates no code: it accepts literals and struct literals only, and
it refuses a call, a function or a second term, naming the line. It also
refuses a file whose first line names another format. The file never holds the
failure's exception, the teardown commands or a timestamp.

If a command field holds a function, pid, reference, port, improper list or
non-binary bitstring, no artifact is written. The report's footer then names the
target, root, leaf and field path, and the failure still reproduces from its
seed.

To run the same failure from its seed instead, use the seed:

<!-- pd-doc-verify: runnable -->
```elixir
# Run with the same seed
{:error, rerun} = PropertyDamage.run(
  model: MyApp.Model,
  targets: [MyApp.Adapter],
  seed: failure.seed,
  max_runs: 1
)
```

> **If the seed does not reproduce**, generation is probably not a pure function
> of the seed: an impure generator, `when:`/`overrides:`, or projection. Confirm and
> localize it with `mix pd.audit MyModel`; see the
> [deterministic generation guide](deterministic_generation.md).

### Reproducing one variant

With several targets, each target may run its own expansion of a root. To see
the sequence one target ran before shrinking, regenerate it. Nothing runs, and
no adapter is touched:

<!-- pd-doc-verify: runnable -->
```elixir
# run is 1-based; failure.seed is the seed the failing run generated from.
# The bank has one target, named "Adapter" after its adapter module.
{:ok, %{sequence: sequence}} =
  PropertyDamage.Expansion.for(MyApp.Model, failure.seed, 1, "Adapter")
```

With several targets, name the one you want: `"second"` in the examples below.

The last argument is the target's name. A target given without `name:` is named
after the last segment of its adapter module (`"Adapter"` for `MyApp.Adapter`),
as the report's Reproduction section prints it. Pass `targets:` when a target does not run `:random`, because the pick then
depends on the reference. To run part of a campaign, use `only:`:

```elixir
# Run 1 of the seed, the reference and the target named "second".
PropertyDamage.run(model: MyModel, targets: [MyAdapter, {OtherAdapter, name: "second"}],
  seed: failure.seed, only: [run: 1, variants: ["second"]])

# Run "second" alone, with the model's checks and no @compare.
PropertyDamage.run(model: MyModel, targets: [MyAdapter, {OtherAdapter, name: "second"}],
  seed: failure.seed, only: [run: 1, variants: ["second"], with_reference: false])
```

`with_reference: false` is legal only with exactly one non-reference name.
`only:` takes `max_runs: 1` at most, no `branching:`, and `seed:` is not allowed
beside `replay:`.

## Step 2: Understand the Shrunk Sequence

The shrinker stops when it cannot remove any single command without losing the
failure. So no one command of the shrunk sequence can be dropped, but a shorter
sequence that also fails may exist: the bank example's shrunk sequence ranges
from 2 to 14 commands, depending on the seed. Print it:

<!-- pd-doc-verify: runnable -->
```elixir
# Print the shrunk sequence (a %PropertyDamage.Sequence{}; flatten with to_list/1)
PropertyDamage.FailureReport.shrunk_sequence(failure)
|> PropertyDamage.Sequence.to_list()
|> Enum.with_index()
|> Enum.each(fn {cmd, idx} ->
  IO.puts("[#{idx}] #{inspect(cmd)}")
end)
```

The output has one line per command: its index, then the command as Elixir
prints it, for example `[0] %MyApp.Deposit{account: "alice", amount: 5}`.

## Step 3: Explain the Sequence

Use `explain/1` to see which command triggered the failure and which commands
it depends on:

<!-- pd-doc-verify: runnable -->
```elixir
# explain/1 returns a map; format it for printing
explanation = PropertyDamage.explain(failure)
IO.puts(PropertyDamage.Analysis.format_explanation(explanation))
```

`format_explanation/1` prints a `FAILURE ANALYSIS` header with a summary (the
number of commands and the command that triggered the failure), then a
`COMMAND BREAKDOWN` section with one entry per command: its index, its name, a
marker (`← FAILURE TRIGGER` or `← DEPENDENCY`, or none), and a line giving the
reason. A `DEPENDENCY CHAIN` section follows when the failing command depends on
earlier ones. The text comes from the analysis of the command structs, so it
names commands and roles, not what they mean in your domain. It infers a role
from the placeholders alone. A command no placeholder links to the failing
command, such as a deposit that only supplies a balance, has no marker and
reads `Kept by shrinking: removing it lost the failure; it may set up state the
failing command reads`. It stays out of the `DEPENDENCY CHAIN`, because the
analysis does not infer dependencies through state.

## Step 4: Step-by-Step Replay

Replay the sequence step by step to observe state changes:

<!-- pd-doc-verify: runnable -->
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
- `{:check_failed, name, exception}` — a check failed. `name` is the check
  name (an atom, e.g. `:balance_non_negative`) and `exception` is the exception
  struct the check raised. Only `:check_failed` failures take this shape.
- `{:error, reason}` — any other failure: an adapter/execution error, or a
  non-check failure (a poll/settle timeout, linearization, framework error).
  `reason` is the underlying value.

So the failing step is the one whose `result` is not `:ok`:

<!-- pd-doc-verify: runnable -->
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

If the failure was saved to a `.pd` file (see
[Step 8](#step-8-save-for-later) for `PropertyDamage.save_failure/2`), you can
replay it from the shell without writing any code:

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
`git bisect` for you, replaying the saved failure (a `.pd` file, see
[Step 8](#step-8-save-for-later)) at each candidate commit. It needs a project
in a git repository and exits 1 outside one:

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

<!-- pd-doc-verify: runnable -->
```elixir
{:ok, trigger} = PropertyDamage.isolate_trigger(failure)

IO.puts("Trigger: #{inspect(trigger)}")
# => %{trigger_index: 0, trigger_command: %Withdraw{...}, likely_cause: "...", changes: [%{field: ..., original: ..., fixed: ...}]}
```

## Step 6: Visual Debugging

### The report in a browser

`PropertyDamage.FailureReport.HTML` turns a report into one HTML page that
opens from disk and loads nothing from the network. It shows one column per
target. Each step unfolds to its log lines and events. Repeated log lines
collapse into one, and the detail under a log line folds by its indentation.
Below each step, the step's events are compared across targets.

```elixir
{:error, report} = PropertyDamage.run(model: MyModel, targets: targets)
File.write!("failure.html", PropertyDamage.FailureReport.HTML.render(report))
```

To get a page for every failing run without touching the tests, name a
directory when running the suite:

```bash
PD_REPORT_HTML=_build/pd_reports mix test
open _build/pd_reports/index.html
```

Each failing run writes its page into that directory. The run option
`report_html: "_build/pd_reports"` does the same for one run. `index.html`
shows one report at a time; its arrow buttons move between them. The left and
right arrow keys do the same while the index page has focus, but a browser may
keep the key presses inside the report frame, so use the buttons.
When several test processes write into one directory, run
`PropertyDamage.FailureReport.HTML.write_index/1` once they finish, so the
index lists every page.

The page holds the same text `PropertyDamage.ExUnit.format_failure/2` prints,
with the same tag filter, and log lines in it are written to disk: keep the
directory out of git.

### Sequence Diagrams

Generate visual diagrams of the failing sequence:

<!-- pd-doc-verify: runnable -->
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
before = RunTrace.capture(model: MyModel, targets: [MyAdapter.Fixed], seed: failure.seed)
after_ = RunTrace.capture(model: MyModel, targets: [MyAdapter.Buggy], seed: failure.seed)

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
`run_nonce` is generated per capture so client-minted values never collide on a
shared SUT:

```elixir
{_traces, comparison} =
  RunComparison.investigate(
    runs: 10,
    capture: [model: MyModel, targets: [MyAdapter], seed: failure.seed]
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
    capture: [model: MyModel, targets: [MyAdapter]]
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

<!-- pd-doc-verify: runnable -->
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

<!-- pd-doc-verify: runnable -->
```elixir
:ok = PropertyDamage.FailureReport.verify_projections(failure)
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

<!-- pd-doc-verify: runnable -->
```elixir
test_code = PropertyDamage.Export.to_exunit(failure)
File.mkdir_p!("test/regression")
File.write!("test/regression/capture_overflow_test.exs", test_code)
```

### Generate Reproduction Script

<!-- pd-doc-verify: runnable -->
```elixir
# Curl script for API testing (script/livebook exports need a :base_url)
File.mkdir_p!("debug")
script = PropertyDamage.Export.to_script(failure, :curl, base_url: "http://localhost:4000")
File.write!("debug/reproduce.sh", script)

# Elixir script
script = PropertyDamage.Export.to_script(failure, :elixir, base_url: "http://localhost:4000")
File.write!("debug/reproduce.exs", script)
```

### Generate Livebook

<!-- pd-doc-verify: runnable -->
```elixir
notebook = PropertyDamage.Export.to_livebook(failure, base_url: "http://localhost:4000")
File.write!("debug/failure_analysis.livemd", notebook)
```

## Step 8: Save for Later

### Persist the Failure

<!-- pd-doc-verify: runnable -->
```elixir
{:ok, path} = PropertyDamage.save_failure(failure, "failures/")
# => "failures/20261028T002141-check_failed-never_negative-seed20.pd"
```

The directory is created when missing. The name is the report's UTC timestamp
(`YYYYMMDDTHHMMSS`), its failure kind, its check name and its seed. Pass
`filename:` to choose another name.

### Replay the failing seed first while you fix it

Enable the seed library: the failing seed is replayed before random exploration
on the next run, and new failures are appended automatically. It is an ephemeral,
self-pruning working set (the entry ages out once it passes a few times in a
row), not a durable corpus — for a durable regression, export the failure to an
ExUnit test, which freezes the concrete sequence.

```elixir
PropertyDamage.run(model: M, targets: [A], seed_library: "seeds.json")
```

## Step 9: Verify the Fix

After fixing the bug (these fences need your fixed system, so the guide does not
run them against the planted-bug bank):

```elixir
# Run with the same seed - should pass now
assert {:ok, _stats} =
         PropertyDamage.run(
           model: MyModel,
           targets: [MyAdapter],
           seed: failure.seed
         )

# Use fix verification for a comprehensive check. The model is positional;
# :targets and :max_variations go in the opts.
verification = PropertyDamage.FailureIntelligence.verify_fix(
  failure,
  MyModel,
  targets: [MyAdapter],
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
      targets: [MyAdapter],
      verbose: true
    )

Verbose mode shows:
- Each generated command with field values and placeholders
- Execution results (events returned by the adapter)
- Checks (which triggers fired, pass/fail)
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
different one. For a divergence between targets (or a failure to converge), the name is the
`@compare` key `{Projection, function}`: a candidate that diverges on another
observation, or in another target, is a different failure and is rejected too.
When a run has several failures (in every run, retirement or not), only the primary one (the first by root, then by
target order) is shrunk, and `report.other_failures` lists the rest.

### Shrinking and References

Before it runs a candidate, the shrinker folds it through the model's projection,
simulator and `when:` predicates. A candidate the model rejects there, or on which
model code raises, is invalid and never counts as a reproduction. This matters for
commands that reference an entity an earlier command created. Shrinking can drop
the creating command and keep the one that references it. A reference stays valid
under shrinking only in one of two ways:

- The reference is a placeholder (an `external()` field): dropping the producer
  leaves the placeholder unresolved, so the candidate fails with another kind and
  is rejected.
- The model's projection rejects the orphan: its `apply/2` raises when it folds an
  event that references an entity the state does not hold.

A reference held as a plain value, such as an owner login a model picked from
state, passes neither check. A `CreateRepo` for owner `u0` then survives the
removal of `CreateUser u0`, and the shrunk sequence reproduces a failure the
generator could never produce.

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

If the failure was saved to a `.pd` file (see
[Step 8](#step-8-save-for-later)), re-shrink it from the shell without writing
any code:

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
    capture: [model: MyModel, targets: [MyAdapter], seed: failure.seed]
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
