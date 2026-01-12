defmodule PropertyDamage.Test.FullModel do
  @moduledoc """
  Complete test model implementing all callbacks.

  Demonstrates full Model behaviour implementation including
  lifecycle hooks and terminate?/3.
  """
  @behaviour PropertyDamage.Model

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem, MinimalCommand}
  alias PropertyDamage.Test.Projections.{ModelState, TestAssertions}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  @impl true
  def commands do
    [
      {3, CreateItem},
      {2, ViewItem},
      {1, MinimalCommand}
    ]
  end

  @impl true
  def state_projection, do: ModelState

  @impl true
  def extra_projections, do: [TestAssertions]

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

  # Terminate after MinimalCommand
  @impl true
  def terminate?(_state, %MinimalCommand{}, _events), do: true
  def terminate?(_state, _command, _events), do: false
end

defmodule PropertyDamage.Test.MinimalModel do
  @moduledoc """
  Minimal test model with only required callbacks.

  Demonstrates that optional callbacks can be omitted.
  """
  @behaviour PropertyDamage.Model

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.Projections.{ModelState, TestAssertions}

  @impl true
  def commands, do: [CreateItem, ViewItem]

  @impl true
  def state_projection, do: ModelState

  @impl true
  def extra_projections, do: [TestAssertions]
end

defmodule PropertyDamage.Test.SimpleWeightModel do
  @moduledoc """
  Test model using simple (unweighted) command list.
  """
  @behaviour PropertyDamage.Model

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.Projections.{ModelState, TestAssertions}

  # Simple list - all commands weighted equally
  @impl true
  def commands, do: [CreateItem, ViewItem]

  @impl true
  def state_projection, do: ModelState

  @impl true
  def extra_projections, do: [TestAssertions]
end

defmodule PropertyDamage.Test.WeightedModel do
  @moduledoc """
  Test model using explicit command weights.
  """
  @behaviour PropertyDamage.Model

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.Projections.{ModelState, TestAssertions}

  # Weighted list - CreateItem 3x more likely than ViewItem
  @impl true
  def commands do
    [
      {3, CreateItem},
      {1, ViewItem}
    ]
  end

  @impl true
  def state_projection, do: ModelState

  @impl true
  def extra_projections, do: [TestAssertions]
end
