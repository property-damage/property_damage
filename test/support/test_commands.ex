defmodule PropertyDamage.Test.Events do
  @moduledoc false
  # Test event structs for use in test commands

  defmodule ItemCreated do
    @moduledoc false
    defstruct [:item_ref, :name, :quantity]
  end

  defmodule ItemViewed do
    @moduledoc false
    defstruct [:item_ref]
  end
end

defmodule PropertyDamage.Test.Commands.CreateItem do
  @moduledoc """
  Test command that creates an item.

  Demonstrates:
  - Full generator/1 + new!/2 pattern
  - creates_ref/0 for entity creation
  - downstream_observables/0 for validation
  - simulate/2 for symbolic execution
  """
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  alias PropertyDamage.Test.Events.ItemCreated

  defstruct [:name, :quantity]

  @impl true
  def precondition(_state), do: true

  @impl true
  def creates_ref, do: :item_ref

  @impl true
  def downstream_observables, do: [ItemCreated]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      name: StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
      quantity: StreamData.positive_integer()
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  @impl true
  def new!(_state, overrides \\ %{}) do
    generator(overrides)
    |> StreamData.map(&struct!(__MODULE__, &1))
  end

  @impl true
  def simulate(_state, %__MODULE__{name: name, quantity: quantity}) do
    [%ItemCreated{item_ref: nil, name: name, quantity: quantity}]
  end
end

defmodule PropertyDamage.Test.Commands.ViewItem do
  @moduledoc """
  Test command that views an existing item.

  Demonstrates:
  - State-dependent precondition
  - State-dependent new!/2 (selecting from existing items)
  - read_only?/0 metadata
  """
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  alias PropertyDamage.Test.Events.ItemViewed

  defstruct [:item_ref]

  @impl true
  def precondition(state), do: map_size(Map.get(state, :items, %{})) > 0

  @impl true
  def read_only?, do: true

  @impl true
  def downstream_observables, do: [ItemViewed]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      item_ref: nil
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  @impl true
  def new!(state, overrides \\ %{}) do
    items = Map.get(state, :items, %{})

    generator(
      Map.merge(
        %{item_ref: StreamData.member_of(Map.keys(items))},
        overrides
      )
    )
    |> StreamData.map(&struct!(__MODULE__, &1))
  end

  @impl true
  def simulate(_state, %__MODULE__{item_ref: item_ref}) do
    [%ItemViewed{item_ref: item_ref}]
  end

  @impl true
  def label(_state, %__MODULE__{item_ref: ref}) do
    "viewing item #{inspect(ref)}"
  end
end

defmodule PropertyDamage.Test.Commands.MinimalCommand do
  @moduledoc """
  Minimal test command with only required callbacks.

  Demonstrates that optional callbacks can be omitted.
  """
  @behaviour PropertyDamage.Command

  defstruct []

  @impl true
  def precondition(_state), do: true

  @impl true
  def new!(_state, _overrides \\ %{}) do
    StreamData.constant(%__MODULE__{})
  end
end
