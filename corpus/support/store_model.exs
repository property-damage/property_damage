defmodule Corpus.Store.Events do
  @moduledoc "What happened against the store."

  defmodule EntryPut do
    @moduledoc false
    defstruct [:key, :value]
  end

  defmodule EntryRead do
    @moduledoc false
    # `value` is what the store returned, `nil` when the key is absent.
    defstruct [:key, :value]
  end

  defmodule EntryDeleted do
    @moduledoc false
    defstruct [:key]
  end
end

defmodule Corpus.Store.PutKey do
  @moduledoc "Write a value under a key."
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:key, :value]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      key: StreamData.member_of([:k0, :k1, :k2]),
      value: StreamData.integer(0..5)
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Corpus.Store.GetKey do
  @moduledoc "Read a key."
  use PropertyDamage.Command, shrink: :prefer_remove

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:key]

  @impl true
  def generator(overrides \\ %{}) do
    %{key: StreamData.member_of([:k0, :k1, :k2])}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Corpus.Store.DelKey do
  @moduledoc "Delete a key. Deleting an absent key is fine."
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:key]

  @impl true
  def generator(overrides \\ %{}) do
    %{key: StreamData.member_of([:k0, :k1, :k2])}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Corpus.Store.Projection do
  @moduledoc """
  Tracks the expected contents and checks that every read returns what the
  model expects.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.Store.Events.{EntryDeleted, EntryPut, EntryRead}
  alias Corpus.Store.GetKey

  @impl true
  def init, do: %{expected: %{}, last_read: nil}

  @impl true
  def apply(state, %EntryPut{key: key, value: value}), do: put_in(state, [:expected, key], value)

  def apply(state, %EntryDeleted{key: key}),
    do: update_in(state, [:expected], &Map.delete(&1, key))

  def apply(state, %EntryRead{key: key, value: value}), do: %{state | last_read: {key, value}}
  def apply(state, _event), do: state

  @check every: GetKey
  def assert_read_consistent(state, _command) do
    {key, actual} = state.last_read
    expected = Map.get(state.expected, key)

    actual == expected or
      PropertyDamage.fail!(
        "Read of #{inspect(key)} returned #{inspect(actual)}, model expects #{inspect(expected)}",
        key: key,
        actual: actual,
        expected: expected
      )
  end
end

defmodule Corpus.Store.Simulator do
  @moduledoc "Predicts the events of a command before any store exists."
  @behaviour PropertyDamage.Model.Simulator

  alias Corpus.Store.Events.{EntryDeleted, EntryPut, EntryRead}
  alias Corpus.Store.{DelKey, GetKey, PutKey}

  @impl true
  def simulate(%PutKey{key: key, value: value}, _state), do: [%EntryPut{key: key, value: value}]

  def simulate(%GetKey{key: key}, state),
    do: [%EntryRead{key: key, value: get_in(state, [:expected, key])}]

  def simulate(%DelKey{key: key}, _state), do: [%EntryDeleted{key: key}]
  def simulate(_command, _state), do: []
end

defmodule Corpus.Store.Model do
  @moduledoc "Puts, gets and deletes over three keys."
  use PropertyDamage.Model

  alias Corpus.Store.{DelKey, GetKey, PutKey}

  @impl true
  def commands, do: [{PutKey, weight: 5}, {GetKey, weight: 4}, {DelKey, weight: 2}]

  @impl true
  def command_sequence_projection, do: Corpus.Store.Projection

  @impl true
  def check_projections, do: [Corpus.Store.Projection]

  @impl true
  def simulator, do: Corpus.Store.Simulator
end

defmodule Corpus.Store.Adapter do
  @moduledoc "Runs the store commands against a `Corpus.Store` started with the entry's bug."
  use PropertyDamage.Adapter

  alias Corpus.Store
  alias Corpus.Store.Events.{EntryDeleted, EntryPut, EntryRead}
  alias Corpus.Store.{DelKey, GetKey, PutKey}

  @impl true
  def setup(config) do
    {:ok, store} = Store.start(bug: config[:bug], fire_log: config[:fire_log])
    {:ok, %{store: store}}
  end

  @impl true
  def teardown(%{store: store}) do
    if Process.alive?(store), do: Store.stop(store)
    :ok
  end

  @impl true
  def execute(%PutKey{key: key, value: value}, %{store: store}, _runtime) do
    Store.put(store, key, value)
    {:ok, [%EntryPut{key: key, value: value}]}
  end

  def execute(%GetKey{key: key}, %{store: store}, _runtime) do
    {:ok, [%EntryRead{key: key, value: Store.get(store, key)}]}
  end

  def execute(%DelKey{key: key}, %{store: store}, _runtime) do
    Store.delete(store, key)
    {:ok, [%EntryDeleted{key: key}]}
  end
end
