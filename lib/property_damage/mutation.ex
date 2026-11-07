defmodule PropertyDamage.Mutation do
  @moduledoc """
  Mutation testing for PropertyDamage.

  Mutation testing verifies that your property-based tests are effective by:
  1. Injecting faults (mutations) into adapter responses
  2. Running tests against the mutated responses
  3. Checking if tests catch (kill) the mutations

  A **killed** mutant means your tests detected the simulated bug (good).
  A **survived** mutant means your tests missed the bug (bad - weak tests).
  A mutant **killed by error** made the run fail with an `:execution_failed`
  report, for example a status mutation that made the adapter return an error.
  No check caught it, so the mutation score leaves these out:
  `killed / (total - killed_by_error)`. The report shows the count next to
  killed and survived (see DR-059).

  Before it mutates each command, `run/1` runs the whole model once with the
  unmodified adapter, up to 10 commands (`max_commands: 10`) and a fresh random
  seed, and takes every event of that run as the sample events to mutate. A
  model with three commands in `commands/0` runs three baselines. If a baseline run fails
  for any reason (an adapter error, a failed setup, a failed check or
  invariant), `run/1` stops and returns
  `{:error, {:baseline_failed, command_module, message}}`. Without this guard
  every mutation would fail the same way: an adapter error is reported as
  killed by error, a failed setup yields no events and an empty report, and a
  failed check counts every mutation as killed. Each hides that the model or
  the adapter is broken. The message is the failure message of the baseline
  run.

  ## Usage

      # Run mutation testing
      {:ok, report} = PropertyDamage.Mutation.run(
        model: MyModel,
        targets: [{MyAdapter, config: %{base_url: "http://localhost:4000"}}],
        target_score: 0.80
      )

      # Check if tests are effective
      if PropertyDamage.Mutation.passes?(report) do
        IO.puts("Tests are effective!")
      else
        IO.puts("Tests need improvement")
        IO.puts(PropertyDamage.Mutation.format(report))
      end

      # Get detailed analysis
      analysis = PropertyDamage.Mutation.analyze(report)
      IO.puts(PropertyDamage.Mutation.Analysis.format(analysis))

  Each command module of the model's `commands/0` is a mutation target: a
  mutant changes the events that module's commands answer. For a model with
  `c:PropertyDamage.Model.expansions/0` the targets are still the roots of
  `commands/0`, not the leaf modules an expansion produces. A leaf's events
  are not mutated, and a mutant of a root that every run executes as an
  expansion is never applied, so it is reported as survived.

  ## Mutation Operators

  - `:value` - Mutates numeric and string values (zero, negate, off-by-one)
  - `:omission` - Removes fields from events
  - `:status` - Changes success/error outcomes
  - `:event` - Modifies event contents and structure
  - `:boundary` - Pushes values to edge cases (0, -1, max, nil)

  ## Options

  - `:model` - The model module (required)
  - `:targets` - A list with exactly one entry (required): an adapter module or
    `{AdapterModule, config: map}`; see `PropertyDamage.Target`. `injectors:` and
    `mocks:` are not supported and raise.
  - `:operators` - List of operator names (default: all)
  - `:mutations_per_command` - Max mutations per operator (default: 5). A command
    gets up to this cap times the number of operators.
  - `:max_runs` - Property test runs per mutation (default: 10)
  - `:target_score` - Target mutation score (default: 0.80)
  - `:timeout_ms` - Timeout per mutation test (default: 30000)
  - `:verbose` - Print progress (default: false)
  - `:on_progress` - A 1-arity function called with a `%PropertyDamage.Progress{}`
    per mutation (`data: %PropertyDamage.Progress.MutationUpdate{}`) and once at
    the end with the terminal report (`data: %PropertyDamage.Progress.MutationResult{}`)

  ## Outcomes

  Each mutation ends as `:killed`, `:killed_by_error`, `:survived` or
  `:timeout`. A mutation is `:timeout` when its test runs longer than
  `:timeout_ms`; the report counts it in `timeout` and in the score's
  denominator, so it counts against the score like a survivor.
  """

  alias PropertyDamage.Mutation.{Analysis, Formatter, Report, Runner}

  @doc """
  Runs mutation testing against a model.

  Returns `{:ok, report}` with mutation testing results, or
  `{:error, {:baseline_failed, command_module, message}}` when the baseline run
  for `command_module` fails with an adapter error or a failed setup.

  ## Examples

      {:ok, report} = PropertyDamage.Mutation.run(
        model: MyModel,
        targets: [MyAdapter],
        operators: [:value, :omission],
        target_score: 0.80
      )

      report.mutation_score  # => 0.85
      report.killed          # => 17
      report.killed_by_error # => 2
      report.survived        # => 3
  """
  @spec run(keyword()) ::
          {:ok, Report.t()}
          | {:error, {:baseline_failed, module(), String.t()}}
  defdelegate run(opts), to: Runner

  @doc """
  Checks if a mutation report passes the target score.

  ## Examples

      if PropertyDamage.Mutation.passes?(report) do
        IO.puts("Tests are effective!")
      end
  """
  @spec passes?(Report.t()) :: boolean()
  defdelegate passes?(report), to: Report

  @doc """
  Formats a mutation report for display.

  ## Formats

  - `:terminal` - ASCII boxes for console output (default)
  - `:markdown` - Markdown tables for documentation
  - `:json` - JSON for programmatic analysis

  ## Examples

      IO.puts(PropertyDamage.Mutation.format(report))
      IO.puts(PropertyDamage.Mutation.format(report, :markdown))
  """
  @spec format(Report.t(), atom()) :: String.t()
  defdelegate format(report, format \\ :terminal), to: Formatter

  @doc """
  Analyzes a mutation report to identify weaknesses.

  Returns insights about:
  - Weak commands (low kill rates)
  - Weak operators (types of mutations that survive)
  - Unchecked fields
  - Actionable suggestions

  ## Examples

      analysis = PropertyDamage.Mutation.analyze(report)
      IO.puts(analysis.summary)
      Enum.each(analysis.suggestions, &IO.puts/1)
  """
  @spec analyze(Report.t()) :: Analysis.analysis()
  defdelegate analyze(report), to: Analysis

  @doc """
  Returns the weakest commands from a report, sorted by kill rate.

  ## Examples

      for {cmd, stats} <- PropertyDamage.Mutation.weakest_commands(report) do
        IO.puts("\#{cmd}: \#{stats.score * 100}%")
      end
  """
  @spec weakest_commands(Report.t()) :: [{module(), Report.command_stats()}]
  defdelegate weakest_commands(report), to: Report

  @doc """
  Returns the weakest operators from a report, sorted by kill rate.
  """
  @spec weakest_operators(Report.t()) :: [{atom(), Report.command_stats()}]
  defdelegate weakest_operators(report), to: Report

  @doc """
  Returns all available mutation operator names.

  ## Examples

      PropertyDamage.Mutation.available_operators()
      # => [:value, :omission, :status, :event, :boundary]
  """
  @spec available_operators() :: [atom()]
  def available_operators do
    [:value, :omission, :status, :event, :boundary]
  end
end
