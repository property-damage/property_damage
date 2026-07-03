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

1. It collects sample events for each command from a baseline run.
2. For each command it generates mutations (via the configured operators).
3. It runs your property against each mutated adapter.
4. A mutation is **killed** if your tests now fail (good: the bug was caught) and
   **survived** if they still pass (bad: the bug slipped through).

The **mutation score** is the fraction of mutations killed. A low score means
your invariants or assertions are not pinning down behaviour tightly enough.

## Quick start

```elixir
{:ok, report} =
  PropertyDamage.Mutation.run(
    model: MyApp.Model,
    adapter: MyApp.Adapter,
    adapter_config: %{base_url: "http://localhost:4000"},
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
| `:status` | Flips success/error outcomes |
| `:event` | Modifies event contents and structure |
| `:boundary` | Pushes values to edges (`0`, `-1`, max, `nil`) |

By default all operators run. Narrow the set with `operators:`:

```elixir
PropertyDamage.Mutation.run(
  model: MyApp.Model,
  adapter: MyApp.Adapter,
  operators: [:value, :boundary]
)
```

## Reading the report

The `%PropertyDamage.Mutation.Report{}` returned by `run/1` carries:

- `:mutation_score` - fraction of mutations killed (0.0–1.0)
- `:killed` / `:survived` / `:timeout` / `:total` - mutation counts
- `:by_command` / `:by_operator` - per-command and per-operator stats
- `:survived_mutations` - the mutations your tests missed (the actionable list)

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

## Improving a low score

A survived mutation is a concrete lead: the SUT returned something subtly wrong
and nothing complained. Usually the fix is a tighter invariant. See
[Writing Invariants](writing_invariants.md), which has a section on using
mutation testing to validate the invariants you write.

## Watching progress

A mutation run can take a while (it runs your whole property once per mutation),
so pass an `on_progress` function to watch it. It receives a
`%PropertyDamage.Progress{}` projection (DR-022): a `MutationUpdate` per mutation
as it is killed, survived, or timed out, then a terminal `MutationResult`
carrying a copy of the final report. The same stream drives `verbose: true` and
the `[:property_damage, :mutation, :progress | :result]` telemetry events.

```elixir
alias PropertyDamage.Progress
alias PropertyDamage.Progress.{MutationResult, MutationUpdate}

PropertyDamage.Mutation.run(
  model: MyApp.Model,
  adapter: MyApp.Adapter,
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
| `:adapter` | required | Adapter module implementing `PropertyDamage.Adapter` |
| `:adapter_config` | `%{}` | Configuration passed to `adapter.setup/1` |
| `:operators` | all | Mutation operators to use |
| `:mutations_per_command` | 5 | Max mutations generated per command type |
| `:max_runs` | 10 | Property test runs per mutation |
| `:target_score` | 0.80 | Score `passes?/1` checks against |
| `:timeout_ms` | 30000 | Timeout per mutation test |
| `:verbose` | false | Print a status line per mutation |
| `:on_progress` | nil | Progress consumer (see [Watching progress](#watching-progress)) |
