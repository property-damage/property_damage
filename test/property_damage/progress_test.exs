defmodule PropertyDamage.ProgressTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.Progress
  alias PropertyDamage.Progress.{LoadResult, LoadUpdate, RunResult, RunUpdate}

  describe "new/2" do
    test "wraps a payload struct and carries metadata" do
      payload = %RunUpdate{run_number: 3, total_runs: 100}

      progress = Progress.new(payload, at: 123, elapsed_ms: 45, run_id: :abc)

      assert %Progress{data: ^payload, at: 123, elapsed_ms: 45, run_id: :abc} = progress
    end

    test "defaults metadata to nil" do
      progress = Progress.new(%LoadResult{report: %{}})

      assert progress.at == nil
      assert progress.elapsed_ms == nil
      assert progress.run_id == nil
    end

    test "rejects a non-struct payload" do
      assert_raise FunctionClauseError, fn -> Progress.new(%{not: :a_struct}) end
    end
  end

  describe "operation/1, kind/1, telemetry_event/1" do
    cases = [
      {%RunUpdate{run_number: 1, total_runs: 1}, :test_run, :progress},
      {%RunResult{outcome: :ok}, :test_run, :result},
      {%LoadUpdate{snapshot: %{}}, :load_test, :progress},
      {%LoadResult{report: %{}}, :load_test, :result}
    ]

    for {payload, operation, kind} <- cases do
      test "#{inspect(payload.__struct__)} => #{operation}/#{kind}" do
        progress = Progress.new(unquote(Macro.escape(payload)))

        assert Progress.operation(progress) == unquote(operation)
        assert Progress.kind(progress) == unquote(kind)

        assert Progress.telemetry_event(progress) ==
                 [:property_damage, unquote(operation), unquote(kind)]
      end
    end
  end
end
