defmodule PropertyDamage.Next.SteeringCanaryTest do
  # PD's own engine stores a StreamData value as a path of child indices in
  # StreamData's shrink tree, and reaches that node again by answering pass or
  # fail to each value StreamData.check_all/3 offers while it shrinks. That
  # works only because check_all/3 offers a failing node's children in order,
  # descends into the first child that fails, and never returns to that
  # child's later siblings. StreamData does not document this order. These
  # tests call check_all/3 directly, with no PD code, and pin the order the
  # StreamData version in mix.lock shows, so a release that changes it fails here
  # first.
  use ExUnit.Case, async: true

  @steering "PD's steering of StreamData.check_all/3 depends on this visiting order; " <>
              "a StreamData release changed it"

  # A generator whose values depend on the seed alone: no maps, so the order
  # of keys in this VM plays no part.
  defp generator do
    StreamData.tuple(
      {StreamData.integer(1..1000), StreamData.list_of(StreamData.integer(0..9), max_length: 4)}
    )
  end

  @options [
    initial_seed: {5, 0, 0},
    initial_size: 30,
    max_runs: 1,
    max_shrinking_steps: 1_000_000_000
  ]

  # Runs check_all/3 with a callback that fails the first value it is offered
  # (the root of the tree), then answers each later value from `answers` in
  # turn, and `rest` once they run out. Returns every value offered, in order.
  defp offered(answers, rest \\ :pass) do
    key = {__MODULE__, make_ref()}
    Process.put(key, %{answers: answers, seen: []})

    StreamData.check_all(generator(), @options, fn value ->
      %{answers: answers, seen: seen} = Process.get(key)
      {answer, answers} = next_answer(seen, answers, rest)
      Process.put(key, %{answers: answers, seen: [value | seen]})
      if answer == :fail, do: {:error, value}, else: {:ok, value}
    end)

    key |> Process.delete() |> Map.fetch!(:seen) |> Enum.reverse()
  end

  defp next_answer([], answers, _rest), do: {:fail, answers}
  defp next_answer(_seen, [answer | answers], _rest), do: {answer, answers}
  defp next_answer(_seen, [], rest), do: {rest, []}

  # The answers that steer to the node at `path`: for each index, pass that
  # many siblings, then fail the one at the index.
  defp steer_answers(path), do: Enum.flat_map(path, &(List.duplicate(:pass, &1) ++ [:fail]))

  # The value at `path` and every value offered on the way, passing all
  # values after the node is reached.
  defp walk(path) do
    seen = offered(steer_answers(path))
    {Enum.at(seen, length(steer_answers(path))), seen}
  end

  @root {115, [1, 3]}

  @root_children [
    {58, [1, 3]},
    {87, [1, 3]},
    {101, [1, 3]},
    {108, [1, 3]},
    {112, [1, 3]},
    {114, [1, 3]},
    {115, [3]},
    {115, [1]},
    {115, [0, 3]},
    {115, [1, 0]},
    {115, [1, 2]}
  ]

  test "passing every child offers the root, then its children in order, and stops" do
    assert offered([]) == [@root | @root_children], @steering
  end

  test "failing every value descends through first children only" do
    assert offered([], :fail) == [
             @root,
             {58, [1, 3]},
             {29, [1, 3]},
             {15, [1, 3]},
             {8, [1, 3]},
             {4, [1, 3]},
             {2, [1, 3]},
             {1, [1, 3]},
             {1, [3]},
             {1, []}
           ],
           @steering
  end

  test "failing chosen children walks the chosen path and offers that node's children" do
    # Child 1 of the root, then child 2 of that node.
    assert offered([:pass, :fail, :pass, :pass, :fail]) == [
             @root,
             {58, [1, 3]},
             {87, [1, 3]},
             {44, [1, 3]},
             {66, [1, 3]},
             {77, [1, 3]},
             {39, [1, 3]},
             {58, [1, 3]},
             {68, [1, 3]},
             {73, [1, 3]},
             {75, [1, 3]},
             {76, [1, 3]},
             {77, [3]},
             {77, [1]},
             {77, [0, 3]},
             {77, [1, 0]},
             {77, [1, 2]}
           ],
           @steering

    assert walk([1, 2]) |> elem(0) == {77, [1, 3]}, @steering
  end

  test "a failing child's later siblings are never offered once its children run out" do
    # Child 7 of the root, {115, [1]}, has eight children. After them the
    # walk ends: the root's children 8 to 10 are not offered again.
    seen = offered(List.duplicate(:pass, 7) ++ [:fail])

    assert seen ==
             [@root | Enum.take(@root_children, 8)] ++
               [
                 {58, [1]},
                 {87, [1]},
                 {101, [1]},
                 {108, [1]},
                 {112, [1]},
                 {114, [1]},
                 {115, []},
                 {115, [0]}
               ],
           @steering
  end

  test "a node's children are counted as the values offered after failing it" do
    # Fail the node at the path, pass everything after it: the number of
    # values offered after the node is its number of children.
    counts =
      for path <- [[], [1], [7], [9], [1, 2]] do
        {_value, seen} = walk(path)
        length(seen) - length(steer_answers(path)) - 1
      end

    assert counts == [11, 11, 8, 7, 11], @steering
  end

  test "rejecting a node instead of failing it does not count its children" do
    # The counting rule written against an older StreamData took the
    # difference between a walk that fails the node and one that passes it.
    # On this version the difference is not the node's number of children,
    # because the walk never comes back to the node's later siblings.
    accept = offered([:pass, :fail])
    reject = offered([:pass, :pass])

    assert {length(accept), length(reject)} == {14, 12}, @steering
  end

  test "two walks along one path give one value and offer the same values" do
    for path <- [[], [0], [1], [1, 2], [7, 3], [9, 0, 0]] do
      assert walk(path) == walk(path)
    end
  end

  test "a path longer than the tree ends at the deepest node it reaches" do
    # Node [7, 3] has children; asking for child 50 of it passes them all and
    # the walk ends with [7, 3] the last failing node.
    assert offered(steer_answers([7, 3, 50])) == offered(steer_answers([7, 3])), @steering
  end
end
