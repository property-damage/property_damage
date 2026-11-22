defmodule PropertyDamage.Next.JournalSlotsTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Next
  alias PropertyDamage.Next.{Journal, Step}
  alias PropertyDamage.Next.Test.Scheme.{Adapter, Model}

  @seed 7

  defp saved_plan do
    plan = Next.plan(Model, @seed, max_steps: 3)
    {plan, plan.journal |> Journal.to_binary() |> Journal.from_binary()}
  end

  defp executed_commands do
    receive do
      {:scheme_executed, command, _assigns, _result} -> [command | executed_commands()]
    after
      0 -> []
    end
  end

  test "a saved journal records its number of slots" do
    {plan, loaded} = saved_plan()

    assert length(plan.steps) == 3
    assert loaded.max_steps == 3
  end

  test "a loaded journal rebuilds the identical plan without the max_steps option" do
    {plan, loaded} = saved_plan()

    rebuilt = Next.plan(Model, loaded)
    assert rebuilt.steps == plan.steps
    assert rebuilt.withdrawn == plan.withdrawn
  end

  test "a loaded journal replays the identical plan without the max_steps option" do
    {plan, loaded} = saved_plan()

    assert {:ok, %{plans: 1}} =
             Next.replay(loaded, model: Model, adapter: Adapter, config: %{recorder: self()})

    planned = Enum.map(plan.steps, fn %Step{command: command} -> command.__struct__ end)
    assert Enum.map(executed_commands(), & &1.__struct__) == planned
  end

  test "a max_steps option that differs from the journal's raises ArgumentError" do
    {_plan, loaded} = saved_plan()

    error = assert_raise ArgumentError, fn -> Next.plan(Model, loaded, max_steps: 5) end
    assert error.message =~ "3"
    assert error.message =~ "5"

    error =
      assert_raise ArgumentError, fn ->
        Next.replay(loaded, model: Model, adapter: Adapter, max_steps: 20)
      end

    assert error.message =~ "3"
    assert error.message =~ "20"
  end

  test "a max_steps option equal to the journal's is accepted" do
    {plan, loaded} = saved_plan()

    assert Next.plan(Model, loaded, max_steps: 3).steps == plan.steps

    assert {:ok, %{plans: 1}} =
             Next.replay(loaded, model: Model, adapter: Adapter, max_steps: 3)
  end
end
