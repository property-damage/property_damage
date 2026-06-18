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
  - Pure generator/1 pattern (state-independent)
  - downstream_observables/0 for validation

  Note: preconditions, overrides, and simulate are defined in the Model.
  """
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:name, :quantity]

  @impl true
  def downstream_observables, do: [PropertyDamage.Test.Events.ItemCreated]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      name: StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
      quantity: StreamData.positive_integer()
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule PropertyDamage.Test.Commands.ViewItem do
  @moduledoc """
  Test command that views an existing item.

  Demonstrates:
  - Pure generator/1 with nil default for ref field
  - read_only?/0 metadata

  Note: The Model defines when this command is valid (items must exist)
  and how to parameterize it (select from existing item refs).
  """
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:item_ref]

  @impl true
  def read_only?, do: true

  @impl true
  def downstream_observables, do: [PropertyDamage.Test.Events.ItemViewed]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      item_ref: nil
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  @impl true
  def label(_state, %__MODULE__{item_ref: ref}) do
    "viewing item #{inspect(ref)}"
  end
end

defmodule PropertyDamage.Test.Commands.MinimalCommand do
  @moduledoc """
  Minimal test command with only required callback (generator/1).

  Demonstrates that optional callbacks can be omitted.
  """
  @behaviour PropertyDamage.Command

  defstruct []

  @impl true
  def generator(_overrides \\ %{}) do
    StreamData.constant(%{})
  end
end

defmodule PropertyDamage.Test.Commands.ProbeItem do
  @moduledoc """
  Test command with :probe semantics for testing shrinking priority.

  Probe commands are read-only polling operations that should be
  prioritized for removal during shrinking (see DR-008).
  """
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:item_ref]

  @impl true
  def semantics, do: :probe

  @impl true
  def read_only?, do: true

  @impl true
  def downstream_observables, do: [PropertyDamage.Test.Events.ItemViewed]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      item_ref: nil
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end
