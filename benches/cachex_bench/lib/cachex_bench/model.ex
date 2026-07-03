defmodule CachexBench.Projection do
  @moduledoc """
  Tracks the expected cache contents and asserts that every read observed
  from the real Cachex instance matches the model's expectation.
  """
  use PropertyDamage.Model.Projection

  alias CachexBench.Events.{CacheCleared, EntryDeleted, EntryPut, EntryRead}

  @impl true
  def init, do: %{expected: %{}, last_read: nil}

  @impl true
  def apply(state, %EntryPut{key: key, value: value}) do
    put_in(state, [:expected, key], value)
  end

  def apply(state, %EntryDeleted{key: key}) do
    update_in(state, [:expected], &Map.delete(&1, key))
  end

  def apply(state, %CacheCleared{}) do
    %{state | expected: %{}}
  end

  def apply(state, %EntryRead{key: key, value: value}) do
    %{state | last_read: {key, value}}
  end

  def apply(state, _event), do: state

  # DR-026 invariant catalog: the property the assertion below upholds. Enables
  # anti-vacuity (assertion) coverage reporting for this bench.
  @invariant id: :read_consistent,
             description: "Every read returns the value the model expects for that key"

  # After every read, the value the SUT returned must equal what the
  # model expects for that key (nil when the key should be absent).
  @trigger every: CachexBench.Commands.GetKey, validates: :read_consistent
  def assert_read_consistent(state, _command) do
    {key, actual} = state.last_read
    expected = Map.get(state.expected, key)

    if actual != expected do
      PropertyDamage.fail!(
        "Read of #{inspect(key)} returned #{inspect(actual)}, model expects #{inspect(expected)}",
        key: key,
        actual: actual,
        expected: expected
      )
    end
  end
end

defmodule CachexBench.Simulator do
  @moduledoc "Predicts events during generation, before any cache exists."
  @behaviour PropertyDamage.Model.Simulator

  alias CachexBench.Commands.{ClearCache, DelKey, GetKey, PutKey}
  alias CachexBench.Events.{CacheCleared, EntryDeleted, EntryPut, EntryRead}

  @impl true
  def simulate(%PutKey{key: key, value: value}, _state) do
    [%EntryPut{key: key, value: value}]
  end

  def simulate(%GetKey{key: key}, state) do
    # Predict the read from the model's own expected state
    [%EntryRead{key: key, value: get_in(state, [:expected, key])}]
  end

  def simulate(%DelKey{key: key}, _state) do
    [%EntryDeleted{key: key}]
  end

  def simulate(%ClearCache{}, _state) do
    [%CacheCleared{}]
  end

  def simulate(_command, _state), do: []
end

defmodule CachexBench.Model do
  @moduledoc "Ties cache commands and the consistency projection together."
  @behaviour PropertyDamage.Model

  alias CachexBench.Commands.{ClearCache, DelKey, GetKey, PutKey}

  @impl true
  def commands do
    [
      {PutKey, weight: 5},
      {GetKey, weight: 5},
      {DelKey, weight: 2},
      {ClearCache, weight: 1}
    ]
  end

  @impl true
  def command_sequence_projection, do: CachexBench.Projection

  @impl true
  def assertion_projections, do: [CachexBench.Projection]

  @impl true
  def simulator, do: CachexBench.Simulator
end
