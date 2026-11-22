defmodule PropertyDamage.Next.EngineTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Next.{Engine, Gen, Journal}
  alias PropertyDamage.Next.Engine.Native

  defp journal(entries \\ %{}), do: %Journal{seed: 0, entries: entries, fingerprint: nil}

  # Key terms of unrelated shapes. The engine may only look them up and
  # derive a seed from them.
  @keys [
    "a string key",
    {:nested, {:tuple, [1, 2]}},
    {{0, 1}, :command, :amount},
    42,
    [:a, :b],
    %{map: :key}
  ]

  describe "the behaviour" do
    test "has exactly one callback, draw/4" do
      assert Engine.behaviour_info(:callbacks) == [draw: 4]
    end

    test "PD's own engine implements it" do
      behaviours = Native.module_info(:attributes) |> Keyword.get_values(:behaviour)
      assert Engine in List.flatten(behaviours)
    end
  end

  describe "a fresh key" do
    test "an integer description stores the value and the range" do
      drawn =
        for k <- 1..100 do
          {value, entry} = Native.draw(journal(), {:k, k}, Gen.integer(1..5), 7)
          assert entry == {:integer, value, 1..5}
          value
        end

      assert Enum.all?(drawn, &(&1 in 1..5))
      assert Enum.sort(Enum.uniq(drawn)) == [1, 2, 3, 4, 5]
    end

    test "a member description stores the member and its index from zero" do
      list = [:red, :green, :blue]

      drawn =
        for k <- 1..100 do
          {value, {:member, stored, index}} =
            Native.draw(journal(), {:k, k}, Gen.member_of(list), 7)

          assert stored == value
          assert Enum.at(list, index) == value
          value
        end

      assert Enum.sort(Enum.uniq(drawn)) == Enum.sort(list)
    end

    test "boolean draws a member of false and true" do
      for k <- 1..20 do
        {value, {:member, stored, index}} = Native.draw(journal(), {:k, k}, Gen.boolean(), 3)
        assert stored == value
        assert Enum.at([false, true], index) == value
      end
    end

    test "a plain or delegated StreamData generator stores the value and the empty path" do
      for k <- 1..20 do
        {value, entry} = Native.draw(journal(), {:k, k}, StreamData.integer(1..5), 3)
        assert entry == {:stream_data, value, []}
        assert value in 1..5

        {list, entry} = Native.draw(journal(), {:k, k}, Gen.list_of(Gen.integer(1..3)), 3)
        assert entry == {:stream_data, list, []}
        assert Enum.all?(list, &(&1 in 1..3))
      end
    end

    test "the same journal, key, generator and seed give the same value and entry" do
      for generator <- [Gen.integer(1..1000), Gen.member_of(Enum.to_list(1..50)), Gen.term()] do
        assert Native.draw(journal(), :key, generator, 11) ==
                 Native.draw(journal(), :key, generator, 11)
      end
    end

    test "the seed changes what a key draws" do
      drawn = for seed <- 1..50, do: Native.draw(journal(), :key, Gen.integer(1..1000), seed)
      assert drawn |> Enum.uniq() |> length() > 1
    end
  end

  describe "the key is opaque" do
    test "draws the same value and entry for a key term of any shape, used consistently" do
      for key <- @keys, generator <- [Gen.integer(1..100), Gen.member_of([:a, :b, :c])] do
        {value, entry} = Native.draw(journal(), key, generator, 5)

        assert Native.draw(journal(), key, generator, 5) == {value, entry}
        assert Native.draw(journal(%{key => entry}), key, generator, 999) == {value, entry}
      end
    end

    test "an entry under one key does not change what another key draws" do
      for key <- @keys, other <- @keys, key != other do
        stored = journal(%{key => {:integer, 1, 1..100}})

        assert Native.draw(stored, other, Gen.integer(1..100), 5) ==
                 Native.draw(journal(), other, Gen.integer(1..100), 5)
      end
    end
  end

  describe "a key with an entry" do
    test "a stored integer that fits the range is returned, its entry recording the current range" do
      stored = journal(%{k: {:integer, 4, 1..9}})
      assert Native.draw(stored, :k, Gen.integer(1..5), 1) == {4, {:integer, 4, 1..5}}
    end

    test "a stored member still in the list is kept" do
      stored = journal(%{k: {:member, :b, 1}})
      assert {:b, {:member, :b, _index}} = Native.draw(stored, :k, Gen.member_of([:a, :b]), 1)
    end

    test "a stored StreamData value is returned" do
      {value, entry} = Native.draw(journal(), :k, StreamData.integer(1..5), 1)
      stored = journal(%{k: entry})
      assert Native.draw(stored, :k, StreamData.integer(1..5), 1) == {value, entry}
    end

    test "a stored value outside the new domain gives a value inside it" do
      {value, entry} =
        Native.draw(journal(%{k: {:integer, 50, 1..100}}), :k, Gen.integer(1..5), 1)

      assert value in 1..5
      assert entry == {:integer, value, 1..5}

      list = [:a, :b]

      {member, {:member, stored, index}} =
        Native.draw(journal(%{k: {:member, :gone, 2}}), :k, Gen.member_of(list), 1)

      assert stored == member
      assert Enum.at(list, index) == member
    end
  end
end
