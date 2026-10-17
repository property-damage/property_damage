defmodule PropertyDamage.Executor.SteppingOutcomeTest do
  # Outcomes of commands that do not go through a plain sync adapter call.
  use ExUnit.Case, async: true

  alias PropertyDamage.Executor.Stepping
  alias PropertyDamage.Failure

  alias PropertyDamage.Test.Lockstep.{
    FaultInjected,
    ProbeModel,
    ProbeStep,
    StepAdapter,
    StepModel,
    TimedFault
  }

  defmodule RaisingProbeAdapter do
    use PropertyDamage.Adapter

    @impl true
    def setup(config), do: {:ok, config}

    @impl true
    def teardown(_ctx), do: :ok

    @impl true
    def execute(%ProbeStep{}, _ctx, _runtime), do: raise("probe exploded")
  end

  defp context(model, adapter) do
    {:ok, adapter_context} = adapter.setup(%{})
    %Stepping.Context{model: model, adapter: adapter, adapter_context: adapter_context}
  end

  test "a raise inside a probe command's settle loop is returned as {:raised, exception}" do
    ctx = context(ProbeModel, RaisingProbeAdapter)

    assert {:error, %Failure{type: %Failure.Execution{kind: :adapter_error, detail: detail}},
            _failed_state, {:raised, %RuntimeError{message: "probe exploded"}}} =
             Stepping.step(%ProbeStep{value: 1}, 0, Stepping.init_state(ProbeModel), ctx)

    # The failure keeps the {exception, stacktrace} shape a full run reports.
    assert {%RuntimeError{message: "probe exploded"}, stacktrace} = detail
    assert is_list(stacktrace)
  end

  test "a nemesis command's outcome is what its inject/2 returned" do
    ctx = context(StepModel, StepAdapter)

    assert {:ok, _state, {:ok, [%FaultInjected{tag: :brief}]}} =
             Stepping.step(
               %TimedFault{duration_ms: 0, tag: :brief},
               0,
               Stepping.init_state(StepModel),
               ctx
             )
  end
end
