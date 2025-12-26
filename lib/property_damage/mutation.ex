defmodule PropertyDamage.Mutation do
  @moduledoc """
  Mutation testing for PropertyDamage.

  Mutation testing verifies that your property-based tests are effective by:
  1. Injecting faults (mutations) into adapter responses
  2. Running tests against the mutated responses
  3. Checking if tests catch (kill) the mutations

  A **killed** mutant means your tests detected the simulated bug (good).
  A **survived** mutant means your tests missed the bug (bad - weak tests).

  ## Usage

      # Run mutation testing
      {:ok, report} = PropertyDamage.Mutation.run(
        model: MyModel,
        adapter: MyAdapter,
        adapter_config: %{base_url: "http://localhost:4000"},
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

  ## Mutation Operators

  - `:value` - Mutates numeric and string values (zero, negate, off-by-one)
  - `:omission` - Removes fields from events
  - `:status` - Changes success/error outcomes
  - `:event` - Modifies event contents and structure
  - `:boundary` - Pushes values to edge cases (0, -1, max, nil)

  ## Options

  - `:model` - The model module (required)
  - `:adapter` - The adapter module (required)
  - `:adapter_config` - Configuration for the adapter
  - `:operators` - List of operator names (default: all)
  - `:mutations_per_command` - Max mutations per command (default: 5)
  - `:max_runs` - Property test runs per mutation (default: 10)
  - `:target_score` - Target mutation score (default: 0.80)
  - `:timeout_ms` - Timeout per mutation test (default: 30000)
  - `:verbose` - Print progress (default: false)
  """

  alias PropertyDamage.Mutation.{Analysis, Formatter, Report, Runner}

  @doc """
  Runs mutation testing against a model.

  Returns `{:ok, report}` with mutation testing results.

  ## Examples

      {:ok, report} = PropertyDamage.Mutation.run(
        model: MyModel,
        adapter: MyAdapter,
        operators: [:value, :omission],
        target_score: 0.80
      )

      report.mutation_score  # => 0.85
      report.killed          # => 17
      report.survived        # => 3
  """
  @spec run(keyword()) :: {:ok, Report.t()} | {:error, term()}
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
