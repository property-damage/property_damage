defmodule PropertyDamage.LoadTest.RampStrategy do
  @moduledoc """
  Controls how load is ramped up and down during a load test.

  ## Strategies

  - `:immediate` - Start all users at once
  - `{:linear, duration}` - Gradually add users over duration
  - `{:step, count, interval}` - Add users in steps
  - `{:exponential, duration}` - Exponential growth to target

  ## Usage

      # Immediate - all 100 users start at once
      plan = RampStrategy.plan(:immediate, 100)

      # Linear - ramp to 100 users over 60 seconds
      plan = RampStrategy.plan({:linear, {60, :seconds}}, 100)

      # Step - add 25 users every 15 seconds
      plan = RampStrategy.plan({:step, 4, {15, :seconds}}, 100)

      # Exponential - exponential growth to 100 over 2 minutes
      plan = RampStrategy.plan({:exponential, {2, :minutes}}, 100)

  ## Plan Format

  A plan is a list of `{time_ms, target_users}` tuples:

      [
        {0, 25},
        {15000, 50},
        {30000, 75},
        {45000, 100}
      ]
  """

  @type strategy ::
          :immediate
          | {:linear, duration()}
          | {:step, pos_integer(), duration()}
          | {:exponential, duration()}

  @type duration :: {pos_integer(), :milliseconds | :seconds | :minutes}
  @type plan :: [{non_neg_integer(), pos_integer()}]

  @doc """
  Generate a ramp plan for the given strategy and target users.

  ## Parameters

  - `strategy` - The ramping strategy to use
  - `target_users` - Target number of concurrent users

  ## Returns

  A list of `{time_ms, target_users}` tuples indicating when to
  adjust the number of active sessions.
  """
  @spec plan(strategy(), pos_integer()) :: plan()
  def plan(:immediate, target_users) do
    [{0, target_users}]
  end

  def plan({:linear, duration}, target_users) do
    duration_ms = to_ms(duration)

    # Create 10 steps for linear ramp
    steps = min(10, target_users)
    step_duration = div(duration_ms, steps)
    users_per_step = target_users / steps

    for i <- 0..(steps - 1) do
      time_ms = i * step_duration
      users = round((i + 1) * users_per_step)
      {time_ms, users}
    end
  end

  def plan({:step, num_steps, interval}, target_users) do
    interval_ms = to_ms(interval)
    users_per_step = div(target_users, num_steps)
    remainder = rem(target_users, num_steps)

    for i <- 0..(num_steps - 1) do
      time_ms = i * interval_ms
      # Distribute remainder across first steps
      users = (i + 1) * users_per_step + min(i + 1, remainder)
      {time_ms, min(users, target_users)}
    end
  end

  def plan({:exponential, duration}, target_users) do
    duration_ms = to_ms(duration)

    # Use 10 steps for exponential growth
    steps = 10
    step_duration = div(duration_ms, steps)

    # Exponential growth: users = target * (e^(k*t) - 1) / (e^k - 1)
    # where k is chosen so we reach target at t=1
    k = 2.0

    for i <- 0..(steps - 1) do
      time_ms = i * step_duration
      t = (i + 1) / steps
      # Normalized exponential growth
      factor = (:math.exp(k * t) - 1) / (:math.exp(k) - 1)
      users = round(target_users * factor)
      {time_ms, max(1, users)}
    end
  end

  @doc """
  Generate a ramp-down plan.

  Similar to plan/2 but decreases from current users to 0.

  ## Parameters

  - `strategy` - The ramping strategy to use
  - `current_users` - Current number of active users
  """
  @spec plan_down(strategy(), pos_integer()) :: plan()
  def plan_down(:immediate, _current_users) do
    [{0, 0}]
  end

  def plan_down({:linear, duration}, current_users) do
    duration_ms = to_ms(duration)
    steps = min(10, current_users)
    step_duration = div(duration_ms, steps)
    users_per_step = current_users / steps

    for i <- 0..(steps - 1) do
      time_ms = i * step_duration
      users = round(current_users - (i + 1) * users_per_step)
      {time_ms, max(0, users)}
    end
  end

  def plan_down({:step, num_steps, interval}, current_users) do
    interval_ms = to_ms(interval)
    users_per_step = div(current_users, num_steps)

    for i <- 0..(num_steps - 1) do
      time_ms = i * interval_ms
      users = current_users - (i + 1) * users_per_step
      {time_ms, max(0, users)}
    end
  end

  def plan_down({:exponential, duration}, current_users) do
    duration_ms = to_ms(duration)
    steps = 10
    step_duration = div(duration_ms, steps)
    k = 2.0

    for i <- 0..(steps - 1) do
      time_ms = i * step_duration
      t = (i + 1) / steps
      factor = (:math.exp(k * t) - 1) / (:math.exp(k) - 1)
      users = round(current_users * (1 - factor))
      {time_ms, max(0, users)}
    end
  end

  @doc """
  Get the users to add/remove at a given time point.

  Returns the delta from the previous step.
  """
  @spec delta_at(plan(), non_neg_integer()) :: integer()
  def delta_at(plan, time_ms) do
    # Find the applicable step
    applicable =
      plan
      |> Enum.filter(fn {t, _} -> t <= time_ms end)
      |> List.last()

    case applicable do
      nil -> 0
      {_, users} -> users
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

  # ============================================================================
  # Internal
  # ============================================================================

  defp to_ms({value, :milliseconds}), do: value
  defp to_ms({value, :seconds}), do: value * 1000
  defp to_ms({value, :minutes}), do: value * 60 * 1000
end
