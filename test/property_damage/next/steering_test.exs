defmodule PropertyDamage.Next.SteeringTest do
  # PropertyDamage.Next.Steering reaches a node of a StreamData generator's
  # shrink tree from a seed and a path of child indices, through the public
  # StreamData.check_all/3 alone.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PropertyDamage.Next.Test.Surface

  defp list_generator(max_length),
    do: StreamData.list_of(StreamData.integer(0..9), max_length: max_length)

  defp pair_generator(upper) do
    StreamData.tuple(
      {StreamData.integer(1..upper), StreamData.string(:alphanumeric, max_length: 4)}
    )
  end

  # A path that exists on `generator` at `seed`, chosen by `picks`: at each
  # step, the child at the pick's position modulo the node's child count,
  # until the picks run out or a node has no children.
  defp valid_path(generator, seed, picks) do
    Enum.reduce_while(picks, [], fn pick, path ->
      case Surface.child_count(generator, seed, path) do
        0 -> {:halt, path}
        count -> {:cont, path ++ [rem(pick, count)]}
      end
    end)
  end

  test "two walks along one path on one generator and seed give one value" do
    generator = pair_generator(1_000)

    for seed <- [1, 7, 4_000_000_000], picks <- [[], [0], [3, 1], [1, 0, 2]] do
      path = valid_path(generator, seed, picks)
      assert Surface.walk(generator, seed, path) == Surface.walk(generator, seed, path)
      assert {_value, ^path} = Surface.walk(generator, seed, path)
    end
  end

  test "the empty path gives the root, and each child of it is reached by its index" do
    generator = list_generator(6)

    for seed <- 1..10 do
      {root, []} = Surface.walk(generator, seed, [])
      count = Surface.child_count(generator, seed, [])

      for index <- 0..(count - 1)//1 do
        assert {_child, [^index]} = Surface.walk(generator, seed, [index])
      end

      # One past the last child does not exist: the walk stops at the root.
      assert Surface.walk(generator, seed, [count]) == {root, []}
    end
  end

  property "a path walked twice gives one value" do
    check all(
            seed <- StreamData.integer(0..4_294_967_295),
            picks <- StreamData.list_of(StreamData.integer(0..20), max_length: 4),
            max_runs: 40
          ) do
      generator = pair_generator(500)
      path = valid_path(generator, seed, picks)

      assert Surface.walk(generator, seed, path) == Surface.walk(generator, seed, path)
    end
  end

  property "a path cut at its longest valid prefix gives a value the new generator can draw" do
    check all(
            seed <- StreamData.integer(0..4_294_967_295),
            picks <- StreamData.list_of(StreamData.integer(0..20), max_length: 4),
            max_runs: 40
          ) do
      old = list_generator(8)
      new = list_generator(2)
      path = valid_path(old, seed, picks)

      {value, reached} = Surface.walk(new, seed, path)

      assert reached == Enum.take(path, length(reached))
      assert Surface.walk(new, seed, reached) == {value, reached}
      assert length(value) <= 2
      assert Enum.all?(value, &(&1 in 0..9))
    end
  end

  property "a path walked on a narrower integer range stays inside the new range" do
    check all(
            seed <- StreamData.integer(0..4_294_967_295),
            picks <- StreamData.list_of(StreamData.integer(0..20), max_length: 4),
            max_runs: 40
          ) do
      path = valid_path(pair_generator(1_000), seed, picks)

      {{number, text}, reached} = Surface.walk(pair_generator(50), seed, path)

      assert reached == Enum.take(path, length(reached))
      assert number in 1..50
      assert String.length(text) <= 4
      assert Surface.walk(pair_generator(50), seed, reached) == {{number, text}, reached}
    end
  end
end
