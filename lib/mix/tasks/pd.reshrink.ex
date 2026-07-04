defmodule Mix.Tasks.Pd.Reshrink do
  @moduledoc """
  Re-shrink a saved PropertyDamage failure with a larger budget.

  Loads a `.pd` failure file and runs the shrinker again over its already-shrunk
  sequence, this time with a more aggressive budget, to squeeze out reductions the
  original run missed. This is a thin CLI shell over
  `PropertyDamage.load_failure/1` and `PropertyDamage.shrink_further/2`; for
  anything the flags do not expose (notably a custom adapter config map), call
  `shrink_further/2` directly.

  ## Usage

      mix pd.reshrink path/to/failure.pd [--strategy exhaustive] [--output smaller.pd]

  The failure file records which model and adapter produced it, so no
  `--model` / `--adapter` flags are needed. Those modules must be compiled and
  loadable in the current project, otherwise the file cannot be decoded.

  ## Cost

  Unlike a single replay, re-shrinking exercises the System Under Test heavily:
  the shrinker sets up the adapter and executes many candidate sub-sequences, and
  a final run re-checks the result. Against a live or HTTP-backed adapter this
  hits the real service repeatedly. Against an in-memory adapter it is cheap.

  ## Output

  By default the task prints the reduction and writes nothing. To persist the
  smaller report:

  - `--output PATH` writes it to `PATH` (replacing any file already there).
  - `--overwrite` replaces the input file in place.

  Both target an explicit location, so no file is ever clobbered silently.

  ## Exit code

  Re-shrink is not a pass/fail regression gate (that is `mix pd.replay`'s job).
  The task exits **zero** on any successful re-shrink, whether or not the sequence
  got smaller: "no further reduction under this budget" is a normal outcome, not a
  failure. It exits **non-zero** only on a real error: the file failed to load,
  the report does not record a model/adapter, or a requested write failed.

  ## Options

      --strategy NAME       quick | thorough | exhaustive (default: thorough)
      --max-iterations N     override the strategy's iteration budget
      --max-time-ms N        override the strategy's time budget (milliseconds)
      --output PATH          write the re-shrunk report to PATH
      --overwrite            write the re-shrunk report back over the input file

  The strategies set these budgets (overridable per flag above):

  | strategy     | max iterations | max time (ms) |
  |--------------|----------------|---------------|
  | `quick`      | 500            | 10_000        |
  | `thorough`   | 2000           | 60_000        |
  | `exhaustive` | 10_000         | 300_000       |

  ## Examples

      # Try harder to shrink a failure that came out too long
      mix pd.reshrink failures/currency-bug.pd --strategy exhaustive

      # Re-shrink with a custom budget and save the smaller report alongside
      mix pd.reshrink failures/currency-bug.pd --max-time-ms 120000 --output failures/currency-bug-min.pd

      # Re-shrink in place
      mix pd.reshrink failures/currency-bug.pd --overwrite
  """

  use Mix.Task

  alias PropertyDamage.Sequence

  @shortdoc "Re-shrink a saved PropertyDamage failure with a larger budget"

  @strategies ~w(quick thorough exhaustive)a

  @impl true
  def run(args) do
    args |> exec() |> halt_on_error()
  end

  # Run the re-shrink and return its status (`:ok` or `:error`) without halting.
  # This is the testable seam: `run/1` is the thin wrapper that calls `exec/1`
  # and translates an `:error` status into a non-zero `System.halt`, so the
  # decision logic can be exercised in-process without killing the test VM.
  #
  # `:error` (non-zero) means a real failure (load, missing model/adapter, write).
  # `:ok` (zero) means the re-shrink ran, whether or not it reduced the sequence.
  @doc false
  @spec exec([String.t()]) :: :ok | :error
  def exec(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          strategy: :string,
          max_iterations: :integer,
          max_time_ms: :integer,
          output: :string,
          overwrite: :boolean
        ]
      )

    if invalid != [] do
      print_color(:red, "Error: invalid option #{inspect(hd(invalid))}\n")
      print_usage()
      :error
    else
      dispatch(argv, opts)
    end
  end

  defp dispatch([path], opts) do
    case parse_strategy(opts) do
      {:ok, strategy} ->
        # Ensure the project (and the model/adapter the file references) is
        # compiled before we try to decode terms that name those modules.
        Mix.Task.run("compile", [])
        reshrink_file(path, strategy, opts)

      {:error, value} ->
        print_color(:red, "Error: unknown strategy #{inspect(value)}\n")
        print_hint("Valid strategies: quick, thorough, exhaustive.")
        :error
    end
  end

  defp dispatch([], _opts) do
    print_color(:red, "Error: a failure file path is required\n")
    print_usage()
    :error
  end

  defp dispatch(_argv, _opts) do
    print_color(:red, "Error: expected exactly one failure file path\n")
    print_usage()
    :error
  end

  defp parse_strategy(opts) do
    case Keyword.get(opts, :strategy) do
      nil ->
        {:ok, :thorough}

      value ->
        atom = String.to_atom(value)
        if atom in @strategies, do: {:ok, atom}, else: {:error, value}
    end
  end

  defp halt_on_error(:error), do: System.halt(1)
  defp halt_on_error(_), do: :ok

  defp reshrink_file(path, strategy, opts) do
    case PropertyDamage.load_failure(path) do
      {:ok, failure} ->
        do_reshrink(failure, path, strategy, opts)

      {:ok, failure, warnings} ->
        print_load_warnings(warnings)
        do_reshrink(failure, path, strategy, opts)

      {:error, reason} ->
        print_load_error(path, reason)
        :error
    end
  end

  defp do_reshrink(failure, path, strategy, opts) do
    before_count = command_count(PropertyDamage.FailureReport.shrunk_sequence(failure))

    IO.puts("")
    print_header("PropertyDamage Re-shrink")
    IO.puts("")
    print_summary(failure, strategy, before_count)
    IO.puts("")

    shrink_opts =
      [strategy: strategy]
      |> maybe_put(:max_iterations, Keyword.get(opts, :max_iterations))
      |> maybe_put(:max_time_ms, Keyword.get(opts, :max_time_ms))

    case PropertyDamage.shrink_further(failure, shrink_opts) do
      {:ok, new_report} ->
        report_reduction(new_report, before_count)
        write_result(new_report, path, opts)

      {:error, reason} ->
        print_reshrink_error(reason)
        :error
    end
  end

  defp report_reduction(new_report, before_count) do
    after_count = command_count(PropertyDamage.FailureReport.shrunk_sequence(new_report))

    IO.puts("Before:     #{before_count} commands")
    IO.puts("After:      #{after_count} commands")
    IO.puts("Iterations: #{new_report.shrink_iterations}")
    IO.puts("Time:       #{new_report.shrink_time_ms}ms")
    IO.puts("")

    if after_count < before_count do
      print_color(
        :green,
        "Reduced #{before_count} -> #{after_count} commands.\n"
      )
    else
      print_color(:yellow, "Already minimal under this budget (no further reduction).\n")
    end
  end

  defp write_result(new_report, path, opts) do
    cond do
      output = Keyword.get(opts, :output) ->
        write_to(new_report, output)

      Keyword.get(opts, :overwrite, false) ->
        write_to(new_report, path)

      true ->
        # Default: print only, write nothing.
        print_hint("Pass --output PATH or --overwrite to save this result.")
        :ok
    end
  end

  defp write_to(new_report, target) do
    directory = Path.dirname(target)
    filename = Path.basename(target)

    case PropertyDamage.save_failure(new_report, directory, filename: filename, overwrite: true) do
      {:ok, written} ->
        IO.puts("")
        print_color(:green, "Wrote re-shrunk failure to #{written}\n")
        :ok

      {:error, reason} ->
        IO.puts("")
        print_color(:red, "ERROR: could not write re-shrunk failure to #{target}\n")
        IO.puts("  Reason: #{inspect(reason)}")
        :error
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp command_count(nil), do: 0
  defp command_count(sequence), do: length(Sequence.to_list(sequence))

  defp print_summary(failure, strategy, command_count) do
    IO.puts("Model:    #{inspect(failure.model)}")
    IO.puts("Adapter:  #{inspect(failure.adapter)}")
    IO.puts("Seed:     #{inspect(failure.seed)}")

    IO.puts(
      "Failure:  #{PropertyDamage.FailureReport.failure_type(failure)}#{check_suffix(PropertyDamage.FailureReport.check_name(failure))}"
    )

    IO.puts("Commands: #{command_count}")
    IO.puts("Strategy: #{strategy}")
  end

  defp check_suffix(nil), do: ""
  defp check_suffix(check), do: " (#{check})"

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

  defp print_reshrink_error(reason) do
    if reason == :missing_model_or_adapter do
      print_color(:red, "ERROR: the failure file does not record a model and adapter\n")

      print_hint(
        "Re-shrinking re-runs the engine, which needs the model and adapter that produced the failure; this file cannot be re-shrunk."
      )
    else
      print_color(:red, "ERROR: re-shrink could not run\n")
      IO.puts("  Reason: #{inspect(reason)}")
    end
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

    Usage: mix pd.reshrink FILE [OPTIONS]

    Arguments:
      FILE    Path to a saved .pd failure file

    Options:
      --strategy NAME       quick | thorough | exhaustive (default: thorough)
      --max-iterations N     override the strategy's iteration budget
      --max-time-ms N        override the strategy's time budget (milliseconds)
      --output PATH          write the re-shrunk report to PATH
      --overwrite            write the re-shrunk report back over the input file

    Examples:
      mix pd.reshrink failures/currency-bug.pd --strategy exhaustive
      mix pd.reshrink failures/currency-bug.pd --output failures/currency-bug-min.pd
    """)
  end
end
