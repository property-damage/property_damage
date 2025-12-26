defmodule PropertyDamage.Mutation.Report do
  @moduledoc """
  Report structure for mutation testing results.

  The report aggregates results from running mutations and provides
  statistics about test effectiveness.

  ## Fields

  - `mutation_score` - Ratio of killed to total mutations (0.0 to 1.0)
  - `killed` - Number of mutations that were caught by tests
  - `survived` - Number of mutations that tests failed to catch
  - `timeout` - Number of mutations that timed out
  - `total` - Total number of mutations tested
  - `by_command` - Breakdown by command type
  - `by_operator` - Breakdown by mutation operator
  - `survived_mutations` - Details of mutations that survived
  - `killed_mutations` - Details of mutations that were killed
  - `duration_ms` - Total time taken
  - `started_at` - When testing started
  - `completed_at` - When testing completed
  """

  defstruct [
    :mutation_score,
    :killed,
    :survived,
    :timeout,
    :total,
    :by_command,
    :by_operator,
    :survived_mutations,
    :killed_mutations,
    :duration_ms,
    :started_at,
    :completed_at,
    :target_score,
    :model,
    :adapter
  ]

  @type mutation_result :: %{
          mutation: map(),
          command: module(),
          operator: atom(),
          result: :killed | :survived | :timeout,
          failure_message: String.t() | nil,
          duration_ms: non_neg_integer()
        }

  @type command_stats :: %{
          killed: non_neg_integer(),
          survived: non_neg_integer(),
          timeout: non_neg_integer(),
          total: non_neg_integer(),
          score: float()
        }

  @type t :: %__MODULE__{
          mutation_score: float(),
          killed: non_neg_integer(),
          survived: non_neg_integer(),
          timeout: non_neg_integer(),
          total: non_neg_integer(),
          by_command: %{module() => command_stats()},
          by_operator: %{atom() => command_stats()},
          survived_mutations: [mutation_result()],
          killed_mutations: [mutation_result()],
          duration_ms: non_neg_integer(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          target_score: float(),
          model: module() | nil,
          adapter: module() | nil
        }

  @doc """
  Creates a new empty report.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      mutation_score: 0.0,
      killed: 0,
      survived: 0,
      timeout: 0,
      total: 0,
      by_command: %{},
      by_operator: %{},
      survived_mutations: [],
      killed_mutations: [],
      duration_ms: 0,
      started_at: nil,
      completed_at: nil,
      target_score: Keyword.get(opts, :target_score, 0.80),
      model: Keyword.get(opts, :model),
      adapter: Keyword.get(opts, :adapter)
    }
  end

  @doc """
  Records a mutation result in the report.
  """
  @spec record_result(t(), mutation_result()) :: t()
  def record_result(report, result) do
    %{command: command, operator: operator, result: outcome} = result

    report
    |> increment_totals(outcome)
    |> update_by_command(command, outcome)
    |> update_by_operator(operator, outcome)
    |> record_mutation_detail(result, outcome)
    |> recalculate_score()
  end

  @doc """
  Finalizes the report with timing information.
  """
  @spec finalize(t(), DateTime.t(), DateTime.t()) :: t()
  def finalize(report, started_at, completed_at) do
    duration_ms = DateTime.diff(completed_at, started_at, :millisecond)

    %{report | started_at: started_at, completed_at: completed_at, duration_ms: duration_ms}
    |> recalculate_score()
  end

  @doc """
  Checks if the report passes the target score.
  """
  @spec passes?(t()) :: boolean()
  def passes?(report) do
    report.mutation_score >= report.target_score
  end

  @doc """
  Returns commands sorted by kill rate (weakest first).
  """
  @spec weakest_commands(t()) :: [{module(), command_stats()}]
  def weakest_commands(report) do
    report.by_command
    |> Enum.sort_by(fn {_cmd, stats} -> stats.score end, :asc)
  end

  @doc """
  Returns operators sorted by kill rate (weakest first).
  """
  @spec weakest_operators(t()) :: [{atom(), command_stats()}]
  def weakest_operators(report) do
    report.by_operator
    |> Enum.sort_by(fn {_op, stats} -> stats.score end, :asc)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp increment_totals(report, outcome) do
    report = %{report | total: report.total + 1}

    case outcome do
      :killed -> %{report | killed: report.killed + 1}
      :survived -> %{report | survived: report.survived + 1}
      :timeout -> %{report | timeout: report.timeout + 1}
    end
  end

  defp update_by_command(report, command, outcome) do
    stats = Map.get(report.by_command, command, empty_stats())
    updated_stats = increment_stats(stats, outcome)
    %{report | by_command: Map.put(report.by_command, command, updated_stats)}
  end

  defp update_by_operator(report, operator, outcome) do
    stats = Map.get(report.by_operator, operator, empty_stats())
    updated_stats = increment_stats(stats, outcome)
    %{report | by_operator: Map.put(report.by_operator, operator, updated_stats)}
  end

  defp record_mutation_detail(report, result, :killed) do
    %{report | killed_mutations: [result | report.killed_mutations]}
  end

  defp record_mutation_detail(report, result, :survived) do
    %{report | survived_mutations: [result | report.survived_mutations]}
  end

  defp record_mutation_detail(report, _result, :timeout) do
    # Don't record timeout details
    report
  end

  defp recalculate_score(report) do
    score =
      if report.total > 0 do
        report.killed / report.total
      else
        0.0
      end

    %{report | mutation_score: score}
  end

  defp empty_stats do
    %{killed: 0, survived: 0, timeout: 0, total: 0, score: 0.0}
  end

  defp increment_stats(stats, outcome) do
    stats = %{stats | total: stats.total + 1}

    stats =
      case outcome do
        :killed -> %{stats | killed: stats.killed + 1}
        :survived -> %{stats | survived: stats.survived + 1}
        :timeout -> %{stats | timeout: stats.timeout + 1}
      end

    score = if stats.total > 0, do: stats.killed / stats.total, else: 0.0
    %{stats | score: score}
  end
end
