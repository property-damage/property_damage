defmodule Mix.Tasks.Pd.Replay do
  @moduledoc """
  Replay a saved PropertyDamage failure against the System Under Test.

  Loads a `.pd` failure file and re-executes its shrunk command sequence through
  the real engine, printing each step and a final verdict. This is a thin CLI
  shell over `PropertyDamage.load_failure/1` and `PropertyDamage.replay/2`; for
  anything beyond what the flags expose (custom adapter config, stutter), use
  those functions directly.

  ## Usage

      mix pd.replay path/to/failure.pd [--verbose]

  The failure file already records which model and adapter produced it, so no
  `--model` / `--adapter` flags are needed. Those modules must be compiled and
  loadable in the current project, otherwise the file cannot be decoded.

  ## Exit code

  The exit code answers a single question: **does the bug still reproduce?**

  - **Non-zero** when the failure reproduces (any command failed its check or
    errored, or the replay could not run). This is the success case for a
    regression check: the bug is still present.
  - **Zero** only when every command passes, meaning the failure no longer
    reproduces and the bug appears fixed.

  This makes `mix pd.replay` usable as a regression gate and is the contract
  `mix pd.bisect` consumes per commit.

  ## Options

      --verbose    Print the events and projection state after each step

  ## Examples

      # Check whether a saved bug still reproduces
      mix pd.replay failures/2025-12-26T14-30-00-check_failed-NonNegativeBalance-seed512902757.pd

      # Show per-step events and state
      mix pd.replay failures/currency-bug.pd --verbose
  """

  use Mix.Task

  alias PropertyDamage.Sequence

  @shortdoc "Replay a saved PropertyDamage failure against the SUT"

  @impl true
  def run(args) do
    args |> exec() |> halt_on_error()
  end

  # Run the replay and return its status (`:ok` or `:error`) without halting.
  # This is the testable seam: `run/1` is the thin wrapper that calls `exec/1`
  # and translates an `:error` status into a non-zero `System.halt`, so the
  # decision logic can be exercised in-process without killing the test VM.
  #
  # Status semantics mirror the exit code: `:error` (non-zero) means the failure
  # reproduced or the replay could not run; `:ok` (zero) means it no longer
  # reproduces.
  @doc false
  @spec exec([String.t()]) :: :ok | :error
  def exec(args) do
    {opts, argv, _} = OptionParser.parse(args, strict: [verbose: :boolean])
    verbose = Keyword.get(opts, :verbose, false)

    dispatch(argv, verbose)
  end

  defp dispatch([path], verbose) do
    # Ensure the project (and the model/adapter the file references) is compiled
    # before we try to decode terms that name those modules.
    Mix.Task.run("compile", [])
    replay_file(path, verbose)
  end

  defp dispatch([], _verbose) do
    print_color(:red, "Error: a failure file path is required\n")
    print_usage()
    :error
  end

  defp dispatch(_argv, _verbose) do
    print_color(:red, "Error: expected exactly one failure file path\n")
    print_usage()
    :error
  end

  defp halt_on_error(:error), do: System.halt(1)
  defp halt_on_error(_), do: :ok

  defp replay_file(path, verbose) do
    case PropertyDamage.load_failure(path) do
      {:ok, failure} ->
        do_replay(failure, verbose)

      {:ok, failure, warnings} ->
        print_load_warnings(warnings)
        do_replay(failure, verbose)

      {:error, reason} ->
        print_load_error(path, reason)
        :error
    end
  end

  defp do_replay(failure, verbose) do
    IO.puts("")
    print_header("PropertyDamage Replay")
    IO.puts("")
    print_summary(failure)
    IO.puts("")

    case PropertyDamage.replay(failure) do
      {:ok, steps} ->
        Enum.each(steps, &print_step(&1, verbose))
        IO.puts("")
        verdict(steps)

      {:error, reason} ->
        print_replay_error(reason)
        :error
    end
  end

  defp verdict(steps) do
    failed = Enum.filter(steps, fn step -> step.result != :ok end)

    if failed == [] do
      print_color(:green, "VERDICT: failure no longer reproduces\n")

      IO.puts("  Every command passed. The bug appears fixed. (exit 0)")

      :ok
    else
      print_color(:red, "VERDICT: failure reproduces\n")

      for step <- failed do
        IO.puts("  [#{step.index}] #{step.command_name} -> #{describe_result(step.result)}")
      end

      IO.puts("")
      print_hint("Non-zero exit means the replay worked as intended: the bug is still present.")
      :error
    end
  end

  defp print_summary(failure) do
    command_count =
      case failure.shrunk_sequence do
        nil -> 0
        seq -> length(Sequence.to_list(seq))
      end

    IO.puts("Model:    #{inspect(failure.model)}")
    IO.puts("Adapter:  #{inspect(failure.adapter)}")
    IO.puts("Seed:     #{inspect(failure.seed)}")
    IO.puts("Failure:  #{failure.failure_type}#{check_suffix(failure.check_name)}")
    IO.puts("Commands: #{command_count}")
  end

  defp check_suffix(nil), do: ""
  defp check_suffix(check), do: " (#{check})"

  defp print_step(step, verbose) do
    IO.puts("  [#{step.index}] #{step.command_name} -> #{describe_result(step.result)}")

    if verbose do
      events =
        case step.events do
          [] -> "(none)"
          events -> Enum.map_join(events, ", ", &short_name/1)
        end

      IO.puts("        events: #{events}")
      IO.puts("        state:  #{inspect(step.projections)}")
    end
  end

  defp describe_result(:ok), do: "OK"
  defp describe_result({:check_failed, name, _exception}), do: "FAILED (#{name})"
  defp describe_result({:error, reason}), do: "ERROR: #{inspect(reason)}"

  defp short_name(%{__struct__: mod}), do: mod |> Module.split() |> List.last()
  defp short_name(other), do: inspect(other)

  defp print_load_warnings(warnings) do
    print_color(:yellow, "Load warnings:\n")

    for warning <- warnings do
      IO.puts("  - #{format_warning(warning)}")
    end

    print_hint("The saved file may not reproduce exactly under the current versions.")
    IO.puts("")
  end

  defp format_warning({:property_damage_version_mismatch, saved, current}),
    do: "PropertyDamage: saved=#{saved}, current=#{current}"

  defp format_warning({:dependency_version_mismatch, app, saved, current}),
    do: "#{app}: saved=#{saved}, current=#{current}"

  defp format_warning({:dependency_missing, app, saved}),
    do: "#{app}: was #{saved}, now missing"

  defp format_warning({:struct_shape_drift, missing, unexpected}),
    do:
      "FailureReport struct drifted (missing: #{inspect(missing)}, unexpected: #{inspect(unexpected)})"

  defp format_warning(other), do: inspect(other)

  defp print_load_error(path, reason) do
    print_color(:red, "ERROR: could not load failure file #{path}\n")
    IO.puts("  Reason: #{inspect(reason)}")

    case reason do
      {:file_not_found, _} ->
        print_hint("Check the path. List saved failures with PropertyDamage.list_failures/1.")

      :unsafe_terms ->
        print_hint(
          "The file references modules that are not loaded. Is the project that produced this failure compiled?"
        )

      :checksum_mismatch ->
        print_hint("The file is corrupted (checksum mismatch).")

      :term_too_large ->
        print_hint("The file declares an implausibly large term and was rejected.")

      :invalid_format ->
        print_hint("This does not look like a .pd failure file.")

      {:incompatible_version, file_version, supported} ->
        print_hint(
          "File format v#{file_version} is newer than this build supports (v#{supported}). Upgrade PropertyDamage."
        )

      _ ->
        :ok
    end
  end

  defp print_replay_error(:missing_model) do
    print_color(:red, "ERROR: the failure file does not record a model\n")
    print_hint("Replay needs the model that produced the failure; this file cannot be replayed.")
  end

  defp print_replay_error(:missing_adapter) do
    print_color(:red, "ERROR: the failure file does not record an adapter\n")

    print_hint(
      "Replay needs the adapter that produced the failure; this file cannot be replayed."
    )
  end

  defp print_replay_error(:branching_replay_unsupported) do
    print_color(:red, "ERROR: this failure used parallel/branching execution\n")

    print_hint(
      "Stepping replay cannot reproduce fork/merge semantics. Use the exported ExUnit test instead."
    )
  end

  defp print_replay_error({:adapter_setup_failed, reason}) do
    print_color(:red, "ERROR: adapter setup failed\n")
    IO.puts("  Reason: #{inspect(reason)}")
    print_hint("The SUT could not be brought up for replay. Check the adapter's setup/1.")
  end

  defp print_replay_error(reason) do
    print_color(:red, "ERROR: replay could not run\n")
    IO.puts("  Reason: #{inspect(reason)}")
  end

  defp print_hint(text) do
    print_color(:cyan, "    Hint: #{text}\n")
  end

  defp print_header(text) do
    border = String.duplicate("=", String.length(text) + 4)
    IO.puts(border)
    IO.puts("  #{text}")
    IO.puts(border)
  end

  defp print_color(color, text) do
    IO.puts([color_code(color), text, IO.ANSI.reset()])
  end

  defp color_code(:red), do: IO.ANSI.red()
  defp color_code(:green), do: IO.ANSI.green()
  defp color_code(:yellow), do: IO.ANSI.yellow()
  defp color_code(:cyan), do: IO.ANSI.cyan()

  defp print_usage do
    IO.puts("""

    Usage: mix pd.replay FILE [OPTIONS]

    Arguments:
      FILE    Path to a saved .pd failure file

    Options:
      --verbose    Print the events and projection state after each step

    Examples:
      mix pd.replay failures/currency-bug.pd
      mix pd.replay failures/currency-bug.pd --verbose
    """)
  end
end
