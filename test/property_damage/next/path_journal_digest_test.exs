defmodule PropertyDamage.Next.PathJournalDigestTest do
  # A journal of a model that states no paths is byte-identical to one
  # saved before paths existed. The digests below were computed in a fresh
  # OS process (`mix run`) on code without paths, from plans of existing
  # fixture models: the scheme model on four seeds, and the scheme model
  # with two assigns on two seeds. A plan journal with one extra entry, or
  # one changed entry, gives a different digest.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Journal
  alias PropertyDamage.Next.Test.LayerJournal
  alias PropertyDamage.Next.Test.Scheme

  @digests [
    {Scheme.Model, 1, "45d541811d40237cfa5b83ec361565e307ee4a4b1cd404404e2b970201391fe3"},
    {Scheme.Model, 2, "23ee011ae5fff18c61b3cc71af7a90ed7bc60a7136df25f0d92f63110c0bbe49"},
    {Scheme.Model, 3, "ca131aa04018001900c459b994f8eb23ff13b2bf3fa8f8bcbd697b45aa1904d1"},
    {Scheme.Model, 4, "9a2a207688197981c547d2b1d01c28349df482d3349277319068d7f3736e0e7b"},
    {LayerJournal.Base, 1, "c68838804c1b2a060f7fb56f0d4b2b875e6b4488c201a389b9608d7b387b7e66"},
    {LayerJournal.Base, 2, "8873c09274a683f364ed1be1cde8e8a75b90175e17c0af90cbe04963e113a267"}
  ]

  defp digest(journal) do
    journal
    |> Journal.to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  for {model, seed, expected} <- @digests do
    test "#{inspect(model)} on seed #{seed} saves the same bytes as before paths existed" do
      journal = Next.plan(unquote(model), unquote(seed), max_steps: 20).journal

      assert digest(journal) == unquote(expected)
      refute journal.entries |> Map.keys() |> Enum.any?(&match?({_, :path}, &1))
    end
  end

  test "the journal with assigns holds assign entries, so its digest covers them" do
    journal = Next.plan(LayerJournal.Base, 1, max_steps: 20).journal

    assert journal.entries |> Map.keys() |> Enum.any?(&match?({_, :assigns, _}, &1))
  end
end
