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

  The exit code answers a single question: **does the bug still reproduce?**, but
  splits "no" into two cases so the task composes with `git bisect run` (which
  reads 0 = good, 1 = bad, 125 = skip):

  - **0** when every command passes: the failure no longer reproduces and the bug
    appears fixed (*good*).
  - **1** when the failure reproduces: a command failed its check or errored
    during execution (*bad*).
  - **125** when the replay could not run at all: the project does not compile,
    the file fails to load, it records no model/adapter, or the sequence is
    branching. The outcome is *indeterminate*, not a reproduction, so `git bisect`
    treats it as *skip* rather than wrongly blaming the commit (*skip*). 125 is
    still non-zero, so the headline "non-zero means not-confirmed-fixed" contract
    holds.

  A usage error (missing or surplus path, unknown option) exits **2** and is not
  part of the reproduction question.

  Note the asymmetry: a per-command `{:error, reason}` *during* execution is a
  reproduction (exit 1, it can be the regression). Only *pre-execution* failures,
  which leave the bug's presence undetermined, are 125. This makes `mix pd.replay`
  usable as a regression gate and is the contract `mix pd.bisect` consumes per
  commit.

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
    args |> exec() |> halt_on_status()
  end

  # Run the replay and return its status without halting. This is the testable
  # seam: `run/1` is the thin wrapper that calls `exec/1` and translates the
  # status into a `System.halt` exit code at the boundary, so the decision logic
  # can be exercised in-process without killing the test VM.
  #
  # The status mirrors the exit code one-for-one:
  #
  #   * `:ok`            -> 0   the failure no longer reproduces (good)
  #   * `:reproduces`    -> 1   a command failed its check or errored (bad)
  #   * `:indeterminate` -> 125 the replay could not run at all (skip)
  #   * `:usage_error`   -> 2   bad CLI invocation, unrelated to reproduction
  #
  # The `:indeterminate`/125 split is what lets `git bisect run mix pd.replay`
  # skip commits that do not compile or predate the model/adapter, instead of
  # wrongly marking them bad.
  @doc false
  @spec exec([String.t()]) :: :ok | :reproduces | :indeterminate | :usage_error
  def exec(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [verbose: :boolean])

    if invalid != [] do
      print_color(:red, "Error: invalid option #{inspect(hd(invalid))}\n")
      print_usage()
      :usage_error
    else
      verbose = Keyword.get(opts, :verbose, false)
      dispatch(argv, verbose)
    end
  end

  defp dispatch([path], verbose) do
    # Ensure the project (and the model/adapter the file references) is compiled
    # before we try to decode terms that name those modules. A commit that does
    # not compile is indeterminate (125 -> bisect skip), never a reproduction.
    case compile_project() do
      :ok ->
        replay_file(path, verbose)

      :error ->
        print_color(:red, "ERROR: the project failed to compile\n")
        print_hint("Cannot replay at a commit that does not build. (exit 125)")
        :indeterminate
    end
  end

  defp dispatch([], _verbose) do
    print_color(:red, "Error: a failure file path is required\n")
    print_usage()
    :usage_error
  end

  defp dispatch(_argv, _verbose) do
    print_color(:red, "Error: expected exactly one failure file path\n")
    print_usage()
    :usage_error
  end

  # Compile the project, mapping a compile failure to `:error` instead of letting
  # it raise (which would exit 1 and read as "bad" under `git bisect run`).
  defp compile_project do
    case Mix.Task.run("compile", ["--return-errors"]) do
      {:error, _diagnostics} -> :error
      _ -> :ok
    end
  rescue
    _ -> :error
  end

  defp halt_on_status(:ok), do: :ok
  defp halt_on_status(:reproduces), do: System.halt(1)
  defp halt_on_status(:indeterminate), do: System.halt(125)
  defp halt_on_status(:usage_error), do: System.halt(2)

  defp replay_file(path, verbose) do
    case PropertyDamage.load_failure(path) do
      {:ok, failure} ->
        do_replay(failure, verbose)

      {:ok, failure, warnings} ->
        print_load_warnings(warnings)
        do_replay(failure, verbose)

      {:error, reason} ->
        print_load_error(path, reason)
        :indeterminate
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
        :indeterminate
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
      print_hint("Exit 1 means the replay worked as intended: the bug is still present.")
      :reproduces
    end
  end

  defp print_summary(failure) do
    command_count =
      case PropertyDamage.FailureReport.shrunk_sequence(failure) do
        nil -> 0
        seq -> length(Sequence.to_list(seq))
      end

    IO.puts("Model:    #{inspect(failure.model)}")
    IO.puts("Adapter:  #{inspect(failure.adapter)}")
    IO.puts("Seed:     #{inspect(failure.seed)}")
    IO.puts("Failure:  #{PropertyDamage.FailureReport.failure_type(failure)}#{check_suffix(PropertyDamage.FailureReport.check_name(failure))}")
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
