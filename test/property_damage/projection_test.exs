defmodule PropertyDamage.ProjectionTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.Projections.ModelState
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}
  alias PropertyDamage.Ref

  describe "Projection behaviour" do
    test "init/0 returns initial state" do
      state = ModelState.init()

      assert state == %{items: %{}, view_count: 0}
    end

    test "apply/2 handles ItemCreated event" do
      state = ModelState.init()
      ref = Ref.symbolic(label: "item")
      event = %ItemCreated{item_ref: ref, name: "Widget", quantity: 5}

      new_state = ModelState.apply(state, event)

      assert new_state.items[ref] == %{name: "Widget", quantity: 5}
    end

    test "apply/2 handles ItemViewed event" do
      state = ModelState.init()

      new_state = ModelState.apply(state, %ItemViewed{item_ref: nil})

      assert new_state.view_count == 1
    end

    test "apply/2 ignores unknown events" do
      state = ModelState.init()

      # Unknown struct
      new_state = ModelState.apply(state, %{unknown: true})

      assert new_state == state
    end

    test "multiple events accumulate state" do
      ref1 = Ref.symbolic(label: "item1")
      ref2 = Ref.symbolic(label: "item2")

      state =
        ModelState.init()
        |> ModelState.apply(%ItemCreated{item_ref: ref1, name: "Widget", quantity: 5})
        |> ModelState.apply(%ItemCreated{item_ref: ref2, name: "Gadget", quantity: 3})
        |> ModelState.apply(%ItemViewed{item_ref: ref1})
        |> ModelState.apply(%ItemViewed{item_ref: ref2})

      assert map_size(state.items) == 2
      assert state.view_count == 2
    end
  end

  describe "behaviour callbacks" do
    test "Projection defines required callbacks" do
      callbacks = PropertyDamage.Projection.behaviour_info(:callbacks)

      assert {:init, 0} in callbacks
      assert {:apply, 2} in callbacks
    end
  end
end
