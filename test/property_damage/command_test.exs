defmodule PropertyDamage.CommandTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem, MinimalCommand}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}
  alias PropertyDamage.Ref

  describe "CreateItem command" do
    test "compiles correctly with behaviour" do
      # Verify generator is implemented
      assert function_exported?(CreateItem, :generator, 1)
      # Verify metadata callbacks
      assert function_exported?(CreateItem, :creates_ref, 0)
      assert function_exported?(CreateItem, :downstream_observables, 0)
    end

    test "creates_ref returns :item_ref" do
      assert CreateItem.creates_ref() == :item_ref
    end

    test "downstream_observables returns expected events" do
      assert CreateItem.downstream_observables() == [ItemCreated]
    end

    test "generator/1 produces valid maps" do
      check all(map <- CreateItem.generator(%{})) do
        assert is_map(map)
        assert Map.has_key?(map, :name)
        assert Map.has_key?(map, :quantity)
        assert is_binary(map.name)
        assert is_integer(map.quantity)
        assert map.quantity > 0
      end
    end

    test "generator/1 respects overrides" do
      check all(map <- CreateItem.generator(%{name: "Fixed"})) do
        assert map.name == "Fixed"
        assert is_integer(map.quantity)
      end
    end
  end

  describe "ViewItem command" do
    test "compiles correctly with behaviour" do
      assert function_exported?(ViewItem, :generator, 1)
      assert function_exported?(ViewItem, :read_only?, 0)
      assert function_exported?(ViewItem, :downstream_observables, 0)
    end

    test "read_only? returns true" do
      assert ViewItem.read_only?() == true
    end

    test "downstream_observables returns expected events" do
      assert ViewItem.downstream_observables() == [ItemViewed]
    end

    test "generator/1 produces valid maps with nil item_ref" do
      check all(map <- ViewItem.generator(%{})) do
        assert is_map(map)
        assert Map.has_key?(map, :item_ref)
        assert map.item_ref == nil
      end
    end

    test "generator/1 respects overrides" do
      ref = Ref.symbolic(label: "item")

      check all(map <- ViewItem.generator(%{item_ref: ref})) do
        assert map.item_ref == ref
      end
    end

    test "label/2 returns formatted string" do
      ref = Ref.symbolic(label: "item")
      state = %{items: %{ref => %{name: "Widget"}}}
      cmd = %ViewItem{item_ref: ref}

      label = ViewItem.label(state, cmd)

      assert is_binary(label)
      assert label =~ "viewing item"
    end
  end

  describe "MinimalCommand" do
    test "compiles with only required callback (generator)" do
      assert function_exported?(MinimalCommand, :generator, 1)
    end

    test "optional callbacks are not exported" do
      refute function_exported?(MinimalCommand, :label, 2)
      refute function_exported?(MinimalCommand, :creates_ref, 0)
      refute function_exported?(MinimalCommand, :downstream_observables, 0)
      refute function_exported?(MinimalCommand, :read_only?, 0)
    end

    test "generator/1 produces empty map" do
      check all(map <- MinimalCommand.generator(%{})) do
        assert map == %{}
      end
    end
  end

  describe "behaviour enforcement" do
    test "generator is required callback" do
      callbacks = PropertyDamage.Command.behaviour_info(:callbacks)

      assert {:generator, 1} in callbacks
    end

    test "optional callbacks are declared" do
      optional = PropertyDamage.Command.behaviour_info(:optional_callbacks)

      assert {:label, 2} in optional
      assert {:creates_ref, 0} in optional
      assert {:downstream_observables, 0} in optional
      assert {:read_only?, 0} in optional
    end

    test "precondition is no longer a callback (moved to Model)" do
      callbacks = PropertyDamage.Command.behaviour_info(:callbacks)

      refute {:precondition, 1} in callbacks
    end

    test "new! is no longer a callback (replaced by generator)" do
      callbacks = PropertyDamage.Command.behaviour_info(:callbacks)

      refute {:new!, 2} in callbacks
    end

    test "simulate is no longer a callback (moved to Model)" do
      callbacks = PropertyDamage.Command.behaviour_info(:callbacks)
      optional = PropertyDamage.Command.behaviour_info(:optional_callbacks)

      refute {:simulate, 2} in callbacks
      refute {:simulate, 2} in optional
    end
  end
end
