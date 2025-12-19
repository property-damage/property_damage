defmodule PropertyDamage.RefTest do
  use ExUnit.Case, async: true
  doctest PropertyDamage.Ref

  alias PropertyDamage.Ref
  alias PropertyDamage.Ref.Unresolved

  describe "symbolic/0" do
    test "creates a ref with unique identity via make_ref/0" do
      ref = Ref.symbolic()

      assert %Ref{ref: ref_identity} = ref
      assert is_reference(ref_identity)
    end

    test "each call creates a distinct ref" do
      ref1 = Ref.symbolic()
      ref2 = Ref.symbolic()

      assert ref1.ref != ref2.ref
    end

    test "creates unresolved ref by default" do
      ref = Ref.symbolic()

      assert ref.resolved == Unresolved
    end

    test "has nil label by default" do
      ref = Ref.symbolic()

      assert ref.label == nil
    end
  end

  describe "symbolic/1 with label option" do
    test "sets label from option" do
      ref = Ref.symbolic(label: "order")

      assert ref.label == "order"
    end

    test "label does not affect ref identity" do
      ref1 = Ref.symbolic(label: "order")
      ref2 = Ref.symbolic(label: "order")

      # Same label but different refs
      assert ref1.label == ref2.label
      assert ref1.ref != ref2.ref
    end
  end

  describe "resolved?/1" do
    test "returns false for new refs" do
      ref = Ref.symbolic()

      refute Ref.resolved?(ref)
    end

    test "returns true after resolution" do
      ref =
        Ref.symbolic()
        |> Ref.resolve("concrete_value")

      assert Ref.resolved?(ref)
    end

    test "returns true even when resolved to nil" do
      ref =
        Ref.symbolic()
        |> Ref.resolve(nil)

      assert Ref.resolved?(ref)
    end

    test "returns true even when resolved to false" do
      ref =
        Ref.symbolic()
        |> Ref.resolve(false)

      assert Ref.resolved?(ref)
    end
  end

  describe "resolve/2" do
    test "sets the resolved value" do
      ref = Ref.symbolic()
      resolved = Ref.resolve(ref, "ord_123")

      assert resolved.resolved == "ord_123"
    end

    test "preserves ref identity" do
      ref = Ref.symbolic()
      resolved = Ref.resolve(ref, "ord_123")

      assert resolved.ref == ref.ref
    end

    test "preserves label" do
      ref = Ref.symbolic(label: "order")
      resolved = Ref.resolve(ref, "ord_123")

      assert resolved.label == "order"
    end

    test "can resolve to any value type" do
      ref = Ref.symbolic()

      # Integer
      assert Ref.resolve(ref, 42).resolved == 42

      # String
      assert Ref.resolve(ref, "hello").resolved == "hello"

      # Map
      assert Ref.resolve(ref, %{id: 1}).resolved == %{id: 1}

      # List
      assert Ref.resolve(ref, [1, 2, 3]).resolved == [1, 2, 3]

      # Tuple
      assert Ref.resolve(ref, {:ok, "result"}).resolved == {:ok, "result"}
    end
  end

  describe "value!/1" do
    test "raises on unresolved ref" do
      ref = Ref.symbolic()

      assert_raise RuntimeError, "Ref not yet resolved", fn ->
        Ref.value!(ref)
      end
    end

    test "returns value on resolved ref" do
      ref =
        Ref.symbolic()
        |> Ref.resolve("ord_abc123")

      assert Ref.value!(ref) == "ord_abc123"
    end

    test "returns nil when resolved to nil" do
      ref =
        Ref.symbolic()
        |> Ref.resolve(nil)

      assert Ref.value!(ref) == nil
    end

    test "returns false when resolved to false" do
      ref =
        Ref.symbolic()
        |> Ref.resolve(false)

      assert Ref.value!(ref) == false
    end
  end

  describe "two refs with same label" do
    test "are distinct (different ref identities)" do
      ref1 = Ref.symbolic(label: "item")
      ref2 = Ref.symbolic(label: "item")

      assert ref1.label == ref2.label
      assert ref1.ref != ref2.ref
      refute ref1 == ref2
    end
  end

  describe "Inspect protocol" do
    test "renders unresolved ref without label" do
      ref = Ref.symbolic()
      inspected = inspect(ref)

      assert inspected =~ ~r/^<Ref:\d+>$/
    end

    test "renders unresolved ref with label" do
      ref = Ref.symbolic(label: "order")
      inspected = inspect(ref)

      assert inspected =~ ~r/^<Ref:order:\d+>$/
    end

    test "renders resolved ref without label" do
      ref =
        Ref.symbolic()
        |> Ref.resolve("ord_123")

      inspected = inspect(ref)

      assert inspected =~ ~r/^<Ref:\d+ -> "ord_123">$/
    end

    test "renders resolved ref with label" do
      ref =
        Ref.symbolic(label: "order")
        |> Ref.resolve("ord_123")

      inspected = inspect(ref)

      assert inspected =~ ~r/^<Ref:order:\d+ -> "ord_123">$/
    end

    test "renders complex resolved values" do
      ref =
        Ref.symbolic(label: "data")
        |> Ref.resolve(%{id: 1, name: "test"})

      inspected = inspect(ref)

      assert inspected =~ "<Ref:data:"
      assert inspected =~ "%{id: 1, name: \"test\"}"
    end
  end
end
