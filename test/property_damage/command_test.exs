defmodule PropertyDamage.CommandTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PropertyDamage.Test.Commands.{CreateItem, MinimalCommand, ViewItem}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  describe "CreateItem command" do
    test "compiles correctly with behaviour" do
      # Ensure module is loaded before checking exports
      Code.ensure_loaded!(CreateItem)
      # Verify generator is implemented
      assert function_exported?(CreateItem, :generator, 1)
      # Verify the static metadata surface
      assert function_exported?(CreateItem, :command_spec, 1)
    end

    test "command_spec :observables returns expected events" do
      assert CreateItem.command_spec([]).observables == [ItemCreated]
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
      Code.ensure_loaded!(ViewItem)
      assert function_exported?(ViewItem, :generator, 1)
      assert function_exported?(ViewItem, :command_spec, 1)
    end

    test "read-only commands declare shrink: :prefer_remove" do
      assert ViewItem.command_spec([]).shrink == :prefer_remove
    end

    test "command_spec :observables returns expected events" do
      assert ViewItem.command_spec([]).observables == [ItemViewed]
    end

    test "generator/1 produces valid maps with nil item_ref" do
      check all(map <- ViewItem.generator(%{})) do
        assert is_map(map)
        assert Map.has_key?(map, :item_ref)
        assert map.item_ref == nil
      end
    end

    test "generator/1 respects overrides" do
      item_ref = "item_0"

      check all(map <- ViewItem.generator(%{item_ref: item_ref})) do
        assert map.item_ref == item_ref
      end
    end

    test "label/2 returns formatted string" do
      item_ref = "item_0"
      state = %{items: %{item_ref => %{name: "Widget"}}}
      cmd = %ViewItem{item_ref: item_ref}

      label = ViewItem.label(state, cmd)

      assert is_binary(label)
      assert label =~ "viewing item"
    end
  end

  describe "MinimalCommand" do
    test "compiles with only required callback (generator)" do
      Code.ensure_loaded!(MinimalCommand)
      assert function_exported?(MinimalCommand, :generator, 1)
    end

    test "optional callbacks are not exported" do
      Code.ensure_loaded!(MinimalCommand)
      refute function_exported?(MinimalCommand, :label, 2)
      refute function_exported?(MinimalCommand, :idempotency_key, 1)
      refute function_exported?(MinimalCommand, :awaits, 2)
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
      assert {:idempotency_key, 1} in optional
      assert {:awaits, 2} in optional
      assert {:command_spec, 1} in optional
    end

    test "the deleted static metadata callbacks are no longer declared (DR-028)" do
      optional = PropertyDamage.Command.behaviour_info(:optional_callbacks)
      callbacks = PropertyDamage.Command.behaviour_info(:callbacks)
      all = optional ++ callbacks

      refute {:semantics, 0} in all
      refute {:settle_config, 0} in all
      refute {:read_only?, 0} in all
      refute {:idempotent?, 0} in all
      refute {:acceptable_retry_events, 0} in all
      refute {:downstream_observables, 0} in all
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
