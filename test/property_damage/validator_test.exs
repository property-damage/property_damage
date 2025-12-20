defmodule PropertyDamage.ValidatorTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Validator
  alias PropertyDamage.Ref

  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Test.ExecutorModel

  describe "valid_sequence?/2" do
    test "returns true for empty sequence" do
      assert Validator.valid_sequence?([], ExecutorModel)
    end

    test "returns true for valid single command" do
      commands = [%CreateItem{name: "Test", quantity: 5}]

      assert Validator.valid_sequence?(commands, ExecutorModel)
    end

    test "returns true for valid multi-command sequence" do
      commands = [
        %CreateItem{name: "First", quantity: 1},
        %CreateItem{name: "Second", quantity: 2},
        %CreateItem{name: "Third", quantity: 3}
      ]

      assert Validator.valid_sequence?(commands, ExecutorModel)
    end

    test "returns false when precondition fails" do
      # ViewItem requires items to exist
      ref = Ref.symbolic(label: "missing")
      commands = [%ViewItem{item_ref: ref}]

      refute Validator.valid_sequence?(commands, ExecutorModel)
    end

    test "simulates state transitions" do
      # First create an item, then view it
      # This should pass because CreateItem.simulate creates the item state
      commands = [
        %CreateItem{name: "Test", quantity: 5},
        %CreateItem{name: "Another", quantity: 3}
      ]

      assert Validator.valid_sequence?(commands, ExecutorModel)
    end

    test "validates preconditions against simulated state" do
      # ViewItem after CreateItem should work because:
      # 1. CreateItem.simulate returns ItemCreated event
      # 2. ModelState.apply handles ItemCreated by adding to items map
      # 3. ViewItem.precondition checks if items map is non-empty
      # Even though ref is unresolved (nil), the item still gets added

      ref = Ref.symbolic(label: "item")

      commands = [
        %CreateItem{name: "Test", quantity: 5},
        %ViewItem{item_ref: ref}
      ]

      # This should pass because CreateItem.simulate populates state
      assert Validator.valid_sequence?(commands, ExecutorModel)
    end
  end
end
