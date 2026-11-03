defmodule PropertyDamage.Model.Projection.Statistics do
  @moduledoc """
  Projection that computes statistical properties over event streams.

  Traditional checks test exact conditions. Statistical projections enable
  probabilistic checks like:

  - "p99 latency < 100ms"
  - "error rate < 1%"
  - "success rate > 99% over last 100 operations"

  ## Why Statistical Projections?

  Nemesis can inject latency, but we need **statistical checks** to verify
  the system handles it gracefully:

  - A single slow request isn't a bug
  - 50% of requests being slow IS a bug
  - 1% error rate might be acceptable; 10% is not

  ## Usage

  List the module bare in `check_projections/0`. It tracks the metrics below
  from the events of a run and ships no check of its own.

      def check_projections do
        [PropertyDamage.Model.Projection.Statistics]
      end

  A threshold is a check, and a check belongs to a projection of your own.
  Write one that hands `init/0` and `apply/2` to this module and declares a
  `@check` over `compute_metrics/1`:

      defmodule MyApp.LatencyBudget do
        use PropertyDamage.Model.Projection

        alias PropertyDamage.Model.Projection.Statistics

        def init, do: Statistics.init()

        def apply(state, item), do: Statistics.apply(state, item)

        @check every: 10
        def p99_under_budget(state, _cmd_or_event) do
          p99 = Statistics.compute_metrics(state).p99_latency_ms

          p99 < 500 or
            PropertyDamage.fail!("p99 latency over budget", p99_latency_ms: p99, budget_ms: 500)
        end
      end

  List `MyApp.LatencyBudget` in `check_projections/0` in place of this module.
  The same pattern covers `error_rate`, `success_rate` and the other metrics.

  The state keeps the last 100 latency samples. For another window, build the
  state with `new/1` in your own `init/0`:

      def init, do: Statistics.new(window_size: 20)

  ## Tracked Metrics

  - `:p50_latency_ms` - Median latency
  - `:p95_latency_ms` - 95th percentile latency
  - `:p99_latency_ms` - 99th percentile latency
  - `:max_latency_ms` - Maximum observed latency
  - `:mean_latency_ms` - Average latency
  - `:success_rate` - Ratio of successes to total
  - `:error_rate` - Ratio of errors to total

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

  use PropertyDamage.Model.Projection

  defstruct [
    :latency_samples,
    :success_count,
    :error_count,
    :window_size,
    :current_step
  ]

  @type t :: %__MODULE__{
          latency_samples: :queue.queue(float()),
          success_count: non_neg_integer(),
          error_count: non_neg_integer(),
          window_size: pos_integer(),
          current_step: non_neg_integer()
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

  @default_window_size 100

  @doc """
  Build an empty state.

  The `:window_size` option caps how many latency samples the state keeps
  (default 100). Older samples drop out first.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      latency_samples: :queue.new(),
      success_count: 0,
      error_count: 0,
      window_size: Keyword.get(opts, :window_size, @default_window_size),
      current_step: 0
    }
  end

  @impl PropertyDamage.Model.Projection
  @spec init() :: t()
  def init, do: new()

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
