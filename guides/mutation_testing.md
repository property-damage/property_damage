# Mutation Testing

> **Note:** the operator set and scoring heuristics continue to evolve, so read
> the mutation score as a directional signal about test strength rather than a
> hard pass/fail gate.

Property-based tests can pass for the wrong reason: a weak invariant, an adapter
that swallows errors, or a check that never really exercises the interesting
state. Mutation testing measures how good your tests actually are by deliberately
injecting bugs and seeing whether your tests catch them.

## How it works

`PropertyDamage.Mutation.run/1` wraps your real adapter in a
`MutatingAdapter` that perturbs the events the SUT returns, then runs your
property against the mutated responses:

1. For each command, it runs the property once as a baseline (one whole run
   of up to 10 commands, with a fresh seed for each baseline run) and keeps
   the events of that run, from all commands, as samples.
2. It generates that command's mutations (via the configured operators) from
   its own samples, so two commands do not share one sample set.
3. It runs your property against each mutated adapter.
4. A mutation is **killed** if a check now fails (good: the bug was caught) and
   **survived** if your tests still pass (bad: the bug slipped through).

A third outcome, **killed by error**, covers a mutation whose run fails because
a command could not be executed: the adapter returned an error, so the run
stops with an `:execution_failed` report before any check can judge the
state. The `:status` operator causes this when it turns a success into an
`{:error, _}`. Any model fails that way, however weak its checks are, so the
report counts these mutations apart (`killed_by_error`) and leaves them out of
the score.

The **mutation score** is `killed / (total - killed_by_error)`: the fraction of
the measurable mutations that a check killed. Timeouts stay in the
denominator. The score is 0.0 when every mutation was killed by an error. A
low score means your invariants or checks are not pinning down behavior
tightly enough.

> **Expansions caveat:** for a model with `expansions/0`, mutation targets are
> still the roots of `commands/0`. The events of an expansion leaf are not
> mutated. A mutant of a root that every run executes as an expansion is never
> applied, so the report counts it as survived. Do not read those survivors as
> weak checks.

Before it mutates a command, `run/1` runs one baseline property run with the unmodified
adapter. If that baseline run fails with an adapter error, every mutation of
the command would fail the same way and count as killed by error. If the
adapter's setup fails, the baseline yields no events to mutate and the report
comes back empty. If a check or an invariant fails the baseline, every mutation
would count as killed, and the score would say nothing about your checks. Each
case hides a broken model or adapter. So `run/1` stops and returns
`{:error, {:baseline_failed, command_module, message}}`, where `message` is the
failure message of the baseline run (for example `":backend_down"`). Make the
property pass against the unmodified adapter and run again.

## Quick start

```elixir
{:ok, report} =
  PropertyDamage.Mutation.run(
    model: MyApp.Model,
    targets: [{MyApp.Adapter, config: %{base_url: "http://localhost:4000"}}],
    target_score: 0.80
  )

if PropertyDamage.Mutation.passes?(report) do
  IO.puts("Tests are effective (score: #{report.mutation_score})")
else
  IO.puts(PropertyDamage.Mutation.format(report))
end
```

## Mutation operators

| Operator | What it mutates |
|----------|-----------------|
| `:value` | Numeric and string values (zero, negate, off-by-one, empty string) |
| `:omission` | Removes fields from events, or whole events |
| `:status` | Turns a success into an error (`{:error, _}`) or into an empty event list |
| `:event` | Modifies event contents and structure |
| `:boundary` | Pushes values to edges (`0`, `-1`, max, `nil`) |

By default all operators run. Narrow the set with `operators:`. Most `:status`
mutations make the adapter return an error, so they end as killed by error and
do not score; leave `:status` out of `operators:` if you only want mutations a
check can catch:

```elixir
PropertyDamage.Mutation.run(
  model: MyApp.Model,
  targets: [MyApp.Adapter],
  operators: [:value, :boundary]
)
```

## Reading the report

The `%PropertyDamage.Mutation.Report{}` returned by `run/1` carries:

- `:mutation_score` - `killed / (total - killed_by_error)` (0.0–1.0)
- `:killed` / `:killed_by_error` / `:survived` / `:timeout` / `:total` -
  mutation counts
