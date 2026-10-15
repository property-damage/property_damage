defmodule PropertyDamage.ExpansionRewriteIdentityTest do
  # An entry whose one leaf equals the root it rewrites runs the root itself:
  # a run realizes it as the root (at the root's position, with no alias), a
  # replay of the recorded choice agrees, and the counts and the sample
  # behind `mix pd.validate --seeds` count it as identity, not under the
  # entry's key.
  use ExUnit.Case, async: true

  alias PropertyDamage.{Expansion, Generator, Options}
  alias PropertyDamage.Test.ReplayFixtures, as: R
  alias PropertyDamage.Test.ReplayFixtures.LeafRootModel

  @seed 3

  setup do
    {:ok, targets} = Options.validate_targets([R.target("ref")])

    sequence =
      LeafRootModel
      |> Generator.generate_sequence(max_commands: 3)
      |> Generator.generate_value(@seed)

    %{targets: targets, sequence: sequence}
  end

  test "a run realizes the entry as the root, and a replay agrees", ctx do
    realized = Expansion.expand(LeafRootModel, ctx.sequence, ctx.targets, @seed)
    choices = realized.variants["ref"].choices

    assert choices != []

    for choice <- choices do
      assert %{leaves?: false, entry: :identity, index: nil, aliases: aliases} = choice
      assert aliases == %{}
      assert Expansion.steps([choice]) == [[{hd(choice.commands), nil}]]
    end

    replayed =
      Expansion.recorded(LeafRootModel, ctx.sequence, @seed, %{"ref" => choices}, %{})

    shape = &Map.take(&1, [:root_id, :entry, :index, :commands, :leaves?, :aliases])
    assert Enum.map(replayed.variants["ref"].choices, shape) == Enum.map(choices, shape)
  end

  test "the counts and the sample count it as identity, not under its key", ctx do
    realized = Expansion.expand(LeafRootModel, ctx.sequence, ctx.targets, @seed)
    roots = length(realized.variants["ref"].choices)

    assert Expansion.counts(realized) == %{"ref" => %{R.Open => %{identity: roots}}}

    sample = Expansion.sample(LeafRootModel, ctx.targets, [@seed], max_commands: 3)

    assert sample.realized == %{}
    assert sample.identity == %{R.Open => roots}
    assert sample.leaves == MapSet.new()
  end
end
