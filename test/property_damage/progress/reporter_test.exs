defmodule PropertyDamage.Progress.ReporterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PropertyDamage.Progress
  alias PropertyDamage.Progress.{Reporter, RunUpdate}

  defp update(n), do: %RunUpdate{run_number: n, total_runs: 10}

  describe "new/2 and active?/1" do
    test "an empty consumer list is inert" do
      refute Reporter.active?(Reporter.new([]))
      refute Reporter.active?(Reporter.new([nil, nil]))
    end

    test "nil consumers are dropped; real ones make it active" do
      reporter = Reporter.new([nil, fn _ -> :ok end, nil])
      assert Reporter.active?(reporter)
      assert length(reporter.consumers) == 1
    end
  end

  describe "emit/2" do
    test "an inert reporter never invokes the build function (zero cost)" do
      parent = self()
      reporter = Reporter.new([])

      Reporter.emit(reporter, fn ->
        send(parent, :built)
        update(1)
      end)

      refute_received :built
    end

    test "builds once and fans out to every consumer in order" do
      parent = self()

      reporter =
        Reporter.new([
          fn p -> send(parent, {:a, p.data.run_number}) end,
          fn p -> send(parent, {:b, p.data.run_number}) end
        ])

      build_calls = :counters.new(1, [])
      Reporter.emit(reporter, fn -> :counters.add(build_calls, 1, 1) && update(7) end)

      assert_received {:a, 7}
      assert_received {:b, 7}
      assert :counters.get(build_calls, 1) == 1
    end

    test "stamps run_id and elapsed_ms onto the envelope" do
      parent = self()
      started_at = System.monotonic_time(:millisecond)

      reporter =
        Reporter.new([fn p -> send(parent, p) end], run_id: :corr, started_at: started_at)

      Reporter.emit(reporter, fn -> update(1) end)

      assert_received %Progress{run_id: :corr, elapsed_ms: elapsed, at: at}
      assert is_integer(at)
      assert is_integer(elapsed) and elapsed >= 0
    end

    test "a raising consumer is caught and logged; later consumers still run" do
      parent = self()

      reporter =
        Reporter.new([
          fn _ -> raise "boom" end,
          fn p -> send(parent, {:reached, p.data.run_number}) end
        ])

      log =
        capture_log(fn ->
          assert Reporter.emit(reporter, fn -> update(3) end) == :ok
        end)

      assert_received {:reached, 3}
      assert log =~ "progress consumer raised and was skipped"
    end
  end
end
