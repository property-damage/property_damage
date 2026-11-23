defmodule PropertyDamage.Next.SourcePairListTest do
  # On the engine that draws every value through StreamData from a recording
  # source, a string records, for each character, a position whose value
  # does not reach the string. Lowering such a position alone rebuilds the
  # plan already held, so the single-edit round runs nothing for it. Paired
  # with the string's length, it gives candidates that only repeat what the
  # single edits of the length already ran. These tests read run/1, the
  # failure it returns, its journal and the candidates the adapter saw; they
  # never name the shrinker's own modules.
  use ExUnit.Case, async: true

  @moduletag :patched_stream_data
  @moduletag timeout: 120_000

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Engine.StreamDataSource
  alias PropertyDamage.Next.Failure
  alias PropertyDamage.Next.Test.Shrink

  # A note fails once it holds two bytes or more.
  @fails? &__MODULE__.fails?/2

  def fails?(%Shrink.Note{text: text}, _earlier), do: byte_size(text) >= 2

  defp run(seed) do
    Next.run(
      model: Shrink.NoteModel,
      adapter: Shrink.Adapter,
      engine: StreamDataSource,
      seed: seed,
      max_plans: 2_000,
      max_steps: 1,
      config: %{fails?: @fails?, recorder: self()}
    )
  end

  # Every execution the adapter reported, in order, each as the list of the
  # commands it ran.
  defp executions do
    collect([])
    |> Enum.reverse()
    |> Enum.reduce([], fn
      {:shrink_setup, _instance}, acc -> [[] | acc]
      {:shrink_executed, _instance, command}, [commands | acc] -> [commands ++ [command] | acc]
    end)
    |> Enum.reverse()
  end

  defp collect(acc) do
    receive do
      {:shrink_setup, _} = message -> collect([message | acc])
      {:shrink_executed, _, _} = message -> collect([message | acc])
    after
      0 -> acc
    end
  end

  # The candidates of the last round of a shrink that ends without adopting
  # a pair: the executions after the last one that ran no step (block
  # removal starts each round with the empty plan), without the final
  # execution of the result. Within that round, single edits run distinct
  # candidates, so a repeated candidate is one the pair pass ran.
  defp last_round(%Failure{plan_number: number}, executions) do
    candidates = Enum.drop(executions, number)
    start = candidates |> Enum.with_index() |> Enum.filter(&match?({[], _}, &1)) |> List.last()
    assert {[], index} = start, "no execution ran the empty plan"
    candidates |> Enum.drop(index) |> Enum.drop(-1)
  end

  defp repeats(candidates), do: length(candidates) - length(Enum.uniq(candidates))

  defp positions_above_lower_bound(%Failure{journal: journal}) do
    for {{_step, :command, :text}, entry} <- journal.entries,
        {_position, {value, lo, _hi}} <- StreamDataSource.positions(entry),
        value > lo,
        reduce: 0,
        do: (count -> count + 1)
  end

  describe "a pair whose position changes nothing alone" do
    test "costs no shrink run, and the note still shrinks to two bytes" do
      shrinks =
        for seed <- 1..6 do
          assert {:error, %Failure{} = failure} = run(seed)
          assert [%Shrink.Note{text: "aa"}] = Enum.map(failure.plan.steps, & &1.command)

          round = last_round(failure, executions())

          assert repeats(round) == 0,
                 "seed #{seed}: the pair pass ran #{repeats(round)} candidates " <>
                   "the last round had already run: #{inspect(round)}"

          positions_above_lower_bound(failure)
        end

      # Some final note holds two positions above their lower bound, so a
      # pair was there to try and the count above was tested, not assumed.
      assert Enum.any?(shrinks, &(&1 >= 2))
    end
  end
end
