defmodule PropertyDamage.Differential.Result do
  @moduledoc """
  Result from differential testing.

  Contains comparison results, divergences, and performance metrics.
  """

  @type divergence :: %{
          required(:seed) => integer(),
          required(:command) => struct(),
          required(:step) => non_neg_integer(),
          required(:reference_result) => term(),
          required(:results) => map(),
          optional(:divergent_target) => String.t(),
          optional(:divergent_result) => term(),
          optional(:run_index) => non_neg_integer(),
          optional(:reference_name) => String.t()
        }

  @type metrics :: %{
          optional(:latency_p50) => float(),
          optional(:latency_p95) => float(),
          optional(:latency_p99) => float(),
          optional(:latency_mean) => float(),
          optional(:latency_min) => float(),
          optional(:latency_max) => float(),
          optional(:total_commands) => non_neg_integer(),
          optional(:error_count) => non_neg_integer(),
          optional(:error_rate) => float(),
          optional(:error) => atom(),
          optional(:reason) => term()
        }

  @type t :: %__MODULE__{
          mode: :correctness | :performance | :both,
          execution: :interleaved | :sequential,
          runs: non_neg_integer(),
          seed: integer(),
          reference: String.t() | nil,
          status: :equivalent | :divergent | :complete,
          divergences: [divergence()],
          metrics: %{String.t() => metrics()},
          targets: [String.t()],
          baseline: String.t() | nil
        }

  defstruct [
    :mode,
    :execution,
    :runs,
    :seed,
    :reference,
    :status,
    :divergences,
    :metrics,
    :targets,
    :baseline
  ]

  @doc """
  Check if the result indicates all targets are equivalent.
  """
  @spec equivalent?(t()) :: boolean()
  def equivalent?(%__MODULE__{status: :equivalent}), do: true
  def equivalent?(%__MODULE__{}), do: false

  @doc """
  Check if the result indicates divergence was found.
  """
  @spec divergent?(t()) :: boolean()
  def divergent?(%__MODULE__{status: :divergent}), do: true
  def divergent?(%__MODULE__{}), do: false

  @doc """
  Get the number of divergences found.
  """
  @spec divergence_count(t()) :: non_neg_integer()
  def divergence_count(%__MODULE__{divergences: divergences}) do
    length(divergences)
  end

  @doc """
  Get metrics for a specific target.
  """
  @spec metrics_for(t(), String.t()) :: metrics() | nil
  def metrics_for(%__MODULE__{metrics: metrics}, target_name) do
    Map.get(metrics, target_name)
  end

  @doc """
  Format the result for display.
  """
  @spec format(t(), keyword()) :: String.t()
  def format(%__MODULE__{} = result, opts \\ []) do
    format_type = Keyword.get(opts, :format, :summary)

    case format_type do
      :summary -> format_summary(result)
      :full -> format_full(result)
      :metrics -> format_metrics(result)
      :divergences -> format_divergences(result)
    end
  end

  defp format_summary(result) do
    """
    Differential Testing Result
    ===========================
    Mode: #{result.mode}
    Execution: #{result.execution}
    Runs: #{result.runs}
    Seed: #{result.seed}
    Status: #{format_status(result.status)}
    #{if result.reference, do: "Reference: #{result.reference}\n", else: ""}
    Targets: #{Enum.join(result.targets, ", ")}
    #{if result.status == :divergent, do: "Divergences: #{length(result.divergences)}\n", else: ""}
    """
  end

  defp format_full(result) do
    summary = format_summary(result)
    metrics = if map_size(result.metrics) > 0, do: "\n" <> format_metrics(result), else: ""

    divergences =
      if length(result.divergences) > 0, do: "\n" <> format_divergences(result), else: ""

    summary <> metrics <> divergences
  end

  defp format_metrics(result) do
    lines =
      for {target, metrics} <- result.metrics do
        format_target_metrics(target, metrics)
      end

    """
    Performance Metrics
    -------------------
    #{Enum.join(lines, "\n")}
    """
  end

  defp format_target_metrics(target, %{error: error} = metrics) do
    reason = Map.get(metrics, :reason, "")
    "#{target}: ERROR - #{error} #{inspect(reason)}"
  end

  defp format_target_metrics(target, metrics) do
    """
    #{target}:
      Latency P50: #{format_us(metrics.latency_p50)}
      Latency P95: #{format_us(metrics.latency_p95)}
      Latency P99: #{format_us(metrics.latency_p99)}
      Latency Mean: #{format_us(metrics.latency_mean)}
      Commands: #{metrics.total_commands}
      Errors: #{metrics.error_count} (#{Float.round(metrics.error_rate * 100, 2)}%)
    """
  end

  defp format_us(microseconds) when is_number(microseconds) do
    cond do
      microseconds < 1000 ->
        "#{Float.round(microseconds / 1, 2)}µs"

      microseconds < 1_000_000 ->
        "#{Float.round(microseconds / 1000, 2)}ms"

      true ->
        "#{Float.round(microseconds / 1_000_000, 2)}s"
    end
  end

  defp format_divergences(result) do
    lines =
      result.divergences
      |> Enum.take(10)
      |> Enum.map(&format_divergence/1)

    remaining = length(result.divergences) - 10

    suffix =
      if remaining > 0 do
        "\n... and #{remaining} more divergences"
      else
        ""
      end

    """
    Divergences
    -----------
    #{Enum.join(lines, "\n\n")}#{suffix}
    """
  end

  defp format_divergence(div) do
    """
    Step #{div.step}: #{inspect(div.command.__struct__)}
      Reference: #{inspect(div.reference_result)}
      #{div.divergent_target}: #{inspect(div.divergent_result)}
    """
  end

  defp format_status(:equivalent), do: "EQUIVALENT ✓"
  defp format_status(:divergent), do: "DIVERGENT ✗"
  defp format_status(:complete), do: "COMPLETE"
end
