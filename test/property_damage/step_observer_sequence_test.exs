defmodule PropertyDamage.StepObserverSequenceTest do
  @moduledoc """
  What a mock adapter is told during a public `PropertyDamage.run/1`, in order:
  `on_command/2` before the adapter call, `on_event/2` for each mock event
  after the command's own events, the projections the registry holds when the
  next step starts, and `teardown/1` last. The recording mock appends to an
  Agent only from inside its own callbacks.

  The run folds a mock event pushed after a step's own flush at the boundary
  drain that follows the step; an event pushed while that drain checks the
  late one is folded when the run finalizes.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.StepObserver, as: S

  setup do
    {:ok, _} = S.Recorder.start()
    on_exit(&S.Recorder.stop/0)
  end

  defp run!(model, count, mock_config) do
    assert {:ok, %{runs: 1}} = S.run(model, [S.target(mock_config)], count)
    S.Recorder.records()
  end

  test "a mock event pushed during a step folds into that step, before the next command" do
    assert run!(S.Model, 2, %{push_on: [0]}) == [
             {:command, "First", 0},
             {:projections, :none},
             {:event, "Echoed", 0},
             {:command, "Second", 1},
             {:projections, %{stepped: [0], echoed: [0]}},
             {:teardown, %{stepped: [0, 1], echoed: [0]}}
           ]
  end

  test "a mock event pushed after the last command's flush is folded at the drain before teardown" do
    assert run!(S.LateModel, 2, %{}) == [
             {:command, "First", 0},
             {:projections, :none},
             {:command, "Second", 1},
             {:projections, %{stepped: [0], echoed: []}},
             {:event, "Echoed", {:late, 1}},
             {:teardown, %{stepped: [0, 1], echoed: [late: 1]}}
           ]
  end

  test "a mock event pushed after the last drain's flush is folded at finalize, after the registry snapshot" do
    assert run!(S.FinalModel, 2, %{}) == [
             {:command, "First", 0},
             {:projections, :none},
             {:command, "Second", 1},
             {:projections, %{stepped: [0], echoed: []}},
             {:event, "Echoed", {:late, 1}},
             {:event, "Echoed", {:final, 1}},
             # The registry snapshot was last refreshed at the drain, so it
             # does not hold the event folded at finalize.
             {:teardown, %{stepped: [0, 1], echoed: [late: 1]}}
           ]
  end

  test "the registry snapshot after each step is the projections the model computes" do
    records = run!(S.Model, 3, %{push_on: [0, 2]})

    assert records == [
             {:command, "First", 0},
             {:projections, :none},
             {:event, "Echoed", 0},
             {:command, "Second", 1},
             {:projections, %{stepped: [0], echoed: [0]}},
             {:command, "Second", 2},
             {:projections, %{stepped: [0, 1], echoed: [0]}},
             {:event, "Echoed", 2},
             {:teardown, %{stepped: [0, 1, 2], echoed: [0, 2]}}
           ]

    snapshots = for {:projections, %{stepped: stepped}} <- records, do: stepped
    assert snapshots == [[0], [0, 1]]
  end

  test "a mock whose on_command/2 raises fails the step, after the commands it was told of" do
    assert {:error, report} = S.run(S.Model, [S.target(%{raise_on: 1})], 2)

    assert report.report_kind == :execution_failed
    assert report.failed_at_index == 1
    assert {S.Mock, :on_command, %RuntimeError{}} = report.failure_reason.type.detail

    # A failed run is reproduced once; only the first pass is pinned.
    records = S.Recorder.records()
    first_pass = Enum.take(records, Enum.find_index(records, &match?({:teardown, _}, &1)) + 1)

    assert first_pass == [
             {:command, "First", 0},
             {:projections, :none},
             {:command, "Second", 1},
             {:teardown, %{stepped: [0], echoed: []}}
           ]
  end
end
