defmodule Corpus.KeyValue.Events do
  @moduledoc "What happened against the store."

  defmodule Stored do
    @moduledoc false
    # `accepted` is whether the store took the value.
    defstruct [:key, :value, :accepted]
  end

  defmodule Read do
    @moduledoc false
    defstruct [:key, :value]
  end
end

defmodule Corpus.KeyValue.Set do
  @moduledoc "Set a key to a short value, possibly the empty string."
  use PropertyDamage.Command, observables: [Corpus.KeyValue.Events.Stored]

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:key, :value]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      key: StreamData.member_of(["k0", "k1", "k2"]),
      value: StreamData.string(:alphanumeric, max_length: 6)
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Corpus.KeyValue.Get do
  @moduledoc "Read a key."
  use PropertyDamage.Command, shrink: :prefer_remove, observables: [Corpus.KeyValue.Events.Read]

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:key]

  @impl true
  def generator(overrides \\ %{}) do
    %{key: StreamData.member_of(["k0", "k1", "k2"])}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule Corpus.KeyValue.Projection do
  @moduledoc """
  Tracks the contents the model expects. The model predicts that every set is
  accepted, so a check after each set flags a store that rejects one, and a
  check after each get flags a value that differs.
  """
  use PropertyDamage.Model.Projection

  alias Corpus.KeyValue.Events.{Read, Stored}
  alias Corpus.KeyValue.{Get, Set}

  @impl true
  def init, do: %{expected: %{}, last_set: nil, last_read: nil}

  @impl true
  def apply(state, %Stored{key: key, value: value, accepted: accepted}) do
    state = %{state | last_set: {key, accepted}}
    if accepted, do: put_in(state, [:expected, key], value), else: state
  end

  def apply(state, %Read{key: key, value: value}), do: %{state | last_read: {key, value}}
  def apply(state, _event), do: state

  @check every: Set
  def set_is_accepted(state, _command) do
    {key, accepted} = state.last_set

    accepted or
      PropertyDamage.fail!(
        "The store rejected a set of #{inspect(key)}, the model predicts success",
        key: key
      )
  end

  @check every: Get
  def read_matches_model(state, _command) do
    {key, actual} = state.last_read
    expected = Map.get(state.expected, key)

    actual == expected or
      PropertyDamage.fail!(
        "A read of #{inspect(key)} returned #{inspect(actual)}, the model expects #{inspect(expected)}",
        key: key
      )
  end
end

defmodule Corpus.KeyValue.Simulator do
  @moduledoc "Predicts the events of a command before any store exists."
  @behaviour PropertyDamage.Model.Simulator

  alias Corpus.KeyValue.Events.{Read, Stored}
  alias Corpus.KeyValue.{Get, Set}

  @impl true
  def simulate(%Set{key: key, value: value}, _state),
    do: [%Stored{key: key, value: value, accepted: true}]

  def simulate(%Get{key: key}, state), do: [%Read{key: key, value: Map.get(state.expected, key)}]
  def simulate(_command, _state), do: []
end

defmodule Corpus.KeyValue.Model do
  @moduledoc "Sets and gets over three keys."
  use PropertyDamage.Model

  alias Corpus.KeyValue.{Get, Projection, Set}

  @impl true
  def commands, do: [{Set, weight: 3}, {Get, weight: 2}]

  @impl true
  def command_sequence_projection, do: Projection

  @impl true
  def check_projections, do: [Projection]

  @impl true
  def simulator, do: Corpus.KeyValue.Simulator
end

defmodule Corpus.KeyValue.Adapter do
  @moduledoc "Runs the store commands against a `Corpus.KeyValue` started with the entry's bug."
  use PropertyDamage.Adapter

  alias Corpus.KeyValue
  alias Corpus.KeyValue.Events.{Read, Stored}
  alias Corpus.KeyValue.{Get, Set}

  @impl true
  def setup(config) do
    {:ok, store} = KeyValue.start(bug: config[:bug], fire_log: config[:fire_log])
    {:ok, %{store: store}}
  end

  @impl true
  def teardown(%{store: store}) do
    if Process.alive?(store), do: KeyValue.stop(store)
    :ok
  end

  @impl true
  def execute(%Set{key: key, value: value}, %{store: store}, _runtime) do
    accepted = KeyValue.set(store, key, value) == :ok
    {:ok, [%Stored{key: key, value: value, accepted: accepted}]}
  end

  def execute(%Get{key: key}, %{store: store}, _runtime) do
    {:ok, [%Read{key: key, value: KeyValue.get(store, key)}]}
  end
end
