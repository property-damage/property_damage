defmodule PropertyDamage.Progress do
  @moduledoc """
  Progress reporting for PropertyDamage test runs.

  Provides user-friendly output during test execution including:
  - Run start headers
  - Per-run progress updates
  - Failure summaries
  - Success summaries with statistics
  """

  alias PropertyDamage.{Error, FailureReport, Sequence}

  @doc """
  Print the test run header showing what's being tested.
  """
  @spec print_header(module(), module(), keyword()) :: :ok
  def print_header(model, adapter, opts \\ []) do
    max_runs = Keyword.get(opts, :max_runs, 100)
    max_commands = Keyword.get(opts, :max_commands, 50)

    IO.puts("")
    IO.puts("=" |> String.duplicate(60))
    IO.puts("  PropertyDamage Test Run")
    IO.puts("=" |> String.duplicate(60))
    IO.puts("")
    IO.puts("  Model:        #{inspect(model)}")
    IO.puts("  Adapter:      #{inspect(adapter)}")
    IO.puts("  Max Runs:     #{max_runs}")
    IO.puts("  Max Commands: #{max_commands}")

    if Keyword.get(opts, :seed) do
      IO.puts("  Seed:         #{Keyword.get(opts, :seed)}")
    end

    IO.puts("")
    IO.puts("-" |> String.duplicate(60))
    :ok
  end

  @doc """
  Print progress for the current run.

  Shows run number, command count, and optional branch info.
  """
  @spec print_run(non_neg_integer(), non_neg_integer(), Sequence.t()) :: :ok
  def print_run(run_number, max_runs, sequence) do
    command_count = Sequence.command_count(sequence)

    branch_info =
      if Sequence.branching?(sequence),
        do: " (#{Sequence.branch_count(sequence)} branches)",
        else: ""

    # Use carriage return to update in place for cleaner output
    IO.write("\r  Run #{run_number + 1}/#{max_runs}: #{command_count} commands#{branch_info}    ")
    :ok
  end

  @doc """
  Print a failure summary with helpful context.
  """
  @spec print_failure(FailureReport.t()) :: :ok
  def print_failure(%FailureReport{} = report) do
    # Clear the progress line
    IO.puts("")
    IO.puts("")
    IO.puts("!" |> String.duplicate(60))
    IO.puts("  TEST FAILURE DETECTED")
    IO.puts("!" |> String.duplicate(60))
    IO.puts("")

    # Basic failure info
    IO.puts("  Run:          #{report.run_number + 1}")
    IO.puts("  Seed:         #{report.seed}")
    IO.puts("  Failed at:    Command #{report.failed_at_index + 1}")
    IO.puts("")

    # Failure reason with formatted error message
    IO.puts("  Reason:")
    error_msg = Error.format(report.failure_reason, %{})
    # Indent the error message
    error_lines = String.split(error_msg, "\n")

    for line <- error_lines do
      IO.puts("    #{line}")
    end

    IO.puts("")

    # Shrinking info
    if report.shrink_iterations > 0 do
      original_count = Sequence.command_count(report.original_sequence)
      shrunk_count = Sequence.command_count(report.shrunk_sequence)

      IO.puts("  Shrinking:")
      IO.puts("    Original commands: #{original_count}")
      IO.puts("    Shrunk commands:   #{shrunk_count}")
      IO.puts("    Iterations:        #{report.shrink_iterations}")
      IO.puts("    Time:              #{report.shrink_time_ms}ms")
      IO.puts("")
    end

    # How to reproduce
    IO.puts("  To Reproduce:")
    IO.puts("    PropertyDamage.run(")
    IO.puts("      model: YourModel,")
    IO.puts("      adapter: YourAdapter,")
    IO.puts("      seed: #{report.seed},")
    IO.puts("      max_runs: 1")
    IO.puts("    )")
    IO.puts("")
    IO.puts("-" |> String.duplicate(60))
    :ok
  end

  @doc """
  Print a success summary with statistics.
  """
  @spec print_success(map()) :: :ok
  def print_success(stats) do
    # Clear the progress line
    IO.puts("")
    IO.puts("")
    IO.puts("=" |> String.duplicate(60))
    IO.puts("  TEST PASSED")
    IO.puts("=" |> String.duplicate(60))
    IO.puts("")
    IO.puts("  Runs:           #{stats.runs}")
    IO.puts("  Total Commands: #{stats.total_commands}")
    IO.puts("  Seed:           #{stats.seed}")

    if Map.has_key?(stats, :duration_ms) and stats.duration_ms > 0 do
      IO.puts("  Duration:       #{format_duration(stats.duration_ms)}")
      cmds_per_sec = Float.round(stats.total_commands / (stats.duration_ms / 1000), 1)
      IO.puts("  Throughput:     #{cmds_per_sec} commands/sec")
    end

    IO.puts("")
    :ok
  end

  @doc """
  Print a progress dot (compact mode).
  """
  @spec print_dot() :: :ok
  def print_dot do
    IO.write(".")
    :ok
  end

  @doc """
  Print a failure X (compact mode).
  """
  @spec print_x() :: :ok
  def print_x do
    IO.write("X")
    :ok
  end

  # Format duration in human-readable form
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 2)}s"

  defp format_duration(ms) do
    minutes = div(ms, 60_000)
    seconds = Float.round(rem(ms, 60_000) / 1000, 1)
    "#{minutes}m #{seconds}s"
  end
end
