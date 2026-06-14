defmodule PropertyDamage.Test.ShrinkQuality do
  @moduledoc """
  Shared SUT for the seeded-bug shrink-quality suite (Phase 6a).

  A tiny in-memory key/value store (an `Agent`, zero infrastructure) plus the
  model, commands, projection, and simulator that drive it. The store is a real
  stateful system; the seeded bugs live in adapter variants (defined in the
  test) that misbehave against it, exactly like the Cachex bench's lying-delete
  adapter. The model's read-consistency invariant catches the lie, and the suite
  asserts the shrinker reaches the known minimal reproduction.

  The key space is deliberately small so random generation collides keys often,
  making the order-dependent bugs reliably discoverable within a bounded run
  budget under a pinned seed.
  """

  @keys [:k0, :k1, :k2]

  @doc "The fixed key space the generators draw from."
  def keys, do: @keys
end

defmodule PropertyDamage.Test.ShrinkQuality.Store do
  @moduledoc "An Agent-backed key/value map. One instance per run."

  @doc false
  def start_link, do: Agent.start_link(fn -> %{} end)

  @doc false
  def put(pid, key, value), do: Agent.update(pid, &Map.put(&1, key, value))

  @doc false
  def get(pid, key), do: Agent.get(pid, &Map.get(&1, key))

  @doc false
  def delete(pid, key), do: Agent.update(pid, &Map.delete(&1, key))

  @doc false
  def stop(pid), do: Agent.stop(pid)
end

defmodule PropertyDamage.Test.ShrinkQuality.Events do
  @moduledoc "Events describing what happened against the store."

  defmodule EntryPut do
    @moduledoc false
    defstruct [:key, :value]
  end

  defmodule EntryRead do
    @moduledoc false
    # value is what the SUT actually returned (nil when absent)
    defstruct [:key, :value]
  end

  defmodule EntryDeleted do
    @moduledoc false
    defstruct [:key]
  end
end

defmodule PropertyDamage.Test.ShrinkQuality.Commands.PutKey do
  @moduledoc "Write a value under a key."
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  alias PropertyDamage.Test.ShrinkQuality

  defstruct [:key, :value]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      key: StreamData.member_of(ShrinkQuality.keys()),
      value: StreamData.integer(0..5)
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule PropertyDamage.Test.ShrinkQuality.Commands.GetKey do
  @moduledoc "Read a key; the model asserts the returned value matches expectation."
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  alias PropertyDamage.Test.ShrinkQuality

  defstruct [:key]

  @impl true
  def read_only?, do: true

  @impl true
  def generator(overrides \\ %{}) do
    %{key: StreamData.member_of(ShrinkQuality.keys())}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule PropertyDamage.Test.ShrinkQuality.Commands.DelKey do
  @moduledoc "Delete a key (idempotent: deleting an absent key is fine)."
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  alias PropertyDamage.Test.ShrinkQuality

  defstruct [:key]

  @impl true
  def generator(overrides \\ %{}) do
    %{key: StreamData.member_of(ShrinkQuality.keys())}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule PropertyDamage.Test.ShrinkQuality.Projection do
  @moduledoc """
  Tracks the expected store contents and asserts every observed read matches
  the model's expectation (the `last_read` shuttle idiom).
  """
  use PropertyDamage.Model.Projection

  alias PropertyDamage.Test.ShrinkQuality.Commands.GetKey
  alias PropertyDamage.Test.ShrinkQuality.Events.{EntryDeleted, EntryPut, EntryRead}

  @impl true
  def init, do: %{expected: %{}, last_read: nil}

  @impl true
  def apply(state, %EntryPut{key: key, value: value}) do
    put_in(state, [:expected, key], value)
  end

  def apply(state, %EntryDeleted{key: key}) do
    update_in(state, [:expected], &Map.delete(&1, key))
  end

  def apply(state, %EntryRead{key: key, value: value}) do
    %{state | last_read: {key, value}}
  end

  def apply(state, _event), do: state

  @trigger every: GetKey
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

defmodule PropertyDamage.Test.ShrinkQuality.Simulator do
  @moduledoc "Predicts events during generation, before any store exists."
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Test.ShrinkQuality.Commands.{DelKey, GetKey, PutKey}
  alias PropertyDamage.Test.ShrinkQuality.Events.{EntryDeleted, EntryPut, EntryRead}

  @impl true
  def simulate(%PutKey{key: key, value: value}, _state) do
    [%EntryPut{key: key, value: value}]
  end

  def simulate(%GetKey{key: key}, state) do
    [%EntryRead{key: key, value: get_in(state, [:expected, key])}]
  end

  def simulate(%DelKey{key: key}, _state) do
    [%EntryDeleted{key: key}]
  end

  def simulate(_command, _state), do: []
end

defmodule PropertyDamage.Test.ShrinkQuality.Model do
  @moduledoc "Ties the store commands and the consistency projection together."
  @behaviour PropertyDamage.Model

  alias PropertyDamage.Test.ShrinkQuality.Commands.{DelKey, GetKey, PutKey}

  @impl true
  def commands do
    [
      {PutKey, weight: 5},
      {GetKey, weight: 4},
      {DelKey, weight: 2}
    ]
  end

  @impl true
  def command_sequence_projection, do: PropertyDamage.Test.ShrinkQuality.Projection

  @impl true
  def assertion_projections, do: [PropertyDamage.Test.ShrinkQuality.Projection]

  @impl true
  def simulator, do: PropertyDamage.Test.ShrinkQuality.Simulator
end

defmodule PropertyDamage.Test.ShrinkQuality.CorrectAdapter do
  @moduledoc "Faithfully executes store commands. The model invariant holds for it."
  use PropertyDamage.Adapter

  alias PropertyDamage.Test.ShrinkQuality.Commands.{DelKey, GetKey, PutKey}
  alias PropertyDamage.Test.ShrinkQuality.Events.{EntryDeleted, EntryPut, EntryRead}
  alias PropertyDamage.Test.ShrinkQuality.Store

  @impl true
  def setup(_config) do
    {:ok, pid} = Store.start_link()
    {:ok, %{store: pid}}
  end

  @impl true
  def teardown(%{store: pid}) do
    if Process.alive?(pid), do: Store.stop(pid)
    :ok
  end

  @impl true
  def execute(%PutKey{key: key, value: value}, %{store: pid}) do
    Store.put(pid, key, value)
    {:ok, [%EntryPut{key: key, value: value}]}
  end

  def execute(%GetKey{key: key}, %{store: pid}) do
    {:ok, [%EntryRead{key: key, value: Store.get(pid, key)}]}
  end

  def execute(%DelKey{key: key}, %{store: pid}) do
    Store.delete(pid, key)
    {:ok, [%EntryDeleted{key: key}]}
  end
end
