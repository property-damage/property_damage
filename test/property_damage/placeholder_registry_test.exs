defmodule PropertyDamage.PlaceholderRegistryTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Placeholder
  alias PropertyDamage.PlaceholderRegistry

  defmodule TestEvent do
    defstruct [:id, :amount]
  end

  defmodule OtherEvent do
    defstruct [:ref, :data]
  end

  describe "new/0" do
    test "creates empty registry" do
      reg = PlaceholderRegistry.new()

      assert %PlaceholderRegistry{} = reg
      assert reg.placeholders == %{}
      assert reg.by_location == %{}
    end
  end

  describe "register/2" do
    test "adds placeholder to registry" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)

      reg = PlaceholderRegistry.register(reg, p)

      assert Map.has_key?(reg.placeholders, p.id)
    end

    test "indexes by location" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)

      reg = PlaceholderRegistry.register(reg, p)

      location = {TestEvent, [:id], 0, 0}
      assert Map.has_key?(reg.by_location, location)
      assert reg.by_location[location] == p.id
    end

    test "can register multiple placeholders" do
      reg = PlaceholderRegistry.new()
      p1 = Placeholder.new(TestEvent, [:id], 0, 0)
      p2 = Placeholder.new(OtherEvent, [:ref], 1, 0)

      reg =
        reg
        |> PlaceholderRegistry.register(p1)
        |> PlaceholderRegistry.register(p2)

      assert map_size(reg.placeholders) == 2
      assert map_size(reg.by_location) == 2
    end
  end

  describe "get/2" do
    test "returns placeholder by ID" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      reg = PlaceholderRegistry.register(reg, p)

      result = PlaceholderRegistry.get(reg, p.id)

      assert result == p
    end

    test "returns nil for unknown ID" do
      reg = PlaceholderRegistry.new()

      assert PlaceholderRegistry.get(reg, make_ref()) == nil
    end
  end

  describe "get_by_location/5" do
    test "returns placeholder by location" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      reg = PlaceholderRegistry.register(reg, p)

      result = PlaceholderRegistry.get_by_location(reg, TestEvent, [:id], 0, 0)

      assert result == p
    end

    test "returns nil for unknown location" do
      reg = PlaceholderRegistry.new()

      assert PlaceholderRegistry.get_by_location(reg, TestEvent, [:id], 0, 0) == nil
    end
  end

  describe "resolve_by_location/6" do
    test "resolves placeholder by location" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      reg = PlaceholderRegistry.register(reg, p)

      reg = PlaceholderRegistry.resolve_by_location(reg, TestEvent, [:id], 0, 0, "order_123")

      resolved = PlaceholderRegistry.get(reg, p.id)
      assert resolved.resolved == "order_123"
    end

    test "returns unchanged registry for unknown location" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      reg = PlaceholderRegistry.register(reg, p)

      reg2 = PlaceholderRegistry.resolve_by_location(reg, OtherEvent, [:ref], 0, 0, "value")

      # Placeholder should still be unresolved
      assert PlaceholderRegistry.get(reg2, p.id).resolved == nil
    end

    test "resolves correct placeholder when multiple exist" do
      reg = PlaceholderRegistry.new()
      p1 = Placeholder.new(TestEvent, [:id], 0, 0)
      p2 = Placeholder.new(TestEvent, [:id], 1, 0)
      p3 = Placeholder.new(OtherEvent, [:ref], 0, 0)

      reg =
        reg
        |> PlaceholderRegistry.register(p1)
        |> PlaceholderRegistry.register(p2)
        |> PlaceholderRegistry.register(p3)

      reg = PlaceholderRegistry.resolve_by_location(reg, TestEvent, [:id], 1, 0, "order_456")

      # Only p2 should be resolved
      assert PlaceholderRegistry.get(reg, p1.id).resolved == nil
      assert PlaceholderRegistry.get(reg, p2.id).resolved == "order_456"
      assert PlaceholderRegistry.get(reg, p3.id).resolved == nil
    end
  end

  describe "deep_resolve/2" do
    test "resolves single placeholder" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      reg = PlaceholderRegistry.register(reg, p)
      reg = PlaceholderRegistry.resolve_by_location(reg, TestEvent, [:id], 0, 0, "order_123")

      result = PlaceholderRegistry.deep_resolve(reg, p)

      assert result == "order_123"
    end

    test "resolves placeholder in map" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      reg = PlaceholderRegistry.register(reg, p)
      reg = PlaceholderRegistry.resolve_by_location(reg, TestEvent, [:id], 0, 0, "order_123")

      data = %{id: p, name: "test"}
      result = PlaceholderRegistry.deep_resolve(reg, data)

      assert result == %{id: "order_123", name: "test"}
    end

    test "resolves placeholder in list" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      reg = PlaceholderRegistry.register(reg, p)
      reg = PlaceholderRegistry.resolve_by_location(reg, TestEvent, [:id], 0, 0, "order_123")

      data = [p, "other"]
      result = PlaceholderRegistry.deep_resolve(reg, data)

      assert result == ["order_123", "other"]
    end

    test "resolves placeholder in tuple" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      reg = PlaceholderRegistry.register(reg, p)
      reg = PlaceholderRegistry.resolve_by_location(reg, TestEvent, [:id], 0, 0, "order_123")

      data = {:ok, p}
      result = PlaceholderRegistry.deep_resolve(reg, data)

      assert result == {:ok, "order_123"}
    end

    test "resolves placeholder in struct" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      reg = PlaceholderRegistry.register(reg, p)
      reg = PlaceholderRegistry.resolve_by_location(reg, TestEvent, [:id], 0, 0, "order_123")

      data = %TestEvent{id: p, amount: 100}
      result = PlaceholderRegistry.deep_resolve(reg, data)

      assert %TestEvent{} = result
      assert result.id == "order_123"
      assert result.amount == 100
    end

    test "resolves deeply nested placeholder" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      reg = PlaceholderRegistry.register(reg, p)
      reg = PlaceholderRegistry.resolve_by_location(reg, TestEvent, [:id], 0, 0, "order_123")

      data = %{outer: %{inner: [p]}}
      result = PlaceholderRegistry.deep_resolve(reg, data)

      assert result == %{outer: %{inner: ["order_123"]}}
    end

    test "resolves multiple placeholders" do
      reg = PlaceholderRegistry.new()
      p1 = Placeholder.new(TestEvent, [:id], 0, 0)
      p2 = Placeholder.new(OtherEvent, [:ref], 1, 0)

      reg =
        reg
        |> PlaceholderRegistry.register(p1)
        |> PlaceholderRegistry.register(p2)
        |> PlaceholderRegistry.resolve_by_location(TestEvent, [:id], 0, 0, "order_123")
        |> PlaceholderRegistry.resolve_by_location(OtherEvent, [:ref], 1, 0, "ref_456")

      data = %{order_id: p1, other_ref: p2}
      result = PlaceholderRegistry.deep_resolve(reg, data)

      assert result == %{order_id: "order_123", other_ref: "ref_456"}
    end

    test "resolves placeholder as map key" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      reg = PlaceholderRegistry.register(reg, p)
      reg = PlaceholderRegistry.resolve_by_location(reg, TestEvent, [:id], 0, 0, :key)

      data = %{p => "value"}
      result = PlaceholderRegistry.deep_resolve(reg, data)

      assert result == %{key: "value"}
    end

    test "raises for unresolved placeholder" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      reg = PlaceholderRegistry.register(reg, p)

      assert_raise ArgumentError, ~r/Unresolved placeholder/, fn ->
        PlaceholderRegistry.deep_resolve(reg, p)
      end
    end

    test "error includes path, command_index, event_index" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:ids, :order], 5, 3)
      reg = PlaceholderRegistry.register(reg, p)

      assert_raise ArgumentError, ~r/\[:ids, :order\]/, fn ->
        PlaceholderRegistry.deep_resolve(reg, p)
      end

      assert_raise ArgumentError, ~r/command 5/, fn ->
        PlaceholderRegistry.deep_resolve(reg, p)
      end

      assert_raise ArgumentError, ~r/event 3/, fn ->
        PlaceholderRegistry.deep_resolve(reg, p)
      end
    end

    test "raises for unknown placeholder ID" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      # Note: not registered

      assert_raise ArgumentError, ~r/Unknown placeholder ID/, fn ->
        PlaceholderRegistry.deep_resolve(reg, p)
      end
    end

    test "leaves non-placeholder values unchanged" do
      reg = PlaceholderRegistry.new()

      assert PlaceholderRegistry.deep_resolve(reg, "string") == "string"
      assert PlaceholderRegistry.deep_resolve(reg, 123) == 123
      assert PlaceholderRegistry.deep_resolve(reg, :atom) == :atom
      assert PlaceholderRegistry.deep_resolve(reg, %{key: "value"}) == %{key: "value"}
    end
  end

  describe "contains_placeholder?/1" do
    test "returns true for Placeholder struct" do
      p = Placeholder.new(TestEvent, [:id], 0, 0)

      assert PlaceholderRegistry.contains_placeholder?(p)
    end

    test "returns true for map containing placeholder" do
      p = Placeholder.new(TestEvent, [:id], 0, 0)

      assert PlaceholderRegistry.contains_placeholder?(%{id: p})
    end

    test "returns true for nested map containing placeholder" do
      p = Placeholder.new(TestEvent, [:id], 0, 0)

      assert PlaceholderRegistry.contains_placeholder?(%{outer: %{inner: p}})
    end

    test "returns true for list containing placeholder" do
      p = Placeholder.new(TestEvent, [:id], 0, 0)

      assert PlaceholderRegistry.contains_placeholder?([p, "other"])
    end

    test "returns true for tuple containing placeholder" do
      p = Placeholder.new(TestEvent, [:id], 0, 0)

      assert PlaceholderRegistry.contains_placeholder?({:ok, p})
    end

    test "returns true for struct containing placeholder" do
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      event = %TestEvent{id: p, amount: 100}

      assert PlaceholderRegistry.contains_placeholder?(event)
    end

    test "returns false for map without placeholder" do
      refute PlaceholderRegistry.contains_placeholder?(%{id: "123"})
    end

    test "returns false for simple values" do
      refute PlaceholderRegistry.contains_placeholder?(nil)
      refute PlaceholderRegistry.contains_placeholder?("string")
      refute PlaceholderRegistry.contains_placeholder?(123)
    end
  end

  describe "collect_placeholder_ids/1" do
    test "collects ID from single placeholder" do
      p = Placeholder.new(TestEvent, [:id], 0, 0)

      ids = PlaceholderRegistry.collect_placeholder_ids(p)

      assert ids == [p.id]
    end

    test "collects IDs from map" do
      p1 = Placeholder.new(TestEvent, [:id], 0, 0)
      p2 = Placeholder.new(OtherEvent, [:ref], 1, 0)
      data = %{id: p1, ref: p2}

      ids = PlaceholderRegistry.collect_placeholder_ids(data)

      assert p1.id in ids
      assert p2.id in ids
      assert length(ids) == 2
    end

    test "collects IDs from list" do
      p1 = Placeholder.new(TestEvent, [:id], 0, 0)
      p2 = Placeholder.new(TestEvent, [:id], 1, 0)
      data = [p1, "middle", p2]

      ids = PlaceholderRegistry.collect_placeholder_ids(data)

      assert p1.id in ids
      assert p2.id in ids
      assert length(ids) == 2
    end

    test "collects IDs from nested structure" do
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      data = %{outer: %{inner: [p]}}

      ids = PlaceholderRegistry.collect_placeholder_ids(data)

      assert ids == [p.id]
    end

    test "deduplicates IDs" do
      p = Placeholder.new(TestEvent, [:id], 0, 0)
      data = [p, p, p]

      ids = PlaceholderRegistry.collect_placeholder_ids(data)

      assert ids == [p.id]
    end

    test "returns empty list for non-placeholder data" do
      assert PlaceholderRegistry.collect_placeholder_ids(%{id: "123"}) == []
      assert PlaceholderRegistry.collect_placeholder_ids("string") == []
    end
  end

  describe "all/1" do
    test "returns all placeholders" do
      reg = PlaceholderRegistry.new()
      p1 = Placeholder.new(TestEvent, [:id], 0, 0)
      p2 = Placeholder.new(OtherEvent, [:ref], 1, 0)

      reg =
        reg
        |> PlaceholderRegistry.register(p1)
        |> PlaceholderRegistry.register(p2)

      all = PlaceholderRegistry.all(reg)

      assert length(all) == 2
      assert p1 in all
      assert p2 in all
    end

    test "returns empty list for empty registry" do
      reg = PlaceholderRegistry.new()

      assert PlaceholderRegistry.all(reg) == []
    end
  end

  describe "resolved/1" do
    test "returns only resolved placeholders" do
      reg = PlaceholderRegistry.new()
      p1 = Placeholder.new(TestEvent, [:id], 0, 0)
      p2 = Placeholder.new(OtherEvent, [:ref], 1, 0)

      reg =
        reg
        |> PlaceholderRegistry.register(p1)
        |> PlaceholderRegistry.register(p2)
        |> PlaceholderRegistry.resolve_by_location(TestEvent, [:id], 0, 0, "value")

      resolved = PlaceholderRegistry.resolved(reg)

      assert length(resolved) == 1
      assert hd(resolved).id == p1.id
    end
  end

  describe "unresolved/1" do
    test "returns only unresolved placeholders" do
      reg = PlaceholderRegistry.new()
      p1 = Placeholder.new(TestEvent, [:id], 0, 0)
      p2 = Placeholder.new(OtherEvent, [:ref], 1, 0)

      reg =
        reg
        |> PlaceholderRegistry.register(p1)
        |> PlaceholderRegistry.register(p2)
        |> PlaceholderRegistry.resolve_by_location(TestEvent, [:id], 0, 0, "value")

      unresolved = PlaceholderRegistry.unresolved(reg)

      assert length(unresolved) == 1
      assert hd(unresolved).id == p2.id
    end
  end

  describe "producers/1" do
    test "returns map from ID to command index" do
      reg = PlaceholderRegistry.new()
      p1 = Placeholder.new(TestEvent, [:id], 0, 0)
      p2 = Placeholder.new(OtherEvent, [:ref], 5, 0)

      reg =
        reg
        |> PlaceholderRegistry.register(p1)
        |> PlaceholderRegistry.register(p2)

      producers = PlaceholderRegistry.producers(reg)

      assert producers[p1.id] == 0
      assert producers[p2.id] == 5
    end
  end
end
