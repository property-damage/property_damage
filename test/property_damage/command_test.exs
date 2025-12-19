defmodule PropertyDamage.CommandTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem, MinimalCommand}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}
  alias PropertyDamage.Ref

  describe "CreateItem command" do
    test "compiles correctly with behaviour" do
      # Verify behaviour is implemented
      assert function_exported?(CreateItem, :precondition, 1)
      assert function_exported?(CreateItem, :new!, 2)
      assert function_exported?(CreateItem, :generator, 1)
    end

    test "precondition always returns true" do
      assert CreateItem.precondition(%{})
      assert CreateItem.precondition(%{items: %{}})
      assert CreateItem.precondition(%{anything: "here"})
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

    test "new!/2 produces valid command structs" do
      state = %{}

      check all(cmd <- CreateItem.new!(state, %{})) do
        assert %CreateItem{} = cmd
        assert is_binary(cmd.name)
        assert is_integer(cmd.quantity)
        assert cmd.quantity > 0
      end
    end

    test "simulate/2 returns expected events" do
      state = %{}
      cmd = %CreateItem{name: "Widget", quantity: 5}

      events = CreateItem.simulate(state, cmd)

      assert [%ItemCreated{name: "Widget", quantity: 5, item_ref: nil}] = events
    end
  end

  describe "ViewItem command" do
    test "compiles correctly with behaviour" do
      assert function_exported?(ViewItem, :precondition, 1)
      assert function_exported?(ViewItem, :new!, 2)
      assert function_exported?(ViewItem, :generator, 1)
    end

    test "precondition returns false when no items exist" do
      refute ViewItem.precondition(%{})
      refute ViewItem.precondition(%{items: %{}})
    end

    test "precondition returns true when items exist" do
      ref = Ref.symbolic(label: "item")
      state = %{items: %{ref => %{name: "Widget"}}}

      assert ViewItem.precondition(state)
    end

    test "read_only? returns true" do
      assert ViewItem.read_only?() == true
    end

    test "downstream_observables returns expected events" do
      assert ViewItem.downstream_observables() == [ItemViewed]
    end

    test "new!/2 generates command with item_ref from state" do
      ref1 = Ref.symbolic(label: "item1")
      ref2 = Ref.symbolic(label: "item2")
      state = %{items: %{ref1 => %{name: "Widget"}, ref2 => %{name: "Gadget"}}}

      check all(cmd <- ViewItem.new!(state, %{})) do
        assert %ViewItem{} = cmd
        assert cmd.item_ref in [ref1, ref2]
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

    test "simulate/2 returns expected events" do
      ref = Ref.symbolic(label: "item")
      state = %{items: %{ref => %{name: "Widget"}}}
      cmd = %ViewItem{item_ref: ref}

      events = ViewItem.simulate(state, cmd)

      assert [%ItemViewed{item_ref: ^ref}] = events
    end
  end

  describe "MinimalCommand" do
    test "compiles with only required callbacks" do
      assert function_exported?(MinimalCommand, :precondition, 1)
      assert function_exported?(MinimalCommand, :new!, 2)
    end

    test "optional callbacks are not exported" do
      refute function_exported?(MinimalCommand, :generator, 1)
      refute function_exported?(MinimalCommand, :simulate, 2)
      refute function_exported?(MinimalCommand, :label, 2)
      refute function_exported?(MinimalCommand, :creates_ref, 0)
      refute function_exported?(MinimalCommand, :downstream_observables, 0)
      refute function_exported?(MinimalCommand, :read_only?, 0)
    end

    test "precondition works" do
      assert MinimalCommand.precondition(%{})
    end

    test "new!/2 generates command struct" do
      check all(cmd <- MinimalCommand.new!(%{}, %{})) do
        assert %MinimalCommand{} = cmd
      end
    end
  end

  describe "behaviour enforcement" do
    test "command without precondition fails compilation" do
      # We can't easily test compile-time behavior, but we can verify
      # that the behaviour specifies precondition as required
      callbacks = PropertyDamage.Command.behaviour_info(:callbacks)

      assert {:precondition, 1} in callbacks
      assert {:new!, 2} in callbacks
    end

    test "optional callbacks are declared" do
      optional = PropertyDamage.Command.behaviour_info(:optional_callbacks)

      assert {:generator, 1} in optional
      assert {:simulate, 2} in optional
      assert {:label, 2} in optional
      assert {:creates_ref, 0} in optional
      assert {:downstream_observables, 0} in optional
      assert {:read_only?, 0} in optional
    end
  end
end
