defmodule PropertyDamage.StepObserverSteppingTest do
  @moduledoc """
  The notifications a mock adapter gets, observed one call of
  `PropertyDamage.Executor.Stepping` at a time: the records each `step/4`,
  `drain/2` and `finalize/2` adds to the recording mock's list, and the
  projections the registry holds after each.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Executor.Stepping
  alias PropertyDamage.MockServiceRegistry
  alias PropertyDamage.Test.StepObserver, as: S

  setup do
    {:ok, _} = S.Recorder.start()
    on_exit(&S.Recorder.stop/0)

    {state, ctx, registry, mock_context} = S.start_stepping_state(%{push_on: [0]})

    on_exit(fn ->
      try do
        MockServiceRegistry.stop(registry)
      catch
        :exit, _ -> :ok
      end
    end)

    %{state: state, ctx: ctx, registry: registry, mock_context: mock_context}
  end

  # The records added by `fun`, and what it returned.
  defp delta(fun) do
    before = S.Recorder.records()
    result = fun.()
    after_ = S.Recorder.records()
    assert Enum.take(after_, length(before)) == before
    {Enum.drop(after_, length(before)), result}
  end

  defp snapshot(registry) do
    {:ok, handler_state} = MockServiceRegistry.get_handler_state(registry, S.Mock)
    handler_state.projections[S.Ledger]
  end

  test "each call adds the records of its own step and nothing else", t do
    assert S.Recorder.records() == []

    {records, {:ok, state, _outcome}} =
      delta(fn -> Stepping.step(%S.First{n: 0}, 0, t.state, t.ctx) end)

    # The mock is told of the command, then drives a request, then is told of
    # the event it pushed.
    assert records == [{:command, "First", 0}, {:projections, :none}, {:event, "Echoed", 0}]
    assert snapshot(t.registry) == %{stepped: [0], echoed: [0]}

    assert {[], {:ok, state}} = delta(fn -> Stepping.drain(state, t.ctx) end)

    {records, {:ok, state, _outcome}} =
      delta(fn -> Stepping.step(%S.Second{n: 1}, 1, state, t.ctx) end)

    assert records == [{:command, "Second", 1}, {:projections, %{stepped: [0], echoed: [0]}}]
    assert snapshot(t.registry) == %{stepped: [0, 1], echoed: [0]}

    assert {[], %{}} = delta(fn -> Stepping.finalize(state, t.ctx) end)
  end

  test "drain folds an event pushed after the step's flush, tells the mock and refreshes the snapshot",
       t do
    {:ok, state, _} = Stepping.step(%S.First{n: 0}, 0, t.state, t.ctx)
    :ok = MockServiceRegistry.push_event(t.registry, S.Mock, %S.Echoed{n: :late})

    {records, {:ok, drained}} = delta(fn -> Stepping.drain(state, t.ctx) end)

    assert records == [{:event, "Echoed", :late}]
    assert snapshot(t.registry) == %{stepped: [0], echoed: [0, :late]}
    assert drained.projections[S.Ledger] == %{stepped: [0], echoed: [0, :late]}

    # A stepping state keeps its log newest first.
    assert drained.event_log
           |> Enum.reverse()
           |> Enum.map(&{&1.source, &1.command_index, &1.event.n}) == [
             {:command, 0, 0},
             {:mock, 0, 0},
             {:mock, 0, :late}
           ]
  end

  test "finalize folds a late mock event and tells the mock before it returns", t do
    {:ok, state, _} = Stepping.step(%S.First{n: 0}, 0, t.state, t.ctx)
    {:ok, state} = Stepping.drain(state, t.ctx)
    :ok = MockServiceRegistry.push_event(t.registry, S.Mock, %S.Echoed{n: :final})

    {records, result} = delta(fn -> Stepping.finalize(state, t.ctx) end)

    assert records == [{:event, "Echoed", :final}]
    assert result.projections[S.Ledger] == %{stepped: [0], echoed: [0, :final]}

    assert Enum.map(result.event_log, &{&1.source, &1.command_index, &1.event.n}) == [
             {:command, 0, 0},
             {:mock, 0, 0},
             {:mock, 0, :final}
           ]

    # The registry snapshot is not refreshed by finalize.
    assert snapshot(t.registry) == %{stepped: [0], echoed: [0]}
  end

  test "the mock's teardown runs after finalize and sees the registry's last snapshot", t do
    {:ok, state, _} = Stepping.step(%S.First{n: 0}, 0, t.state, t.ctx)
    _result = Stepping.finalize(state, t.ctx)
    assert S.Recorder.records() |> List.last() == {:event, "Echoed", 0}

    :ok = S.Mock.teardown(t.mock_context)

    assert S.Recorder.records() |> List.last() ==
             {:teardown, %{stepped: [0], echoed: [0]}}
  end

  test "a mock whose on_command/2 raises fails the step before the adapter runs" do
    {state, ctx, _registry, _mock_context} = S.start_stepping_state(%{raise_on: 0})

    {records, result} = delta(fn -> Stepping.step(%S.First{n: 0}, 0, state, ctx) end)

    assert records == [{:command, "First", 0}]
    assert {:error, failure, _failed_state, :not_called} = result
    assert {S.Mock, :on_command, %RuntimeError{}} = failure.type.detail
  end
end
