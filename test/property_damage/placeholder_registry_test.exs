defmodule PropertyDamage.PlaceholderRegistryTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Sequence.Position

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
      assert reg.producer_link == %{}
    end
  end

  describe "register/2" do
    test "adds placeholder to the id index" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)

      reg = PlaceholderRegistry.register(reg, p)

      assert Map.has_key?(reg.placeholders, p.id)
    end

    test "indexes by producer position" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)

      reg = PlaceholderRegistry.register(reg, p)

      assert PlaceholderRegistry.ids_at_position(reg, Position.prefix(0)) == [p.id]
    end

    test "collects multiple placeholders at the same position in order" do
      reg = PlaceholderRegistry.new()
      p1 = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)
      p2 = Placeholder.new_at(TestEvent, [:other], Position.prefix(0), 0)

      reg = reg |> PlaceholderRegistry.register(p1) |> PlaceholderRegistry.register(p2)

      assert PlaceholderRegistry.ids_at_position(reg, Position.prefix(0)) == [p1.id, p2.id]
    end

    test "can register multiple placeholders at distinct positions" do
      reg = PlaceholderRegistry.new()
      p1 = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)
      p2 = Placeholder.new_at(OtherEvent, [:ref], Position.branch(1, 0), 0)

      reg = reg |> PlaceholderRegistry.register(p1) |> PlaceholderRegistry.register(p2)

      assert map_size(reg.placeholders) == 2
      assert PlaceholderRegistry.ids_at_position(reg, Position.prefix(0)) == [p1.id]
      assert PlaceholderRegistry.ids_at_position(reg, Position.branch(1, 0)) == [p2.id]
    end
  end

  describe "ids_at_position/2" do
    test "returns [] for a position with no producers" do
      assert PlaceholderRegistry.ids_at_position(PlaceholderRegistry.new(), Position.prefix(9)) ==
               []
    end
  end

  describe "get/2" do
    test "returns placeholder by ID" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)
      reg = PlaceholderRegistry.register(reg, p)

      assert PlaceholderRegistry.get(reg, p.id) == p
    end

    test "returns nil for unknown ID" do
      assert PlaceholderRegistry.get(PlaceholderRegistry.new(), make_ref()) == nil
    end
  end

  describe "resolve/3 (by id)" do
    test "resolves a placeholder by its id" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)
      reg = PlaceholderRegistry.register(reg, p)

      reg = PlaceholderRegistry.resolve(reg, p.id, "order_123")

      assert PlaceholderRegistry.get(reg, p.id).resolved == "order_123"
    end

    test "returns the registry unchanged for an unknown id" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)
      reg = PlaceholderRegistry.register(reg, p)

      reg2 = PlaceholderRegistry.resolve(reg, make_ref(), "value")

      assert PlaceholderRegistry.get(reg2, p.id).resolved == nil
    end

    test "resolves only the targeted placeholder when several exist" do
      reg = PlaceholderRegistry.new()
      p1 = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)
      p2 = Placeholder.new_at(TestEvent, [:id], Position.prefix(1), 0)

      reg =
        reg
        |> PlaceholderRegistry.register(p1)
        |> PlaceholderRegistry.register(p2)
        |> PlaceholderRegistry.resolve(p2.id, "order_456")

      assert PlaceholderRegistry.get(reg, p1.id).resolved == nil
      assert PlaceholderRegistry.get(reg, p2.id).resolved == "order_456"
    end
  end

  describe "deep_resolve/2" do
    setup do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)

      reg =
        reg |> PlaceholderRegistry.register(p) |> PlaceholderRegistry.resolve(p.id, "order_123")

      {:ok, reg: reg, p: p}
    end

    test "resolves single placeholder", %{reg: reg, p: p} do
      assert PlaceholderRegistry.deep_resolve(reg, p) == "order_123"
    end

    test "resolves placeholder in map", %{reg: reg, p: p} do
      assert PlaceholderRegistry.deep_resolve(reg, %{id: p, name: "test"}) ==
               %{id: "order_123", name: "test"}
    end

    test "resolves placeholder in list", %{reg: reg, p: p} do
      assert PlaceholderRegistry.deep_resolve(reg, [p, "other"]) == ["order_123", "other"]
    end

    test "resolves placeholder in tuple", %{reg: reg, p: p} do
      assert PlaceholderRegistry.deep_resolve(reg, {:ok, p}) == {:ok, "order_123"}
    end

    test "resolves placeholder in struct", %{reg: reg, p: p} do
      result = PlaceholderRegistry.deep_resolve(reg, %TestEvent{id: p, amount: 100})

      assert %TestEvent{id: "order_123", amount: 100} = result
    end

    test "resolves deeply nested placeholder", %{reg: reg, p: p} do
      assert PlaceholderRegistry.deep_resolve(reg, %{outer: %{inner: [p]}}) ==
               %{outer: %{inner: ["order_123"]}}
    end

    test "resolves placeholder used as a map key", %{reg: reg, p: p} do
      assert PlaceholderRegistry.deep_resolve(reg, %{p => "value"}) == %{"order_123" => "value"}
    end

    test "resolves multiple placeholders" do
      reg = PlaceholderRegistry.new()
      p1 = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)
      p2 = Placeholder.new_at(OtherEvent, [:ref], Position.prefix(1), 0)

      reg =
        reg
        |> PlaceholderRegistry.register(p1)
        |> PlaceholderRegistry.register(p2)
        |> PlaceholderRegistry.resolve(p1.id, "order_123")
        |> PlaceholderRegistry.resolve(p2.id, "ref_456")

      assert PlaceholderRegistry.deep_resolve(reg, %{order_id: p1, other_ref: p2}) ==
               %{order_id: "order_123", other_ref: "ref_456"}
    end

    test "raises for an unresolved placeholder" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)
      reg = PlaceholderRegistry.register(reg, p)

      assert_raise ArgumentError, ~r/Unresolved placeholder/, fn ->
        PlaceholderRegistry.deep_resolve(reg, p)
      end
    end

    test "unresolved error includes path, position, event" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new_at(TestEvent, [:ids, :order], Position.prefix(5), 3)
      reg = PlaceholderRegistry.register(reg, p)

      assert_raise ArgumentError, ~r/\[:ids, :order\]/, fn ->
        PlaceholderRegistry.deep_resolve(reg, p)
      end

      assert_raise ArgumentError, ~r/position .*section: :prefix, offset: 5/, fn ->
        PlaceholderRegistry.deep_resolve(reg, p)
      end

      assert_raise ArgumentError, ~r/event 3/, fn ->
        PlaceholderRegistry.deep_resolve(reg, p)
      end
    end

    test "raises for an unknown placeholder ID" do
      reg = PlaceholderRegistry.new()
      p = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)

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
    setup do
      {:ok, p: Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)}
    end

    test("true for a Placeholder struct", %{p: p},
      do: assert(PlaceholderRegistry.contains_placeholder?(p))
    )

    test "true for a map containing one", %{p: p} do
      assert PlaceholderRegistry.contains_placeholder?(%{id: p})
    end

    test "true when nested", %{p: p} do
      assert PlaceholderRegistry.contains_placeholder?(%{outer: %{inner: p}})
    end

    test("true in a list", %{p: p},
      do: assert(PlaceholderRegistry.contains_placeholder?([p, "other"]))
    )

    test("true in a tuple", %{p: p},
      do: assert(PlaceholderRegistry.contains_placeholder?({:ok, p}))
    )

    test "true in a struct", %{p: p} do
      assert PlaceholderRegistry.contains_placeholder?(%TestEvent{id: p, amount: 100})
    end

    test "false without a placeholder" do
      refute PlaceholderRegistry.contains_placeholder?(%{id: "123"})
      refute PlaceholderRegistry.contains_placeholder?(nil)
      refute PlaceholderRegistry.contains_placeholder?("string")
      refute PlaceholderRegistry.contains_placeholder?(123)
    end
  end

  describe "collect_placeholder_ids/1" do
    test "collects ID from a single placeholder" do
      p = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)

      assert PlaceholderRegistry.collect_placeholder_ids(p) == [p.id]
    end

    test "collects IDs from nested structures and deduplicates" do
      p1 = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)
      p2 = Placeholder.new_at(OtherEvent, [:ref], Position.prefix(1), 0)

      ids = PlaceholderRegistry.collect_placeholder_ids(%{a: [p1, p2], b: %{c: p1}})

      assert Enum.sort(ids) == Enum.sort([p1.id, p2.id])
    end

    test "returns [] for non-placeholder data" do
      assert PlaceholderRegistry.collect_placeholder_ids(%{id: "123"}) == []
      assert PlaceholderRegistry.collect_placeholder_ids("string") == []
    end
  end

  describe "collect_placeholders/1" do
    test "returns the placeholder structs, deduplicated by id" do
      p1 = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)
      p2 = Placeholder.new_at(OtherEvent, [:ref], Position.prefix(1), 0)

      collected = PlaceholderRegistry.collect_placeholders(%{a: p1, b: [p2, p1]})

      assert Enum.sort_by(collected, & &1.id) == Enum.sort_by([p1, p2], & &1.id)
    end
  end

  describe "all / resolved / unresolved" do
    setup do
      reg = PlaceholderRegistry.new()
      p1 = Placeholder.new_at(TestEvent, [:id], Position.prefix(0), 0)
      p2 = Placeholder.new_at(OtherEvent, [:ref], Position.prefix(1), 0)

      reg =
        reg
        |> PlaceholderRegistry.register(p1)
        |> PlaceholderRegistry.register(p2)
        |> PlaceholderRegistry.resolve(p1.id, "value")

      {:ok, reg: reg, p1: p1, p2: p2}
    end

    test "all/1 returns every placeholder", %{reg: reg, p1: p1, p2: p2} do
      all = PlaceholderRegistry.all(reg)
      assert length(all) == 2
      assert Enum.map(all, & &1.id) |> Enum.sort() == Enum.sort([p1.id, p2.id])
    end

    test "resolved/1 returns only resolved", %{reg: reg, p1: p1} do
      assert [only] = PlaceholderRegistry.resolved(reg)
      assert only.id == p1.id
    end

    test "unresolved/1 returns only unresolved", %{reg: reg, p2: p2} do
      assert [only] = PlaceholderRegistry.unresolved(reg)
      assert only.id == p2.id
    end
  end
end
