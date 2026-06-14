defmodule RedisBench.Projection do
  @moduledoc """
  Tracks the expected register value and asserts every observed read matches it.

  Identical consistency invariant to the 6c ETS register, now over a real Redis
  socket: a read must return exactly the count the model has tallied from the
  increments observed so far.
  """
  use PropertyDamage.Model.Projection

  alias RedisBench.Commands.ReadValue
  alias RedisBench.Events.{Incremented, ValueRead}

  @impl true
  def init, do: %{count: 0, last_read: nil}

  @impl true
  def apply(state, %Incremented{to: to}), do: %{state | count: to}
  def apply(state, %ValueRead{value: value}), do: %{state | last_read: value}
  def apply(state, _event), do: state

  @trigger every: ReadValue
  def assert_value_consistent(state, _command) do
    if state.last_read != state.count do
      PropertyDamage.fail!(
        "Read returned #{inspect(state.last_read)}, model expects #{inspect(state.count)}",
        actual: state.last_read,
        expected: state.count
      )
    end
  end
end

defmodule RedisBench.Simulator do
  @moduledoc "Predicts events during generation, before any connection exists."
  @behaviour PropertyDamage.Model.Simulator

  alias RedisBench.Commands.{Increment, ReadValue}
  alias RedisBench.Events.{Incremented, ValueRead}

  @impl true
  def simulate(%Increment{}, state) do
    [%Incremented{from: state.count, to: state.count + 1}]
  end

  def simulate(%ReadValue{}, state) do
    [%ValueRead{value: state.count}]
  end

  def simulate(_command, _state), do: []
end

defmodule RedisBench.Model do
  @moduledoc "Ties the register commands and the consistency projection together."
  @behaviour PropertyDamage.Model

  alias RedisBench.Commands.{Increment, ReadValue}

  @impl true
  def commands do
    [
      {Increment, weight: 5},
      {ReadValue, weight: 3}
    ]
  end

  @impl true
  def command_sequence_projection, do: RedisBench.Projection

  @impl true
  def assertion_projections, do: [RedisBench.Projection]

  @impl true
  def simulator, do: RedisBench.Simulator
end
