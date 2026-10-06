defmodule PropertyDamage.EquivalenceTest do
  # `PropertyDamage.Equivalence` builds `using:` predicates: `by_key/1` lifts a
  # key function into a predicate, `normalize/1` and `drop_keys/2` transform
  # values. `PropertyDamage.ComparisonMismatch` is the default mismatch detail.
  use ExUnit.Case, async: true

  alias PropertyDamage.Test.Compare

  defmodule Event do
    @moduledoc false
    defstruct [:value, :id, :fees, :inserted_at]
  end

  # Resolved at runtime, so this file compiles before the module exists.
  defp equivalence, do: Module.concat(PropertyDamage, Equivalence)

  defp by_key(fun), do: equivalence().by_key(fun)
  defp normalize(value), do: equivalence().normalize(value)
  defp drop_keys(value, keys), do: equivalence().drop_keys(value, keys)

  defp mismatch(fields), do: struct(Compare.mismatch_module(), fields)

  describe "by_key/1" do
    test "is a 2-arity predicate that agrees when the keys are equal" do
      predicate = by_key(&Map.take(&1, [:net]))
      assert is_function(predicate, 2)
      assert predicate.(%{net: 1, fees: 2}, %{net: 1, fees: 3}) in [:match, true]
    end

    test "returns a mismatch holding the two keys, reference first" do
      predicate = by_key(&Map.take(&1, [:net]))

      assert {:mismatch, detail} = predicate.(%{net: 1, fees: 2}, %{net: 4, fees: 2})
      assert Compare.mismatch?(detail)
      assert detail.left == %{net: 1}
      assert detail.right == %{net: 4}
    end

    test "composes with normalize/1 and drop_keys/2 inside a closure" do
      predicate = by_key(fn v -> v |> normalize() |> drop_keys([:fees]) end)

      assert predicate.({:ok, %{net: 5, fees: 1, id: "a"}}, {:ok, %{net: 5, fees: 2, id: "b"}}) in [
               :match,
               true
             ]

      assert {:mismatch, detail} = predicate.(%{net: 5, id: "a"}, %{net: 6, id: "b"})
      assert {detail.left, detail.right} == {%{net: 5}, %{net: 6}}
    end
  end

  describe "normalize/1" do
    test "strips the identifier and timestamp keys" do
      noisy = %{
        value: 1,
        id: 1,
        inserted_at: 2,
        updated_at: 3,
        created_at: 4,
        timestamp: 5,
        uuid: 6,
        request_id: 7,
        correlation_id: 8
      }

      assert normalize(noisy) == %{value: 1}
    end

    test "unwraps {:ok, _} and {:error, _}" do
      assert normalize({:ok, %{value: 1, id: 9}}) == %{value: 1}
      assert normalize({:error, %{reason: :busy, request_id: "r"}}) == %{reason: :busy}
    end

    test "reaches into lists, tuples, nested maps and structs" do
      a = [
        %Event{value: 1, id: "a", inserted_at: 1},
        {%{id: 1, n: 2}},
        %{inner: %{uuid: "x", k: 1}}
      ]

      b = [
        %Event{value: 1, id: "b", inserted_at: 2},
        {%{id: 2, n: 2}},
        %{inner: %{uuid: "y", k: 1}}
      ]

      assert normalize(a) == normalize(b)
      assert [_event, {%{n: 2} = tuple_map}, %{inner: inner}] = normalize(a)
      refute Map.has_key?(tuple_map, :id)
      assert inner == %{k: 1}
    end
  end

  describe "drop_keys/2" do
    test "removes the keys recursively through maps, lists and tuples" do
      value = %{a: 1, fees: 2, nested: [%{fees: 1, b: 2}], pair: {%{fees: 3, c: 4}, :x}}

      assert drop_keys(value, [:fees]) == %{
               a: 1,
               nested: [%{b: 2}],
               pair: {%{c: 4}, :x}
             }
    end

    test "removes the keys from structs" do
      dropped = drop_keys(%Event{value: 1, fees: 9}, [:fees])

      assert Map.get(dropped, :fees) == nil
      assert Map.get(dropped, :value) == 1

      assert drop_keys(%Event{value: 1, fees: 9}, [:fees]) ==
               drop_keys(%Event{value: 1, fees: 2}, [:fees])
    end
  end

  describe "ComparisonMismatch" do
    test "is an exception whose message is its text when it has one" do
      detail = mismatch(message: "fees differ")
      assert Compare.mismatch?(detail)
      assert Exception.message(detail) == "fees differ"
    end

    test "renders a diff of left and right when it has no text" do
      message = Exception.message(mismatch(left: %{net: 100}, right: %{net: 250}))

      assert is_binary(message)
      assert message =~ "100"
      assert message =~ "250"
    end
  end
end
