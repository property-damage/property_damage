defmodule PropertyDamage.PlaceholderAccessorsTest do
  # A placeholder is read through the functions of `PropertyDamage.Placeholder`,
  # never through its fields.
  use ExUnit.Case, async: true

  alias PropertyDamage.{External, Placeholder}
  alias PropertyDamage.Sequence.Position

  defmodule Event do
    defstruct [:id]
  end

  @position Position.setup(2)

  defp fresh, do: Placeholder.new_at(Event, [:ids, :order], @position, 3)

  defp nil_resolved, do: Placeholder.resolve(fresh(), nil)

  defp value_resolved, do: Placeholder.resolve(fresh(), "order_1")

  defp build(:fresh), do: fresh()
  defp build(:nil_resolved), do: nil_resolved()
  defp build(:value_resolved), do: value_resolved()

  describe "the identity accessors" do
    for label <- [:fresh, :nil_resolved, :value_resolved] do
      test "read the coordinates of a #{label} placeholder" do
        placeholder = build(unquote(label))

        assert Placeholder.position(placeholder) == @position
        assert Placeholder.path(placeholder) == [:ids, :order]
        assert Placeholder.event_module(placeholder) == Event
        assert Placeholder.event_index(placeholder) == 3
      end

      test "id/1 of a #{label} placeholder equals the id of a fresh one" do
        assert Placeholder.id(build(unquote(label))) == Placeholder.id(fresh())
      end
    end

    test "id/1 differs between placeholders of different coordinates" do
      other = Placeholder.new_at(Event, [:ids, :order], Position.setup(3), 3)

      refute Placeholder.id(fresh()) == Placeholder.id(other)
    end

    test "id/1 names the position the id_position/1 function reads back" do
      assert Placeholder.id_position(Placeholder.id(fresh())) == @position
    end
  end

  describe "resolved?/1" do
    test "is false for a fresh placeholder" do
      refute Placeholder.resolved?(fresh())
    end

    test "is true for a placeholder resolved to a value" do
      assert Placeholder.resolved?(value_resolved())
    end

    test "is true for a placeholder resolved to nil" do
      assert Placeholder.resolved?(nil_resolved())
    end
  end

  describe "value/1" do
    test "is :error for a fresh placeholder" do
      assert Placeholder.value(fresh()) == :error
    end

    test "is {:ok, nil} for a placeholder resolved to nil" do
      assert Placeholder.value(nil_resolved()) == {:ok, nil}
    end

    test "is {:ok, value} for a placeholder resolved to a value" do
      assert Placeholder.value(value_resolved()) == {:ok, "order_1"}
    end

    test "is {:ok, false} for a placeholder resolved to false" do
      assert Placeholder.value(Placeholder.resolve(fresh(), false)) == {:ok, false}
    end
  end

  describe "value!/1" do
    test "returns the value of a placeholder resolved to a value" do
      assert Placeholder.value!(value_resolved()) == "order_1"
    end

    test "returns nil for a placeholder resolved to nil" do
      assert Placeholder.value!(nil_resolved()) == nil
    end

    test "raises for a fresh placeholder" do
      assert_raise ArgumentError, ~r/not yet resolved/, fn -> Placeholder.value!(fresh()) end
    end
  end

  describe "resolve/2" do
    test "resolving the same placeholder to the same value gives equal placeholders" do
      assert value_resolved() == Placeholder.resolve(fresh(), "order_1")
    end

    test "a placeholder resolved to nil differs from the fresh one" do
      refute nil_resolved() == fresh()
    end

    test "a placeholder resolved to a value differs from the fresh one" do
      refute value_resolved() == fresh()
    end

    test "resolving again replaces the value" do
      again = Placeholder.resolve(value_resolved(), "order_2")

      assert Placeholder.value!(again) == "order_2"
    end
  end

  describe "External.fetch_at_path/2" do
    test "returns {:ok, value} for a present value" do
      assert External.fetch_at_path(%{ids: %{order: "o1"}}, [:ids, :order]) == {:ok, "o1"}
    end

    test "returns {:ok, nil} for a present nil" do
      assert External.fetch_at_path(%{ids: %{order: nil}}, [:ids, :order]) == {:ok, nil}
    end

    test "returns :error for a missing key" do
      assert External.fetch_at_path(%{ids: %{}}, [:ids, :order]) == :error
      assert External.fetch_at_path(%{}, [:ids, :order]) == :error
    end

    test "returns :error through a non-container" do
      assert External.fetch_at_path(%{ids: nil}, [:ids, :order]) == :error
      assert External.fetch_at_path(%{ids: "text"}, [:ids, :order]) == :error
    end

    test "reads a list index" do
      assert External.fetch_at_path(%{items: ["a", "b"]}, [:items, 1]) == {:ok, "b"}
      assert External.fetch_at_path(%{items: [nil]}, [:items, 0]) == {:ok, nil}
    end
  end

  describe "External.get_at_path/2" do
    test "stays nil for a missing key and for a present nil" do
      assert External.get_at_path(%{ids: %{}}, [:ids, :order]) == nil
      assert External.get_at_path(%{ids: %{order: nil}}, [:ids, :order]) == nil
      assert External.get_at_path(%{ids: nil}, [:ids, :order]) == nil
    end

    test "reads a present value and a list index" do
      assert External.get_at_path(%{ids: %{order: "o1"}}, [:ids, :order]) == "o1"
      assert External.get_at_path(%{items: ["a", "b"]}, [:items, 1]) == "b"
    end
  end
end
