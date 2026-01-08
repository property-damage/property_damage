defmodule PropertyDamage.AssertionProjectionTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.Projections.{
    TestAssertions,
    SingleAfterTrigger,
    EventAfterTrigger,
    LegacyCheckProjection
  }

  alias PropertyDamage.Test.Events.ItemCreated
  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem}
  alias PropertyDamage.{AssertionProjection, Ref}

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

  describe "@trigger every: 1 (every step)" do
    test "assertion with every: 1 trigger is registered" do
      assertions = TestAssertions.__assertions__()
      quantity_assertion = Enum.find(assertions, &(&1.name == :quantity_non_negative))

      assert quantity_assertion != nil
      assert quantity_assertion.trigger == %{type: :every_step}
    end

    test "assert function returns :ok for valid state" do
      state = TestAssertions.init()

      result = TestAssertions.assert(:quantity_non_negative, state)

      assert result == :ok
    end

    test "assert function returns error tuple for invalid state" do
      state = %{total_quantity: -5}

      result = TestAssertions.assert(:quantity_non_negative, state)

      assert {:error, _} = result
    end
  end

  describe "@trigger every: Module" do
    test "assertion with single module trigger" do
      assertions = SingleAfterTrigger.__assertions__()
      after_assertion = Enum.find(assertions, &(&1.name == :after_create))

      assert after_assertion != nil
      assert after_assertion.trigger == %{type: :modules, modules: [CreateItem]}
    end

    test "TestAssertions has every: CreateItem assertion" do
      assertions = TestAssertions.__assertions__()
      create_assertion = Enum.find(assertions, &(&1.name == :create_increments_count))

      assert create_assertion != nil
      assert create_assertion.trigger == %{type: :modules, modules: [CreateItem]}
    end
  end

  describe "@trigger every: [Mod1, Mod2]" do
    test "assertion with multiple module trigger" do
      assertions = TestAssertions.__assertions__()
      cmd_assertion = Enum.find(assertions, &(&1.name == :command_was_tracked))

      assert cmd_assertion != nil
      assert cmd_assertion.trigger == %{type: :modules, modules: [CreateItem, ViewItem]}
    end
  end

  describe "@trigger every: Event" do
    test "assertion with event trigger" do
      assertions = EventAfterTrigger.__assertions__()
      event_assertion = Enum.find(assertions, &(&1.name == :after_item_created))

      assert event_assertion != nil
      assert event_assertion.trigger == %{type: :modules, modules: [ItemCreated]}
    end
  end

  describe "@trigger every: N (sampling)" do
    test "assertion with sampling is registered" do
      assertions = TestAssertions.__assertions__()
      sampled_assertion = Enum.find(assertions, &(&1.name == :sampled_check))

      assert sampled_assertion != nil
      assert sampled_assertion.trigger == %{type: :every_n, n: 5, target: :step}
    end
  end

  describe "@requirement attribute" do
    test "single @requirement is captured" do
      assertions = TestAssertions.__assertions__()
      quantity_assertion = Enum.find(assertions, &(&1.name == :quantity_non_negative))

      assert "REQ-INV-001" in quantity_assertion.requirements
    end

    test "multiple @requirement attributes accumulate" do
      assertions = TestAssertions.__assertions__()
      cmd_assertion = Enum.find(assertions, &(&1.name == :command_was_tracked))

      assert "REQ-CMD-001" in cmd_assertion.requirements
      assert "REQ-CMD-002" in cmd_assertion.requirements
    end
  end

  describe "requirements/1 macro" do
    test "requirements macro sets multiple requirements" do
      assertions = TestAssertions.__assertions__()
      multi_assertion = Enum.find(assertions, &(&1.name == :multi_requirement_check))

      assert "REQ-MULTI-001" in multi_assertion.requirements
      assert "REQ-MULTI-002" in multi_assertion.requirements
      assert "REQ-MULTI-003" in multi_assertion.requirements
      assert length(multi_assertion.requirements) == 3
    end
  end

  describe "__assertions__/0" do
    test "returns list of assertion metadata" do
      assertions = TestAssertions.__assertions__()

      assert is_list(assertions)
      assert length(assertions) == 5

      Enum.each(assertions, fn assertion ->
        assert Map.has_key?(assertion, :name)
        assert Map.has_key?(assertion, :trigger)
        assert Map.has_key?(assertion, :requirements)
      end)
    end

    test "__checks__/0 is aliased to __assertions__/0 for backward compatibility" do
      assertions = TestAssertions.__assertions__()
      checks = TestAssertions.__checks__()

      assert assertions == checks
    end
  end

  describe "should_run?/4" do
    test "every_step triggers on any step" do
      trigger = %{type: :every_step}
      counters = %{step: 5, command: 3, event: 2}

      assert AssertionProjection.should_run?(trigger, :command, CreateItem, counters)
      assert AssertionProjection.should_run?(trigger, :event, ItemCreated, counters)
    end

    test "every_n triggers on Nth step" do
      trigger = %{type: :every_n, n: 3, target: :step}

      assert AssertionProjection.should_run?(trigger, :command, CreateItem, %{step: 3})
      assert AssertionProjection.should_run?(trigger, :command, CreateItem, %{step: 6})
      refute AssertionProjection.should_run?(trigger, :command, CreateItem, %{step: 4})
    end

    test "wildcard :command triggers on any command" do
      trigger = %{type: :wildcard, target: :command}

      assert AssertionProjection.should_run?(trigger, :command, CreateItem, %{})
      refute AssertionProjection.should_run?(trigger, :event, ItemCreated, %{})
    end

    test "wildcard :event triggers on any event" do
      trigger = %{type: :wildcard, target: :event}

      assert AssertionProjection.should_run?(trigger, :event, ItemCreated, %{})
      refute AssertionProjection.should_run?(trigger, :command, CreateItem, %{})
    end

    test "modules trigger on matching module" do
      trigger = %{type: :modules, modules: [CreateItem, ViewItem]}

      assert AssertionProjection.should_run?(trigger, :command, CreateItem, %{})
      assert AssertionProjection.should_run?(trigger, :command, ViewItem, %{})
      refute AssertionProjection.should_run?(trigger, :event, ItemCreated, %{})
    end

    test "every_n with modules triggers on Nth matching module" do
      trigger = %{type: :every_n, n: 2, target: :modules, modules: [CreateItem]}
      counters = %{CreateItem => 2}

      assert AssertionProjection.should_run?(trigger, :command, CreateItem, counters)
      refute AssertionProjection.should_run?(trigger, :command, CreateItem, %{CreateItem => 1})
      refute AssertionProjection.should_run?(trigger, :command, ViewItem, counters)
    end
  end

  describe "legacy check/3 backward compatibility" do
    test "check/3 is still recognized" do
      assertions = LegacyCheckProjection.__assertions__()

      assert length(assertions) == 1
      assert hd(assertions).name == :legacy_check
    end

    test "legacy check function works" do
      state = LegacyCheckProjection.init()

      # Legacy check/3 still callable
      result = LegacyCheckProjection.check(:legacy_check, state, %{})

      assert result == :ok
    end

    test "legacy :always trigger normalizes to every_step" do
      assertions = LegacyCheckProjection.__assertions__()
      assertion = hd(assertions)

      assert assertion.trigger == %{type: :every_step}
    end
  end

  describe "behaviour callbacks" do
    test "AssertionProjection defines required callbacks" do
      callbacks = PropertyDamage.AssertionProjection.behaviour_info(:callbacks)

      assert {:init, 0} in callbacks
      assert {:apply, 2} in callbacks
      assert {:assert, 2} in callbacks
    end
  end
end
