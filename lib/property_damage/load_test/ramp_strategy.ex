defmodule PropertyDamage.LoadTest.RampStrategy do
  @moduledoc """
  Controls how arrival rate is ramped up and down during a load test.

  ## Strategies

  - `:immediate` - Start at full rate immediately
  - `{:linear, duration}` - Gradually increase rate over duration
  - `{:step, count, interval}` - Increase rate in steps
  - `{:exponential, duration}` - Exponential growth to target rate

  ## Usage

      # Immediate - start at 100 arrivals/sec immediately
      plan = RampStrategy.plan(:immediate, {100, {1, :seconds}})

      # Linear - ramp to 100/sec over 60 seconds
      plan = RampStrategy.plan({:linear, {60, :seconds}}, {100, {1, :seconds}})

      # Step - increase rate every 15 seconds in 4 steps
      plan = RampStrategy.plan({:step, 4, {15, :seconds}}, {100, {1, :seconds}})

      # Exponential - exponential growth to 100/sec over 2 minutes
      plan = RampStrategy.plan({:exponential, {2, :minutes}}, {100, {1, :seconds}})

  ## Plan Format

  A plan is a list of `{time_ms, rate_spec}` tuples:

      [
        {0, {25, {1, :seconds}}},
        {15000, {50, {1, :seconds}}},
        {30000, {75, {1, :seconds}}},
        {45000, {100, {1, :seconds}}}
      ]

  The rate_spec is in the normalized form `{count, {time, unit}}`.
  """

  alias PropertyDamage.Options

  @type strategy ::
          :immediate
          | {:linear, duration()}
          | {:step, pos_integer(), duration()}
          | {:exponential, duration()}

  @type duration :: {pos_integer(), :milliseconds | :seconds | :minutes | :hours}
  @type rate_spec :: {pos_integer(), duration()}
  @type plan :: [{non_neg_integer(), rate_spec()}]

  @doc """
  Generate a ramp plan for the given strategy and target rate.

  ## Parameters

  - `strategy` - The ramping strategy to use
  - `target_rate` - Target arrival rate as `{count, {time, unit}}`

  ## Returns

  A list of `{time_ms, rate_spec}` tuples indicating when to
  adjust the arrival rate.
  """
  @spec plan(strategy(), rate_spec()) :: plan()
  def plan(:immediate, target_rate) do
    [{0, target_rate}]
  end

  def plan({:linear, duration}, target_rate) do
    duration_ms = to_ms(duration)
    target_per_sec = rate_to_per_second(target_rate)

    # Create 10 steps for linear ramp
    steps = 10
    step_duration = div(duration_ms, steps)

    for i <- 0..(steps - 1) do
      time_ms = i * step_duration
      factor = (i + 1) / steps
      rate_per_sec = max(1, round(target_per_sec * factor))
      {time_ms, {rate_per_sec, {1, :seconds}}}
    end
  end

  def plan({:step, num_steps, interval}, target_rate) do
    interval_ms = to_ms(interval)
    target_per_sec = rate_to_per_second(target_rate)

    for i <- 0..(num_steps - 1) do
      time_ms = i * interval_ms
      factor = (i + 1) / num_steps
      rate_per_sec = max(1, round(target_per_sec * factor))
      {time_ms, {rate_per_sec, {1, :seconds}}}
    end
  end

  def plan({:exponential, duration}, target_rate) do
    duration_ms = to_ms(duration)
    target_per_sec = rate_to_per_second(target_rate)

    # Use 10 steps for exponential growth
    steps = 10
    step_duration = div(duration_ms, steps)

    # Exponential growth: rate = target * (e^(k*t) - 1) / (e^k - 1)
    k = 2.0

    for i <- 0..(steps - 1) do
      time_ms = i * step_duration
      t = (i + 1) / steps
      factor = (:math.exp(k * t) - 1) / (:math.exp(k) - 1)
      rate_per_sec = max(1, round(target_per_sec * factor))
      {time_ms, {rate_per_sec, {1, :seconds}}}
    end
  end

  @doc """
  Generate a ramp-down plan.

  Similar to plan/2 but decreases from current rate to minimum (1/sec).

  ## Parameters

  - `strategy` - The ramping strategy to use
  - `current_rate` - Current arrival rate as `{count, {time, unit}}`
  """
  @spec plan_down(strategy(), rate_spec()) :: plan()
  def plan_down(:immediate, _current_rate) do
    # Minimum rate of 1 per second during ramp-down
    [{0, {1, {1, :seconds}}}]
  end

  def plan_down({:linear, duration}, current_rate) do
    duration_ms = to_ms(duration)
    current_per_sec = rate_to_per_second(current_rate)

    steps = 10
    step_duration = div(duration_ms, steps)

    for i <- 0..(steps - 1) do
      time_ms = i * step_duration
      factor = 1 - (i + 1) / steps
      rate_per_sec = max(1, round(current_per_sec * factor))
      {time_ms, {rate_per_sec, {1, :seconds}}}
    end
  end

  def plan_down({:step, num_steps, interval}, current_rate) do
    interval_ms = to_ms(interval)
    current_per_sec = rate_to_per_second(current_rate)

    for i <- 0..(num_steps - 1) do
      time_ms = i * interval_ms
      factor = 1 - (i + 1) / num_steps
      rate_per_sec = max(1, round(current_per_sec * factor))
      {time_ms, {rate_per_sec, {1, :seconds}}}
    end
  end

  def plan_down({:exponential, duration}, current_rate) do
    duration_ms = to_ms(duration)
    current_per_sec = rate_to_per_second(current_rate)

    steps = 10
    step_duration = div(duration_ms, steps)
    k = 2.0

    for i <- 0..(steps - 1) do
      time_ms = i * step_duration
      t = (i + 1) / steps
      factor = (:math.exp(k * t) - 1) / (:math.exp(k) - 1)
      rate_per_sec = max(1, round(current_per_sec * (1 - factor)))
      {time_ms, {rate_per_sec, {1, :seconds}}}
    end
  end

  @doc """
  Get the rate at a given time point from a plan.
  """
  @spec rate_at(plan(), non_neg_integer()) :: rate_spec() | nil
  def rate_at(plan, time_ms) do
    applicable =
      plan
      |> Enum.filter(fn {t, _} -> t <= time_ms end)
      |> List.last()

    case applicable do
      nil -> nil
      {_, rate} -> rate
    end
  end

  @doc """
  Get total duration of a plan in milliseconds.
  """
  @spec duration_ms(plan()) :: non_neg_integer()
  def duration_ms([]), do: 0

  def duration_ms(plan) do
    plan
    |> Enum.map(fn {t, _} -> t end)
    |> Enum.max()
  end

  @doc """
  Convert a rate spec to arrivals per second.
  """
  @spec rate_to_per_second(rate_spec()) :: float()
  def rate_to_per_second({count, {time, unit}}) do
    interval_ms = to_ms({time, unit})
    count * 1000.0 / interval_ms
  end

  @doc """
  Convert a rate spec to interval in milliseconds between arrivals.
  """
  @spec rate_to_interval_ms(rate_spec()) :: float()
  def rate_to_interval_ms(rate_spec) do
    Options.arrival_rate_to_interval_ms(rate_spec)
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp to_ms({value, :milliseconds}), do: value
  defp to_ms({value, :seconds}), do: value * 1000
  defp to_ms({value, :minutes}), do: value * 60 * 1000
  defp to_ms({value, :hours}), do: value * 60 * 60 * 1000
end
