defmodule PropertyDamage.Next.FitTest do
  # How PD's own engine fits a stored value when the domain at its key moved
  # on a rebuild. Each row gives the stored entry and the new generator, and
  # the value and entry the engine must answer. The entry records the domain
  # of the current draw, so a later rebuild reads the current bounds.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next.Engine.Native
  alias PropertyDamage.Next.{Gen, Journal}
  alias PropertyDamage.Next.Test.Surface

  @key {{0, 3}, :command, :amount}
  @seed 41

  defp draw(entry, generator, key \\ @key) do
    Native.draw(%Journal{seed: @seed, entries: %{key => entry}}, key, generator, @seed)
  end

  describe "a number: keep the stored value if it fits, else clamp it" do
    # {stored entry, new range, value, entry}
    @number_rows [
      # Fits the new range: kept, with the new range recorded.
      {{:integer, 300, 1..665}, 1..400, 300, {:integer, 300, 1..400}},
      # Sat on the old upper bound, which moved down: clamped to the new one.
      {{:integer, 665, 1..665}, 1..400, 400, {:integer, 400, 1..400}},
      # Sat on the old upper bound, which moved up: kept here; trying the new
      # bound is the shrinker's step, taken only after this candidate passes.
      {{:integer, 665, 1..665}, 1..900, 665, {:integer, 665, 1..900}},
      # Above the new range: clamped to its upper bound.
      {{:integer, 50, 1..100}, 1..5, 5, {:integer, 5, 1..5}},
      # Below the new range: clamped to its lower bound.
      {{:integer, 5, 1..9}, 10..20, 10, {:integer, 10, 10..20}},
      # The same range: kept as it was.
      {{:integer, 4, 1..9}, 1..9, 4, {:integer, 4, 1..9}},
      # A one-value range: that value.
      {{:integer, 7, 1..9}, 3..3, 3, {:integer, 3, 3..3}}
    ]

    for {stored, range, value, entry} <- @number_rows do
      test "#{inspect(stored)} under integer(#{inspect(range)}) gives #{value}" do
        assert draw(unquote(Macro.escape(stored)), Gen.integer(unquote(Macro.escape(range)))) ==
                 {unquote(value), unquote(Macro.escape(entry))}
      end
    end
  end

  describe "a member: keep it if still offered, else the member at the stored index, else the last" do
    # {stored entry, new list, value, entry}
    @member_rows [
      # Still offered, at another index: kept, with its current index.
      {{:member, :b, 1}, [:b, :c], :b, {:member, :b, 0}},
      # Still offered at the same index.
      {{:member, :b, 1}, [:a, :b, :c], :b, {:member, :b, 1}},
      # Gone; the list still has the stored index: the member now there.
      {{:member, :gone, 1}, [:x, :y, :z], :y, {:member, :y, 1}},
      # Gone; the list got shorter than the stored index: the last member.
      {{:member, :gone, 2}, [:x, :y], :y, {:member, :y, 1}},
      {{:member, :gone, 5}, [:x], :x, {:member, :x, 0}},
      # Gone, stored at index 0.
      {{:member, :gone, 0}, [:x, :y], :x, {:member, :x, 0}}
    ]

    for {stored, list, value, entry} <- @member_rows do
      test "#{inspect(stored)} under member_of(#{inspect(list)}) gives #{inspect(value)}" do
        assert draw(unquote(Macro.escape(stored)), Gen.member_of(unquote(list))) ==
                 {unquote(value), unquote(Macro.escape(entry))}
      end
    end

    test "a boolean is a member of false and true, kept if stored" do
      assert draw({:member, true, 1}, Gen.boolean()) == {true, {:member, true, 1}}
      assert draw({:member, false, 0}, Gen.boolean()) == {false, {:member, false, 0}}
    end
  end

  describe "the five cases of a stored value whose domain moved" do
    test "a full refund of 665 whose payment drops to 400 is clamped to 400" do
      assert draw({:integer, 665, 1..665}, Gen.integer(1..400)) == {400, {:integer, 400, 1..400}}
    end

    test "a refund of 300 whose payment drops to 400 is kept" do
      assert draw({:integer, 300, 1..665}, Gen.integer(1..400)) == {300, {:integer, 300, 1..400}}
    end

    test "a full refund of 665 whose payment grows to 900 is kept, with the new range" do
      assert draw({:integer, 665, 1..665}, Gen.integer(1..900)) == {665, {:integer, 665, 1..900}}
    end

    test "a member at index 1 whose payment is gone gives the member now at index 1, or the last" do
      assert draw({:member, :gone, 1}, Gen.member_of([:p1, :p2, :p3])) ==
               {:p2, {:member, :p2, 1}}

      assert draw({:member, :gone, 1}, Gen.member_of([:p1])) == {:p1, {:member, :p1, 0}}
    end

    test "a StreamData value whose generator changed follows its stored path on the new generator" do
      old = StreamData.list_of(StreamData.integer(0..9), max_length: 6)
      new = StreamData.list_of(StreamData.integer(0..9), max_length: 2)
      {key, key_seed, path} = key_with_path(old)

      {old_value, ^path} = Surface.walk(old, key_seed, path)
      {value, reached} = Surface.walk(new, key_seed, path)

      assert draw({:stream_data, old_value, path}, new, key) ==
               {value, {:stream_data, value, reached}}

      assert reached == Enum.take(path, length(reached))
      assert length(value) <= 2
    end
  end

  describe "a StreamData value" do
    test "a fresh draw records the value and the empty path, and walking it gives the value" do
      generator = StreamData.list_of(StreamData.integer(0..9), max_length: 6)
      key_seed = Journal.key_seed(@seed, @key)

      {value, entry} = Native.draw(%Journal{seed: @seed}, @key, generator, @seed)

      assert entry == {:stream_data, value, []}
      assert Surface.walk(generator, key_seed, []) == {value, []}
    end

    test "a stored path on the same generator gives back the stored value and entry" do
      generator = StreamData.list_of(StreamData.integer(0..9), max_length: 6)
      {key, key_seed, path} = key_with_path(generator)
      {value, ^path} = Surface.walk(generator, key_seed, path)

      assert draw({:stream_data, value, path}, generator, key) ==
               {value, {:stream_data, value, path}}
    end
  end

  # The first of several keys whose value at the key's seed has children, with
  # a path of up to three steps into its tree.
  defp key_with_path(generator) do
    Enum.find_value(1..50, fn slot ->
      key = {{0, slot}, :command, :amount}
      key_seed = Journal.key_seed(@seed, key)

      case deepest_path(generator, key_seed, 3) do
        [] -> nil
        path -> {key, key_seed, path}
      end
    end) || flunk("no key in 50 gives a value with children")
  end

  # A path of up to `depth` steps from the root, taking each node's last
  # child, so the path exists on `generator` at `seed`.
  defp deepest_path(generator, seed, depth) do
    Enum.reduce_while(1..depth, [], fn _step, path ->
      case Surface.child_count(generator, seed, path) do
        0 -> {:halt, path}
        count -> {:cont, path ++ [count - 1]}
      end
    end)
  end
end
