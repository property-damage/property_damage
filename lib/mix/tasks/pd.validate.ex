defmodule Mix.Tasks.Pd.Validate do
  @moduledoc """
  Validates a PropertyDamage model and adapter configuration.

  This task checks that your model is correctly configured before running tests,
  catching common mistakes early.

  ## Usage

      mix pd.validate MyApp.TestModel MyApp.TestAdapter

  ## What Gets Checked

  ### Errors (validation fails)
  - Model module exists and implements required callbacks
  - Adapter module exists and implements required callbacks
  - All command modules exist and implement required callbacks
  - All projection modules exist
  - Injectable events are covered by injector adapters

  ### Warnings (validation passes with warnings)
  - Commands missing `downstream_observables/0`
  - Events produced but not handled by assertion projections
  - Missing optional callbacks that may be useful

  ## Options

      --verbose    Show detailed information about the model
      --strict     Treat warnings as errors

  ## Examples

      # Basic validation
      mix pd.validate MyApp.TestModel MyApp.TestAdapter

      # With verbose output
      mix pd.validate MyApp.TestModel MyApp.TestAdapter --verbose

      # Fail on warnings
      mix pd.validate MyApp.TestModel MyApp.TestAdapter --strict
  """

  use Mix.Task

  @shortdoc "Validate PropertyDamage model configuration"

  @impl true
  def run(args) do
    # Parse arguments
    {opts, argv, _} = OptionParser.parse(args, strict: [verbose: :boolean, strict: :boolean])
    verbose = Keyword.get(opts, :verbose, false)
    strict = Keyword.get(opts, :strict, false)

    case argv do
      [model_str, adapter_str] ->
        # Ensure code is compiled
        Mix.Task.run("compile", [])

        # Convert strings to modules
        model = parse_module(model_str)
        adapter = parse_module(adapter_str)

        validate_and_report(model, adapter, verbose, strict)

      [model_str] ->
        # Only model provided - show helpful message
        Mix.Task.run("compile", [])
        model = parse_module(model_str)

        IO.puts("\n")
        print_color(:yellow, "Note: No adapter specified. Validating model only.\n")
        validate_model_only(model, verbose, strict)

      [] ->
        print_usage()

      _ ->
        print_color(:red, "Error: Expected 1 or 2 arguments (model and optional adapter)\n")
        print_usage()
        System.halt(1)
    end
  end

  defp parse_module(string) do
    string
    |> String.replace(~r/^Elixir\./, "")
    |> then(&("Elixir." <> &1))
    |> String.to_atom()
  end

  defp validate_and_report(model, adapter, verbose, strict) do
    IO.puts("\n")
    print_header("PropertyDamage Validation")
    IO.puts("")

    # Check if modules exist
    model_exists = Code.ensure_loaded?(model)
    adapter_exists = Code.ensure_loaded?(adapter)

    unless model_exists do
      print_color(:red, "ERROR: Model module #{inspect(model)} does not exist\n")
      print_hint("Make sure the module is defined and the project is compiled.")
      System.halt(1)
    end

    unless adapter_exists do
      print_color(:red, "ERROR: Adapter module #{inspect(adapter)} does not exist\n")
      print_hint("Make sure the module is defined and the project is compiled.")
      System.halt(1)
    end

    # Run validation
    case PropertyDamage.Validation.validate!(model, adapter) do
      {:ok, warnings} ->
        if verbose do
          PropertyDamage.Validation.print_summary(model, adapter, warnings)
        end

        print_validation_results(model, adapter, warnings, verbose)

        if strict and warnings != [] do
          IO.puts("")
          print_color(:red, "FAILED: #{length(warnings)} warning(s) in strict mode\n")
          System.halt(1)
        else
          print_color(:green, "\nVALIDATION PASSED\n")
        end
    end
  rescue
    e in ArgumentError ->
      IO.puts("")
      print_color(:red, "VALIDATION FAILED\n")
      IO.puts("")
      print_errors_with_hints(e.message)
      System.halt(1)
  end

  defp validate_model_only(model, verbose, strict) do
    unless Code.ensure_loaded?(model) do
      print_color(:red, "ERROR: Model module #{inspect(model)} does not exist\n")
      System.halt(1)
    end

    errors = []
    warnings = []

    # Check model callbacks (assertion_projections is optional)
    required_callbacks = [:commands, :command_sequence_projection]

    errors =
      for callback <- required_callbacks,
          not function_exported?(model, callback, 0),
          reduce: errors do
        acc -> ["Model missing required callback #{callback}/0" | acc]
      end

    unless Enum.empty?(errors) do
      print_color(:red, "ERRORS:\n")

      for error <- errors do
        IO.puts("  - #{error}")
      end

      System.halt(1)
    end

    # Check commands
    commands = model.commands() |> PropertyDamage.Model.normalize_commands()

    errors =
      for {_weight, cmd, _spec} <- commands, not Code.ensure_loaded?(cmd), reduce: errors do
        acc -> ["Command module #{inspect(cmd)} does not exist" | acc]
      end

    # Check command callbacks
    errors =
      for {_weight, cmd, _spec} <- commands, Code.ensure_loaded?(cmd), reduce: errors do
        acc ->
          if function_exported?(cmd, :generator, 1),
            do: acc,
            else: ["Command #{inspect(cmd)} missing generator/1" | acc]
      end

    # Check projections
    state_proj = model.command_sequence_projection()

    errors =
      if Code.ensure_loaded?(state_proj) do
        errors
      else
        ["State projection #{inspect(state_proj)} does not exist" | errors]
      end

    extra_projs =
      if function_exported?(model, :assertion_projections, 0) do
        model.assertion_projections()
      else
        []
      end

    errors =
      for proj <- extra_projs, not Code.ensure_loaded?(proj), reduce: errors do
        acc -> ["Extra projection #{inspect(proj)} does not exist" | acc]
      end

    # Collect warnings
    warnings =
      for {_weight, cmd, _spec} <- commands,
          Code.ensure_loaded?(cmd),
          not function_exported?(cmd, :downstream_observables, 0),
          reduce: warnings do
        acc ->
          [
            "Command #{cmd |> Module.split() |> List.last()} missing downstream_observables/0"
            | acc
          ]
      end

    if verbose do
      print_model_summary(model, commands)
    end

    if Enum.empty?(errors) do
      if warnings != [] do
        print_color(:yellow, "\nWARNINGS:\n")

        for warning <- warnings do
          IO.puts("  - #{warning}")
        end
      end

      if strict and warnings != [] do
        print_color(:red, "\nFAILED: #{length(warnings)} warning(s) in strict mode\n")
        System.halt(1)
      else
        print_color(:green, "\nMODEL VALIDATION PASSED\n")
      end
    else
      print_color(:red, "\nERRORS:\n")

      for error <- errors do
        IO.puts("  - #{error}")
      end

      System.halt(1)
    end
  end

  defp print_validation_results(model, adapter, warnings, _verbose) do
    commands = model.commands() |> PropertyDamage.Model.normalize_commands()

    extra_projs =
      if function_exported?(model, :assertion_projections, 0) do
        model.assertion_projections()
      else
        []
      end

    IO.puts("Model:      #{inspect(model)}")
    IO.puts("Adapter:    #{inspect(adapter)}")
    IO.puts("Commands:   #{length(commands)}")
    IO.puts("Extra:      #{length(extra_projs)}")

    if warnings != [] do
      IO.puts("")
      print_color(:yellow, "WARNINGS (#{length(warnings)}):\n")

      for warning <- warnings do
        IO.puts("  - #{warning}")
      end
    end
  end

  defp print_model_summary(model, commands) do
    state_proj = model.command_sequence_projection()

    extra_projs =
      if function_exported?(model, :assertion_projections, 0) do
        model.assertion_projections()
      else
        []
      end

    IO.puts("Model: #{inspect(model)}")
    IO.puts("")
    IO.puts("Commands (#{length(commands)}):")

    for {weight, cmd, _spec} <- commands do
      name = cmd |> Module.split() |> List.last()
      IO.puts("  #{String.pad_trailing(name, 25)} weight: #{weight}")
    end

    IO.puts("")
    IO.puts("State Projection: #{inspect(state_proj)}")
    IO.puts("Extra Projections: #{length(extra_projs)}")

    for proj <- extra_projs do
      name = proj |> Module.split() |> List.last()
      IO.puts("  - #{name}")
    end
  end

  defp print_errors_with_hints(message) do
    # Parse the error message and provide hints
    lines = String.split(message, "\n")

    for line <- lines do
      cond do
        String.contains?(line, "does not exist") ->
          IO.puts(line)
          print_hint("Check the module name spelling and ensure the code is compiled.")

        String.contains?(line, "missing required callback") ->
          IO.puts(line)
          print_hint("Add the missing callback to implement the behaviour.")

        String.contains?(line, "not covered by any InjectorAdapter") ->
          IO.puts(line)
          print_hint("Add the event to an injector adapter's @emits list.")

        true ->
          IO.puts(line)
      end
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

    Usage: mix pd.validate MODEL [ADAPTER] [OPTIONS]

    Arguments:
      MODEL     The model module (e.g., MyApp.TestModel)
      ADAPTER   The adapter module (e.g., MyApp.HTTPAdapter) [optional]

    Options:
      --verbose    Show detailed information about the configuration
      --strict     Treat warnings as errors (exit code 1)

    Examples:
      mix pd.validate MyApp.TestModel MyApp.HTTPAdapter
      mix pd.validate MyApp.TestModel MyApp.HTTPAdapter --verbose
      mix pd.validate MyApp.TestModel --strict
    """)
  end
end
