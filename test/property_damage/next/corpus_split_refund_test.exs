defmodule PropertyDamage.Next.CorpusSplitRefundTest do
  # The split refund entry of the next corpus: a refund of a payment that
  # already had a refund is credited one unit short, and only the comparison
  # of a plan's two executions can see it. Both corpus engines find it and
  # the bug fires on the final plan. The same model without paths finds
  # nothing, and with the bug off the entry is clean.
  #
  # async: false because the corpus support files load once for the whole VM.
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag timeout: 900_000

  alias PropertyDamage.Corpus.{Engine, Entry, Loader}

  @corpus "corpus/next"
  @name "split_refund"
  @plan_cap 200

  setup_all do
    {:ok, [%Entry{name: @name} = entry]} = Loader.load(@corpus, [@name])
    {:ok, entry: entry}
  end

  for {engine, corpus_engine} <- [{"native", Engine.Next}, {"source", Engine.NextSource}] do
    @corpus_engine corpus_engine

    tag = if engine == "source", do: :patched_stream_data, else: :split_refund
    @tag tag
    test "the #{engine} engine finds the bug with it firing on the final plan", %{entry: entry} do
      entry = %{entry | engine: @corpus_engine}

      for seed <- 1..4 do
        result = @corpus_engine.run(entry, seed, @plan_cap)

        assert result.found?, "seed #{seed}: bug not found"
        assert result.bug_fired?, "seed #{seed}: failed without the bug firing on the final plan"
        assert Enum.any?(result.shrunk, &match?(%{command: :refund, path: [_, _]}, &1))
      end
    end

    @tag tag
    test "the #{engine} engine finds nothing without paths on seeds 1 to 20", %{entry: entry} do
      entry = %{entry | engine: @corpus_engine, model: Corpus.Next.Scheme.UnsplitModel}

      for seed <- 1..20 do
        result = @corpus_engine.run(entry, seed, @plan_cap)

        refute result.found?, "seed #{seed}: found without paths"
      end
    end

    @tag tag
    test "the #{engine} engine finds nothing with the bug off", %{entry: entry} do
      entry = %{entry | engine: @corpus_engine, bug: nil}

      for seed <- 1..5 do
        result = @corpus_engine.run(entry, seed, @plan_cap)

        refute result.found?, "seed #{seed}: failed with the bug off"
        assert result.fires == 0
      end
    end
  end
end
