defmodule PropertyDamage.Next.ValueOrderTest do
  # The shrinker lowers drawn values in three phases: one candidate with
  # every value at its minimum, then a bisection over the set of values for
  # the ones that must keep their stored value, then a bisection of each
  # kept value. After a round that adopts nothing it removes each step
  # together with the later steps that hold a placeholder of it. These tests
  # read run/1, the failure it returns and the candidates the adapter saw;
  # the dependents test drives the shrinker through a stand-in build.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Failure, Journal, Placeholder, Plan, Shrinker, Step}
  alias PropertyDamage.Next.Test.Shrink
  alias PropertyDamage.Next.Test.Shrink.{Five, Split}

  # --- Helpers

  defp run(model, fails?, opts) do
    [
      model: model,
      adapter: Shrink.Adapter,
      max_steps: 1,
      max_plans: 2_000,
      config: %{fails?: fails?, recorder: self()}
    ]
    |> Keyword.merge(opts)
    |> Next.run()
  end

  # The commands of every execution the adapter reported, in order.
  defp executions do
    collect([])
    |> Enum.reverse()
    |> Enum.reduce([], fn
      {:shrink_setup, _instance}, acc -> [[] | acc]
      {:shrink_executed, _instance, command}, [commands | acc] -> [commands ++ [command] | acc]
    end)
    |> Enum.reverse()
  end

  defp collect(acc) do
    receive do
      {:shrink_setup, _} = message -> collect([message | acc])
      {:shrink_executed, _, _} = message -> collect([message | acc])
    after
      0 -> acc
    end
  end

  # The executions after the plan that first failed: the shrink's candidates.
  defp candidates(%Failure{plan_number: number}), do: Enum.drop(executions(), number)

  defp commands(plan), do: Enum.map(plan.steps, & &1.command)

  defp five(a, b, c, d, e), do: %Five{a: a, b: b, c: c, d: d, e: e}

  # --- All values at their minimum

  describe "the candidate with every value at its minimum" do
    test "is the first value edit, and is adopted when it fails the same way" do
      for seed <- 1..4 do
        assert {:error, %Failure{} = failure} =
                 run(Shrink.FiveModel, fn _, _ -> true end, seed: seed)

        [%Five{} = first] = commands(failure.original.plan)
        refute first == five(1, 1, 1, 1, 1)

        # Block removal tries the empty plan first; the next candidate sets
        # all five values at once.
        assert [[], [all_minimum] | _] = candidates(failure)
        assert all_minimum == five(1, 1, 1, 1, 1)
        assert commands(failure.plan) == [five(1, 1, 1, 1, 1)]
      end
    end
  end

  # --- The values that must keep their stored value

  describe "the bisection over the set of values" do
    test "keeps exactly the two values of five that the failure needs" do
      fails? = fn %Five{b: b, d: d}, _ -> b >= 40 and d >= 70 end

      checked =
        for seed <- 1..10,
            {:error, %Failure{} = failure} <- [run(Shrink.FiveModel, fails?, seed: seed)],
            [%Five{} = first] = commands(failure.original.plan),
            first.a > 1 and first.c > 1 and first.e > 1 do
          tried = candidates(failure)

          # The candidate that keeps b and d and puts a, c and e at their
          # minimum is executed: the phase found the two values together.
          assert [five(1, first.b, 1, first.d, 1)] in tried

          assert commands(failure.plan) == [five(1, 40, 1, 70, 1)]
          seed
        end

      assert checked != []
    end
  end

  # --- The moved-bound retry inside the phase

  describe "a kept value that sat on a bound that moved, inside the phase" do
    test "is tried at its new bound right after the candidate that kept it" do
      fails? = fn %Split{cut: cut, rest: rest}, _ -> rest == 101 - cut end

      checked =
        for seed <- 1..8,
            {:error, %Failure{} = failure} <- [run(Shrink.SplitModel, fails?, seed: seed)],
            [%Split{cut: cut, rest: rest}] = commands(failure.original.plan),
            cut > 1 do
          tried = for [%Split{} = split] <- candidates(failure), do: {split.cut, split.rest}
          kept = Enum.find_index(tried, &(&1 == {1, rest}))

          assert kept != nil, "no candidate kept #{rest} with the cut at 1"
          assert Enum.at(tried, kept + 1) == {1, 100}
          assert commands(failure.plan) == [%Split{cut: 1, rest: 100}]
          seed
        end

      assert checked != []
    end
  end

  # --- The run budget ends inside the phase

  describe "a run budget that ends inside the phase" do
    test "adopts the failing candidate with the fewest kept values seen so far" do
      fails? = fn %Five{b: b, d: d}, _ -> b >= 40 and d >= 70 end

      checked =
        for seed <- 1..10,
            {:error, %Failure{} = failure} <- [
              run(Shrink.FiveModel, fails?, seed: seed, max_shrink_runs: 6)
            ],
            [%Five{} = first] = commands(failure.original.plan),
            Enum.all?([first.a, first.c, first.e], &(&1 > 1)) do
          assert failure.shrink_ended == :cap
          assert failure.shrink_runs == 6
          [%Five{} = final] = commands(failure.plan)

          # The final plan is a candidate the phase executed, with fewer
          # values at their stored value than the plan that first failed.
          refute final == first
          assert [final] in candidates(failure)
          assert final.b == first.b and final.d == first.d
          assert Enum.any?([final.a, final.c, final.e], &(&1 == 1))
          seed
        end

      assert checked != []
    end
  end

  # --- Removing a step with its dependents

  # A stand-in build: each live pick is a step. A payment step is `:pay`; a
  # refund names the payment slot it refunds, and refunds the first live
  # payment instead when that slot holds none. A refund with no payment
  # left is withdrawn.
  defp build(journal) do
    live =
      for({{step, :pick}, {:pick, kind}} <- journal.entries, do: {step, kind})
      |> Enum.sort()

    payments = for {step, :pay} <- live, do: step

    steps =
      Enum.flat_map(live, fn
        {step, :pay} ->
          [%Step{key: step, spec_id: 1, command: :pay}]

        {step, {:refund, target}} ->
          case if(target in payments, do: target, else: List.first(payments)) do
            nil -> []
            paid -> [%Step{key: step, spec_id: 2, command: {:refund, placeholder(paid)}}]
          end
      end)

    drawn = Enum.map(steps, &{&1.key, :pick})
    {%Plan{journal: journal, steps: steps, schedule: %{}}, drawn}
  end

  defp placeholder(step), do: %Placeholder{step: step, event_index: 0, path: [:payment]}

  @reason {:check, :refund_lost, "lost"}

  # Fails at the last step when the plan pays the second payment and
  # refunds it exactly once, and refunds the first payment exactly when it
  # pays it.
  defp execute(plan) do
    refunds = for %Step{command: {:refund, %Placeholder{step: step}}} <- plan.steps, do: step
    paid = for %Step{key: key, command: :pay} <- plan.steps, do: key

    if {0, 2} in paid and Enum.count(refunds, &(&1 == {0, 2})) == 1 and
         {0, 1} in paid == {0, 1} in refunds do
      {:error, List.last(plan.steps).key, @reason}
    else
      :ok
    end
  end

  describe "a step and the later steps that hold a placeholder of it" do
    test "are removed together, which no single block removal can do" do
      entries = %{
        {{0, 1}, :pick} => {:pick, :pay},
        {{0, 2}, :pick} => {:pick, :pay},
        {{0, 3}, :pick} => {:pick, {:refund, {0, 1}}},
        {{0, 4}, :pick} => {:pick, {:refund, {0, 2}}}
      }

      journal = %Journal{seed: 1, max_steps: 4, entries: entries}
      {plan, drawn} = build(journal)
      assert {:error, {0, 4}, @reason} = execute(plan)

      best = %{plan: plan, drawn: drawn, step: {0, 4}, reason: @reason}
      {final, _runs, ended} = Shrinker.search(best, &build/1, &execute/1, 100)

      assert ended == :done
      assert Enum.map(final.plan.steps, & &1.key) == [{0, 2}, {0, 4}]
      assert [:pay, {:refund, %Placeholder{step: {0, 2}}}] = commands(final.plan)
    end
  end

  # --- What ended the shrink

  describe "the failure says what ended the shrink" do
    test "the run budget: shrink_ended is :cap, and the printed failure says so" do
      fails? = fn %Five{b: b, d: d}, _ -> b >= 40 and d >= 70 end

      assert {:error, %Failure{} = failure} =
               run(Shrink.FiveModel, fails?, seed: 1, max_shrink_runs: 3)

      assert failure.shrink_ended == :cap
      assert failure.shrink_runs == 3

      assert Failure.format(failure) =~
               "Shrinking stopped at 3 runs (max_shrink_runs). The plan may shrink further."
    end

    test "no candidate left: shrink_ended is :done, and the printed failure has no notice" do
      fails? = fn %Five{b: b, d: d}, _ -> b >= 40 and d >= 70 end
      assert {:error, %Failure{} = failure} = run(Shrink.FiveModel, fails?, seed: 1)

      assert failure.shrink_ended == :done
      assert failure.shrink_runs < 100
      refute Failure.format(failure) =~ "Shrinking stopped"
      assert Failure.format(failure) =~ "Shrink runs: #{failure.shrink_runs}"
    end

    test "no shrink: shrink_ended is nil" do
      assert {:error, %Failure{shrink_ended: nil, shrink_runs: 0}} =
               run(Shrink.FiveModel, fn _, _ -> true end, seed: 1, shrink: false)
    end

    test "the default budget is 100 shrink runs" do
      # Each candidate passes unless every value is stored, so the shrink
      # bisects for a long time; without a cap it runs past 100.
      fails? = fn %Five{} = five, _ -> rem(five.a + five.b + five.c + five.d + five.e, 7) == 0 end

      failures =
        for seed <- 1..10,
            {:error, %Failure{} = failure} <- [run(Shrink.FiveModel, fails?, seed: seed)],
            do: failure

      assert Enum.all?(failures, &(&1.shrink_runs <= 100))
      assert Enum.any?(failures, &(&1.shrink_ended == :cap and &1.shrink_runs == 100))
    end
  end
end
