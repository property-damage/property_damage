defmodule PropertyDamage.ExpansionDocIdentityTest do
  # A root that ran as itself under a listed key takes the doc of the entry at
  # that index only while that entry is the listed identity. After the list
  # shifts, an entry that is not the identity gives it no doc.
  use ExUnit.Case, async: false

  alias PropertyDamage.{Expansion, Sequence}
  alias PropertyDamage.Test.ExpansionDoc, as: D
  alias PropertyDamage.Test.ExpansionDoc.{Flag, Model, Pay}

  setup do
    D.put_spec(%{
      front: {[D.leaf(2)], 1, "front route"},
      base: [{:root, 1, "identity route"}, {[D.leaf(1)], 1, "leaf route"}]
    })

    :ok
  end

  defp identity_choice(index) do
    %{
      root: 1,
      root_id: 1,
      module: Pay,
      entry: "Pay[#{index}]",
      index: index,
      doc: nil,
      commands: [%Pay{amount: 1}],
      leaves?: false,
      seed_key: nil,
      aliases: %{}
    }
  end

  defp flag_choice do
    %{identity_choice(0) | root: 0, root_id: 0, module: Flag, entry: nil, index: nil}
    |> Map.put(:commands, [%Flag{}])
  end

  defp carried_doc(roots, choices) do
    %{choices: choices} = Expansion.carried(Model, Sequence.linear(roots), choices)
    List.last(choices).doc
  end

  test "a listed identity keeps the doc of the identity entry at its index" do
    assert carried_doc([%Pay{amount: 1}], [%{identity_choice(0) | root: 0, root_id: 0}]) ==
             "identity route"
  end

  test "a shifted index that now names another entry gives the root no doc" do
    # With the flag set the front entry sits at index 0, so index 0 is no
    # longer the identity.
    assert carried_doc([%Flag{}, %Pay{amount: 1}], [flag_choice(), identity_choice(0)]) == nil
  end
end
