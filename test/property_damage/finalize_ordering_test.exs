defmodule PropertyDamage.FinalizeOrderingTest do
  @moduledoc """
  The order in which a run with a mock finishes: the last command's events are
  folded, then the mock events pushed late, then the mock is told of them, then
  the final `@check at: :teardown` runs over everything folded, and the mocks
  are torn down last. A mock whose `on_event/2` raises while the run finalizes
  fails the run before the final check runs, but the mock is still torn down.
  """
  use ExUnit.Case, async: false

  alias PropertyDamage.Test.StepObserver, as: S

  setup do
    {:ok, _} = S.Recorder.start()
    on_exit(&S.Recorder.stop/0)
  end

  test "late mock events are folded and announced before the final check, and teardown is last" do
    assert {:ok, %{runs: 1}} = S.run(S.OrderModel, [S.target()], 2)

    assert S.Recorder.records() == [
             {:command, "First", 0},
             {:projections, :none},
             {:command, "Second", 1},
             {:projections, %{stepped: [0], echoed: []}},
             {:event, "Echoed", {:late, 1}},
             {:event, "Echoed", {:final, 1}},
             {:final_check, [stepped: 0, stepped: 1, echoed: {:late, 1}, echoed: {:final, 1}]},
             {:teardown, %{stepped: [0, 1], echoed: [late: 1]}}
           ]
  end

  test "a mock that rejects an event folded at finalize fails the last command, skips the final check and is torn down" do
    mock = %{raise_event: {:final, 1}}
    assert {:error, report} = S.run(S.OrderModel, [S.target(mock)], 2)

    assert report.report_kind == :execution_failed
    assert report.failed_at_index == 1

    assert {S.Mock, :on_event, %RuntimeError{}} =
             PropertyDamage.FailureReport.failure_reason(report).type.detail

    # A failed run is reproduced once; only the first pass is pinned.
    records = S.Recorder.records()
    first_pass = Enum.take(records, Enum.find_index(records, &match?({:teardown, _}, &1)) + 1)

    assert first_pass == [
             {:command, "First", 0},
             {:projections, :none},
             {:command, "Second", 1},
             {:projections, %{stepped: [0], echoed: []}},
             {:event, "Echoed", {:late, 1}},
             {:event, "Echoed", {:final, 1}},
             {:teardown, %{stepped: [0, 1], echoed: [late: 1]}}
           ]
  end
end
