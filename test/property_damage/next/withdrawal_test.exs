defmodule PropertyDamage.Next.WithdrawalTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Step}
  alias PropertyDamage.Next.Test.Scheme.{Adapter, Model, NoRefundModel, Pay, Refund}
  alias PropertyDamage.Next.Test.Terms

  @max_steps 10

  defp plan(model, seed_or_journal), do: Next.plan(model, seed_or_journal, max_steps: @max_steps)

  defp refund_spec_id do
    Enum.find_value(1..200, fn seed ->
      Enum.find_value(plan(Model, seed).steps, fn
        %Step{command: %Refund{}, spec_id: id} -> id
        _ -> nil
      end)
    end)
  end

  # The journal of `seed`'s plan with the pick at slot 1 changed to Refund,
  # which is never offered at slot 1: no payment exists yet.
  defp refund_at_slot_one(seed) do
    journal = plan(Model, seed).journal
    entries = Map.put(journal.entries, {{0, 1}, :pick}, {:pick, refund_spec_id(), Refund})
    %{journal | entries: entries}
  end

  defp withdrawn_names?(withdrawn, key, module),
    do: Enum.any?(withdrawn, &(Terms.mentions?(&1, key) and Terms.mentions?(&1, module)))

  # A seed whose plan pays at slots 1 and 2 and whose plan, once slot 1 is
  # withdrawn, still holds a refund.
  defp seed_paying_twice_then_refunding do
    Enum.find(1..1_000, fn seed ->
      match?([%Step{command: %Pay{}}, %Step{command: %Pay{}} | _], plan(Model, seed).steps) and
        Enum.any?(
          plan(Model, refund_at_slot_one(seed)).steps,
          &match?(%Step{command: %Refund{}}, &1)
        )
    end) || flunk("no seed pays twice and then refunds")
  end

  test "a pick no longer offered withdraws its slot; later slots still generate" do
    seed = seed_paying_twice_then_refunding()
    original = plan(Model, seed)
    rebuilt = plan(Model, refund_at_slot_one(seed))

    refute Enum.any?(rebuilt.steps, &(&1.key == {0, 1}))
    assert Enum.find(rebuilt.steps, &(&1.key == {0, 2})) == Enum.at(original.steps, 1)
    assert Enum.any?(rebuilt.steps, &match?(%Step{key: {0, slot}} when slot > 2, &1))
    assert withdrawn_names?(rebuilt.withdrawn, {0, 1}, Refund)
  end

  test "a failing run lists the withdrawn slot on its failure" do
    seed = seed_paying_twice_then_refunding()

    assert {:error, %Failure{} = failure} =
             Next.replay(refund_at_slot_one(seed),
               model: Model,
               adapter: Adapter,
               config: %{fault: :skip_credit},
               max_steps: @max_steps
             )

    assert withdrawn_names?(failure.withdrawn, {0, 1}, Refund)
  end

  test "a model whose when: no longer offers a spec withdraws exactly the slots that held it" do
    withdrawn_counts =
      for seed <- 1..20 do
        original = plan(Model, seed)
        rebuilt = plan(NoRefundModel, original.journal)

        refund_steps = Enum.filter(original.steps, &match?(%Step{command: %Refund{}}, &1))

        assert rebuilt.steps == original.steps -- refund_steps
        assert length(rebuilt.withdrawn) == length(refund_steps)

        for %Step{key: key} <- refund_steps do
          assert withdrawn_names?(rebuilt.withdrawn, key, Refund)
        end

        length(refund_steps)
      end

    assert Enum.sum(withdrawn_counts) > 0
  end

  test "a plan with every pick still offered withdraws nothing" do
    for seed <- 1..10, do: assert(plan(Model, seed).withdrawn == [])
  end
end
