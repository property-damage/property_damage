defmodule PropertyDamage.PatchedStreamDataTest do
  # Proves that the StreamData loaded in the test VM routes seed splitting and
  # range draws through a caller-supplied :rand state. The test helper applies
  # the patch under test/support/stream_data_patch/ and excludes this tag when
  # the patched module is not active.
  use ExUnit.Case, async: true

  @moduletag :patched_stream_data

  test "a :rand state with :split and :uniform_range handlers drives a generator draw" do
    test_pid = self()
    {algorithm, state} = :rand.seed_s(:exsss, {1, 2, 3})

    handlers = %{
      split: fn seed ->
        send(test_pid, :split)
        {seed, seed}
      end,
      uniform_range: fn left, right, seed ->
        send(test_pid, {:uniform_range, left, right})
        {7, seed}
      end
    }

    seed = {Map.merge(algorithm, handlers), state}

    result =
      StreamData.check_all(StreamData.integer(1..10), [initial_seed: seed, max_runs: 1], fn
        value -> {:ok, value}
      end)

    assert result == {:ok, %{}}
    assert_received :split
    assert_received {:uniform_range, 1, 10}
  end

  test "the drawn value is the one the :uniform_range handler returns" do
    {algorithm, state} = :rand.seed_s(:exsss, {1, 2, 3})

    handlers = %{
      split: fn seed -> {seed, seed} end,
      uniform_range: fn _left, _right, seed -> {7, seed} end
    }

    seed = {Map.merge(algorithm, handlers), state}

    result =
      StreamData.check_all(StreamData.integer(1..10), [initial_seed: seed, max_runs: 3], fn
        value -> if value == 7, do: {:ok, value}, else: {:error, value}
      end)

    assert result == {:ok, %{}}
  end
end
