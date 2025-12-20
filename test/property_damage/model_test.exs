defmodule PropertyDamage.ModelTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Model
  alias PropertyDamage.Test.{FullModel, MinimalModel, SimpleWeightModel, WeightedModel}
  alias PropertyDamage.Test.Commands.{CreateItem, ViewItem, MinimalCommand}
  alias PropertyDamage.Test.Projections.{ModelState, TestAssertions}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}

  describe "Model behaviour can be implemented" do
    test "full model with all callbacks" do
      Code.ensure_loaded!(FullModel)

      assert function_exported?(FullModel, :commands, 0)
      assert function_exported?(FullModel, :state_projection, 0)
      assert function_exported?(FullModel, :assertion_projections, 0)
      assert function_exported?(FullModel, :injectable_events, 0)
      assert function_exported?(FullModel, :setup_once, 1)
      assert function_exported?(FullModel, :setup_each, 1)
      assert function_exported?(FullModel, :teardown_each, 1)
      assert function_exported?(FullModel, :teardown_once, 1)
      assert function_exported?(FullModel, :terminate?, 3)
    end

    test "minimal model with only required callbacks" do
      Code.ensure_loaded!(MinimalModel)

      assert function_exported?(MinimalModel, :commands, 0)
      assert function_exported?(MinimalModel, :state_projection, 0)
      assert function_exported?(MinimalModel, :assertion_projections, 0)

      # Optional callbacks not exported
      refute function_exported?(MinimalModel, :injectable_events, 0)
      refute function_exported?(MinimalModel, :setup_once, 1)
      refute function_exported?(MinimalModel, :setup_each, 1)
      refute function_exported?(MinimalModel, :teardown_each, 1)
      refute function_exported?(MinimalModel, :teardown_once, 1)
      refute function_exported?(MinimalModel, :terminate?, 3)
    end
  end

  describe "required callbacks" do
    test "commands/0 returns command list" do
      commands = FullModel.commands()

      assert is_list(commands)
      assert length(commands) == 3
    end

    test "state_projection/0 returns projection module" do
      projection = FullModel.state_projection()

      assert projection == ModelState
    end

    test "assertion_projections/0 returns projection list" do
      projections = FullModel.assertion_projections()

      assert projections == [TestAssertions]
    end
  end

  describe "optional callbacks work" do
    test "injectable_events/0 returns event list" do
      events = FullModel.injectable_events()

      assert events == [ItemCreated, ItemViewed]
    end

    test "setup_once/1 returns :ok" do
      result = FullModel.setup_once(%{})

      assert result == :ok
    end

    test "setup_each/1 returns :ok" do
      result = FullModel.setup_each(%{})

      assert result == :ok
    end

    test "teardown_each/1 returns :ok" do
      result = FullModel.teardown_each(%{})

      assert result == :ok
    end

    test "teardown_once/1 returns :ok" do
      result = FullModel.teardown_once(%{})

      assert result == :ok
    end
  end

  describe "command weights" do
    test "simple command list" do
      commands = SimpleWeightModel.commands()

      # Should be simple modules, not tuples
      assert commands == [CreateItem, ViewItem]
    end

    test "weighted command list" do
      commands = WeightedModel.commands()

      assert commands == [{3, CreateItem}, {1, ViewItem}]
    end

    test "mixed command list" do
      commands = FullModel.commands()

      assert commands == [{3, CreateItem}, {2, ViewItem}, {1, MinimalCommand}]
    end
  end

  describe "terminate?/3" do
    test "receives state, command, and events" do
      state = %{items: %{}}
      command = %CreateItem{name: "Test", quantity: 1}
      events = [%ItemCreated{item_ref: nil, name: "Test", quantity: 1}]

      # Should not raise - callback receives all arguments
      result = FullModel.terminate?(state, command, events)

      assert is_boolean(result)
    end

    test "returns true for terminal command" do
      state = %{}
      command = %MinimalCommand{}
      events = []

      assert FullModel.terminate?(state, command, events) == true
    end

    test "returns false for non-terminal command" do
      state = %{}
      command = %CreateItem{name: "Test", quantity: 1}
      events = []

      assert FullModel.terminate?(state, command, events) == false
    end
  end

  describe "normalize_commands/1" do
    test "passes through weighted tuples" do
      commands = [{3, CreateItem}, {1, ViewItem}]

      result = Model.normalize_commands(commands)

      assert result == [{3, CreateItem}, {1, ViewItem}]
    end

    test "wraps simple modules with weight 1" do
      commands = [CreateItem, ViewItem]

      result = Model.normalize_commands(commands)

      assert result == [{1, CreateItem}, {1, ViewItem}]
    end

    test "handles mixed list" do
      commands = [{3, CreateItem}, ViewItem]

      result = Model.normalize_commands(commands)

      assert result == [{3, CreateItem}, {1, ViewItem}]
    end
  end

  describe "behaviour callbacks" do
    test "required callbacks are specified" do
      callbacks = Model.behaviour_info(:callbacks)

      assert {:commands, 0} in callbacks
      assert {:state_projection, 0} in callbacks
      assert {:assertion_projections, 0} in callbacks
    end

    test "optional callbacks are declared" do
      optional = Model.behaviour_info(:optional_callbacks)

      assert {:injectable_events, 0} in optional
      assert {:setup_once, 1} in optional
      assert {:setup_each, 1} in optional
      assert {:teardown_each, 1} in optional
      assert {:teardown_once, 1} in optional
      assert {:terminate?, 3} in optional
    end
  end
end
