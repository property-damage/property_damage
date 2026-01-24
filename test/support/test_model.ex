defmodule PropertyDamage.Test.FullModel do
  @moduledoc """
  Complete test model implementing all callbacks.

  Demonstrates full Model behaviour implementation including
  lifecycle hooks, terminate?/3, and the new Model-level wiring pattern.
  """
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem, MinimalCommand}
  alias PropertyDamage.Test.Projections.{ModelState, TestAssertions}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  @impl true
  def commands do
    [
      {CreateItem, weight: 3},
      {ViewItem,
       weight: 2,
       when: fn state -> map_size(Map.get(state, :items, %{})) > 0 end,
       with: fn state ->
         items = Map.get(state, :items, %{})
         %{item_ref: StreamData.member_of(Map.keys(items))}
       end},
      {MinimalCommand, weight: 1}
    ]
  end

  @impl true
  def command_sequence_projection, do: ModelState

  @impl true
  def assertion_projections, do: [TestAssertions]

  @impl true
  def injectable_events, do: [ItemCreated, ItemViewed]

  @impl true
  def setup_once(_config), do: :ok

  @impl true
  def setup_each(_config), do: :ok

  @impl true
  def teardown_each(_config), do: :ok

  @impl true
  def teardown_once(_config), do: :ok

  @impl true
  def simulator, do: __MODULE__

  # Simulate expected events for each command type
  @impl PropertyDamage.Model.Simulator
  def simulate(%CreateItem{name: name, quantity: quantity}, _state) do
    [%ItemCreated{item_ref: nil, name: name, quantity: quantity}]
  end

  def simulate(%ViewItem{item_ref: item_ref}, _state) do
    [%ItemViewed{item_ref: item_ref}]
  end

  def simulate(%MinimalCommand{}, _state) do
    []
  end

  # Terminate after MinimalCommand
  @impl true
  def terminate?(_state, %MinimalCommand{}, _events), do: true
  def terminate?(_state, _command, _events), do: false
end

defmodule PropertyDamage.Test.MinimalModel do
  @moduledoc """
  Minimal test model with only required callbacks.

  Demonstrates that optional callbacks can be omitted.
  Uses the new command spec format with Model-level wiring.
  """
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.Projections.{ModelState, TestAssertions}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  @impl true
  def commands do
    [
      CreateItem,
      {ViewItem,
       when: fn state -> map_size(Map.get(state, :items, %{})) > 0 end,
       with: fn state ->
         items = Map.get(state, :items, %{})
         %{item_ref: StreamData.member_of(Map.keys(items))}
       end}
    ]
  end

  @impl true
  def command_sequence_projection, do: ModelState

  @impl true
  def assertion_projections, do: [TestAssertions]

  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(%CreateItem{name: name, quantity: quantity}, _state) do
    [%ItemCreated{item_ref: nil, name: name, quantity: quantity}]
  end

  def simulate(%ViewItem{item_ref: item_ref}, _state) do
    [%ItemViewed{item_ref: item_ref}]
  end
end

defmodule PropertyDamage.Test.SimpleWeightModel do
  @moduledoc """
  Test model using simple (unweighted) command list.
  """
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.Projections.{ModelState, TestAssertions}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  # Simple list - commands use default weight of 1
  @impl true
  def commands do
    [
      CreateItem,
      {ViewItem,
       when: fn state -> map_size(Map.get(state, :items, %{})) > 0 end,
       with: fn state ->
         items = Map.get(state, :items, %{})
         %{item_ref: StreamData.member_of(Map.keys(items))}
       end}
    ]
  end

  @impl true
  def command_sequence_projection, do: ModelState

  @impl true
  def assertion_projections, do: [TestAssertions]

  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(%CreateItem{name: name, quantity: quantity}, _state) do
    [%ItemCreated{item_ref: nil, name: name, quantity: quantity}]
  end

  def simulate(%ViewItem{item_ref: item_ref}, _state) do
    [%ItemViewed{item_ref: item_ref}]
  end
end

defmodule PropertyDamage.Test.WeightedModel do
  @moduledoc """
  Test model using explicit command weights.
  """
  @behaviour PropertyDamage.Model
  @behaviour PropertyDamage.Model.Simulator

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.Projections.{ModelState, TestAssertions}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  # Weighted list - CreateItem 3x more likely than ViewItem
  @impl true
  def commands do
    [
      {CreateItem, weight: 3},
      {ViewItem,
       weight: 1,
       when: fn state -> map_size(Map.get(state, :items, %{})) > 0 end,
       with: fn state ->
         items = Map.get(state, :items, %{})
         %{item_ref: StreamData.member_of(Map.keys(items))}
       end}
    ]
  end

  @impl true
  def command_sequence_projection, do: ModelState

  @impl true
  def assertion_projections, do: [TestAssertions]

  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(%CreateItem{name: name, quantity: quantity}, _state) do
    [%ItemCreated{item_ref: nil, name: name, quantity: quantity}]
  end

  def simulate(%ViewItem{item_ref: item_ref}, _state) do
    [%ItemViewed{item_ref: item_ref}]
  end
end
