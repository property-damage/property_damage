defmodule PropertyDamage.Differential.Result do
  @moduledoc """
  Result from differential testing.

  Contains the run's status, every divergence found (oldest first), the failure
  that ended the campaign (if any), and performance metrics.

  `status` is `:equivalent` when no run diverged, `:divergent` when at least one
  run diverged, and `:failed` when a failure ended the campaign (`failure` is
  set; divergences of earlier runs stay listed).
  """

  alias PropertyDamage.Failure

  @typedoc "A compared target: its zero-based position in `targets:` and its name."
  @type variant :: %{index: non_neg_integer(), name: String.t()}

  @typedoc """
  The first command at which a non-reference target answered differently from
  the reference. `run` is the 0-based run and `root` the command's 0-based
  index; `results` holds every target's observation of that command, keyed by
  target name.
  """
  @type divergence :: %{
          seed: integer(),
          run: non_neg_integer(),
          root: non_neg_integer(),
          command: struct(),
          variant: variant(),
          reference_result: term(),
          divergent_result: term(),
          results: %{String.t() => term()}
        }

  @typedoc """
  What ended the campaign, naming the target it happened in. `root` is `nil`
  when the failure belongs to no command (setup, a `:startup` check). `reason`
  is the `%PropertyDamage.Failure{}`, the exception an adapter raised, or the
  term a setup returned.
  """
  @type failure :: %{
          kind: :check_failed | :setup_failed | :execution_failed,
          variant: variant(),
          run: non_neg_integer(),
          root: non_neg_integer() | nil,
          reason: term()
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
          concurrency: :serial | :parallel,
          runs: non_neg_integer(),
          seed: integer(),
          reference: variant(),
          status: :equivalent | :divergent | :failed,
          divergences: [divergence()],
          failure: failure() | nil,
          metrics: %{String.t() => metrics()},
          targets: [variant()]
        }

  defstruct [
    :mode,
    :concurrency,
    :runs,
    :seed,
    :reference,
    :status,
    :divergences,
    :failure,
    :metrics,
    :targets
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
    Concurrency: #{result.concurrency}
    Runs: #{result.runs}
    Seed: #{result.seed}
    Status: #{format_status(result.status)}
    Reference: #{format_variant(result.reference)}
    Targets: #{Enum.map_join(result.targets, ", ", &format_variant/1)}
    #{if result.status == :divergent, do: "Divergences: #{length(result.divergences)}\n", else: ""}
    """
  end

  defp format_full(result) do
    summary = format_summary(result)
    metrics = if map_size(result.metrics) > 0, do: "\n" <> format_metrics(result), else: ""

    divergences =
      if result.divergences != [], do: "\n" <> format_divergences(result), else: ""

    failure = if result.failure, do: "\n" <> format_failure(result.failure), else: ""

    summary <> metrics <> divergences <> failure
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
    Run #{div.run}, root #{div.root}: #{inspect(div.command.__struct__)}
      Reference: #{inspect(div.reference_result)}
      #{div.variant.name}: #{inspect(div.divergent_result)}
    """
  end

  defp format_failure(failure) do
    """
    Failure
    -------
    #{failure.kind} in #{failure.variant.name} (run #{failure.run}, root #{format_root(failure.root)})
      #{format_reason(failure.reason)}
    """
  end

  defp format_root(nil), do: "none"
  defp format_root(root), do: root

  defp format_reason(%Failure{} = failure) do
    label = Enum.join(Enum.reject([Failure.kind(failure), Failure.name(failure)], &is_nil/1), " ")
    "#{label}: #{inspect(Failure.detail(failure))}"
  end

  defp format_reason(%{__exception__: true} = exception), do: Exception.message(exception)
  defp format_reason(reason), do: inspect(reason)

  defp format_variant(%{index: index, name: name}), do: "[#{index}] #{name}"

  defp format_status(:equivalent), do: "EQUIVALENT ✓"
  defp format_status(:divergent), do: "DIVERGENT ✗"
  defp format_status(:failed), do: "FAILED ✗"
end
