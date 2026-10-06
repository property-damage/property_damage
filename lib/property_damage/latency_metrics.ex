defmodule PropertyDamage.LatencyMetrics do
  @moduledoc false
  # Per-target latency metrics for `latency:` and the judgment of its budget.
  #
  # Every measured run contributes one sample per set-up target: the wall-clock
  # time of each command's `execute/3`, with the module of the root command it
  # belongs to. The metrics of a target summarize all of its samples, in
  # microseconds: the 50th, 95th and 99th percentiles (linear interpolation),
  # the mean, min and max, the number of timed commands, and the 95th
  # percentile and count per root command module. A target with no timed
  # command has `%{error: :no_data}` and is never judged.
  #
  # The budget is judged once, on the metrics of the whole campaign: each
  # `max:` bound against the target's own statistic, each `max_ratio:` bound
  # against the statistic divided by the reference's.

  alias PropertyDamage.Failure

  @statistics [:p50, :p95, :p99, :mean]
  @bounds [:max, :max_ratio]

  @doc false
  # One run's sample, keyed by target name. `latencies` holds one list of
  # `{root_index, elapsed_us}` per set-up target, in target order, as
  # `PropertyDamage.Scheduler` reports them; `commands` is the run's flat
  # command list, which the root index points into.
  @spec sample([PropertyDamage.Target.t()], [list()], [struct()]) :: %{String.t() => map()}
  def sample(targets, latencies, commands) do
    modules = commands |> Enum.map(& &1.__struct__) |> List.to_tuple()

    targets
    |> Enum.zip(latencies)
    |> Map.new(fn {target, timings} ->
      {target.name,
       %{timings: Enum.map(timings, fn {root, elapsed} -> {elem(modules, root), elapsed} end)}}
    end)
  end

  @doc false
  # The metrics of every target over the samples of the measured runs, keyed by
  # target name.
  @spec calculate([PropertyDamage.Target.t()], [%{String.t() => map()}]) :: %{
          String.t() => map()
        }
  def calculate(targets, samples) do
    for target <- targets, into: %{} do
      timings = for run <- samples, data = run[target.name], timing <- data.timings, do: timing
      {target.name, target_metrics(timings)}
    end
  end

  defp target_metrics([]), do: %{error: :no_data}

  defp target_metrics(timings) do
    sorted = timings |> Enum.map(&elem(&1, 1)) |> Enum.sort()

    %{
      p50: percentile(sorted, 50),
      p95: percentile(sorted, 95),
      p99: percentile(sorted, 99),
      mean: mean(sorted),
      min: List.first(sorted),
      max: List.last(sorted),
      commands: length(sorted),
      by_command: by_command(timings)
    }
  end

  defp by_command(timings) do
    timings
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {module, elapsed} ->
      {module, %{p95: percentile(Enum.sort(elapsed), 95), commands: length(elapsed)}}
    end)
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

  # ============================================================================
  # Budget judgment
  # ============================================================================

  @doc false
  # The breaches of `budget` (the normalized `latency:` keyword) in `metrics`,
  # as `{target, %Failure{}}` in reporting order: target order, then
  # `p50, p95, p99, mean`, then `max` before `max_ratio`. The reference (the
  # first target) is judged on `max:` only.
  @spec judge([PropertyDamage.Target.t()], %{String.t() => map()}, keyword()) ::
          [{PropertyDamage.Target.t(), Failure.t()}]
  def judge([reference | _] = targets, metrics, budget) do
    for target <- targets,
        own = Map.fetch!(metrics, target.name),
        not match?(%{error: _}, own),
        statistic <- @statistics,
        bounds = Keyword.get(budget, statistic),
        is_list(bounds),
        bound <- @bounds,
        {:ok, limit} <- [Keyword.fetch(bounds, bound)],
        bound == :max or target.index != reference.index,
        failure = breach(statistic, bound, limit, own, reference, metrics),
        do: {target, failure}
  end

  defp breach(statistic, :max, duration, own, _reference, _metrics) do
    limit = to_microseconds(duration)
    value = Map.fetch!(own, statistic)

    if value > limit do
      Failure.latency_exceeded(%{
        statistic: statistic,
        bound: :max,
        value: value,
        limit: limit,
        reference_value: nil,
        metrics: own
      })
    end
  end

  defp breach(statistic, :max_ratio, ratio, own, reference, metrics) do
    with %{} = reference_metrics <- Map.fetch!(metrics, reference.name),
         {:ok, reference_value} <- Map.fetch(reference_metrics, statistic),
         {true, value} <- exceeds_ratio(Map.fetch!(own, statistic), reference_value, ratio) do
      Failure.latency_exceeded(%{
        statistic: statistic,
        bound: :max_ratio,
        value: value,
        limit: ratio,
        reference_value: reference_value,
        metrics: own
      })
    else
      _ -> nil
    end
  end

  # A zero reference makes any positive statistic an unbounded ratio.
  defp exceeds_ratio(value, reference_value, _ratio) when reference_value == 0,
    do: {value > 0, :infinity}

  defp exceeds_ratio(value, reference_value, ratio) do
    measured = value / reference_value
    {measured > ratio, measured}
  end

  defp to_microseconds({n, :milliseconds}), do: n * 1_000
  defp to_microseconds({n, :seconds}), do: n * 1_000_000
  defp to_microseconds({n, :minutes}), do: n * 60_000_000

  # ============================================================================
  # Rendering
  # ============================================================================

  @doc false
  # What a breach measured, as the tail of the verdict line: the statistic,
  # the bound, the value against the limit, units written.
  @spec describe(Failure.Latency.t()) :: String.t()
  def describe(%Failure.Latency{bound: :max} = latency) do
    "#{latency.statistic} max: #{microseconds(latency.value)} against #{microseconds(latency.limit)}"
  end

  def describe(%Failure.Latency{bound: :max_ratio} = latency) do
    "#{latency.statistic} max_ratio: #{ratio(latency.value)} against #{inspect(latency.limit)}" <>
      " (reference #{latency.statistic} #{microseconds(latency.reference_value)})"
  end

  @doc false
  @spec verdict(String.t(), Failure.Latency.t()) :: String.t()
  def verdict(variant_name, %Failure.Latency{} = latency),
    do: "variant #{variant_name} exceeded #{describe(latency)}"

  defp microseconds(value) when is_integer(value), do: "#{value} us"
  defp microseconds(value), do: "#{:erlang.float_to_binary(value, decimals: 1)} us"

  defp ratio(:infinity), do: "infinity"
  defp ratio(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)

  @rows [:p50, :p95, :p99, :mean, :min, :max, :commands]

  @doc false
  # The metrics of every variant side by side, one line per row, one column per
  # variant name, as text lines. Microseconds are written in the header.
  @spec table_lines(%{String.t() => map()}, [String.t()]) :: [String.t()]
  def table_lines(metrics, names) do
    width = names |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end) |> max(12)
    header = pad("variant (us)", 14) <> Enum.map_join(names, &pad_left(&1, width + 2))

    rows =
      for row <- @rows do
        cells =
          Enum.map_join(names, fn name ->
            pad_left(cell(Map.get(metrics, name), row), width + 2)
          end)

        pad(Atom.to_string(row), 14) <> cells
      end

    [header | rows]
  end

  defp cell(%{error: :no_data}, _row), do: "no data"
  defp cell(nil, _row), do: "-"
  defp cell(metrics, :commands), do: Integer.to_string(metrics.commands)

  defp cell(metrics, row),
    do: :erlang.float_to_binary(Map.fetch!(metrics, row) * 1.0, decimals: 1)

  defp pad(text, width), do: String.pad_trailing(text, width)
  defp pad_left(text, width), do: String.pad_leading(text, width)
end
