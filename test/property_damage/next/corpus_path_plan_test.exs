defmodule PropertyDamage.Next.CorpusPathPlanTest do
  # How the corpus engine writes a shrunk plan whose step runs a path other
  # than the plain one: the step's map gains `path:`, the list of the picked
  # commands as plain maps. A step on its plain path has no `path:` key, so
  # every plan of a model without paths reads as before.
  #
  # async: false because the corpus engine sets the process log level.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias PropertyDamage.Corpus.{Engine, Entry}
  alias PropertyDamage.Next.Test.Paths

  defp entry do
    %Entry{
      name: "short_second_refund",
      engine: Engine.Next,
      system: Paths.System,
      bug: :short_second_refund,
      model: Paths.SplitModel,
      adapter: Paths.Adapter,
      minimum: nil,
      seeds: [1],
      max_commands: 8
    }
  end

  test "a shrunk step on a split path lists its picked commands as plain maps" do
    for seed <- 1..3 do
      result = Engine.Next.run(entry(), seed, 200)
      assert result.found?, "seed #{seed}: bug not found"

      split = Enum.filter(result.shrunk, &Map.has_key?(&1, :path))
      assert [step] = split, "seed #{seed}: expected one split step in #{inspect(result.shrunk)}"

      assert %{command: :refund, path: [first, second]} = step
      assert %{command: :refund, payment: :id} = first
      assert %{command: :refund, payment: :id} = second
      assert first.amount + second.amount == step.amount
    end
  end

  test "a step on its plain path has no path key, so the plans of other models read as before" do
    result = Engine.Next.run(entry(), 1, 200)

    for step <- result.shrunk, not Map.has_key?(step, :path) do
      assert Map.keys(step) -- [:amount, :command, :payment] == []
    end
  end
end
