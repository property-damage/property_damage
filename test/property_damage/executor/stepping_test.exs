defmodule PropertyDamage.Executor.SteppingTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Executor.Stepping
  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.Events.ItemCreated
  alias PropertyDamage.Test.MinimalModel
  alias PropertyDamage.Test.TestAdapter

  defp context do
    {:ok, adapter_context} = TestAdapter.setup(%{})

    %Stepping.Context{
      model: MinimalModel,
      adapter: TestAdapter,
      adapter_context: adapter_context,
      event_queue: nil
    }
  end

  describe "Context" do
    test "requires model, adapter, and adapter_context" do
      assert_raise ArgumentError, fn ->
        struct!(Stepping.Context, model: MinimalModel)
      end
    end

    test "event_queue defaults to nil" do
      ctx = %Stepping.Context{model: MinimalModel, adapter: TestAdapter, adapter_context: %{}}
      assert ctx.event_queue == nil
    end
  end

  describe "init_state/2" do
    test "builds a fresh executor state" do
      state = Stepping.init_state(MinimalModel)

      assert state.event_log == []
      assert state.step_count == 0
    end
  end

  describe "step/4" do
    test "executes one command and appends its event to the returned state" do
      ctx = context()
      state = Stepping.init_state(MinimalModel)

      assert {:ok, state} = Stepping.step(%CreateItem{name: "a", quantity: 1}, 0, state, ctx)
      assert [%ItemCreated{name: "a"}] = Enum.map(state.event_log, & &1.event)

      # Threading the returned state forward advances execution.
      assert {:ok, state} = Stepping.step(%CreateItem{name: "b", quantity: 2}, 1, state, ctx)
      names = state.event_log |> Enum.map(& &1.event.name) |> Enum.sort()
      assert names == ["a", "b"]
    end

    test "positions the command at {:prefix, index}" do
      ctx = context()
      state = Stepping.init_state(MinimalModel)

      {:ok, state} = Stepping.step(%CreateItem{name: "a", quantity: 1}, 3, state, ctx)
      assert state.current_position == {:prefix, 3}
    end
  end

  describe "stop_pollers/1" do
    test "returns :ok when no pollers were started" do
      assert Stepping.stop_pollers(Stepping.init_state(MinimalModel)) == :ok
    end
  end
end
