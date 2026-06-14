defmodule PropertyDamage.PlaceholderTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Placeholder

  defmodule TestEvent do
    defstruct [:id, :amount]
  end

  describe "new_at/4" do
    test "creates a placeholder with unique ID" do
      p = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)

      assert %Placeholder{} = p
      assert is_reference(p.id)
    end

    test "each call creates distinct placeholder" do
      p1 = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)
      p2 = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)

      assert p1.id != p2.id
    end

    test "stores event module" do
      p = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)

      assert p.event_module == TestEvent
    end

    test "stores path" do
      p = Placeholder.new_at(TestEvent, [:ids, :order], {:prefix, 0}, 0)

      assert p.path == [:ids, :order]
    end

    test "stores structured position" do
      assert Placeholder.new_at(TestEvent, [:id], {:prefix, 5}, 0).position == {:prefix, 5}
      assert Placeholder.new_at(TestEvent, [:id], {:branch, 1, 2}, 0).position == {:branch, 1, 2}
      assert Placeholder.new_at(TestEvent, [:id], {:suffix, 3}, 0).position == {:suffix, 3}
    end

    test "stores event index" do
      p = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 3)

      assert p.event_index == 3
    end

    test "is unresolved by default" do
      p = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)

      assert p.resolved == nil
    end

    test "supports list indices in path" do
      p = Placeholder.new_at(TestEvent, [:items, 0], {:prefix, 0}, 0)

      assert p.path == [:items, 0]
    end
  end

  describe "resolve/2" do
    test "sets the resolved value" do
      p = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)
      resolved = Placeholder.resolve(p, "order_123")

      assert resolved.resolved == "order_123"
    end

    test "preserves ID" do
      p = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)
      resolved = Placeholder.resolve(p, "order_123")

      assert resolved.id == p.id
    end

    test "preserves path and position" do
      p = Placeholder.new_at(TestEvent, [:ids, :order], {:prefix, 5}, 3)
      resolved = Placeholder.resolve(p, "order_123")

      assert resolved.path == [:ids, :order]
      assert resolved.position == {:prefix, 5}
      assert resolved.event_index == 3
    end

    test "can resolve to any value type" do
      p = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)

      assert Placeholder.resolve(p, 42).resolved == 42
      assert Placeholder.resolve(p, "hello").resolved == "hello"
      assert Placeholder.resolve(p, %{id: 1}).resolved == %{id: 1}
      assert Placeholder.resolve(p, [1, 2, 3]).resolved == [1, 2, 3]
      assert Placeholder.resolve(p, nil).resolved == nil
      assert Placeholder.resolve(p, false).resolved == false
    end
  end

  describe "resolved?/1" do
    test "returns false for new placeholder" do
      p = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)

      refute Placeholder.resolved?(p)
    end

    test "returns true after resolution" do
      p =
        Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)
        |> Placeholder.resolve("order_123")

      assert Placeholder.resolved?(p)
    end

    test "treats resolution to nil as unresolved (matches Ref behavior)" do
      p =
        Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)
        |> Placeholder.resolve(nil)

      refute Placeholder.resolved?(p)
    end

    test "returns true when resolved to false" do
      p =
        Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)
        |> Placeholder.resolve(false)

      assert Placeholder.resolved?(p)
    end
  end

  describe "placeholder?/1" do
    test "returns true for Placeholder struct" do
      p = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)

      assert Placeholder.placeholder?(p)
    end

    test "returns false for other values" do
      refute Placeholder.placeholder?(nil)
      refute Placeholder.placeholder?("string")
      refute Placeholder.placeholder?(123)
      refute Placeholder.placeholder?(%{})
      refute Placeholder.placeholder?([])
    end
  end

  describe "value!/1" do
    test "raises on unresolved placeholder" do
      p = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)

      assert_raise ArgumentError, ~r/Placeholder not yet resolved/, fn ->
        Placeholder.value!(p)
      end
    end

    test "error message includes path, position, event_index" do
      p = Placeholder.new_at(TestEvent, [:ids, :order], {:prefix, 5}, 3)

      assert_raise ArgumentError, ~r/path=\[:ids, :order\]/, fn -> Placeholder.value!(p) end
      assert_raise ArgumentError, ~r/position=\{:prefix, 5\}/, fn -> Placeholder.value!(p) end
      assert_raise ArgumentError, ~r/event_index=3/, fn -> Placeholder.value!(p) end
    end

    test "returns value on resolved placeholder" do
      p =
        Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)
        |> Placeholder.resolve("order_123")

      assert Placeholder.value!(p) == "order_123"
    end

    test "returns false when resolved to false" do
      p =
        Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)
        |> Placeholder.resolve(false)

      assert Placeholder.value!(p) == false
    end
  end

  describe "Inspect protocol" do
    test "renders unresolved placeholder with its position" do
      p = Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)
      inspected = inspect(p)

      assert inspected =~ "<Placeholder:"
      assert inspected =~ "id@pre0/evt0>"
    end

    test "renders resolved placeholder" do
      p =
        Placeholder.new_at(TestEvent, [:id], {:prefix, 0}, 0)
        |> Placeholder.resolve("order_123")

      inspected = inspect(p)

      assert inspected =~ "id@pre0/evt0"
      assert inspected =~ "-> \"order_123\">"
    end

    test "renders branch and suffix positions" do
      assert inspect(Placeholder.new_at(TestEvent, [:id], {:branch, 1, 2}, 0)) =~ "id@br1.2/evt0>"
      assert inspect(Placeholder.new_at(TestEvent, [:id], {:suffix, 3}, 1)) =~ "id@suf3/evt1>"
    end

    test "renders nested and list-index paths" do
      assert inspect(Placeholder.new_at(TestEvent, [:ids, :order], {:prefix, 2}, 1)) =~
               "ids.order@pre2/evt1>"

      assert inspect(Placeholder.new_at(TestEvent, [:items, 0], {:prefix, 0}, 0)) =~
               "items.0@pre0/evt0>"
    end
  end
end
