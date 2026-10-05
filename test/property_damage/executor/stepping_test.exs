defmodule PropertyDamage.Executor.SteppingTest do
  use ExUnit.Case, async: true

  import PropertyDamage.Test.VariantSupport, only: [entries: 1, events_from: 2, stepping: 2]

  alias PropertyDamage.{EventQueue, Failure, Placeholder}
  alias PropertyDamage.Sequence.Position

  alias PropertyDamage.Executor.Stepping
  alias PropertyDamage.Test.Commands.CreateItem
  alias PropertyDamage.Test.Events.ItemCreated
  alias PropertyDamage.Test.MinimalModel
  alias PropertyDamage.Test.TestAdapter

  alias PropertyDamage.Test.Lockstep.{
    FaultInjected,
    FaultRestored,
    GuardedStepModel,
    Ledger,
    Noted,
    NoteInjector,
    ProbeAdapter,
    Probed,
    ProbeModel,
    ProbeStep,
    Step,
    StepAdapter,
    StepModel,
    Stepped,
    TimedFault
  }

  defp context do
    {:ok, adapter_context} = TestAdapter.setup(%{})

    %Stepping.Context{
      model: MinimalModel,
      adapter: TestAdapter,
      adapter_context: adapter_context,
      event_queue: nil
    }
  end

  defp context(model, adapter, config, event_queue \\ nil) do
    {:ok, adapter_context} = adapter.setup(config)

    %Stepping.Context{
      model: model,
      adapter: adapter,
      adapter_context: adapter_context,
      event_queue: event_queue
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
    test "executes one command and returns the adapter's events alongside the new state" do
      ctx = context()
      state = Stepping.init_state(MinimalModel)

      assert {:ok, state, {:ok, [%ItemCreated{name: "a"}]}} =
               Stepping.step(%CreateItem{name: "a", quantity: 1}, 0, state, ctx)

      assert [%ItemCreated{name: "a"}] = Enum.map(state.event_log, & &1.event)

      # Threading the returned state forward advances execution.
      assert {:ok, state, {:ok, [%ItemCreated{name: "b"}]}} =
               Stepping.step(%CreateItem{name: "b", quantity: 2}, 1, state, ctx)

      names = state.event_log |> Enum.map(& &1.event.name) |> Enum.sort()
      assert names == ["a", "b"]
    end

    test "positions the command at Position.prefix(index)" do
      ctx = context()
      state = Stepping.init_state(MinimalModel)

      {:ok, state, _outcome} = Stepping.step(%CreateItem{name: "a", quantity: 1}, 3, state, ctx)
      assert state.current_position == Position.prefix(3)
    end

    test "an adapter {:error, reason} returns the failure, the failed state and the raw reason" do
      ctx = context(StepModel, StepAdapter, %{})
      state = Stepping.init_state(StepModel)

      assert {:error, %Failure{type: %Failure.Execution{kind: :adapter_error}}, failed_state,
              {:error, :refused}} = Stepping.step(%Step{value: 1, fail: true}, 0, state, ctx)

      assert failed_state.event_log == []
    end

    test "an adapter raise is returned as {:raised, exception}" do
      ctx = context(StepModel, StepAdapter, %{behavior: :raise})
      state = Stepping.init_state(StepModel)

      assert {:error, %Failure{}, _failed_state,
              {:raised, %RuntimeError{message: "candidate exploded"}}} =
               Stepping.step(%Step{value: 1}, 0, state, ctx)
    end

    test "a probe command's outcome is its settled events" do
      ctx = context(ProbeModel, ProbeAdapter, %{retries: 2})
      state = Stepping.init_state(ProbeModel)

      assert {:ok, _state, {:ok, [%Probed{value: 5}]}} =
               Stepping.step(%ProbeStep{value: 5}, 0, state, ctx)
    end

    test "a command whose placeholder cannot be resolved never reaches the adapter" do
      ctx = context(StepModel, StepAdapter, %{test_pid: self()})
      state = Stepping.init_state(StepModel)
      command = %Step{value: %Placeholder{id: :never_produced}}

      assert {:error, %Failure{type: %Failure.Framework{kind: :placeholder_resolution}},
              _failed_state, :not_called} = Stepping.step(command, 0, state, ctx)

      refute_received {:executed, _, _, _}
    end
  end

  describe "drain/2" do
    test "folds events queued after a step into the state" do
      {:ok, queue} = EventQueue.start_link()
      ctx = context(StepModel, StepAdapter, %{}, queue)
      state = Stepping.init_state(StepModel, event_queue: queue)

      {:ok, state, _outcome} = Stepping.step(%Step{value: 1}, 0, state, ctx)
      EventQueue.push(queue, NoteInjector, %Noted{value: :late})

      assert {:ok, drained} = stepping(:drain, [state, ctx])
      assert events_from(drained.event_log, :injector) == [%Noted{value: :late}]
      assert drained.projections[Ledger].noted == [:late]
      assert EventQueue.size(queue) == 0

      EventQueue.stop(queue)
    end

    test "reports a check that fails on a drained event" do
      {:ok, queue} = EventQueue.start_link()
      ctx = context(GuardedStepModel, StepAdapter, %{}, queue)
      state = Stepping.init_state(GuardedStepModel, event_queue: queue)

      {:ok, state, _outcome} = Stepping.step(%Step{value: 1}, 0, state, ctx)
      EventQueue.push(queue, NoteInjector, %Stepped{value: 13})

      assert {:error, %Failure{type: %Failure.Check{kind: :check_failed, name: :step_is_good}},
              _failed_state} = stepping(:drain, [state, ctx])

      EventQueue.stop(queue)
    end
  end

  describe "finalize/2" do
    test "restores faults still active and returns the finalized run result" do
      ctx = context(StepModel, StepAdapter, %{test_pid: self()})
      state = Stepping.init_state(StepModel)

      {:ok, state, _} =
        Stepping.step(%TimedFault{duration_ms: 600_000, tag: :long}, 0, state, ctx)

      {:ok, state, _} = Stepping.step(%Step{value: 1}, 1, state, ctx)
      refute_received {:fault_restored, :long, _}

      result = stepping(:finalize, [state, ctx])

      assert result.success
      assert_received {:fault_restored, :long, _}

      events = Enum.map(result.event_log, & &1.event)
      assert [%FaultInjected{tag: :long}, %Stepped{value: 1} | _] = events
      assert %FaultRestored{tag: :long} in events
      assert {:command, 1, %Stepped{value: 1}} in entries(result.event_log)
    end
  end

  describe "stop_pollers/1" do
    test "returns :ok when no pollers were started" do
      assert Stepping.stop_pollers(Stepping.init_state(MinimalModel)) == :ok
    end
  end
end
