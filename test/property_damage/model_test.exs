defmodule PropertyDamage.ModelTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Model
  alias PropertyDamage.Test.Commands.{CreateItem, MinimalCommand, ViewItem}
  alias PropertyDamage.Test.Events.{ItemCreated, ItemViewed}
  alias PropertyDamage.Test.{FullModel, MinimalModel, SimpleWeightModel, WeightedModel}
  alias PropertyDamage.Test.Projections.{ModelState, TestAssertions}

  describe "Model behaviour can be implemented" do
    test "full model with all callbacks" do
      Code.ensure_loaded!(FullModel)

      assert function_exported?(FullModel, :commands, 0)
      assert function_exported?(FullModel, :command_sequence_projection, 0)
      assert function_exported?(FullModel, :assertion_projections, 0)
      assert function_exported?(FullModel, :injectable_events, 0)
      assert function_exported?(FullModel, :setup_once, 1)
      assert function_exported?(FullModel, :setup_each, 1)
      assert function_exported?(FullModel, :teardown_each, 1)
      assert function_exported?(FullModel, :teardown_once, 1)
      assert function_exported?(FullModel, :terminate?, 3)
      assert function_exported?(FullModel, :simulate, 2)
    end

    test "minimal model with only required callbacks" do
      Code.ensure_loaded!(MinimalModel)

      assert function_exported?(MinimalModel, :commands, 0)
      assert function_exported?(MinimalModel, :command_sequence_projection, 0)
      assert function_exported?(MinimalModel, :assertion_projections, 0)
      assert function_exported?(MinimalModel, :simulate, 2)

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

    test "command_sequence_projection/0 returns projection module" do
      projection = FullModel.command_sequence_projection()

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

  describe "command specifications" do
    test "simple command list uses new format with when:/with:" do
      commands = SimpleWeightModel.commands()

      # First command is simple module
      assert Enum.at(commands, 0) == CreateItem

      # Second command has when:/with: options
      {module, opts} = Enum.at(commands, 1)
      assert module == ViewItem
      assert is_function(Keyword.get(opts, :when), 1)
      assert is_function(Keyword.get(opts, :with), 1)
    end

    test "weighted command list uses {Module, weight: n} format" do
      commands = WeightedModel.commands()

      # First command has weight
      {module1, opts1} = Enum.at(commands, 0)
      assert module1 == CreateItem
      assert Keyword.get(opts1, :weight) == 3

      # Second command has weight and wiring
      {module2, opts2} = Enum.at(commands, 1)
      assert module2 == ViewItem
      assert Keyword.get(opts2, :weight) == 1
      assert is_function(Keyword.get(opts2, :when), 1)
    end

    test "mixed command list uses new format" do
      commands = FullModel.commands()

      assert length(commands) == 3

      # Check weights are present
      {_, opts1} = Enum.at(commands, 0)
      assert Keyword.get(opts1, :weight) == 3

      {_, opts2} = Enum.at(commands, 1)
      assert Keyword.get(opts2, :weight) == 2

      {_, opts3} = Enum.at(commands, 2)
      assert Keyword.get(opts3, :weight) == 1
    end
  end

  describe "simulate/2 callback" do
    test "simulate returns expected events for CreateItem" do
      state = %{items: %{}}
      command = %CreateItem{name: "Test", quantity: 5}

      events = FullModel.simulate(command, state)

      assert [%ItemCreated{name: "Test", quantity: 5, item_ref: nil}] = events
    end

    test "simulate returns expected events for ViewItem" do
      state = %{items: %{}}
      command = %ViewItem{item_ref: "ref-123"}

      events = FullModel.simulate(command, state)

      assert [%ItemViewed{item_ref: "ref-123"}] = events
    end

    test "simulate returns empty list for MinimalCommand" do
      state = %{}
      command = %MinimalCommand{}

      events = FullModel.simulate(command, state)

      assert events == []
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
    test "normalizes {weight, module} tuples to 3-tuple with spec map" do
      commands = [{3, CreateItem}, {1, ViewItem}]

      result = Model.normalize_commands(commands)

      assert [{3, CreateItem, spec1}, {1, ViewItem, spec2}] = result
      # Spec is now a map with resolved values
      assert is_map(spec1)
      assert spec1.weight == 3
      assert spec1.command == CreateItem
      assert is_map(spec2)
      assert spec2.weight == 1
      assert spec2.command == ViewItem
    end

    test "wraps simple modules with weight 1 and spec map" do
      commands = [CreateItem, ViewItem]

      result = Model.normalize_commands(commands)

      assert [{1, CreateItem, spec1}, {1, ViewItem, spec2}] = result
      assert is_map(spec1)
      assert spec1.weight == 1
      assert spec1.command == CreateItem
      assert is_map(spec2)
      assert spec2.weight == 1
      assert spec2.command == ViewItem
    end

    test "handles mixed list" do
      commands = [{3, CreateItem}, ViewItem]

      result = Model.normalize_commands(commands)

      assert [{3, CreateItem, spec1}, {1, ViewItem, spec2}] = result
      assert spec1.weight == 3
      assert spec2.weight == 1
    end

    test "extracts weight from opts in new format" do
      commands = [{CreateItem, weight: 3, when: fn _ -> true end}]

      result = Model.normalize_commands(commands)

      assert [{3, CreateItem, spec}] = result
      assert spec.weight == 3
      assert is_function(spec.when, 1)
    end

    test "defaults weight to 1 when not specified in opts" do
      commands = [{ViewItem, when: fn _ -> true end}]

      result = Model.normalize_commands(commands)

      assert [{1, ViewItem, spec}] = result
      assert is_function(spec.when, 1)
    end

    test "spec map contains all required fields" do
      commands = [CreateItem]

      result = Model.normalize_commands(commands)

      assert [{1, CreateItem, spec}] = result
      assert is_map(spec)
      assert Map.has_key?(spec, :command)
      assert Map.has_key?(spec, :execution)
      assert Map.has_key?(spec, :settle)
      assert Map.has_key?(spec, :shrink)
      assert Map.has_key?(spec, :when)
      assert Map.has_key?(spec, :with)
      assert Map.has_key?(spec, :weight)
    end
  end

  describe "behaviour callbacks" do
    test "required callbacks are specified" do
      callbacks = Model.behaviour_info(:callbacks)

      assert {:commands, 0} in callbacks
      assert {:command_sequence_projection, 0} in callbacks
      # assertion_projections is now optional
      assert {:assertion_projections, 0} in callbacks
      # simulator is a callback (optional) - returns module implementing Simulator behaviour
      assert {:simulator, 0} in callbacks
    end

    test "optional callbacks are declared" do
      optional = Model.behaviour_info(:optional_callbacks)

      assert {:assertion_projections, 0} in optional
      assert {:injectable_events, 0} in optional
      assert {:setup_once, 1} in optional
      assert {:setup_each, 1} in optional
      assert {:teardown_each, 1} in optional
      assert {:teardown_once, 1} in optional
      assert {:terminate?, 3} in optional
      assert {:simulator, 0} in optional
    end
  end
end
