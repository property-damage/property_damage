defmodule Mix.Tasks.Pd.Validate do
  @moduledoc """
  Validates a PropertyDamage model and adapter configuration.

  This task checks that your model is correctly configured before running tests,
  catching common mistakes early.

  ## Usage

      mix pd.validate MyApp.TestModel MyApp.TestAdapter
      mix pd.validate MyApp.TestModel --targets "[MyApp.TestAdapter]"

  `--targets` takes the same list as the `targets:` option of
  `PropertyDamage.run/1`, as an Elixir expression (see `PropertyDamage.Target`). The model is validated against every
  target's adapter and injectors. It cannot be combined with a positional
  adapter.

  ## What Gets Checked

  ### Errors (validation fails)
  - Model module exists and implements required callbacks
  - Adapter module exists and implements required callbacks
  - All command modules exist and implement required callbacks
  - All projection modules exist
  - Injectable events are covered by injector adapters
  - The model defines no removed lifecycle hook (`setup_each/1`,
    `teardown_each/1`, `setup_once`, `teardown_once`); setup and teardown
    entries are valid commands and no nemesis

  ### Warnings (validation passes with warnings)
  - Commands that declare no `:observables` in their `command_spec/1`
  - Events produced but not handled by check projections
  - Missing optional callbacks that may be useful
  - A `when:` or `weight:` on a setup or teardown entry (`setup_each/0`,
    `teardown_each/0`) or on a leaf of an expansion: every entry of a sequence
    runs, in order
  - Two targets with the same adapter and an identical `config:`: such targets
    share state, so give each its own `config:` (for example a tenant)

  ## Options

      --verbose         Show detailed information about the model
      --strict          Treat warnings as errors
      --targets EXPR    Validate against a `targets:` list instead of a positional adapter
      --seeds N         Root sequences to sample for a model with expansions/0 (default 100)
      --seed S          Sample the seeds S, S+1, ... instead of fresh seeds

  ## Expansions

  For a model that defines `expansions/0`, the task generates `--seeds` root
  sequences and realizes every target's expansions on each, as a run does
  (without `--targets`, one `expansion: :random` target named after the
  adapter). It prints the seeds it used, every entry key with how often the
  sample realized it or that it was never realized, the roots forced to
  identity at every sampled root, and the leaf modules realized. The counts are
  summed over the targets that pick expansions (`expansion: :random`), and a
  line names them; a `:reference` target copies the first target's choices and
  is not counted again. When no target picks (every target is `:identity` or
  `:reference`), one line says so. A generation error fails the validation; a
  `when:` or `weight:` on a leaf is a warning.

  ## Examples

      # Basic validation
      mix pd.validate MyApp.TestModel MyApp.TestAdapter

      # With verbose output
      mix pd.validate MyApp.TestModel MyApp.TestAdapter --verbose

      # Fail on warnings
      mix pd.validate MyApp.TestModel MyApp.TestAdapter --strict

      # Two variants of one adapter, isolated by tenant
      mix pd.validate MyApp.TestModel --targets \
        "[{MyApp.HTTPAdapter, config: %{tenant: 1}}, {MyApp.HTTPAdapter, name: \"b\", config: %{tenant: 2}}]"
  """

  use Mix.Task

  @shortdoc "Validate PropertyDamage model configuration"

  @impl true
  def run(args) do
    args |> exec() |> halt_on_error()
  end

  # Run the validation and return its status (`:ok` or `:error`) without halting.
  # This is the testable seam: `run/1` is a thin wrapper that calls `exec/1` and
  # translates an `:error` status into a non-zero `System.halt`, so the decision
  # logic can be exercised in-process without killing the VM.
  @doc false
  @spec exec([String.t()]) :: :ok | :error
  def exec(args) do
    {opts, argv, _} =
      OptionParser.parse(args,
        strict: [
          verbose: :boolean,
          strict: :boolean,
          targets: :string,
          seeds: :integer,
          seed: :integer
        ]
      )

    verbose = Keyword.get(opts, :verbose, false)
    strict = Keyword.get(opts, :strict, false)
    checks = %{verbose: verbose, strict: strict, sample: Keyword.take(opts, [:seeds, :seed])}

    case Keyword.fetch(opts, :targets) do
      {:ok, expr} -> dispatch_targets(argv, expr, checks)
      :error -> dispatch(argv, checks)
    end
  end

  defp dispatch_targets([model_str], expr, checks) do
    Mix.Task.run("compile", [])

    case evaluate_targets(expr) do
      {:ok, targets} ->
        validate_and_report(parse_module(model_str), targets, checks)

      {:error, message} ->
        print_color(:red, "ERROR: invalid --targets: #{message}\n")
        :error
    end
  end

  defp dispatch_targets(_argv, _expr, _checks) do
    print_color(:red, "Error: --targets takes a model and no positional adapter\n")
    print_usage()
    :error
  end

  # Evaluates the `--targets` expression and validates it with the same rules
  # as the `targets:` option.
  defp evaluate_targets(expr) do
    {entries, _binding} = Code.eval_string(expr)
    PropertyDamage.Options.validate_targets(entries)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp dispatch([model_str, adapter_str], checks) do
    # Ensure code is compiled
    Mix.Task.run("compile", [])

    # Convert strings to modules
    model = parse_module(model_str)
    adapter = parse_module(adapter_str)

    target = %PropertyDamage.Target{
      adapter: adapter,
      name: PropertyDamage.Target.default_name(adapter),
      index: 0
    }

    validate_and_report(model, [target], checks)
  end

  defp dispatch([model_str], %{verbose: verbose, strict: strict}) do
    # Only model provided - show helpful message
    Mix.Task.run("compile", [])
    model = parse_module(model_str)

    IO.puts("\n")
    print_color(:yellow, "Note: No adapter specified. Validating model only.\n")
    validate_model_only(model, verbose, strict)
  end

  defp dispatch([], _checks) do
    print_usage()
    :ok
  end

  defp dispatch(_argv, _checks) do
    print_color(:red, "Error: Expected 1 or 2 arguments (model and optional adapter)\n")
    print_usage()
    :error
  end

  defp halt_on_error(:error), do: System.halt(1)
  defp halt_on_error(_), do: :ok

  defp parse_module(string) do
    string
    |> String.replace(~r/^Elixir\./, "")
    |> then(&("Elixir." <> &1))
    |> String.to_atom()
  end

  defp validate_and_report(model, targets, %{verbose: verbose, strict: strict} = checks) do
    IO.puts("\n")
    print_header("PropertyDamage Validation")
    IO.puts("")

    # Check if modules exist
    model_exists = Code.ensure_loaded?(model)
    missing_adapter = Enum.find(targets, &(not Code.ensure_loaded?(&1.adapter)))

    cond do
      not model_exists ->
        print_color(:red, "ERROR: Model module #{inspect(model)} does not exist\n")
        print_hint("Make sure the module is defined and the project is compiled.")
        :error

      missing_adapter != nil ->
        print_color(
          :red,
          "ERROR: Adapter module #{inspect(missing_adapter.adapter)} does not exist\n"
        )

        print_hint("Make sure the module is defined and the project is compiled.")
        :error

      true ->
        # Run validation against every target's adapter and injectors; the
        # model-level warnings repeat per target, so keep each one once.
        base_warnings =
          targets
          |> Enum.flat_map(fn target ->
            {:ok, target_warnings} =
              PropertyDamage.Validation.validate!(model, target.adapter,
                injectors: target.injectors
              )

            target_warnings
          end)
          |> Enum.uniq()

        # Surface declared-but-unchecked invariants (static vacuity, DR-026)
        # so they fail under --strict alongside the other warnings.
        sample = sample_expansions(model, targets, checks.sample)

        warnings =
          base_warnings ++
            invariant_warnings(model) ++
            PropertyDamage.Validation.target_warnings(targets) ++
            sample_warnings(model, sample)

        if verbose do
          for target <- targets do
            PropertyDamage.Validation.print_summary(model, target.adapter, base_warnings)
          end

          print_invariant_catalog(model)
        end

        print_validation_results(model, targets, warnings, verbose)
        print_sample(sample)

        if strict and warnings != [] do
          IO.puts("")
          print_color(:red, "FAILED: #{length(warnings)} warning(s) in strict mode\n")
          :error
        else
          print_color(:green, "\nVALIDATION PASSED\n")
          :ok
        end
    end
  rescue
    e in ArgumentError ->
      IO.puts("")
      print_color(:red, "VALIDATION FAILED\n")
      IO.puts("")
      print_errors_with_hints(e.message)
      :error
  end

  # A model with expansions/0 is sampled: `--seeds N` root sequences (default
  # 100), from seeds S, S+1, ... with `--seed S`, else from fresh seeds, each
  # realized for every target as a run realizes it.
  defp sample_expansions(model, targets, opts) do
    if PropertyDamage.Expansion.defines?(model) do
      count = Keyword.get(opts, :seeds, 100)

      seeds =
        case Keyword.fetch(opts, :seed) do
          {:ok, first} -> Enum.to_list(first..(first + count - 1)//1)
          :error -> for _ <- 1..count//1, do: :rand.uniform(1_000_000_000)
        end

      model
      |> PropertyDamage.Expansion.sample(targets, seeds)
      |> Map.put(:seeds, seeds)
    end
  end

  defp sample_warnings(_model, nil), do: []

  # The sample's own warnings, then the observables and orphan-event warnings
  # for the leaf modules it reached and the ones it never reached.
  defp sample_warnings(model, sample) do
    offered = sample.offered |> Map.values() |> List.flatten()
    reached = MapSet.to_list(sample.leaves)

    sample.warnings ++
      PropertyDamage.Validation.expansion_warnings(model, reached, offered -- reached)
  end

  defp print_sample(nil), do: :ok

  defp print_sample(sample) do
    count = length(sample.seeds)
    IO.puts("")
    IO.puts("Expansions (sampled #{count} seed(s)):")
    IO.puts("  Seeds: #{Enum.join(sample.seeds, ", ")}")
    print_pickers(sample.pickers)

    for {key, modules} <- Enum.sort(sample.offered) do
      leaves = Enum.map_join(modules, ", ", &short_module/1)

      case Map.fetch(sample.realized, key) do
        {:ok, {_modules, n}} -> IO.puts("  #{key} = [#{leaves}]  realized #{n}")
        :error -> IO.puts("  #{key} = [#{leaves}]  not realized in #{count} seeds")
      end
    end

    for module <- sample.forced do
      IO.puts("  #{short_module(module)}: forced to identity in every sampled state")
    end

    IO.puts("  Leaf modules realized:")

    for module <- Enum.sort(sample.leaves) do
      IO.puts("    #{inspect(module)}")
    end
  end

  defp print_pickers([]) do
    IO.puts(
      "  No target picks expansions (each is `expansion: :identity` or copies the " <>
        "first target with `:reference`), so the sample realizes no entry"
    )
  end

  defp print_pickers(names) do
    targets =
      if length(names) == 1, do: "1 target that picks", else: "#{length(names)} targets that pick"

    IO.puts(
      "  Counts are summed over #{targets} expansions: #{Enum.map_join(names, ", ", &inspect/1)}"
    )
  end

  defp validate_model_only(model, verbose, strict) do
    if Code.ensure_loaded?(model) do
      validate_loaded_model_only(model, verbose, strict)
    else
      print_color(:red, "ERROR: Model module #{inspect(model)} does not exist\n")
      :error
    end
  end

  defp validate_loaded_model_only(model, verbose, strict) do
    case missing_required_callbacks(model) ++ lifecycle_errors(model) do
      [] ->
        report_model_only(model, verbose, strict)

      missing ->
        print_color(:red, "ERRORS:\n")
        Enum.each(missing, fn error -> IO.puts("  - #{error}") end)
        :error
    end
  end

  defp missing_required_callbacks(model) do
    for callback <- [:commands, :command_sequence_projection],
        not function_exported?(model, callback, 0) do
      "Model missing required callback #{callback}/0"
    end
  end

  # A removed lifecycle hook, or a nemesis among the setup or teardown commands.
  defp lifecycle_errors(model) do
    PropertyDamage.Model.check_lifecycle!(model)
    []
  rescue
    e in ArgumentError -> [e.message]
  end

  defp report_model_only(model, verbose, strict) do
    # Check commands
    commands = model.commands() |> PropertyDamage.Model.normalize_commands()

    errors =
      for {_weight, cmd, _spec} <- commands, not Code.ensure_loaded?(cmd) do
        "Command module #{inspect(cmd)} does not exist"
      end

    # Check command callbacks
    errors =
      for {_weight, cmd, _spec} <- commands,
          Code.ensure_loaded?(cmd),
          not function_exported?(cmd, :generator, 1),
          reduce: errors do
        acc -> ["Command #{inspect(cmd)} missing generator/1" | acc]
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
      if function_exported?(model, :check_projections, 0) do
        model.check_projections()
      else
        []
      end

    errors =
      for proj <- extra_projs, not Code.ensure_loaded?(proj), reduce: errors do
        acc -> ["Extra projection #{inspect(proj)} does not exist" | acc]
      end

    # Collect warnings
    warnings =
      for {_weight, cmd, spec} <- commands,
          Code.ensure_loaded?(cmd),
          Map.get(spec, :observables, []) == [] do
        "Command #{cmd |> Module.split() |> List.last()} declares no :observables"
      end

    warnings =
      warnings ++ invariant_warnings(model) ++ PropertyDamage.Validation.sequence_warnings(model)

    if verbose do
      print_model_summary(model, commands)
      print_invariant_catalog(model)
    end

    cond do
      errors != [] ->
        print_color(:red, "\nERRORS:\n")
        Enum.each(errors, fn error -> IO.puts("  - #{error}") end)
        :error

      strict and warnings != [] ->
        print_warnings(warnings)
        print_color(:red, "\nFAILED: #{length(warnings)} warning(s) in strict mode\n")
        :error

      true ->
        print_warnings(warnings)
        print_color(:green, "\nMODEL VALIDATION PASSED\n")
        :ok
    end
  end

  # Declared-but-unchecked invariants (static vacuity, DR-026): a guarantee the
  # model claims but no check verifies.
  defp invariant_warnings(model) do
    for %{projection: projection, id: id, checks: []} <- safe_catalog(model) do
      "Invariant #{short_module(projection)}.#{id} declared but never checked (statically vacuous)"
    end
  end

  defp safe_catalog(model) do
    PropertyDamage.Model.check_catalog(model)
  rescue
    _ -> []
  end

  defp print_invariant_catalog(model) do
    catalog = safe_catalog(model)

    IO.puts("")
    IO.puts("Invariants (#{length(catalog)}):")

    if catalog == [] do
      IO.puts("  (none declared)")
    else
      for %{projection: projection, id: id, invariant: invariant, checks: checks} <- catalog do
        description = if invariant.description, do: " — #{invariant.description}", else: ""

        check_str =
          case checks do
            [] -> "no checks (vacuous)"
            cs -> Enum.map_join(cs, ", ", fn c -> "#{c.name} (#{c.kind})" end)
          end

        IO.puts("  #{short_module(projection)}.#{id}#{description}")
        IO.puts("      checks: #{check_str}")
      end
    end
  end

  defp short_module(module), do: module |> Module.split() |> List.last()

  defp print_warnings([]), do: :ok

  defp print_warnings(warnings) do
    print_color(:yellow, "\nWARNINGS:\n")
    Enum.each(warnings, fn warning -> IO.puts("  - #{warning}") end)
  end

  defp print_validation_results(model, targets, warnings, _verbose) do
    commands = model.commands() |> PropertyDamage.Model.normalize_commands()

    extra_projs =
      if function_exported?(model, :check_projections, 0) do
        model.check_projections()
      else
        []
      end

    IO.puts("Model:      #{inspect(model)}")
    print_targets(targets)
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

  defp print_targets([%{adapter: adapter}]), do: IO.puts("Adapter:    #{inspect(adapter)}")

  defp print_targets(targets) do
    IO.puts("Targets:")

    for target <- targets do
      IO.puts("  [#{target.index}] #{target.name} (#{inspect(target.adapter)})")
    end
  end

  defp print_model_summary(model, commands) do
    state_proj = model.command_sequence_projection()

    extra_projs =
      if function_exported?(model, :check_projections, 0) do
        model.check_projections()
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
    if IO.ANSI.enabled?() do
      IO.puts([color_code(color), text, IO.ANSI.reset()])
    else
      IO.puts(text)
    end
  end

  defp color_code(:red), do: IO.ANSI.red()
  defp color_code(:green), do: IO.ANSI.green()
  defp color_code(:yellow), do: IO.ANSI.yellow()
  defp color_code(:cyan), do: IO.ANSI.cyan()

  defp print_usage do
    IO.puts("""

    Usage: mix pd.validate MODEL [ADAPTER | --targets EXPR] [OPTIONS]

    Arguments:
      MODEL     The model module (e.g., MyApp.TestModel)
      ADAPTER   The adapter module (e.g., MyApp.HTTPAdapter) [optional]

    Options:
      --verbose    Show detailed information about the configuration
      --strict     Treat warnings as errors (exit code 1)
      --targets    A `targets:` list as an Elixir expression (instead of ADAPTER)

    Examples:
      mix pd.validate MyApp.TestModel MyApp.HTTPAdapter
      mix pd.validate MyApp.TestModel MyApp.HTTPAdapter --verbose
      mix pd.validate MyApp.TestModel --strict
    """)
  end
end
