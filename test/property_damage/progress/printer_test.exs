defmodule PropertyDamage.Progress.PrinterTest do
  use ExUnit.Case, async: true

  alias PropertyDamage.{FailureReport, Progress.Printer, Sequence}

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

  describe "print_run/3" do
    test "prints run progress" do
      sequence = Sequence.linear([%TestCommand{id: 1}])

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Printer.print_run(0, 10, sequence)
        end)

      assert output =~ "Run 1/10"
      assert output =~ "1 commands"
    end

    test "shows branch info for branching sequences" do
      prefix = [%TestCommand{id: 1}]
      branches = [[%TestCommand{id: 2}], [%TestCommand{id: 3}]]
      sequence = Sequence.branching(prefix, branches)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Printer.print_run(0, 10, sequence)
        end)

      assert output =~ "branches"
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
        failure_reason: {:check_failed, :test_check, "Test failed"},
        original_sequence: original_sequence,
        shrunk_sequence: shrunk_sequence,
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
