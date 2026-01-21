defmodule PropertyDamage.ExternalTest do
  use ExUnit.Case, async: true
  doctest PropertyDamage.External

  alias PropertyDamage.External

  # Test modules for external_paths testing
  defmodule SimpleEvent do
    import PropertyDamage, only: [external: 0]
    defstruct [:amount, :name, id: external()]
  end

  defmodule MultiExternalEvent do
    import PropertyDamage, only: [external: 0]
    defstruct [:amount, order_id: external(), transaction_ref: external()]
  end

  defmodule NestedExternalEvent do
    import PropertyDamage, only: [external: 0]
    defstruct [:amount, ids: %{order: external(), confirmation: external()}]
  end

  defmodule ListExternalEvent do
    import PropertyDamage, only: [external: 0]
    defstruct [:batch_name, item_ids: [external(), external(), external()]]
  end

  defmodule NoExternalEvent do
    defstruct [:id, :name, :amount]
  end

  defmodule DeeplyNestedEvent do
    import PropertyDamage, only: [external: 0]

    defstruct [
      :name,
      data: %{
        nested: %{
          deep: external()
        }
      }
    ]
  end

  describe "external/0" do
    test "returns an External struct" do
      assert %External{} = External.external()
    end

    test "each call returns equivalent struct" do
      ext1 = External.external()
      ext2 = External.external()

      assert ext1 == ext2
    end
  end

  describe "external?/1" do
    test "returns true for External struct" do
      assert External.external?(%External{})
    end

    test "returns true for external() result" do
      assert External.external?(External.external())
    end

    test "returns false for other values" do
      refute External.external?(nil)
      refute External.external?("string")
      refute External.external?(123)
      refute External.external?(%{})
      refute External.external?([])
      refute External.external?({:tuple})
    end
  end

  describe "external_paths/1" do
    test "finds simple external field" do
      paths = External.external_paths(SimpleEvent)

      assert [:id] in paths
      assert length(paths) == 1
    end

    test "finds multiple external fields" do
      paths = External.external_paths(MultiExternalEvent)

      assert [:order_id] in paths
      assert [:transaction_ref] in paths
      assert length(paths) == 2
    end

    test "finds nested external fields in maps" do
      paths = External.external_paths(NestedExternalEvent)

      assert [:ids, :order] in paths
      assert [:ids, :confirmation] in paths
      assert length(paths) == 2
    end

    test "finds external fields in lists with indices" do
      paths = External.external_paths(ListExternalEvent)

      assert [:item_ids, 0] in paths
      assert [:item_ids, 1] in paths
      assert [:item_ids, 2] in paths
      assert length(paths) == 3
    end

    test "returns empty list for event with no externals" do
      paths = External.external_paths(NoExternalEvent)

      assert paths == []
    end

    test "finds deeply nested external fields" do
      paths = External.external_paths(DeeplyNestedEvent)

      assert [:data, :nested, :deep] in paths
      assert length(paths) == 1
    end
  end

  describe "get_at_path/2" do
    test "gets value at simple path" do
      data = %{id: "123", name: "test"}

      assert External.get_at_path(data, [:id]) == "123"
      assert External.get_at_path(data, [:name]) == "test"
    end

    test "gets value at nested path" do
      data = %{ids: %{order: "ord_123", confirmation: "conf_456"}}

      assert External.get_at_path(data, [:ids, :order]) == "ord_123"
      assert External.get_at_path(data, [:ids, :confirmation]) == "conf_456"
    end

    test "gets value at list index path" do
      data = %{items: ["a", "b", "c"]}

      assert External.get_at_path(data, [:items, 0]) == "a"
      assert External.get_at_path(data, [:items, 1]) == "b"
      assert External.get_at_path(data, [:items, 2]) == "c"
    end

    test "gets value with mixed map and list path" do
      data = %{orders: [%{id: "ord_1"}, %{id: "ord_2"}]}

      assert External.get_at_path(data, [:orders, 0, :id]) == "ord_1"
      assert External.get_at_path(data, [:orders, 1, :id]) == "ord_2"
    end

    test "returns data for empty path" do
      data = %{id: "123"}

      assert External.get_at_path(data, []) == data
    end

    test "returns nil for invalid path" do
      data = %{id: "123"}

      assert External.get_at_path(data, [:nonexistent]) == nil
      assert External.get_at_path(data, [:id, :nested]) == nil
    end

    test "works with structs" do
      event = %SimpleEvent{id: "123", amount: 100, name: "test"}

      assert External.get_at_path(event, [:id]) == "123"
      assert External.get_at_path(event, [:amount]) == 100
    end
  end

  describe "put_at_path/3" do
    test "puts value at simple path" do
      data = %{id: nil, name: "test"}
      result = External.put_at_path(data, [:id], "123")

      assert result == %{id: "123", name: "test"}
    end

    test "puts value at nested path" do
      data = %{ids: %{order: nil}}
      result = External.put_at_path(data, [:ids, :order], "ord_123")

      assert result == %{ids: %{order: "ord_123"}}
    end

    test "puts value at list index path" do
      data = %{items: [nil, nil, nil]}

      result = External.put_at_path(data, [:items, 0], "a")
      assert result == %{items: ["a", nil, nil]}

      result = External.put_at_path(data, [:items, 1], "b")
      assert result == %{items: [nil, "b", nil]}
    end

    test "replaces value for empty path" do
      data = %{id: "old"}
      result = External.put_at_path(data, [], "new")

      assert result == "new"
    end

    test "creates intermediate maps for nested paths" do
      data = %{}
      result = External.put_at_path(data, [:a, :b], "value")

      assert result == %{a: %{b: "value"}}
    end

    test "works with structs" do
      event = struct!(SimpleEvent, id: nil, amount: 100, name: "test")
      result = External.put_at_path(event, [:id], "123")

      assert result.id == "123"
      assert result.amount == 100
    end
  end

  describe "contains_external?/1" do
    test "returns true for External struct" do
      assert External.contains_external?(%External{})
    end

    test "returns true for map containing external" do
      assert External.contains_external?(%{id: %External{}})
    end

    test "returns true for nested map containing external" do
      assert External.contains_external?(%{outer: %{inner: %External{}}})
    end

    test "returns true for list containing external" do
      assert External.contains_external?([%External{}, "other"])
    end

    test "returns true for tuple containing external" do
      assert External.contains_external?({:ok, %External{}})
    end

    test "returns true for struct containing external" do
      event = struct!(SimpleEvent, id: %External{}, amount: 100, name: "test")
      assert External.contains_external?(event)
    end

    test "returns false for map without external" do
      refute External.contains_external?(%{id: "123", name: "test"})
    end

    test "returns false for list without external" do
      refute External.contains_external?(["a", "b", "c"])
    end

    test "returns false for simple values" do
      refute External.contains_external?(nil)
      refute External.contains_external?("string")
      refute External.contains_external?(123)
      refute External.contains_external?(:atom)
    end
  end

  describe "Inspect protocol" do
    test "renders as external()" do
      ext = External.external()
      assert inspect(ext) == "external()"
    end
  end
end
