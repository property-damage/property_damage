defmodule PropertyDamage.Progress.PrinterTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{Failure, FailureReport, Progress, Sequence}
  alias PropertyDamage.Progress.{Printer, RunResult, RunUpdate}

  import ExUnit.CaptureIO

  # Simple command struct for testing
  defmodule TestCommand do
    defstruct [:id]
  end

  describe "print_header/3" do
    test "prints configuration summary" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Printer.print_header(TestModel, TestAdapter,
            max_runs: 50,
            max_commands: 25
          )
        end)

      assert output =~ "PropertyDamage Test Run"
      assert output =~ "Model:"
      assert output =~ "TestModel"
      assert output =~ "Adapter:"
      assert output =~ "TestAdapter"
      assert output =~ "Max Runs:     50"
      assert output =~ "Max Commands: 25"
    end

    test "prints seed when provided" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Printer.print_header(TestModel, TestAdapter, seed: 12_345)
        end)

      assert output =~ "Seed:         12345"
    end
  end

  describe "print_run/4" do
    test "prints run progress (run_number is 1-based)" do
      output =
        capture_io(fn ->
          Printer.print_run(1, 10, 1, 0)
        end)

      assert output =~ "Run 1/10"
      assert output =~ "1 commands"
    end

    test "shows branch info when branch_count > 0" do
      output =
        capture_io(fn ->
          Printer.print_run(1, 10, 4, 2)
        end)

      assert output =~ "2 branches"
    end

    test "omits branch info when branch_count is 0" do
      output =
        capture_io(fn ->
          Printer.print_run(3, 10, 5, 0)
        end)

      refute output =~ "branches"
    end
  end

  describe "consumer/3" do
    test "RunUpdate{phase: :start} prints the configuration header" do
      consumer = Printer.consumer(TestModel, TestAdapter, max_runs: 5, max_commands: 7)

      output =
        capture_io(fn ->
          consumer.(Progress.new(%RunUpdate{phase: :start, run_number: 0, total_runs: 5}))
        end)

      assert output =~ "PropertyDamage Test Run"
      assert output =~ "Max Runs:     5"
      assert output =~ "Max Commands: 7"
    end

    test "RunUpdate{phase: :run} prints per-run progress" do
      consumer = Printer.consumer(TestModel, TestAdapter, [])

      output =
        capture_io(fn ->
          consumer.(
            Progress.new(%RunUpdate{
              phase: :run,
              run_number: 2,
              total_runs: 10,
              command_count: 4,
              branch_count: 0
            })
          )
        end)

      assert output =~ "Run 2/10"
      assert output =~ "4 commands"
    end

    test "RunResult{outcome: :ok} prints the success summary" do
      consumer = Printer.consumer(TestModel, TestAdapter, [])

      output =
        capture_io(fn ->
          consumer.(
            Progress.new(%RunResult{
              outcome: :ok,
              runs_completed: 100,
              total_commands: 500,
              seed: 42
            })
          )
        end)

      assert output =~ "TEST PASSED"
      assert output =~ "Runs:           100"
      assert output =~ "Total Commands: 500"
      assert output =~ "Seed:           42"
    end

    test "RunResult{outcome: :error} prints the failure summary" do
      report = %FailureReport{
        seed: 12_345,
        run_number: 5,
        failed_at_index: 2,
        failure_reason: Failure.assertion_failed(:test_check, "Test failed"),
        original_sequence: Sequence.linear([%TestCommand{id: 1}, %TestCommand{id: 2}]),
        trace: PropertyDamage.RunTrace.new(plan: Sequence.linear([%TestCommand{id: 1}])),
        shrink_iterations: 10,
        shrink_time_ms: 100
      }

      consumer = Printer.consumer(TestModel, TestAdapter, [])

      output =
        capture_io(fn ->
          consumer.(Progress.new(%RunResult{outcome: :error, failure: report}))
        end)

      assert output =~ "TEST FAILURE DETECTED"
      assert output =~ "Run:          6"
    end
  end

  describe "print_failure/1" do
    test "prints failure details" do
      original_sequence = Sequence.linear([%TestCommand{id: 1}, %TestCommand{id: 2}])
      shrunk_sequence = Sequence.linear([%TestCommand{id: 1}])

      report = %FailureReport{
        seed: 12_345,
        run_number: 5,
        failed_at_index: 2,
        failure_reason: Failure.assertion_failed(:test_check, "Test failed"),
        original_sequence: original_sequence,
        trace: PropertyDamage.RunTrace.new(plan: shrunk_sequence),
        shrink_iterations: 10,
        shrink_time_ms: 100
      }

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Printer.print_failure(report)
        end)

      assert output =~ "TEST FAILURE DETECTED"
      assert output =~ "Run:          6"
      assert output =~ "Seed:         12345"
      assert output =~ "Failed at:    Command 3"
      assert output =~ "Original commands: 2"
      assert output =~ "Shrunk commands:   1"
      assert output =~ "Iterations:        10"
      assert output =~ "To Reproduce:"
    end
  end

  describe "print_success/1" do
    test "prints success summary" do
      stats = %{
        runs: 100,
        total_commands: 5000,
        seed: 12_345
      }

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Printer.print_success(stats)
        end)

      assert output =~ "TEST PASSED"
      assert output =~ "Runs:           100"
      assert output =~ "Total Commands: 5000"
      assert output =~ "Seed:           12345"
    end

    test "shows duration when provided" do
      stats = %{
        runs: 100,
        total_commands: 5000,
        seed: 12_345,
        duration_ms: 2500
      }

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Printer.print_success(stats)
        end)

      assert output =~ "Duration:"
      assert output =~ "Throughput:"
    end
  end

  describe "print_dot/0" do
    test "prints a dot" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Printer.print_dot()
        end)

      assert output == "."
    end
  end

  describe "print_x/0" do
    test "prints an X" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Printer.print_x()
        end)

      assert output == "X"
    end
  end
end
