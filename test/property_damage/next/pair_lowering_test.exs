defmodule PropertyDamage.Next.PairLoweringTest do
  # Some failures need two integers to move together: lowering either one
  # alone makes the failure go away. When a round of single edits keeps
  # nothing, the shrink tries lowering two integer entries of the journal by
  # the same amount. These tests read run/1, the failure it returns, its
  # journal and the candidates the adapter saw; they never name the
  # shrinker's own modules.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Journal}
  alias PropertyDamage.Next.Test.Pair
  alias PropertyDamage.Next.Test.Shrink

  @moduletag timeout: 120_000

  # A command fails when `a - b` equals this gap.
  @gap 7

  # --- Helpers

  defp run(opts), do: Next.run(Keyword.merge([max_plans: 2_000, max_steps: 1], opts))

  # Every execution the pair adapter reported, in order, as a list of
  # {instance, [command]} pairs.
  defp executions do
    collect([])
    |> Enum.reverse()
    |> Enum.reduce([], fn
      {:pair_setup, instance}, acc ->
        [{instance, []} | acc]

      {:pair_executed, instance, command}, [{instance, commands} | acc] ->
        [{instance, commands ++ [command]} | acc]
    end)
    |> Enum.reverse()
  end

  defp collect(acc) do
    receive do
      {:pair_setup, _} = message -> collect([message | acc])
      {:pair_executed, _, _} = message -> collect([message | acc])
    after
      0 -> acc
    end
  end

  # The executions after the plan that first failed: the shrink's candidates.
  defp candidates(%Failure{plan_number: number}, executions), do: Enum.drop(executions, number)

  defp only_command(plan) do
    assert [step] = plan.steps
    step.command
  end

  # Each candidate's command next to the best command held when it ran. A
  # candidate whose command fails is kept, so it becomes the best: with one
  # step, failing the same way is failing at all.
  defp against_best(first, candidates, config) do
    {paired, _best} =
      Enum.map_reduce(candidates, first, fn
        {_instance, [command]}, best ->
          next = if Pair.Adapter.fails?(command, config), do: command, else: best
          {{command, best}, next}

        {_instance, []}, best ->
          {{nil, best}, best}
      end)

    paired
  end

  # The integer fields a candidate changed from the best, with the change.
  defp changes(nil, _best), do: []

  defp changes(command, best) do
    for field <- [:a, :b, :c],
        Map.has_key?(command, field),
        Map.fetch!(command, field) != Map.fetch!(best, field),
        do: {field, Map.fetch!(command, field) - Map.fetch!(best, field)}
  end

  # A candidate that lowers exactly two integer fields by the same amount.
  defp pair_shaped?(command, best) do
    match?([{_, delta}, {_, delta}] when delta < 0, changes(command, best))
  end

  defp single_edit?(command, best), do: match?([_], changes(command, best))

  # Whether lowering one field of `best` alone, to any value of its range
  # (every range here starts at 1), still fails.
  defp single_edit_keeps?(best, config) do
    for field <- [:a, :b, :c],
        Map.has_key?(best, field),
        value <- 1..(Map.fetch!(best, field) - 1)//1,
        reduce: false do
      found -> found or Pair.Adapter.fails?(Map.put(best, field, value), config)
    end
  end

  # The failure rule of each journal with no pair to lower: one integer
  # entry; no integer entry, only a StreamData value; two integer entries,
  # one with a single-value range.
  defp config(:amount), do: %{fails?: fn c, _ -> c.amount >= 37 end}
  defp config(:note), do: %{fails?: fn c, _ -> byte_size(c.text) >= 2 end}
  defp config(:pinned), do: %{gap: @gap}

  # --- Single edits cannot shrink it; the pair candidate can

  describe "a failure that needs two integers to keep their gap" do
    test "shrinks both to the smallest values the gap allows" do
      config = %{gap: @gap}

      originals =
        for seed <- 1..6 do
          assert {:error, %Failure{} = failure} =
                   run(model: Pair.TwoModel, adapter: Pair.Adapter, seed: seed, config: config)

          first = only_command(failure.original.plan)
          assert first.a - first.b == @gap

          assert only_command(failure.plan) == %Pair.Two{a: @gap + 1, b: 1},
                 "seed #{seed} shrank #{inspect(first)} to #{inspect(only_command(failure.plan))}"

          assert failure.reason == {:adapter_error, {:gap, @gap + 1, 1}}
          first
        end

      assert Enum.any?(originals, &(&1 != %Pair.Two{a: @gap + 1, b: 1}))
    end
  end

  # --- Order: single edits first

  describe "a candidate that lowers two integers by the same amount" do
    test "runs only once single edits keep nothing" do
      # The failure needs `a - b == 7` and `c >= 20`: single lowering takes c
      # down to 20 and can do nothing to a or b. Every pair-shaped candidate
      # must run against a best that no single lowering can shrink.
      config = %{gap: @gap, floor: 20}

      seeds =
        for seed <- 1..6 do
          assert {:error, %Failure{} = failure} =
                   run(
                     model: Pair.ThreeModel,
                     adapter: Pair.Adapter,
                     seed: seed,
                     config: Map.put(config, :recorder, self())
                   )

          first = only_command(failure.original.plan)
          tried = against_best(first, candidates(failure, executions()), config)
          pairs = Enum.filter(tried, fn {command, best} -> pair_shaped?(command, best) end)

          for {command, best} <- pairs do
            refute single_edit_keeps?(best, config),
                   "seed #{seed} ran the pair candidate #{inspect(command)} " <>
                     "while a single edit of #{inspect(best)} still failed"
          end

          assert pairs != [],
                 "seed #{seed}: no candidate lowered two integers by the same amount"

          before_first_pair = Enum.take_while(tried, fn {c, b} -> not pair_shaped?(c, b) end)

          progressed? =
            Enum.any?(before_first_pair, fn {command, best} ->
              single_edit?(command, best) and Pair.Adapter.fails?(command, config)
            end)

          {seed, progressed?}
        end

      # Single edits kept something before the first pair candidate in at
      # least one shrink, so the order above was tested, not assumed.
      assert Enum.any?(seeds, fn {_seed, progressed?} -> progressed? end)
    end
  end

  # --- The run budget

  describe "max_shrink_runs with the pair candidate in play" do
    test "bounds the candidates executed, each counted as a shrink run" do
      for limit <- [1, 3, 10, 18, 25], seed <- 1..3 do
        assert {:error, %Failure{} = failure} =
                 run(
                   model: Pair.TwoModel,
                   adapter: Pair.Adapter,
                   seed: seed,
                   max_shrink_runs: limit,
                   config: %{gap: @gap, recorder: self()}
                 )

        assert failure.shrink_runs <= limit
        assert length(candidates(failure, executions())) == failure.shrink_runs
      end
    end
  end

  # --- Journals with no pair to lower

  describe "a journal with fewer than two integers above their lower bound" do
    # {model, adapter, config, seed, plan number, shrink runs, final command}.
    # Measured on the shrinker before pair candidates existed, twice, with
    # identical results: these shrinks must make exactly those runs.
    @untouched [
      {Shrink.AmountModel, Shrink.Adapter, :amount, 1, 1, 20, %Shrink.Amount{amount: 37}},
      {Shrink.AmountModel, Shrink.Adapter, :amount, 2, 1, 19, %Shrink.Amount{amount: 37}},
      {Shrink.AmountModel, Shrink.Adapter, :amount, 3, 1, 20, %Shrink.Amount{amount: 37}},
      {Shrink.NoteModel, Shrink.Adapter, :note, 1, 2, 16, %Shrink.Note{text: "aa"}},
      {Shrink.NoteModel, Shrink.Adapter, :note, 2, 1, 21, %Shrink.Note{text: "aa"}},
      {Shrink.NoteModel, Shrink.Adapter, :note, 3, 2, 18, %Shrink.Note{text: "aa"}},
      {Pair.PinnedModel, Pair.Adapter, :pinned, 1, 19, 7, %Pair.Pinned{a: 12, b: 5}},
      {Pair.PinnedModel, Pair.Adapter, :pinned, 2, 184, 7, %Pair.Pinned{a: 12, b: 5}},
      {Pair.PinnedModel, Pair.Adapter, :pinned, 3, 41, 7, %Pair.Pinned{a: 12, b: 5}}
    ]

    test "makes exactly the shrink runs it made before pair candidates" do
      for {model, adapter, config, seed, number, runs, command} <- @untouched do
        assert {:error, %Failure{} = failure} =
                 run(model: model, adapter: adapter, seed: seed, config: config(config))

        assert {inspect(model), seed, failure.plan_number, failure.shrink_runs,
                only_command(failure.plan)} == {inspect(model), seed, number, runs, command}
      end
    end
  end

  # --- The result

  describe "the failure after a pair shrink" do
    setup do
      paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})

      on_exit(fn ->
        try do
          :peer.stop(peer)
        catch
          :exit, _ -> :ok
        end
      end)

      %{peer: peer}
    end

    test "fails for the reason of the first failure, and its journal replays in a fresh VM",
         %{peer: peer} do
      config = %{gap: @gap}
      opts = [model: Pair.TwoModel, adapter: Pair.Adapter, config: config]

      refute :peer.call(peer, :code, :is_loaded, [Pair.TwoModel])

      for seed <- 1..3 do
        assert {:error, %Failure{} = failure} = run([seed: seed] ++ opts)

        assert {:adapter_error, {:gap, _, _}} = failure.original.reason
        assert {:adapter_error, {:gap, _, _}} = failure.reason

        binary = Journal.to_binary(failure.journal)

        assert {:error, %Failure{} = again} =
                 :peer.call(peer, Next, :replay, [binary, opts], 60_000)

        assert again.plan.steps == failure.plan.steps
        assert again.journal == failure.journal
        assert again.withdrawn == failure.withdrawn
        assert again.step == failure.step
        assert again.reason == failure.reason
      end
    end
  end
end
