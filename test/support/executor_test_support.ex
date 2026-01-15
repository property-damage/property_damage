defmodule PropertyDamage.Test.ExecutorTestSupport do
  @moduledoc """
  Test support modules for Executor tests.
  """
end

defmodule PropertyDamage.Test.Projections.FailingAssertion do
  @moduledoc """
  Assertion projection that fails when total_quantity exceeds threshold.
  """
  use PropertyDamage.Projection

  alias PropertyDamage.Test.Events.ItemCreated

  @impl true
  def init, do: %{total_quantity: 0}

  @impl true
  def apply(state, %ItemCreated{quantity: qty}) do
    update_in(state, [:total_quantity], &(&1 + qty))
  end

  def apply(state, _), do: state

  @trigger every: 1
  def assert(:quantity_limit, state, _cmd_or_event) do
    unless state.total_quantity <= 100 do
      PropertyDamage.fail!("Quantity exceeds limit", quantity: state.total_quantity, limit: 100)
    end
  end
end

defmodule PropertyDamage.Test.ExecutorModel do
  @moduledoc """
  Simple model for executor tests.
  """
  @behaviour PropertyDamage.Model

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
  def state_projection, do: ModelState

  @impl true
  def extra_projections, do: [TestAssertions]

  @impl true
  def simulate(%CreateItem{name: name, quantity: quantity}, _state) do
    [%ItemCreated{item_ref: nil, name: name, quantity: quantity}]
  end

  def simulate(%ViewItem{item_ref: item_ref}, _state) do
    [%ItemViewed{item_ref: item_ref}]
  end
end

defmodule PropertyDamage.Test.FailingModel do
  @moduledoc """
  Model with failing assertion projection for testing check failures.
  """
  @behaviour PropertyDamage.Model

  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.Projections.{ModelState, FailingAssertion}
  alias PropertyDamage.Test.Events.ItemCreated

  @impl true
  def commands, do: [CreateItem]

  @impl true
  def state_projection, do: ModelState

  @impl true
  def extra_projections, do: [FailingAssertion]

  @impl true
  def simulate(%CreateItem{name: name, quantity: quantity}, _state) do
    [%ItemCreated{item_ref: nil, name: name, quantity: quantity}]
  end
end

defmodule PropertyDamage.Test.SimpleAdapter do
  @moduledoc """
  Simple adapter for executor tests.

  Generates predictable item_refs for testing.
  """
  use PropertyDamage.Adapter

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  @impl true
  def setup(config) do
    {:ok, Map.merge(%{item_counter: 0}, config)}
  end

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def execute(%CreateItem{name: name, quantity: qty}, context) do
    item_ref = "item_#{context.item_counter}"
    {:ok, [%ItemCreated{item_ref: item_ref, name: name, quantity: qty}]}
  end

  def execute(%ViewItem{item_ref: ref}, _context) do
    {:ok, [%ItemViewed{item_ref: ref}]}
  end
end

defmodule PropertyDamage.Test.ErrorAdapter do
  @moduledoc """
  Adapter that returns errors for testing error handling.
  """
  use PropertyDamage.Adapter

  @impl true
  def setup(config), do: {:ok, config}

  @impl true
  def teardown(_context), do: :ok

  @impl true
  def execute(%{fail: true}, _context) do
    {:error, :command_failed}
  end

  def execute(_command, _context) do
    {:ok, []}
  end
end

defmodule PropertyDamage.Test.SimpleModel do
  @moduledoc """
  Simple model without extra projections for ref resolution tests.
  """
  @behaviour PropertyDamage.Model

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.Projections.ModelState

  @impl true
  def commands, do: [CreateItem, ViewItem]

  @impl true
  def state_projection, do: ModelState

  # No extra_projections - optional callback
end

# ============================================================================
# Multi-Check Test Support (for failure equivalence testing)
# ============================================================================

defmodule PropertyDamage.Test.Projections.MultiCheckAssertion do
  @moduledoc """
  Assertion projection with two different checks at different thresholds.

  Used to test that the shrinker preserves failure type:
  - `high_limit` fails when quantity > 200
  - `low_limit` fails when quantity > 100

  If a sequence fails `high_limit`, shrinking shouldn't accept a
  sequence that only fails `low_limit`.
  """
  use PropertyDamage.Projection

  alias PropertyDamage.Test.Events.ItemCreated

  @impl true
  def init, do: %{total_quantity: 0}

  @impl true
  def apply(state, %ItemCreated{quantity: qty}) do
    update_in(state, [:total_quantity], &(&1 + qty))
  end

  def apply(state, _), do: state

  @trigger every: 1
  def assert(:low_limit, state, _cmd_or_event) do
    unless state.total_quantity <= 100 do
      PropertyDamage.fail!("Quantity exceeds low limit",
        quantity: state.total_quantity,
        limit: 100
      )
    end
  end

  @trigger every: 1
  def assert(:high_limit, state, _cmd_or_event) do
    unless state.total_quantity <= 200 do
      PropertyDamage.fail!("Quantity exceeds high limit",
        quantity: state.total_quantity,
        limit: 200
      )
    end
  end
end

defmodule PropertyDamage.Test.MultiCheckModel do
  @moduledoc """
  Model with multiple assertion checks for testing failure equivalence.
  """
  @behaviour PropertyDamage.Model

  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.Projections.{ModelState, MultiCheckAssertion}

  @impl true
  def commands, do: [CreateItem]

  @impl true
  def state_projection, do: ModelState

  @impl true
  def extra_projections, do: [MultiCheckAssertion]
end
