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

  # Test modules for custom markers
  defmodule AtomMarkerEvent do
    defstruct [:amount, id: :__external__, created_at: :__external__]
  end

  defmodule NestedAtomMarkerEvent do
    defstruct [:name, ids: %{order: :__external__, confirm: :__external__}]
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

    test "returns false for atom markers without config" do
      # Without app config, atom markers are not recognized
      refute External.external?(:__external__)
      refute External.external?(:server_generated)
    end
  end

  describe "external?/2 with explicit markers" do
    test "returns true for External struct regardless of markers" do
      assert External.external?(%External{}, [])
      assert External.external?(%External{}, [:other])
    end

    test "returns true for atom in markers list" do
      assert External.external?(:__external__, [:__external__])
      assert External.external?(:server_generated, [:server_generated, :other])
    end

    test "returns false for atom not in markers list" do
      refute External.external?(:__external__, [:other_marker])
      refute External.external?(:random_atom, [])
    end

    test "returns false for nil even with markers" do
      refute External.external?(nil, [:__external__])
    end

    test "returns false for non-atoms even with markers" do
      refute External.external?("__external__", [:__external__])
      refute External.external?(123, [:__external__])
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

  describe "external_paths/2 with explicit markers" do
    test "finds atom marker fields with explicit markers" do
      paths = External.external_paths(AtomMarkerEvent, [:__external__])

      assert [:id] in paths
      assert [:created_at] in paths
      assert length(paths) == 2
    end

    test "finds nested atom marker fields" do
      paths = External.external_paths(NestedAtomMarkerEvent, [:__external__])

      assert [:ids, :order] in paths
      assert [:ids, :confirm] in paths
      assert length(paths) == 2
    end

    test "returns empty for atom markers without explicit list" do
      paths = External.external_paths(AtomMarkerEvent, [])
      assert paths == []
    end

    test "combines explicit markers with External struct detection" do
      # Still finds External{} structs even when looking for atom markers
      paths = External.external_paths(SimpleEvent, [:__external__])

      assert [:id] in paths
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

  describe "contains_external?/2 with explicit markers" do
    test "returns true for atom marker in data" do
      assert External.contains_external?(%{id: :__external__}, [:__external__])
    end

    test "returns true for nested atom marker" do
      data = %{outer: %{inner: :__external__}}
      assert External.contains_external?(data, [:__external__])
    end

    test "returns false for atom marker not in list" do
      refute External.contains_external?(%{id: :__external__}, [:other])
    end

    test "still finds External struct with empty markers" do
      assert External.contains_external?(%{id: %External{}}, [])
    end

    test "handles mixed External struct and atom markers" do
      data = %{id: %External{}, ref: :__external__}
      assert External.contains_external?(data, [:__external__])
    end
  end

  describe "Inspect protocol" do
    test "renders as external()" do
      ext = External.external()
      assert inspect(ext) == "external()"
    end
  end

  describe "ExternalMarker protocol" do
    test "External struct implements protocol" do
      assert PropertyDamage.ExternalMarker.external?(%External{})
    end

    test "regular values return false via Any implementation" do
      refute PropertyDamage.ExternalMarker.external?("string")
      refute PropertyDamage.ExternalMarker.external?(123)
      refute PropertyDamage.ExternalMarker.external?(%{})
    end
  end

  # NOTE: Protocol implementations cannot be tested dynamically because
  # protocols are consolidated at compile time. The ExternalMarker protocol
  # implementation for custom types should be tested in integration tests
  # or in projects that define the protocol implementation at compile time.
  #
  # See the guide "Contract Testing with Shared Libraries" for examples
  # of how to properly implement the protocol in a separate module.
end
