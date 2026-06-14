defmodule ObanBench.Projection do
  @moduledoc """
  Tracks how many increments were enqueued per counter (`expected`) and the
  highest value any resource poller has observed for it in the database
  (`observed`). The eventual-consistency invariant: the observed value must
  catch up to the expected count.
  """
  use PropertyDamage.Model.Projection

  alias ObanBench.Events.{Enqueued, Incremented}

  @impl true
  def init, do: %{expected: %{}, observed: %{}}

  @impl true
  def apply(state, %Enqueued{counter: counter}) do
    update_in(state, [:expected, counter], &((&1 || 0) + 1))
  end

  # Take the max so the invariant is robust to out-of-order poller events:
  # the database counter only grows within a run, so the highest value any
  # poller saw is the truth.
  def apply(state, %Incremented{counter: counter, value: value}) do
    update_in(state, [:observed, counter], &max(&1 || 0, value))
  end

  def apply(state, _event), do: state

  # Eventual consistency: after a job is enqueued, the database value for that
  # counter must eventually reach the number of increments enqueued for it.
  # The confirming values arrive via a resource poller AFTER the command
  # returns, so this is a genuine async/settle check, not a synchronous one.
  @poll_state after: Enqueued,
              timeout: {1500, :milliseconds},
              interval: {20, :milliseconds}
  def counter_eventually_consistent(_state, %Enqueued{counter: counter}) do
    fn s -> Map.get(s.observed, counter, 0) == Map.get(s.expected, counter, 0) end
  end
end

defmodule ObanBench.Simulator do
  @moduledoc "Predicts the synchronous enqueue event during generation."
  @behaviour PropertyDamage.Model.Simulator

  alias ObanBench.Commands.Increment
  alias ObanBench.Events.Enqueued

  @impl true
  def simulate(%Increment{counter: counter}, _state), do: [%Enqueued{counter: counter}]
  def simulate(_command, _state), do: []
end

defmodule ObanBench.Model do
  @moduledoc "Ties the increment command to the eventual-consistency projection."
  @behaviour PropertyDamage.Model

  alias ObanBench.Commands.Increment

  @impl true
  def commands, do: [Increment]

  @impl true
  def command_sequence_projection, do: ObanBench.Projection

  @impl true
  def assertion_projections, do: [ObanBench.Projection]

  @impl true
  def simulator, do: ObanBench.Simulator
end
