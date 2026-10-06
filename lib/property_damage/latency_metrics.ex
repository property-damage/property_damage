defmodule PropertyDamage.LatencyMetrics do
  @moduledoc false
  # Per-target latency metrics for `compare: :performance | :both`.
  #
  # Every measured run contributes one sample per target that was set up: the
  # wall-clock time of each command's `execute/3` and the target's observation
  # of each command. The metrics of a target summarize all of its samples: the
  # 50th, 95th and 99th latency percentiles (linear interpolation), the mean,
  # min and max, the number of timed commands, and how many observations were
  # adapter `{:error, _}` answers. Times are in microseconds.

  @doc false
  # One run's sample, keyed by target name. `latencies` and `observations` hold
  # one list per set-up target, in target order, as `PropertyDamage.Scheduler`
  # reports them.
  @spec sample([PropertyDamage.Target.t()], [list()], [list()]) :: %{String.t() => map()}
  def sample(targets, latencies, observations) do
    [targets, latencies, observations]
    |> Enum.zip()
    |> Map.new(fn {target, latencies, observations} ->
      {target.name,
       %{
         timings: Enum.map(latencies, &elem(&1, 1)),
         results: Enum.map(observations, &elem(&1, 1))
       }}
    end)
  end

  @doc false
  # The metrics of every target over the samples of the measured runs, keyed by
  # target name. A target with no timed command reports `%{error: :no_data}`.
  @spec calculate([PropertyDamage.Target.t()], [%{String.t() => map()}]) :: %{
          String.t() => map()
        }
  def calculate(targets, samples) do
    for target <- targets, into: %{} do
      runs = for run <- samples, data = run[target.name], do: data
      {target.name, target_metrics(runs)}
    end
  end

  defp target_metrics(runs) do
    all_timings =
      runs
      |> Enum.flat_map(& &1.timings)
      |> Enum.sort()

    if all_timings != [] do
      %{
        latency_p50: percentile(all_timings, 50),
        latency_p95: percentile(all_timings, 95),
        latency_p99: percentile(all_timings, 99),
        latency_mean: mean(all_timings),
        latency_min: Enum.min(all_timings),
        latency_max: Enum.max(all_timings),
        total_commands: length(all_timings),
        error_count: count_errors(runs),
        error_rate: error_rate(runs)
      }
    else
      %{error: :no_data}
    end
  end

  defp percentile(sorted_list, p) when sorted_list != [] do
    k = p / 100.0 * (length(sorted_list) - 1)
    f = :erlang.trunc(k)
    c = f + 1

    if c >= length(sorted_list) do
      Enum.at(sorted_list, f)
    else
      d0 = Enum.at(sorted_list, f) * (c - k)
      d1 = Enum.at(sorted_list, c) * (k - f)
      d0 + d1
    end
  end

  defp mean(list) when list != [] do
    Enum.sum(list) / length(list)
  end

  defp count_errors(runs) do
    runs
    |> Enum.flat_map(& &1.results)
    |> Enum.count(&match?({:error, _}, &1))
  end

  defp error_rate(runs) do
    total = runs |> Enum.flat_map(& &1.results) |> length()

    if total > 0 do
      count_errors(runs) / total
    else
      0.0
    end
  end
end
