defmodule PropertyDamage.Next.TreeLevelSizeTest do
  # StreamData's tree/2 draws the size of each level of a tree from a range.
  # With the patched StreamData that draw goes through the recording source
  # like every other range draw, so a journal replays a tree exactly and the
  # shrinker can lower a level size.
  use ExUnit.Case, async: true

  @moduletag :patched_stream_data

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Engine.StreamDataSource, Failure}
  alias PropertyDamage.Next.Test.{Shrink, Tree}

  @engine [engine: StreamDataSource]

  # A term/0 value may hold a reference, which make_ref/0 creates afresh on
  # every draw and no journal can replay, so references compare equal here.
  # A map or struct becomes its sorted pairs, so the order of reference
  # keys, which follows the references themselves, does not matter.
  defp without_refs(term) when is_reference(term), do: :ref
  defp without_refs(term) when is_list(term), do: list_without_refs(term)

  defp without_refs(%{} = map),
    do:
      {:map,
       map
       |> Map.to_list()
       |> Enum.map(fn {k, v} -> {without_refs(k), without_refs(v)} end)
       |> Enum.sort()}

  defp without_refs(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&without_refs/1) |> List.to_tuple()

  defp without_refs(term), do: term

  # Chardata and iodata may be improper lists.
  defp list_without_refs([head | tail]), do: [without_refs(head) | list_without_refs(tail)]
  defp list_without_refs([]), do: []
  defp list_without_refs(tail), do: without_refs(tail)

  describe "a drawn plan's journal replays to the identical plan" do
    for model <- [Tree.ForestModel, Tree.TermModel, Tree.IodataModel, Tree.ChardataModel] do
      test "for #{inspect(model)} on seeds 1 to 20" do
        mismatched =
          for seed <- 1..20,
              plan = Next.plan(unquote(model), seed, [max_steps: 3] ++ @engine),
              again = Next.plan(unquote(model), plan.journal, @engine),
              without_refs({again.steps, again.journal}) !=
                without_refs({plan.steps, plan.journal}),
              do: seed

        assert mismatched == [], "#{length(mismatched)} of 20 seeds replayed differently"
      end
    end
  end

  describe "the shrinker lowers a level size" do
    # The values of the level-size draws of the tree field: inside
    # Tree.Single, only they are drawn from a range whose lower bound is 1.
    defp level_sizes(journal) do
      for {{_slot, :command, :tree}, entry} <- journal.entries,
          {_position, {value, 1, _hi}} <- StreamDataSource.positions(entry),
          do: value
    end

    defp nodes(list) when is_list(list), do: 1 + (list |> Enum.map(&nodes/1) |> Enum.sum())
    defp nodes(_leaf), do: 1

    test "a tree of at least 4 nodes shrinks to lower level sizes and fewer nodes" do
      fails? = fn %Tree.Single{tree: tree}, _earlier -> nodes(tree) >= 4 end

      shrinks =
        for seed <- 1..20,
            {:error, %Failure{} = failure} <-
              [
                Next.run(
                  [
                    model: Tree.SingleModel,
                    adapter: Shrink.Adapter,
                    seed: seed,
                    max_steps: 1,
                    max_plans: 200,
                    config: %{fails?: fails?}
                  ] ++ @engine
                )
              ] do
          [%Tree.Single{tree: first}] = Enum.map(failure.original.plan.steps, & &1.command)
          [%Tree.Single{tree: shrunk}] = Enum.map(failure.plan.steps, & &1.command)

          {level_sizes(failure.original.journal), level_sizes(failure.journal), nodes(first),
           nodes(shrunk)}
        end

      assert length(shrinks) >= 10

      # Every first failing plan recorded its level sizes.
      assert Enum.all?(shrinks, fn {first, _shrunk, _, _} -> first != [] end)

      for {first, shrunk, first_nodes, shrunk_nodes} <- shrinks do
        assert Enum.sum(shrunk) <= Enum.sum(first)
        assert shrunk_nodes <= first_nodes
      end

      assert Enum.any?(shrinks, fn {first, shrunk, _, _} -> Enum.sum(shrunk) < Enum.sum(first) end)
    end
  end
end
