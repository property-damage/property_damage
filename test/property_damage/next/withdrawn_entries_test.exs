defmodule PropertyDamage.Next.WithdrawnEntriesTest do
  # While the shrinker searches, a withdrawn slot keeps its pick and its field
  # entries in the journal of the rebuilt plan, so the command comes back with
  # the values it had if a later edit offers it again. A final journal drops
  # them (see the shrinker's tests).
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Journal, Step}
  alias PropertyDamage.Next.Test.Scheme.{Model, Pay, Refund}
  alias PropertyDamage.Next.Test.Terms

  @max_steps 4

  defp plan(seed_or_journal), do: Next.plan(Model, seed_or_journal, max_steps: @max_steps)

  defp with_amount(%Journal{} = journal, amount) do
    key = {{0, 1}, :command, :amount}
    %{journal | entries: Map.put(journal.entries, key, {:integer, amount, 1..1000})}
  end

  # A seed whose plan pays once, at slot 1, and then refunds more than 1:
  # making that payment too small to refund withdraws every later slot.
  defp seed_paying_once_then_refunding do
    Enum.find(1..2_000, fn seed ->
      case plan(seed).steps do
        [%Step{key: {0, 1}, command: %Pay{amount: amount}} | rest] ->
          amount > 1 and not Enum.any?(rest, &match?(%Step{command: %Pay{}}, &1)) and
            Enum.any?(rest, &match?(%Step{command: %Refund{amount: a}} when a > 1, &1))

        _ ->
          false
      end
    end) || flunk("no seed pays once at slot 1 and then refunds more than 1")
  end

  # That seed's plan with every refund lowered to 1, as a shrinker would
  # lower it, so the stored amounts differ from what the keys draw afresh.
  defp lowered_plan do
    original = plan(seed_paying_once_then_refunding())

    entries =
      Enum.reduce(original.steps, original.journal.entries, fn
        %Step{key: key, command: %Refund{}}, entries ->
          Map.update!(entries, {key, :command, :amount}, fn {:integer, _, range} ->
            {:integer, 1, range}
          end)

        _step, entries ->
          entries
      end)

    lowered = plan(%{original.journal | entries: entries})
    assert lowered.steps != original.steps
    lowered
  end

  test "a withdrawn slot keeps its pick and field entries in the rebuilt journal" do
    original = lowered_plan()
    [_pay | later] = original.steps

    withdrawn = plan(with_amount(original.journal, 1))

    assert Enum.map(withdrawn.steps, & &1.key) == [{0, 1}]

    for %Step{key: key} <- later do
      assert Enum.any?(withdrawn.withdrawn, &Terms.mentions?(&1, key))

      for {entry_key, entry} <- original.journal.entries, elem(entry_key, 0) == key do
        assert withdrawn.journal.entries[entry_key] == entry,
               "#{inspect(entry_key)} was not kept while its slot was withdrawn"
      end
    end
  end

  test "rebuilding the search journal again keeps the withdrawn slots and their entries" do
    original = lowered_plan()
    withdrawn = plan(with_amount(original.journal, 1))
    again = plan(withdrawn.journal)

    assert again.steps == withdrawn.steps
    assert again.withdrawn == withdrawn.withdrawn
    assert again.journal.entries == withdrawn.journal.entries
  end

  test "a later edit that offers the command again brings it back with its stored values" do
    original = lowered_plan()
    [%Step{command: %Pay{amount: amount}} | _] = original.steps

    withdrawn = plan(with_amount(original.journal, 1))
    returned = plan(with_amount(plan(withdrawn.journal).journal, amount))

    assert returned.steps == original.steps
    assert returned.withdrawn == []
  end
end
