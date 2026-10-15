defmodule PropertyDamage.ShrinkExpansionAxisTest do
  # Between dropping roots and simplifying arguments, the shrinker collapses
  # what each target ran at each surviving root: the reference toward the
  # root itself, then every other target onto the reference's choice. A
  # divergence that only one entry exposes keeps that entry in the target
  # that has the bug, against a reference that runs the root itself; a
  # divergence every entry shows ends with both targets running the same
  # commands, which puts the bug in the implementation rather than in a path.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Expansion, Failure, FailureReport, Generator, Placeholder, Sequence}
  alias PropertyDamage.Options
  alias PropertyDamage.Shrinker
  alias PropertyDamage.Shrinker.Config
  alias PropertyDamage.Test.ExpansionFor, as: F
  alias PropertyDamage.Test.ShrinkAxis, as: A

  defp run(model, targets, opts) do
    PropertyDamage.run(
      [
        model: model,
        targets: targets,
        compare: [converge_within: 1],
        max_runs: 1,
        replay_dir: false
      ] ++ opts
    )
  end

  # The report of the first seed in 1..60 whose one run fails.
  defp failing!(model, targets, opts) do
    Enum.find_value(1..60, fn seed ->
      result = run(model, targets, [seed: seed] ++ opts)
      F.drain()

      case result do
        {:error, %FailureReport{} = report} -> report
        {:ok, _stats} -> nil
      end
    end) || flunk("no seed in 1..60 fails")
  end

  # The first seed in 1..60 whose one run fails, unshrunk.
  defp failing_seed!(model, targets, opts) do
    Enum.find(1..60, fn seed ->
      result = run(model, targets, [seed: seed, shrink: false] ++ opts)
      F.drain()
      match?({:error, _}, result)
    end) || flunk("no seed in 1..60 fails")
  end

  defp identity(report),
    do: {report.kind, Failure.name(report.failure_reason), report.variant.index}

  defp roots(report), do: report |> FailureReport.shrunk_sequence() |> Sequence.to_list()

  defp ran(report, name, root), do: report.trace.expansion |> Map.fetch!(name) |> Enum.at(root)

  # "second" answers one too many on the second Part of a two-Part entry.
  defp parts_bug, do: [A.target("ref"), A.target("second", :random, %{bug: :part1})]

  test "a divergence one entry exposes shrinks to that entry against a reference running the root" do
    seed = failing_seed!(A.PartsModel, parts_bug(), max_commands: 8)

    {:error, unshrunk} =
      run(A.PartsModel, parts_bug(), seed: seed, max_commands: 8, shrink: false)

    {:error, report} = run(A.PartsModel, parts_bug(), seed: seed, max_commands: 8)
    F.drain()

    assert identity(report) == identity(unshrunk)
    assert identity(report) == {:diverged, {A.Sum, :sum}, 1}
    assert length(roots(report)) == 1
    assert report.failed_at_index == 0

    # The function does not list the root alone: the reference runs it as
    # itself, recorded as reached by shrinking.
    assert %{entry: :identity, leaves?: false} = ran(report, "ref", 0)
    assert %{entry: "Add[1]", leaves?: true} = ran(report, "second", 0)
  end

  test "the reference collapses alone after the second target copied its entry at that root" do
    # At seed 8 the reference's identity at root 0 is invalid in the first
    # cycle (its Take at root 1 needs a Part before it), so the second
    # target first copies the reference's Add[1] there. Once the Take is
    # gone, the reference reaches the identity while the second target keeps
    # Add[1], whose second Part has the bug.
    opts = [seed: 8, max_commands: 6, seed_library: false]
    {:error, unshrunk} = run(A.StateModel, parts_bug(), [shrink: false] ++ opts)
    {:error, report} = run(A.StateModel, parts_bug(), opts)
    F.drain()

    assert {report.kind, Failure.name(report.failure_reason), report.variant.name} ==
             {unshrunk.kind, Failure.name(unshrunk.failure_reason), "second"}

    assert length(roots(report)) == 1
    assert report.failed_at_index == 0
    assert %{entry: "Add[0]", leaves?: false} = ran(report, "ref", 0)
    assert %{entry: "Add[1]", leaves?: true} = ran(report, "second", 0)
  end

  test "a divergence every entry shows collapses the second target onto the reference's choice" do
    targets = [A.target("ref"), A.target("second", :random, %{bug: :every})]
    report = failing!(A.PartsModel, targets, max_commands: 8)

    assert report.variant.name == "second"
    ref = ran(report, "ref", report.failed_at_index)
    second = ran(report, "second", report.failed_at_index)

    assert {second.entry, second.commands} == {ref.entry, ref.commands}
    assert Enum.at(report.expansions["second"], report.failed_at_index).entry == ref.entry
  end

  test "a :reference target runs what the reference runs in every candidate" do
    targets = parts_bug() ++ [A.target("third", :reference)]
    seed = failing_seed!(A.PartsModel, targets, max_commands: 8)

    assert {:error, report} = run(A.PartsModel, targets, seed: seed, max_commands: 8)
    messages = F.drain()

    ref = F.segments(messages, "ref")
    third = F.segments(messages, "third")

    assert report.shrink_iterations > 0
    assert third == ref
    # The reference collapsed in some candidate, and the copy followed it.
    assert Enum.any?(ref, fn executed -> Enum.any?(executed, &is_struct(&1, A.Add)) end)
  end

  test "leaf arguments shrink toward the generator's least value, overrides and placeholders kept" do
    report = failing!(A.AccountModel, parts_bug(), max_commands: 8)
    root = Enum.at(roots(report), report.failed_at_index)
    second = ran(report, "second", report.failed_at_index)

    assert %{entry: "Add[1]", commands: [first, last]} = second
    assert Enum.map(second.commands, & &1.memo) == [0, 0]

    # The overrides: still decide every other field, from the shrunk root.
    assert {first.amount, first.part} == {div(root.amount, 2), 0}
    assert {last.amount, last.part} == {root.amount - div(root.amount, 2), 1}
    assert %Placeholder{} = root.account
    assert first.account == root.account and last.account == root.account

    # The run drew them above the least value.
    {:ok, drawn} = Expansion.for(A.AccountModel, report.seed, 1, "second", max_commands: 8)
    memos = for %{leaves?: true, commands: leaves} <- drawn.choices, leaf <- leaves, do: leaf.memo
    assert Enum.any?(memos, &(&1 > 0))
  end

  test "a candidate whose carried entry the function no longer returns never runs" do
    targets = [A.target("ref", :random, %{bug: :part}), A.target("second")]
    seed = state_seed!(targets)

    assert {:error, report} = run(A.StateModel, targets, seed: seed, max_commands: 2)
    messages = F.drain()
    [add, _take] = Sequence.to_list(report.original_sequence)

    # "second" ran the Add as Parts and the Take as Pieces, which the Take
    # offers only after a Part ran. Running the Add as itself while still
    # carrying the Pieces would run an entry the function does not return:
    # no execution of "second" ever did.
    for executed <- F.segments(messages, "second") do
      refute add in executed and Enum.any?(executed, &is_struct(&1, A.Piece)),
             "second ran the Add as itself and the Take as Pieces: #{inspect(executed)}"
    end

    # Both roots collapsed onto the reference once the Take no longer needed
    # the Pieces.
    for root <- 0..1 do
      assert {ran(report, "second", root).entry, ran(report, "second", root).commands} ==
               {ran(report, "ref", root).entry, ran(report, "ref", root).commands}
    end
  end

  # A seed whose roots are an Add then a Take, where the reference runs the
  # Add as itself and the Take as Parts, and "second" runs the Add as Parts
  # and the Take as Pieces (offered only after a Part ran).
  defp state_seed!(targets) do
    Enum.find(1..5_000, fn seed ->
      with {:ok, ref} <-
             Expansion.for(A.StateModel, seed, 1, "ref", targets: targets, max_commands: 2),
           {:ok, second} <-
             Expansion.for(A.StateModel, seed, 1, "second", targets: targets, max_commands: 2) do
        match?([%A.Add{}, %A.Take{}], ref.roots) and
          Enum.map(ref.choices, & &1.entry) == ["Add[0]", "Take[1]"] and
          Enum.map(second.choices, & &1.entry) == ["Add[1]", "Take[2]"]
      end
    end) || flunk("no seed in 1..5000 draws the entries this test needs")
  end

  test "the setup commands and their arguments survive every candidate unchanged" do
    targets = [F.target("ref"), F.target("second", :random, %{bug: :credit})]

    assert {:error, report} = run(F.Model, targets, seed: 2, max_commands: 8)
    messages = F.drain()
    {:ok, generated} = Expansion.for(F.Model, 2, 1, "ref", targets: targets, max_commands: 8)

    # The reference collapsed to the listed identity at the failing root.
    assert %{entry: "Refund[0]", leaves?: false} = ran(report, "ref", report.failed_at_index)
    assert report.setup_commands == generated.prefix

    for name <- ["ref", "second"], executed <- F.segments(messages, name) do
      assert Enum.take(executed, length(generated.prefix)) == generated.prefix
    end
  end

  test "the cycle reaches a fixed point within the budget" do
    entries = [F.target("ref"), F.target("second", :random, %{bug: :credit})]
    {:ok, targets} = Options.validate_targets(entries)

    assert {:error, found} = run(F.Model, entries, seed: 2, max_commands: 8, shrink: false)
    F.drain()

    sequence =
      F.Model
      |> Generator.generate_sequence(max_commands: 8)
      |> Generator.generate_value(found.seed)

    config = Config.new()

    opts = [
      failed_at_index: found.failed_at_index,
      failure_reason: found.failure_reason,
      variant_index: found.variant.index,
      model: F.Model,
      targets: targets,
      compare: [converge_within: 1],
      rng_seed: found.seed,
      config: config
    ]

    expansion = Expansion.expand(F.Model, sequence, targets, found.seed)
    result = Shrinker.shrink(sequence, opts ++ [expansion: expansion])
    F.drain()

    assert result.cycles >= 2
    assert result.iterations > 0 and result.iterations < config.max_iterations

    # Shrinking the result again adopts nothing: one cycle, the same roots.
    traced = Map.new(result.expansion.variants, fn {name, variant} -> {name, variant.choices} end)

    again =
      Shrinker.shrink(
        result.sequence,
        Keyword.merge(opts,
          failed_at_index: length(Sequence.to_list(result.sequence)) - 1,
          expansion: traced,
          root_ids: Expansion.root_ids(traced)
        )
      )

    F.drain()

    assert again.cycles == 1
    assert Sequence.to_list(again.sequence) == Sequence.to_list(result.sequence)
  end

  test "the report counts the shrunk run, a collapsed root as identity, by shrinking" do
    report = failing!(A.PartsModel, parts_bug(), max_commands: 8)

    assert report.expansion_counts == %{
             "ref" => %{A.Add => %{identity: 1}},
             "second" => %{A.Add => %{"Add[1]" => 1}}
           }

    text = FailureReport.Formatter.format(report, :terminal, color: false)
    assert text =~ "identity, by shrinking"
  end
end
