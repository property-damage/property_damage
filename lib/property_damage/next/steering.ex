defmodule PropertyDamage.Next.Steering do
  @moduledoc """
  Reaches a node of a StreamData generator's shrink tree from a seed and a
  path, through the public `StreamData.check_all/3` alone.

  A StreamData generator drawn from one seed at one size gives one value,
  the root of a tree whose children are smaller values. A path is a list of
  child indices from the root: `[]` is the root, `[2]` its third child,
  `[2, 0]` that child's first child. PD's own engine stores a StreamData
  value as its path, so a rebuilt plan reaches the same value, and a
  shrinker reaches a smaller one by extending the path.

  `check_all/3` shrinks a failing value by offering its children in order
  to the property; it descends into the first child that fails and never
  returns to that child's later siblings. Steering answers each offered
  value: it fails the child at the next index of the path and passes the
  others, so the values offered follow the path. A node's children are
  counted as the values offered after failing it, every one of them
  passed.

  StreamData does not document this order, so a StreamData release could
  change it. A test that calls `check_all/3` directly pins the order of the
  StreamData version PD locks, and fails first if a release changes it.

  Seeds are integers, such as the key seed `PropertyDamage.Next.Journal.key_seed/2`
  returns. Every draw is at the fixed size `size/0`, so a value depends on
  the generator, the seed and the path alone.

  A path that names a child a node does not have is cut at its longest
  valid prefix: the walk ends at the deepest node the path reaches, and
  that node's value belongs to the generator walked. So a path stored on
  one generator gives a value of another generator when walked on it.

  Cost, counted in values the generator builds: `walk/3` builds the root
  plus, for each index `i` of the path, `i + 1` children. `child_count/3`
  builds the same, plus every child of the node it counts.
  """

  # The size StreamData draws at, fixed so a draw depends on the seed alone.
  @size 30

  # check_all/3 stops after this many offered children. Set far above any
  # tree PD walks, so a walk ends because the path or the tree ends.
  @max_shrinking_steps 1_000_000_000

  @typedoc "Child indices from the root, each counted from 0."
  @type path :: [non_neg_integer()]

  @doc "The size every draw is made at."
  @spec size() :: pos_integer()
  def size, do: @size

  @doc """
  The value at `path` in the shrink tree of `stream_data` drawn from `seed`,
  and the path that reached it.

  The reached path is `path` when every index exists, and otherwise the
  longest prefix of `path` that exists on this tree.
  """
  @spec walk(StreamData.t(term()), integer(), path()) :: {term(), path()}
  def walk(stream_data, seed, path) when is_integer(seed) and is_list(path) do
    tag = make_ref()

    try do
      # check_all/3 ends on its own only when the path names a child that
      # does not exist; the last failed node is then the deepest one reached.
      %{value: value, reached: reached} =
        steer(stream_data, seed, path, fn
          # The node the path names is reached: stop here rather than build
          # the children check_all/3 would offer next.
          value, [], reached -> throw({tag, value, Enum.reverse(reached)})
          _value, _todo, _reached -> :go_on
        end)

      {value, Enum.reverse(reached)}
    catch
      {^tag, value, reached} -> {value, reached}
    end
  end

  @doc """
  The number of children of the node at `path` in the shrink tree of
  `stream_data` drawn from `seed`.

  A path that runs past a node's last child, or names a child that does not
  exist, is cut at its longest valid prefix, and the children of the node
  it reaches are counted.
  """
  @spec child_count(StreamData.t(term()), integer(), path()) :: non_neg_integer()
  def child_count(stream_data, seed, path) when is_integer(seed) and is_list(path) do
    %{index: count} = steer(stream_data, seed, path, fn _value, _todo, _reached -> :go_on end)
    count
  end

  # Runs check_all/3 on `stream_data` from `seed`, failing the root and then
  # the child at each index of `path` in turn, and passing every other
  # value. `on_node` is called with each failed node's value, the indices
  # still to walk and the reversed path walked so far.
  #
  # Returns the state when check_all/3 ends: `index` is the number of
  # children of the last failed node that were offered, all of them passed,
  # which is its number of children; `value` and `reached` are that node's.
  defp steer(stream_data, seed, path, on_node) do
    key = {__MODULE__, make_ref()}
    Process.put(key, :root)

    options = [
      initial_seed: {seed, 0, 0},
      initial_size: @size,
      max_runs: 1,
      max_shrinking_steps: @max_shrinking_steps
    ]

    try do
      StreamData.check_all(stream_data, options, fn value ->
        {answer, state} = answer(Process.get(key), value, path, on_node)
        Process.put(key, state)
        if answer == :fail, do: {:error, value}, else: {:ok, value}
      end)

      Process.get(key)
    after
      Process.delete(key)
    end
  end

  # The first value offered is the root.
  defp answer(:root, value, path, on_node) do
    on_node.(value, path, [])
    {:fail, %{todo: path, index: 0, value: value, reached: []}}
  end

  # The child at the next index of the path: fail it, so check_all/3
  # descends into its children.
  defp answer(%{todo: [index | todo], index: index, reached: reached}, value, _path, on_node) do
    reached = [index | reached]
    on_node.(value, todo, reached)
    {:fail, %{todo: todo, index: 0, value: value, reached: reached}}
  end

  # Any other child: pass it, so check_all/3 offers its next sibling.
  defp answer(%{index: index} = state, _value, _path, _on_node),
    do: {:pass, %{state | index: index + 1}}
end
