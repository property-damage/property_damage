defmodule PropertyDamage.Next.NativeShrinkRunsTest do
  # Pins what PD's own engine shrinks to and how many shrink runs it takes
  # on the shrink fixtures, so a change to the shrinker for another engine's
  # entries cannot move the native rows by one run unnoticed.
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.Test.Shrink
  alias PropertyDamage.Next.Test.Shrink.{Stock, Till}

  # {model, adapter, max_steps, config, seed, plan number, shrink runs, final step count}
  @rows [
    {Shrink.AmountModel, Shrink.Adapter, 1, :amount, 1, 1, 20, 1},
    {Shrink.AmountModel, Shrink.Adapter, 1, :amount, 2, 1, 19, 1},
    {Shrink.SplitModel, Shrink.Adapter, 1, :split, 1, 11, 16, 1},
    {Shrink.SplitModel, Shrink.Adapter, 1, :split, 2, 7, 18, 1},
    {Shrink.NoteModel, Shrink.Adapter, 1, :note, 1, 2, 16, 1},
    {Shrink.NoteModel, Shrink.Adapter, 1, :note, 2, 1, 21, 1},
    {Till.Model, Till.Adapter, 14, :till, 1, 2, 34, 6},
    {Till.Model, Till.Adapter, 14, :till, 2, 1, 35, 6},
    {Stock.Model, Shrink.Adapter, 8, :stock, 1, 1, 22, 2},
    {Stock.Model, Shrink.Adapter, 8, :stock, 2, 1, 24, 2}
  ]

  defp config(:amount), do: %{fails?: fn c, _ -> c.amount >= 37 end}
  defp config(:split), do: %{fails?: fn c, _ -> c.rest == 101 - c.cut end}
  defp config(:note), do: %{fails?: fn c, _ -> byte_size(c.text) >= 2 end}
  defp config(:till), do: %{bug: true}
  defp config(:stock), do: %{fails?: fn c, _ -> match?(%Stock.Take{count: n} when n >= 3, c) end}

  test "the native engine's shrinks of the fixtures keep their plan numbers, shrink runs and sizes" do
    for {model, adapter, max_steps, config, seed, number, runs, steps} <- @rows do
      assert {:error, failure} =
               Next.run(
                 model: model,
                 adapter: adapter,
                 seed: seed,
                 max_steps: max_steps,
                 max_plans: 2_000,
                 config: config(config)
               )

      assert {inspect(model), seed, failure.plan_number, failure.shrink_runs,
              length(failure.plan.steps)} == {inspect(model), seed, number, runs, steps}
    end
  end
end
