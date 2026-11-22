defmodule PropertyDamage.Next.SteeringThrowCanaryTest do
  # PropertyDamage.Next.Steering.walk/3 stops StreamData.check_all/3 as soon
  # as it reaches the node a path names, by throwing from the property
  # callback. That works only because check_all/3 lets a throw from the
  # callback pass through to its caller: it neither catches it nor builds
  # more values first. StreamData does not document this. These tests call
  # check_all/3 directly, with no PD code, and pin that behavior on the
  # StreamData version in mix.lock, together with the number of values the
  # generator builds before the throw, so a release that catches throws, or
  # builds children eagerly, fails here first.
  use ExUnit.Case, async: true

  @steering "PD's steering stops StreamData.check_all/3 with a throw from the property " <>
              "callback; a StreamData release changed how check_all/3 treats that throw"

  @options [
    initial_seed: {5, 0, 0},
    initial_size: 30,
    max_runs: 1,
    max_shrinking_steps: 1_000_000_000
  ]

  # A generator that counts, in the test process, every value it builds:
  # StreamData.map/2 calls its function once per node of the shrink tree,
  # when check_all/3 builds that node.
  defp counting_generator(counter) do
    StreamData.map(
      StreamData.tuple(
        {StreamData.integer(1..1000), StreamData.list_of(StreamData.integer(0..9), max_length: 4)}
      ),
      fn value ->
        Process.put(counter, Process.get(counter) + 1)
        value
      end
    )
  end

  # Runs check_all/3, failing the root and then the child at each index of
  # `path`, passing the other children, and throws from the callback when
  # the node at `path` is offered. Returns what the caller caught, what
  # check_all/3 returned if it returned, and the number of values built.
  defp walk_and_throw(path) do
    counter = {__MODULE__, make_ref()}
    state = {__MODULE__, make_ref()}
    tag = make_ref()
    Process.put(counter, 0)
    Process.put(state, {:root, path, 0})

    outcome =
      try do
        returned =
          StreamData.check_all(counting_generator(counter), @options, fn value ->
            {answer, next} = answer(Process.get(state), value, tag)
            Process.put(state, next)
            if answer == :fail, do: {:error, value}, else: {:ok, value}
          end)

        {:returned, returned}
      catch
        {^tag, value} -> {:caught, value}
      end

    Process.delete(state)
    {outcome, Process.delete(counter)}
  end

  defp answer({:root, [], _index}, value, tag), do: throw({tag, value})
  defp answer({:root, path, _index}, _value, _tag), do: {:fail, {:child, path, 0}}
  defp answer({:child, [index], index}, value, tag), do: throw({tag, value})

  defp answer({:child, [index | rest], index}, _value, _tag),
    do: {:fail, {:child, rest, 0}}

  defp answer({:child, path, index}, _value, _tag), do: {:pass, {:child, path, index + 1}}

  # The values a walk to `path` builds: the root, then for each index i of
  # the path, the i + 1 children offered up to and including the one failed.
  defp expected_calls(path), do: 1 + Enum.sum(Enum.map(path, &(&1 + 1)))

  test "a throw at the root reaches the caller after one value is built" do
    assert walk_and_throw([]) == {{:caught, {115, [1, 3]}}, 1}, @steering
  end

  test "a throw at a child reaches the caller with the thrown term and no value built after it" do
    for {path, value} <- [{[0], {58, [1, 3]}}, {[3], {108, [1, 3]}}, {[2, 1], {76, [1, 3]}}] do
      assert walk_and_throw(path) == {{:caught, value}, expected_calls(path)},
             "path #{inspect(path)}: " <> @steering
    end
  end
end
