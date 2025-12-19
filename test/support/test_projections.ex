defmodule PropertyDamage.Test.Projections.ModelState do
  @moduledoc """
  Test projection that tracks model state for command preconditions.

  Demonstrates basic Projection usage without checks.
  """
  @behaviour PropertyDamage.Projection

  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  @impl true
  def init, do: %{items: %{}, view_count: 0}

  @impl true
  def apply(state, %ItemCreated{item_ref: ref, name: name, quantity: qty}) do
    put_in(state, [:items, ref], %{name: name, quantity: qty})
  end

  def apply(state, %ItemViewed{}) do
    update_in(state, [:view_count], &(&1 + 1))
  end

  # Catch-all for unhandled commands/events
  def apply(state, _), do: state
end

defmodule PropertyDamage.Test.Projections.TestAssertions do
  @moduledoc """
  Test assertion projection demonstrating all check features.

  Includes:
  - @check :always trigger
  - @check after: Module trigger
  - @check after: [Module1, Module2] trigger
  - @check with sample: N option
  - @requirement attribute
  - requirements/1 macro
  """
  use PropertyDamage.AssertionProjection

  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}
  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}

  @impl true
  def init, do: %{items: %{}, total_quantity: 0, create_count: 0, view_count: 0}

  @impl true
  def apply(state, %ItemCreated{item_ref: ref, name: name, quantity: qty}) do
    state
    |> put_in([:items, ref], %{name: name, quantity: qty})
    |> update_in([:total_quantity], &(&1 + qty))
  end

  def apply(state, %CreateItem{}) do
    update_in(state, [:create_count], &(&1 + 1))
  end

  def apply(state, %ItemViewed{}) do
    update_in(state, [:view_count], &(&1 + 1))
  end

  def apply(state, _), do: state

  # === Checks ===

  @requirement "REQ-INV-001"
  check(:always)
  @impl true
  def check(:quantity_non_negative, state, _ctx) do
    if state.total_quantity >= 0, do: :ok, else: {:error, "Negative quantity"}
  end

  @requirement "REQ-CREATE-001"
  check(after: CreateItem)

  def check(:create_increments_count, state, _ctx) do
    if state.create_count > 0, do: :ok, else: {:error, "Create count should be positive"}
  end

  @requirement "REQ-CMD-001"
  @requirement "REQ-CMD-002"
  check(after: [CreateItem, ViewItem])

  def check(:command_was_tracked, state, _ctx) do
    if state.create_count > 0 or state.view_count > 0 do
      :ok
    else
      {:error, "No commands tracked"}
    end
  end

  @requirement "REQ-PERF-001"
  check(:always, sample: 5)

  def check(:sampled_check, _state, _ctx) do
    # This only runs every 5th step
    :ok
  end

  requirements(["REQ-MULTI-001", "REQ-MULTI-002", "REQ-MULTI-003"])
  check(:always)

  def check(:multi_requirement_check, _state, _ctx) do
    :ok
  end
end

defmodule PropertyDamage.Test.Projections.SingleAfterTrigger do
  @moduledoc """
  Test projection with single module after trigger.
  """
  use PropertyDamage.AssertionProjection

  alias PropertyDamage.Test.Commands.CreateItem

  @impl true
  def init, do: %{}

  @impl true
  def apply(state, _), do: state

  check(after: CreateItem)
  @impl true
  def check(:after_create, _state, _ctx), do: :ok
end

defmodule PropertyDamage.Test.Projections.EventAfterTrigger do
  @moduledoc """
  Test projection with event-based after trigger.
  """
  use PropertyDamage.AssertionProjection

  alias PropertyDamage.Test.Events.ItemCreated

  @impl true
  def init, do: %{}

  @impl true
  def apply(state, _), do: state

  check(after: ItemCreated)
  @impl true
  def check(:after_item_created, _state, _ctx), do: :ok
end
