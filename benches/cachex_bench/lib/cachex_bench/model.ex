defmodule CachexBench.Projection do
  @moduledoc """
  Tracks the expected cache contents and asserts that every read observed
  from the real Cachex instance matches the model's expectation.
  """
  use PropertyDamage.Model.Projection

  alias CachexBench.Events.{CacheCleared, EntryDeleted, EntryIncremented, EntryPut, EntryRead}

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

  def apply(state, %EntryIncremented{key: key, amount: amount}) do
    %{state | expected: Map.update(state.expected, key, amount, &(&1 + amount))}
  end

  def apply(state, _event), do: state

  # Boundary observation: a run with two or more targets compares them only
  # through observations like this one. Every target evaluates it on its own
  # projection state after each root command, so the expected contents of the
  # cache must agree between targets.
  @compare every: 1
  def expected_contents(state, _root), do: state.expected

  # DR-026 invariant catalog: the property the check below upholds. Enables
  # anti-vacuity (check) coverage reporting for this bench.
  @invariant id: :read_consistent,
             description: "Every read returns the value the model expects for that key"

  # After every read, the value the SUT returned must equal what the
  # model expects for that key (nil when the key should be absent).
  @check every: CachexBench.Commands.GetKey, validates: :read_consistent
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

  alias CachexBench.Commands.{ClearCache, DelKey, GetKey, Incr, PutKey}
  alias CachexBench.Events.{CacheCleared, EntryDeleted, EntryIncremented, EntryPut, EntryRead}

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

  def simulate(%Incr{key: key, amount: amount}, state) do
    value = Map.get(state.expected, key, 0) + amount
    [%EntryIncremented{key: key, amount: amount, value: value}]
  end

  def simulate(_command, _state), do: []
end

defmodule CachexBench.Model do
  @moduledoc """
  Ties cache commands and the consistency projection together.

  `Incr k n` has an expansion: a target may run it as itself or as two
  increments of the same key that add up to `n` (`Incr k 5` as
  `[Incr k 2, Incr k 3]`). Once the root is done, both leave the same counter
  under `k`, which `CachexBench.Projection.expected_contents/2` compares after
  every root.
  """
  @behaviour PropertyDamage.Model

  alias CachexBench.Commands.{ClearCache, DelKey, GetKey, Incr, PutKey}

  @impl true
  def commands do
    [
      {PutKey, weight: 5},
      {GetKey, weight: 5},
      {DelKey, weight: 2},
      {ClearCache, weight: 1},
      {Incr, weight: 2}
    ]
  end

  @impl true
  def expansions, do: [{Incr, &incr_expansions/2}]

  @doc """
  The ways to run `Incr k n`: as itself (listed first, the simplest), and for
  `n >= 2` as `Incr k div(n, 2)` then `Incr k (n - div(n, 2))`.
  """
  def incr_expansions(%Incr{key: key, amount: n} = incr, _state) do
    [{[incr], weight: 2} | split(key, n)]
  end

  defp split(_key, n) when n < 2, do: []

  defp split(key, n) do
    a = div(n, 2)
    [[{Incr, overrides: %{key: key, amount: a}}, {Incr, overrides: %{key: key, amount: n - a}}]]
  end

  @impl true
  def command_sequence_projection, do: CachexBench.Projection

  @impl true
  def check_projections, do: [CachexBench.Projection]

  @impl true
  def simulator, do: CachexBench.Simulator
end
