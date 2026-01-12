defmodule PropertyDamage.Test.Projections.ModelState do
  @moduledoc """
  Test projection that tracks model state for command preconditions.

  Demonstrates basic Projection usage without assertions.
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
  Test assertion projection demonstrating all assertion features.

  Includes:
  - trigger every: 1 (every step)
  - trigger every: Module (after specific module)
  - trigger every: [Module1, Module2] (after any listed)
  - trigger every: N (sampling)
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

  # === Assertions ===

  @requirement "REQ-INV-001"
  trigger(every: 1)
  @impl true
  def assert(:quantity_non_negative, state, _cmd_or_event) do
    if state.total_quantity >= 0, do: :ok, else: {:error, "Negative quantity"}
  end

  @requirement "REQ-CREATE-001"
  trigger(every: CreateItem)

  def assert(:create_increments_count, state, _cmd_or_event) do
    if state.create_count > 0, do: :ok, else: {:error, "Create count should be positive"}
  end

  @requirement "REQ-CMD-001"
  @requirement "REQ-CMD-002"
  trigger(every: [CreateItem, ViewItem])

  def assert(:command_was_tracked, state, _cmd_or_event) do
    if state.create_count > 0 or state.view_count > 0 do
      :ok
    else
      {:error, "No commands tracked"}
    end
  end

  @requirement "REQ-PERF-001"
  trigger(every: 5)

  def assert(:sampled_check, _state, _cmd_or_event) do
    # This only runs every 5th step
    :ok
  end

  requirements(["REQ-MULTI-001", "REQ-MULTI-002", "REQ-MULTI-003"])
  trigger(every: 1)

  def assert(:multi_requirement_check, _state, _cmd_or_event) do
    :ok
  end
end

defmodule PropertyDamage.Test.Projections.SingleAfterTrigger do
  @moduledoc """
  Test projection with single module trigger.
  """
  use PropertyDamage.AssertionProjection

  alias PropertyDamage.Test.Commands.CreateItem

  @impl true
  def init, do: %{}

  @impl true
  def apply(state, _), do: state

  trigger(every: CreateItem)
  @impl true
  def assert(:after_create, _state, _cmd_or_event), do: :ok
end

defmodule PropertyDamage.Test.Projections.EventAfterTrigger do
  @moduledoc """
  Test projection with event-based trigger.
  """
  use PropertyDamage.AssertionProjection

  alias PropertyDamage.Test.Events.ItemCreated

  @impl true
  def init, do: %{}

  @impl true
  def apply(state, _), do: state

  trigger(every: ItemCreated)
  @impl true
  def assert(:after_item_created, _state, _cmd_or_event), do: :ok
end

# Legacy projection using old check/3 syntax for backward compatibility testing
defmodule PropertyDamage.Test.Projections.LegacyCheckProjection do
  @moduledoc """
  Test projection using legacy check/3 syntax for backward compatibility.
  """
  use PropertyDamage.AssertionProjection

  @impl true
  def init, do: %{count: 0}

  @impl true
  def apply(state, _), do: update_in(state, [:count], &(&1 + 1))

  # Legacy syntax using check/3
  check(:always)
  @impl true
  def check(:legacy_check, state, _ctx) do
    if state.count >= 0, do: :ok, else: {:error, "negative count"}
  end
end