- `:by_command` / `:by_operator` - per-command and per-operator stats; each
  row has its own `killed_by_error` count and a score computed the same way
- `:survived_mutations` - the mutations your tests missed (the actionable list)
- `:killed_mutations` / `:killed_by_error_mutations` - the details of each
  kind of kill; a kill's `failure_message` is the message of the failure
  report the run returned

To read `:status` results, look at `by_operator`: its `:status` row shows how
many of those mutations were killed by error and how many a check killed or
missed.

```elixir
# Which commands have the weakest tests?
for {command, stats} <- PropertyDamage.Mutation.weakest_commands(report) do
  IO.puts("#{inspect(command)}: #{Float.round(stats.score, 2)}")
end

# Structured analysis with recommendations
analysis = PropertyDamage.Mutation.analyze(report)
IO.puts(PropertyDamage.Mutation.Analysis.format(analysis))
```

`format/2` renders the report as `:terminal`, `:markdown`, or `:json`:

```elixir
IO.puts(PropertyDamage.Mutation.format(report, :markdown))
```

When any mutation was killed by error, the terminal and Markdown outputs name
the count and say the score excludes it. The JSON output carries
`killed_by_error` as a number (in the report, in each `by_command` and
`by_operator` entry) and a `score_rule` string that states the exclusion. The
terminal output shows a summary such as the following. The
`, 3 by adapter error` suffix appears only when the count is above 0:

```text
Mutation Score: 41.7% (5/15 killed, 3 by adapter error)  ✗ FAIL (target: 80.0%)
3 killed by adapter error, excluded from the score (no check caught them)
```

Each row of the by-command and by-operator boxes ends with the kill count, the
total and the error kills, for example `(0/3, 3 by error)`.

The Markdown output adds a "Killed by adapter error" row to its summary and a
"Killed by error" column to its per-command and per-operator tables:

```text
| Operator | Score | Killed | Killed by error | Survived | Total |
|----------|-------|--------|-----------------|----------|-------|
| `:value` | 33.3% | 1 | 0 | 2 | 3 |
| `:status` | 0.0% | 0 | 3 | 0 | 3 |
```

## Improving a low score

A survived mutation is a concrete lead: the SUT returned something subtly wrong
and nothing complained. Usually the fix is a tighter invariant. See
[Writing Invariants](writing_invariants.md), which has a section on using
mutation testing to validate the invariants you write.

## Watching progress

A mutation run can take a while (it runs your whole property once per mutation),
so pass an `on_progress` function to watch it. It receives a
`%PropertyDamage.Progress{}` projection (DR-022): a `MutationUpdate` per mutation
as it is killed, killed by error, survived, or timed out, then a terminal `MutationResult`
carrying a copy of the final report. The same stream drives `verbose: true` and
the `[:property_damage, :mutation, :progress | :result]` telemetry events.

```elixir
alias PropertyDamage.Progress
alias PropertyDamage.Progress.{MutationResult, MutationUpdate}

PropertyDamage.Mutation.run(
  model: MyApp.Model,
  targets: [MyApp.Adapter],
  on_progress: fn
    %Progress{data: %MutationUpdate{result: outcome, command: command}} ->
      IO.puts("#{outcome}: #{inspect(command)}")

    %Progress{data: %MutationResult{report: report}} ->
      IO.puts("score: #{report.mutation_score}")
  end
)
```

The authoritative report is still the `{:ok, report}` return value;
`MutationResult` is a copy emitted for consumers.

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `:model` | required | Model module implementing `PropertyDamage.Model` |
| `:targets` | required | List with one target: `[Adapter]` or `[{Adapter, config: %{...}}]` |
| `:operators` | all | Mutation operators to use |
| `:mutations_per_command` | 5 | Max mutations each operator generates per command type (so a command gets up to this number times the number of operators) |
| `:max_runs` | 10 | Property test runs per mutation |
| `:target_score` | 0.80 | Score `passes?/1` checks against |
| `:timeout_ms` | 30000 | Timeout per mutation test |
| `:verbose` | false | Print a status line per mutation |
| `:on_progress` | nil | Progress consumer (see [Watching progress](#watching-progress)) |
