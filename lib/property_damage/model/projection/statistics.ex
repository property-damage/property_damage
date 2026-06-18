defmodule PropertyDamage.Model.Projection.Statistics do
  @moduledoc """
  Projection that computes statistical properties over event streams.

  Traditional assertions check exact conditions. Statistical projections enable
  probabilistic assertions like:

  - "p99 latency < 100ms"
  - "error rate < 1%"
  - "success rate > 99% over last 100 operations"

  ## Why Statistical Projections?

  Nemesis can inject latency, but we need **statistical assertions** to verify
  the system handles it gracefully:

  - A single slow request isn't a bug
  - 50% of requests being slow IS a bug
  - 1% error rate might be acceptable; 10% is not

  ## Usage

      defmodule MyModel do
        def assertion_projections do
          [
            {PropertyDamage.Model.Projection.Statistics, [
              window_size: 100,
              assertions: [
                {:p99_latency_ms, :less_than, 500},
                {:error_rate, :less_than, 0.05},
                {:success_rate, :greater_than, 0.95}
              ]
            ]}
          ]
        end
      end

  ## Tracked Metrics

  - `:p50_latency_ms` - Median latency
  - `:p95_latency_ms` - 95th percentile latency
  - `:p99_latency_ms` - 99th percentile latency
  - `:max_latency_ms` - Maximum observed latency
  - `:mean_latency_ms` - Average latency
  - `:success_rate` - Ratio of successes to total
  - `:error_rate` - Ratio of errors to total
  - `:throughput` - Operations per second (requires time tracking)

  ## Recording Metrics

  Events should include latency information. The projection looks for:
  - `:latency_ms` or `:duration_ms` fields for latency tracking
  - Success events vs error events for rate calculation

  You can also record metrics explicitly in your adapter.

  ## Limitations

  - Statistics only meaningful with sufficient sample size
  - Shrinking statistical failures is problematic (minimal case may not reproduce)
  - Thresholds are environment-dependent (CI vs production hardware)
  """

  @behaviour PropertyDamage.Model.Projection

  defstruct [
    :latency_samples,
    :success_count,
    :error_count,
    :window_size,
    :assertions,
    :current_step,
    :start_time
  ]

  @type t :: %__MODULE__{
          latency_samples: :queue.queue(float()),
          success_count: non_neg_integer(),
          error_count: non_neg_integer(),
          window_size: pos_integer(),
          assertions: [assertion()],
          current_step: non_neg_integer(),
          start_time: integer()
        }

  @type metric ::
          :p50_latency_ms
          | :p95_latency_ms
          | :p99_latency_ms
          | :max_latency_ms
          | :mean_latency_ms
          | :success_rate
          | :error_rate
          | :total_count

  @type comparator :: :less_than | :greater_than | :equal_to

  @type assertion :: {metric(), comparator(), number()}

  @default_window_size 100

  @impl PropertyDamage.Model.Projection
  @spec init(keyword()) :: t()
  def init(opts \\ []) do
    %__MODULE__{
      latency_samples: :queue.new(),
      success_count: 0,
      error_count: 0,
      window_size: Keyword.get(opts, :window_size, @default_window_size),
      assertions: Keyword.get(opts, :assertions, []),
      current_step: 0,
      start_time: System.monotonic_time(:millisecond)
    }
  end

  @impl PropertyDamage.Model.Projection
  def apply(state, item) do
    case item do
      %{__struct__: _} = event ->
        state
        |> maybe_record_latency(event)
        |> maybe_record_outcome(event)
        |> increment_step()

      _ ->
        increment_step(state)
    end
  end

  defp maybe_record_latency(state, event) do
    # Look for latency fields in the event
    latency =
      cond do
        Map.has_key?(event, :latency_ms) -> event.latency_ms
        Map.has_key?(event, :duration_ms) -> event.duration_ms
        true -> nil
      end

    if latency do
      record_latency(state, latency)
    else
      state
    end
  end

  defp maybe_record_outcome(state, event) do
    # Determine if this is a success or error event based on naming convention
    event_module = event.__struct__
    module_name = event_module |> Module.split() |> List.last() |> String.downcase()

    cond do
      String.contains?(module_name, "error") or
        String.contains?(module_name, "failed") or
          String.contains?(module_name, "rejected") ->
        record_error(state)

      String.contains?(module_name, "completed") or
        String.contains?(module_name, "succeeded") or
        String.contains?(module_name, "confirmed") or
          String.contains?(module_name, "created") ->
        record_success(state)

      true ->
        state
    end
  end

  defp increment_step(state) do
    %{state | current_step: state.current_step + 1}
  end

  @doc """
  Record a latency sample.
  """
  @spec record_latency(t(), number()) :: t()
  def record_latency(state, latency_ms) do
    samples = :queue.in(latency_ms, state.latency_samples)

    # Keep only window_size samples
    samples =
      if :queue.len(samples) > state.window_size do
        {_, rest} = :queue.out(samples)
        rest
      else
        samples
      end

    %{state | latency_samples: samples}
  end

  @doc """
  Record a successful operation.
  """
  @spec record_success(t()) :: t()
  def record_success(state) do
    %{state | success_count: state.success_count + 1}
  end

  @doc """
  Record an error/failure.
  """
  @spec record_error(t()) :: t()
  def record_error(state) do
    %{state | error_count: state.error_count + 1}
  end

  @doc """
  Compute all metrics from current state.
  """
  @spec compute_metrics(t()) :: %{metric() => number()}
  def compute_metrics(state) do
    samples = :queue.to_list(state.latency_samples)
    sorted_samples = Enum.sort(samples)
    sample_count = length(samples)

    total_count = state.success_count + state.error_count

    %{
      p50_latency_ms: percentile(sorted_samples, 50),
      p95_latency_ms: percentile(sorted_samples, 95),
      p99_latency_ms: percentile(sorted_samples, 99),
      max_latency_ms: if(sample_count > 0, do: Enum.max(samples), else: 0),
      mean_latency_ms: if(sample_count > 0, do: Enum.sum(samples) / sample_count, else: 0),
      success_rate: if(total_count > 0, do: state.success_count / total_count, else: 1.0),
      error_rate: if(total_count > 0, do: state.error_count / total_count, else: 0.0),
      total_count: total_count,
      sample_count: sample_count
    }
  end

  defp percentile([], _p), do: 0

  defp percentile(sorted_samples, p) do
    n = length(sorted_samples)
    k = max(0, Float.ceil(n * p / 100) - 1) |> trunc()
    Enum.at(sorted_samples, k, 0)
  end

  @doc """
  Check all configured assertions against current metrics.
  """
  @spec check_assertions(t()) :: :ok | {:error, String.t()}
  def check_assertions(state) do
    metrics = compute_metrics(state)

    failed_assertions =
      state.assertions
      |> Enum.filter(fn {metric, comparator, threshold} ->
        value = Map.get(metrics, metric, 0)
        not apply_comparator(value, comparator, threshold)
      end)

    if Enum.empty?(failed_assertions) do
      :ok
    else
      {:error, format_failures(failed_assertions, metrics)}
    end
  end

  defp apply_comparator(value, :less_than, threshold), do: value < threshold
  defp apply_comparator(value, :greater_than, threshold), do: value > threshold
  defp apply_comparator(value, :equal_to, threshold), do: value == threshold

  defp format_failures(failures, metrics) do
    details =
      failures
      |> Enum.map_join("; ", fn {metric, comparator, threshold} ->
        value = Map.get(metrics, metric, 0)
        "#{metric} = #{Float.round(value * 1.0, 4)} (expected #{comparator} #{threshold})"
      end)

    "Statistical assertion failures: #{details}"
  end

  # ============================================================================
  # Check Registration (for use as assertion projection)
  # ============================================================================

  @doc false
  def __checks__ do
    [
      %{
        name: :statistical_assertions,
        trigger: :always,
        sample: 10
      }
    ]
  end

  @doc false
  @spec check(:statistical_assertions, t(), map()) :: :ok | {:error, String.t()}
  def check(:statistical_assertions, state, _ctx) do
    # Only check if we have enough samples
    metrics = compute_metrics(state)

    if metrics.sample_count >= 10 or metrics.total_count >= 10 do
      check_assertions(state)
    else
      :ok
    end
  end

  # ============================================================================
  # Utility Functions
  # ============================================================================

  @doc """
  Get a summary of current statistics.
  """
  @spec summary(t()) :: map()
  def summary(state) do
    metrics = compute_metrics(state)

    %{
      latency: %{
        p50: metrics.p50_latency_ms,
        p95: metrics.p95_latency_ms,
        p99: metrics.p99_latency_ms,
        max: metrics.max_latency_ms,
        mean: metrics.mean_latency_ms
      },
      rates: %{
        success: metrics.success_rate,
        error: metrics.error_rate
      },
      counts: %{
        total: metrics.total_count,
        success: state.success_count,
        error: state.error_count,
        latency_samples: metrics.sample_count
      }
    }
  end

  @doc """
  Format statistics as a human-readable string.
  """
  @spec format_summary(t()) :: String.t()
  def format_summary(state) do
    s = summary(state)

    """
    Statistics Summary:
      Latency (ms): p50=#{r(s.latency.p50)} p95=#{r(s.latency.p95)} p99=#{r(s.latency.p99)} max=#{r(s.latency.max)}
      Rates: success=#{r(s.rates.success * 100)}% error=#{r(s.rates.error * 100)}%
      Counts: total=#{s.counts.total} samples=#{s.counts.latency_samples}
    """
  end

  defp r(n) when is_float(n), do: Float.round(n, 2)
  defp r(n), do: n
end
