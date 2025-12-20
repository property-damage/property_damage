defmodule PropertyDamage.AssertionProjectionTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.Projections.{
    TestAssertions,
    SingleAfterTrigger,
    EventAfterTrigger
  }

  alias PropertyDamage.Test.Events.ItemCreated
  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.Ref

  describe "init/0 and apply/2" do
    test "init returns initial state" do
      state = TestAssertions.init()

      assert state.items == %{}
      assert state.total_quantity == 0
      assert state.create_count == 0
      assert state.view_count == 0
    end

    test "apply handles events" do
      state = TestAssertions.init()
      ref = Ref.symbolic(label: "item")

      new_state =
        TestAssertions.apply(state, %ItemCreated{
          item_ref: ref,
          name: "Widget",
          quantity: 10
        })

      assert new_state.items[ref] == %{name: "Widget", quantity: 10}
      assert new_state.total_quantity == 10
    end

    test "apply handles commands" do
      state = TestAssertions.init()

      new_state = TestAssertions.apply(state, %CreateItem{name: "Widget", quantity: 5})

      assert new_state.create_count == 1
    end
  end

  describe "@check :always trigger" do
    test "check with :always trigger is registered" do
      checks = TestAssertions.__checks__()
      quantity_check = Enum.find(checks, &(&1.name == :quantity_non_negative))

      assert quantity_check != nil
      assert quantity_check.trigger == :always
    end

    test "check function returns :ok for valid state" do
      state = TestAssertions.init()
      ctx = %{}

      result = TestAssertions.check(:quantity_non_negative, state, ctx)

      assert result == :ok
    end

    test "check function returns error tuple for invalid state" do
      state = %{total_quantity: -5}
      ctx = %{}

      result = TestAssertions.check(:quantity_non_negative, state, ctx)

      assert {:error, _} = result
    end
  end

  describe "@check after: Module trigger" do
    test "check with single module after trigger" do
      checks = SingleAfterTrigger.__checks__()
      after_check = Enum.find(checks, &(&1.name == :after_create))

      assert after_check != nil
      assert after_check.trigger == [{:after, [CreateItem]}]
    end

    test "TestAssertions has after: CreateItem check" do
      checks = TestAssertions.__checks__()
      create_check = Enum.find(checks, &(&1.name == :create_increments_count))

      assert create_check != nil
      assert create_check.trigger == [{:after, [CreateItem]}]
    end
  end

  describe "@check after: [Mod1, Mod2] trigger" do
    test "check with multiple module after trigger" do
      checks = TestAssertions.__checks__()
      cmd_check = Enum.find(checks, &(&1.name == :command_was_tracked))

      assert cmd_check != nil
      assert cmd_check.trigger == [{:after, [CreateItem, ViewItem]}]
    end
  end

  describe "@check after: Event trigger" do
    test "check with event after trigger" do
      checks = EventAfterTrigger.__checks__()
      event_check = Enum.find(checks, &(&1.name == :after_item_created))

      assert event_check != nil
      assert event_check.trigger == [{:after, [ItemCreated]}]
    end
  end

  describe "@check sample: N option" do
    test "check with sample option is registered" do
      checks = TestAssertions.__checks__()
      sampled_check = Enum.find(checks, &(&1.name == :sampled_check))

      assert sampled_check != nil
      assert sampled_check.trigger == :always
      assert sampled_check.sample == 5
    end

    test "check without sample option defaults to 1" do
      checks = TestAssertions.__checks__()
      quantity_check = Enum.find(checks, &(&1.name == :quantity_non_negative))

      assert quantity_check.sample == 1
    end
  end

  describe "@requirement attribute" do
    test "single @requirement is captured" do
      checks = TestAssertions.__checks__()
      quantity_check = Enum.find(checks, &(&1.name == :quantity_non_negative))

      assert "REQ-INV-001" in quantity_check.requirements
    end

    test "multiple @requirement attributes accumulate" do
      checks = TestAssertions.__checks__()
      cmd_check = Enum.find(checks, &(&1.name == :command_was_tracked))

      assert "REQ-CMD-001" in cmd_check.requirements
      assert "REQ-CMD-002" in cmd_check.requirements
    end
  end

  describe "requirements/1 macro" do
    test "requirements macro sets multiple requirements" do
      checks = TestAssertions.__checks__()
      multi_check = Enum.find(checks, &(&1.name == :multi_requirement_check))

      assert "REQ-MULTI-001" in multi_check.requirements
      assert "REQ-MULTI-002" in multi_check.requirements
      assert "REQ-MULTI-003" in multi_check.requirements
      assert length(multi_check.requirements) == 3
    end
  end

  describe "__checks__/0" do
    test "returns list of check metadata" do
      checks = TestAssertions.__checks__()

      assert is_list(checks)
      assert length(checks) == 5

      Enum.each(checks, fn check ->
        assert Map.has_key?(check, :name)
        assert Map.has_key?(check, :trigger)
        assert Map.has_key?(check, :requirements)
        assert Map.has_key?(check, :sample)
      end)
    end
  end

  describe "missing @check raises CompileError" do
    test "module without @check on check/3 fails compilation" do
      # We can't easily test compile-time errors, but we verify the
      # __on_definition__ hook is set up to enforce this
      Code.ensure_loaded!(PropertyDamage.AssertionProjection)
      assert function_exported?(PropertyDamage.AssertionProjection, :__on_definition__, 6)
    end
  end

  describe "behaviour callbacks" do
    test "AssertionProjection defines required callbacks" do
      callbacks = PropertyDamage.AssertionProjection.behaviour_info(:callbacks)

      assert {:init, 0} in callbacks
      assert {:apply, 2} in callbacks
      assert {:check, 3} in callbacks
    end
  end
end
