defmodule PropertyDamage.Next.SutBoundaryTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.StepSpec
  alias PropertyDamage.Next.Test.Leak
  alias PropertyDamage.Next.Test.Scheme.{Adapter, Lookup, Model, Pay, Refund}
  alias PropertyDamage.Next.Test.Scheme.Events.Paid

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @max_steps 20

  defmodule Layers do
    @moduledoc false
    alias PropertyDamage.Next.{Gen, StepSpec}
    alias PropertyDamage.Next.Test.Scheme.{Pay, Refund}

    # Every payment gets its own amount, so an amount names one payment.
    def distinct_amounts(%StepSpec{command: Pay} = spec),
      do: StepSpec.update_command(spec, &count_up/2)

    def distinct_amounts(spec), do: spec

    def count_up(fields, state) do
      n = 100 + length(state.order)
      Map.put(fields, :amount, Gen.integer(n..n))
    end

    # A refund carries, for the ports, the payment it targets and a request id.
    def refund_assigns(%StepSpec{command: Refund} = spec) do
      spec
      |> StepSpec.assign_from_command(:target, &target_of/1)
      |> StepSpec.assign(:request, PropertyDamage.mint_per_run(:uuid))
    end

    def refund_assigns(spec), do: spec

    def target_of(%Refund{payment: payment}), do: Gen.member_of([payment])

    def any_payment?(state), do: state.order != []
  end

  defmodule BoundaryModel do
    @moduledoc false
    use PropertyDamage.Next.Test.Scheme.Variants

    def steps do
      (Model.steps() ++ StepSpec.normalize([{Lookup, when: &Layers.any_payment?/1}]))
      |> StepSpec.transform([&Layers.distinct_amounts/1, &Layers.refund_assigns/1])
    end
  end

  # Executes `journal` once and returns what the adapter received, in order.
  defp execute(journal) do
    assert {:ok, _} =
             Next.replay(journal,
               model: BoundaryModel,
               adapter: Adapter,
               config: %{recorder: self()},
               max_steps: @max_steps
             )

    collect([])
  end

  defp collect(acc) do
    receive do
      {:scheme_executed, command, assigns, result} -> collect([{command, assigns, result} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp journal(seed), do: Next.plan(BoundaryModel, seed, max_steps: @max_steps).journal

  defp minted_amounts(calls) do
    for {%Pay{}, _assigns, {:ok, [%Paid{payment: id, amount: amount}]}} <- calls,
        into: %{},
        do: {id, amount}
  end

  test "no PD identifier reaches the adapter, in a command or in its assigns" do
    for seed <- 1..10, {command, assigns, _result} <- execute(journal(seed)) do
      assert Leak.find(command) == [], "command #{inspect(command)} holds PD terms"
      assert Leak.find(assigns) == [], "assigns #{inspect(assigns)} hold PD terms"
    end
  end

  test "a placeholder resolves to the id the system minted for the payment at that slot" do
    counts =
      for seed <- 1..10 do
        calls = execute(journal(seed))
        amounts = minted_amounts(calls)

        lookups = for {%Lookup{} = lookup, _, _} <- calls, do: lookup
        refunds = for {%Refund{} = refund, assigns, _} <- calls, do: {refund, assigns}

        for lookup <- lookups do
          assert Map.fetch!(amounts, lookup.payment) == lookup.expected_amount
        end

        for {refund, assigns} <- refunds do
          assert Map.has_key?(amounts, refund.payment)
          assert assigns.target == refund.payment
        end

        {length(lookups), length(refunds)}
      end

    assert counts |> Enum.map(&elem(&1, 0)) |> Enum.sum() > 0
    assert counts |> Enum.map(&elem(&1, 1)) |> Enum.sum() > 0
  end

  test "a mint is a concrete value, fresh per execution of the same journal" do
    journal = journal(7)
    first = execute(journal)
    second = execute(journal)

    minted = fn calls ->
      for {command, assigns, _} <- calls,
          value <- [Map.get(command, :idempotency_key), Map.get(assigns, :request)],
          value != nil,
          do: value
    end

    first_values = minted.(first)
    second_values = minted.(second)

    assert first_values != []
    assert Enum.all?(first_values ++ second_values, &(is_binary(&1) and &1 =~ @uuid))
    assert Enum.uniq(first_values) == first_values
    assert MapSet.disjoint?(MapSet.new(first_values), MapSet.new(second_values))

    without_mints = fn calls ->
      for {command, assigns, result} <- calls,
          do: {Map.delete(command, :idempotency_key), Map.delete(assigns, :request), result}
    end

    assert without_mints.(first) == without_mints.(second)
  end
end
