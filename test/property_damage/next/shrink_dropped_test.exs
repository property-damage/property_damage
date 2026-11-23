defmodule PropertyDamage.Next.ShrinkDroppedTest do
  # A shrink candidate whose rebuild raises is skipped without a run. The
  # failure counts those candidates in `shrink_dropped`, apart from
  # `shrink_runs`.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Failure
  alias PropertyDamage.Next.Test.Fixtures, as: F
  alias PropertyDamage.Next.Test.Shrink
  alias PropertyDamage.Next.Test.Surface

  require F.Models

  defmodule Guarded do
    @moduledoc false
    # The `guard` field refuses an amount of 1, the lower bound the shrinker
    # tries first, and tells the process that runs the shrink each time it
    # does. Only edited journals reach that amount: the failure needs 3 or
    # more.
    use PropertyDamage.Next.Command

    defstruct [:amount, :guard]

    def generator(_state, _opts) do
      %{
        amount: integer(1..1_000),
        guard:
          from(:amount, fn amount ->
            if amount == 1 do
              send(self(), {:refused, amount})
              raise ArgumentError, "an amount of 1 is refused"
            end

            member_of([:ok])
          end)
      }
    end
  end

  F.Models.defmodel(GuardedModel, [Guarded])

  defp refusals(count \\ 0) do
    receive do
      {:refused, 1} -> refusals(count + 1)
    after
      0 -> count
    end
  end

  defp run(seed) do
    Next.run(
      model: GuardedModel,
      adapter: Shrink.Adapter,
      seed: seed,
      max_steps: 1,
      max_plans: 200,
      config: %{fails?: fn %Guarded{amount: amount}, _earlier -> amount >= 3 end}
    )
  end

  test "the failure counts the candidates whose rebuild raised, none of them in shrink_runs" do
    for seed <- 1..6 do
      assert {:error, %Failure{} = failure} = run(seed)
      raised = refusals()

      assert Surface.field(failure, :shrink_dropped) == raised
      assert raised > 0
      assert [%Guarded{amount: 3}] = Enum.map(failure.plan.steps, & &1.command)
      assert failure.shrink_runs > 0
    end
  end

  test "a run that is not shrunk drops nothing" do
    assert {:error, %Failure{} = failure} =
             Next.run(
               model: GuardedModel,
               adapter: Shrink.Adapter,
               seed: 1,
               max_steps: 1,
               max_plans: 200,
               shrink: false,
               config: %{fails?: fn %Guarded{amount: amount}, _earlier -> amount >= 3 end}
             )

    assert Surface.field(failure, :shrink_dropped) == 0
    assert refusals() == 0
  end
end
