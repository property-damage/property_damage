defmodule PropertyDamage.ExpansionDocShrinkTest do
  # Shrinking cannot misattribute a doc. A shrink candidate carries the index
  # of the entry each root ran, and dropping a root can change the list the
  # expansion function returns, so the index may name another entry in the
  # candidate than in the failing run. The doc of a surviving choice must be
  # the doc of the entry its commands realize, whatever the index says.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias PropertyDamage.Expansion
  alias PropertyDamage.Test.ExpansionDoc, as: D

  @max_runs 150
  @leaves 5
  @entries 7

  # A spec for `ExpansionDoc.Model`: the front entry (listed only while a
  # `Flag` root ran) and the base entries. The sequences all differ, the docs
  # differ or are absent, the weights vary and one base entry may be the
  # listed identity.
  defp spec_gen do
    sequence =
      StreamData.list_of(StreamData.member_of(Enum.map(1..@leaves, &D.leaf/1)),
        min_length: 1,
        max_length: 3
      )

    gen all(
          sequences <-
            StreamData.uniq_list_of(sequence, min_length: 4, max_length: @entries),
          weights <- StreamData.list_of(StreamData.integer(1..4), length: @entries),
          words <-
            StreamData.list_of(StreamData.string(:alphanumeric, min_length: 1, max_length: 5),
              length: @entries
            ),
          documented <-
            StreamData.list_of(StreamData.frequency([{3, true}, {1, false}]), length: @entries),
          identity? <- StreamData.boolean()
        ) do
      entries =
        [sequences, weights, words, documented, Enum.to_list(0..(@entries - 1))]
        |> Enum.zip()
        |> Enum.map(fn {sequence, weight, word, documented?, i} ->
          {sequence, weight, if(documented?, do: "route #{i} #{word}")}
        end)

      [front | base] = entries

      base =
        if identity?,
          do: List.update_at(base, -1, fn {_sequence, weight, doc} -> {:root, weight, doc} end),
          else: base

      %{front: front, base: base}
    end
    |> StreamData.resize(20)
  end

  defp case_gen do
    gen all(
          spec <- spec_gen(),
          seed <- StreamData.integer(1..100_000),
          fail <- StreamData.integer(1..@leaves)
        ) do
      {spec, seed, fail}
    end
  end

  # The failing report of the run, or nil when the run passes.
  defp failing_report({spec, seed, fail}) do
    D.put_spec(spec)

    case D.run(seed: seed, fail: D.leaf(fail)) do
      {:error, report} -> report
      {:ok, _stats} -> nil
    end
  end

  defp modules(choice), do: Enum.map(choice.commands, & &1.__struct__)

  # Every choice of every target of the report names the doc written for the
  # sequence its commands realize.
  defp assert_docs_match(report, spec) do
    docs = D.docs_by_modules(spec)

    for {name, choices} <- report.trace.expansion, choice <- choices do
      doc = Map.fetch!(choice, :doc)

      if is_integer(choice.index) do
        assert {:ok, written} = Map.fetch(docs, modules(choice)),
               "#{name} root #{choice.root_id} ran #{inspect(modules(choice))}, an entry the spec does not list"

        assert doc == written,
               "#{name} root #{choice.root_id} (#{choice.entry}) ran #{inspect(modules(choice))}: " <>
                 "its doc is #{inspect(doc)}, written for it: #{inspect(written)}"
      else
        assert doc == nil,
               "#{name} root #{choice.root_id} ran without an entry but has the doc #{inspect(doc)}"
      end
    end
  end

  # The spec the two tests below pin: the front entry is listed only while a
  # Flag root ran, ahead of the base entries.
  defp pinned_spec do
    %{
      front: {[D.leaf(1), D.leaf(2)], 1, "front route"},
      base: [
        {[D.leaf(3)], 2, "third leaf"},
        {[D.leaf(1), D.leaf(4)], 1, "first then fourth"},
        {:root, 1, "the root, unchanged"},
        {[D.leaf(5), D.leaf(3)], 1, nil}
      ]
    }
  end

  property "every surviving choice of a shrunk report has the doc of the entry its commands realize" do
    check all({spec, _seed, _fail} = generated <- case_gen(), max_runs: @max_runs) do
      case failing_report(generated) do
        nil -> :ok
        report -> assert_docs_match(report, spec)
      end
    end
  end

  test "the generator gives failing runs often enough for the property to mean something" do
    samples = Enum.take(case_gen(), 30)
    failing = Enum.count(samples, &failing_report/1)

    assert failing >= 10
  end

  # Found by search: with this spec, seed 13 fails on Leaf3 and the shrunk
  # report keeps one Pay root, at root id 1. Before the shrink it ran index 0,
  # the front entry (Leaf1, Leaf2), listed because a Flag root came first.
  # The shrink dropped the Flag roots, so index 0 names another entry now
  # (Leaf3) and the carried index no longer says which entry the root ran.
  @seed 13
  @fail 3

  defp before_and_after do
    spec = pinned_spec()
    D.put_spec(spec)

    assert {:error, report} = D.run(seed: @seed, fail: D.leaf(@fail))

    assert {:ok, %{choices: before}} =
             Expansion.for(D.Model, report.seed, 1, "a", max_commands: 6)

    {spec, report, before}
  end

  test "the generator can make a carried index name another entry after shrinking" do
    {_spec, report, before} = before_and_after()

    by_root = Map.new(before, &{&1.root_id, &1})

    shifted =
      for choice <- report.trace.expansion["a"],
          earlier = Map.fetch!(by_root, choice.root_id),
          is_integer(choice.index),
          is_integer(earlier.index),
          modules(choice) != modules(earlier),
          do: {choice, earlier}

    assert [_ | _] = shifted
  end

  test "a doc stays with the sequence it was written for when shrinking shifts the entry list" do
    {spec, report, before} = before_and_after()
    docs = D.docs_by_modules(spec)

    earlier = Enum.find(before, &(&1.module == D.Pay and &1.root_id == 1))
    assert modules(earlier) == [D.leaf(1), D.leaf(2)]
    assert Map.fetch!(earlier, :doc) == "front route"

    [pay] = Enum.filter(report.trace.expansion["a"], &(&1.module == D.Pay))
    assert modules(pay) == [D.leaf(3)]
    assert Map.fetch!(pay, :doc) == "third leaf"
    assert Map.fetch!(pay, :doc) == Map.fetch!(docs, [D.leaf(3)])
  end
end
