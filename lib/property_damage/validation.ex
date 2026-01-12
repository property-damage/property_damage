defmodule PropertyDamage.Validation do
  @moduledoc """
  Validates test configuration before running.

  Validation catches configuration errors early, before spending time on
  property test execution. It checks that all modules exist, implement
  required callbacks, and that event coverage is complete.

  ## Validation Levels

  - **Errors**: Fatal problems that prevent execution (raise exceptions)
  - **Warnings**: Potential issues that may indicate bugs (logged)

  ## What Gets Validated

  ### Errors (cause validation to fail)

  - Model module must exist and export required callbacks
  - Adapter module must exist and export required callbacks
  - All command modules referenced by model must exist
  - All projection modules must exist
  - Command weights must be positive integers
  - Commands must have at least one entry
  - Injectable events must be covered by InjectorAdapter @emits

  ### Warnings (logged but don't fail)

  - Commands missing `downstream_observables/0` (hard to verify coverage)
  - Events produced but not handled by any assertion projection
  - Injectable events not covered by model's assertion projections

  ## Usage

  ```elixir
  # In test setup or run initialization
  Validation.validate!(model, adapter, injector_adapters: adapters)

  # After validation
  Validation.print_summary(model, adapter, result)
  ```
  """

  alias PropertyDamage.Error

  @doc """
  Validate test configuration.

  Raises `ArgumentError` for fatal configuration errors.
  Returns `{:ok, warnings}` where warnings is a list of warning messages.

  ## Parameters

  - `model` - Model module
  - `adapter` - Adapter module
  - `opts` - Options:
    - `:injector_adapters` - List of InjectorAdapter modules

  ## Returns

  - `{:ok, warnings}` - Validation passed, warnings is list of strings
  - Raises `ArgumentError` on fatal errors
  """
  @spec validate!(module(), module(), keyword()) :: {:ok, [String.t()]}
  def validate!(model, adapter, opts \\ []) do
    injector_adapters = Keyword.get(opts, :injector_adapters, [])

    # Phase 1: Validate modules exist
    model_errors = validate_model_exists(model)
    adapter_errors = validate_adapter_exists(adapter)

    unless Enum.empty?(model_errors ++ adapter_errors) do
      error_msg = Enum.join(model_errors ++ adapter_errors, "\n  - ")
      raise ArgumentError, "Validation failed:\n  - #{error_msg}"
    end

    # Phase 2: Validate callbacks exist
    model_callback_errors = validate_model_callbacks(model)
    adapter_callback_errors = validate_adapter_callbacks(adapter)

    unless Enum.empty?(model_callback_errors ++ adapter_callback_errors) do
      error_msg = Enum.join(model_callback_errors ++ adapter_callback_errors, "\n  - ")
      raise ArgumentError, "Validation failed:\n  - #{error_msg}"
    end

    # Phase 3: Validate commands and projections (requires callbacks)
    errors = []
    errors = errors ++ validate_commands(model)
    errors = errors ++ validate_projections(model)
    errors = errors ++ validate_injectable_events(model, injector_adapters)

    unless Enum.empty?(errors) do
      error_msg = Enum.join(errors, "\n  - ")
      raise ArgumentError, "Validation failed:\n  - #{error_msg}"
    end

    # Collect warnings
    warnings = []
    warnings = warnings ++ warn_missing_downstream_observables(model)
    warnings = warnings ++ warn_orphan_events(model)
    warnings = warnings ++ warn_no_extra_projections(model)
    warnings = warnings ++ warn_unbalanced_weights(model)
    warnings = warnings ++ warn_single_command(model)

    {:ok, warnings}
  end

  @doc """
  Validates run options before execution.

  Returns `:ok` if valid, raises `ArgumentError` with helpful message if not.

  ## Validated Options

  - `:model` - Required, must be a module
  - `:adapter` - Required, must be a module
  - `:max_commands` - Must be positive integer if provided
  - `:max_runs` - Must be positive integer if provided
  - `:seed` - Must be positive integer if provided
  """
  @spec validate_run_opts!(keyword()) :: :ok
  def validate_run_opts!(opts) do
    # Required options
    unless Keyword.has_key?(opts, :model) do
      raise ArgumentError, Error.format_config_error(:missing_model, nil)
    end

    unless Keyword.has_key?(opts, :adapter) do
      raise ArgumentError, Error.format_config_error(:missing_adapter, nil)
    end

    # Type validations
    model = Keyword.get(opts, :model)

    unless is_atom(model) and model != nil do
      raise ArgumentError, Error.format_config_error(:invalid_model, model)
    end

    adapter = Keyword.get(opts, :adapter)

    unless is_atom(adapter) and adapter != nil do
      raise ArgumentError, Error.format_config_error(:invalid_adapter, adapter)
    end

    # Optional integer validations
    if Keyword.has_key?(opts, :max_commands) do
      max_commands = Keyword.get(opts, :max_commands)

      unless is_integer(max_commands) and max_commands > 0 do
        raise ArgumentError, Error.format_config_error(:invalid_max_commands, max_commands)
      end
    end

    if Keyword.has_key?(opts, :max_runs) do
      max_runs = Keyword.get(opts, :max_runs)

      unless is_integer(max_runs) and max_runs > 0 do
        raise ArgumentError, Error.format_config_error(:invalid_max_runs, max_runs)
      end
    end

    if Keyword.has_key?(opts, :seed) do
      seed = Keyword.get(opts, :seed)

      unless is_integer(seed) and seed > 0 do
        raise ArgumentError, Error.format_config_error(:invalid_seed, seed)
      end
    end

    :ok
  end

  @doc """
  Validates command list from a model.

  Checks that:
  - Command list is not empty
  - All weights are positive integers
  - All command modules exist and implement required callbacks
  """
  @spec validate_command_list!(module()) :: :ok
  def validate_command_list!(model) do
    commands = model.commands()

    # Check for empty
    if commands == [] do
      raise ArgumentError, Error.format_config_error(:empty_commands, model)
    end

    # Validate raw commands before normalization
    for cmd_spec <- commands do
      validate_command_spec!(cmd_spec)
    end

    # Normalize and validate modules
    normalized = PropertyDamage.Model.normalize_commands(commands)

    for {_weight, cmd} <- normalized do
      # Validate command module exists
      unless Code.ensure_loaded?(cmd) do
        raise ArgumentError,
              Error.format_config_error(:command_not_found, cmd)
      end

      # Validate required callbacks
      validate_command_callbacks!(cmd)
    end

    :ok
  end

  defp validate_command_spec!({weight, _cmd}) when is_integer(weight) and weight > 0 do
    :ok
  end

  defp validate_command_spec!({weight, cmd}) do
    raise ArgumentError, Error.format_config_error(:invalid_command_weight, {weight, cmd})
  end

  defp validate_command_spec!(cmd) when is_atom(cmd) do
    :ok
  end

  defp validate_command_spec!(invalid) do
    raise ArgumentError, Error.format_config_error(:invalid_command_spec, invalid)
  end

  @doc """
  Validates that a command module implements required callbacks.
  """
  @spec validate_command_callbacks!(module()) :: :ok
  def validate_command_callbacks!(cmd) do
    required = [
      {:new, 2},
      {:precondition, 1},
      {:events, 2}
    ]

    for {callback, arity} <- required do
      unless function_exported?(cmd, callback, arity) do
        raise ArgumentError,
              Error.format_config_error(:command_missing_callback, {cmd, callback, arity})
      end
    end

    :ok
  end

  @doc """
  Print a summary of the validated configuration.

  Useful for verbose mode to show what will be tested.

  ## Parameters

  - `model` - Model module
  - `adapter` - Adapter module
  - `warnings` - List of warning strings from validate!/3
  - `opts` - Options:
    - `:io` - IO device to write to (default: :stdio)
  """
  @spec print_summary(module(), module(), [String.t()], keyword()) :: :ok
  def print_summary(model, adapter, warnings, opts \\ []) do
    io = Keyword.get(opts, :io, :stdio)

    IO.puts(io, "PropertyDamage Configuration Summary")
    IO.puts(io, "====================================")
    IO.puts(io, "")
    IO.puts(io, "Model: #{inspect(model)}")
    IO.puts(io, "Adapter: #{inspect(adapter)}")
    IO.puts(io, "")

    # Commands
    commands = model.commands()
    normalized = PropertyDamage.Model.normalize_commands(commands)
    IO.puts(io, "Commands (#{length(normalized)}):")

    for {weight, cmd} <- normalized do
      IO.puts(io, "  - #{inspect(cmd)} (weight: #{weight})")
    end

    IO.puts(io, "")

    # Projections
    state_proj = model.state_projection()

    extra_projs =
      if function_exported?(model, :extra_projections, 0) do
        model.extra_projections()
      else
        []
      end

    IO.puts(io, "State Projection: #{inspect(state_proj)}")
    IO.puts(io, "Extra Projections (#{length(extra_projs)}):")

    for proj <- extra_projs do
      assertions =
        if function_exported?(proj, :__assertions__, 0) do
          proj.__assertions__()
        else
          []
        end

      IO.puts(io, "  - #{inspect(proj)} (#{length(assertions)} assertions)")
    end

    IO.puts(io, "")

    # Warnings
    unless Enum.empty?(warnings) do
      IO.puts(io, "Warnings:")

      for warning <- warnings do
        IO.puts(io, "  ⚠ #{warning}")
      end

      IO.puts(io, "")
    end

    :ok
  end

  @doc """
  Returns run-time warnings for the given configuration options.

  These warnings don't fail validation but indicate potentially suboptimal
  configurations that may reduce test effectiveness.

  ## Parameters

  - `opts` - Run options keyword list

  ## Returns

  List of warning strings (may be empty)
  """
  @spec runtime_warnings(keyword()) :: [String.t()]
  def runtime_warnings(opts) do
    warnings = []

    max_runs = Keyword.get(opts, :max_runs, 100)
    max_commands = Keyword.get(opts, :max_commands, 50)

    warnings =
      if max_runs < 10 do
        [
          "max_runs: #{max_runs} is very low - " <>
            "property testing is most effective with many runs (recommended: 100+). " <>
            "Low run counts may miss edge cases."
          | warnings
        ]
      else
        warnings
      end

    warnings =
      if max_commands < 5 do
        [
          "max_commands: #{max_commands} is very low - " <>
            "short sequences may miss bugs that require multiple operations. " <>
            "Recommended: 20+ commands per sequence."
          | warnings
        ]
      else
        warnings
      end

    warnings =
      if Keyword.get(opts, :shrink, true) == false do
        [
          "shrink: false - failing sequences won't be minimized. " <>
            "Shrinking helps find the minimal reproduction and is recommended."
          | warnings
        ]
      else
        warnings
      end

    warnings =
      if Keyword.get(opts, :validate, true) == false do
        [
          "validate: false - configuration validation disabled. " <>
            "Consider enabling validation to catch configuration errors early."
          | warnings
        ]
      else
        warnings
      end

    warnings
  end

  # Validation helpers

  defp validate_model_exists(model) do
    if Code.ensure_loaded?(model) do
      []
    else
      ["Model module #{inspect(model)} does not exist"]
    end
  end

  defp validate_model_callbacks(model) do
    # extra_projections is optional
    required_callbacks = [:commands, :state_projection]

    for callback <- required_callbacks, not function_exported?(model, callback, 0), reduce: [] do
      acc -> ["Model #{inspect(model)} missing required callback #{callback}/0" | acc]
    end
  end

  defp validate_adapter_exists(adapter) do
    if Code.ensure_loaded?(adapter) do
      []
    else
      ["Adapter module #{inspect(adapter)} does not exist"]
    end
  end

  defp validate_adapter_callbacks(adapter) do
    required_callbacks = [{:setup, 1}, {:teardown, 1}, {:execute, 2}]

    for {callback, arity} <- required_callbacks,
        not function_exported?(adapter, callback, arity),
        reduce: [] do
      acc -> ["Adapter #{inspect(adapter)} missing required callback #{callback}/#{arity}" | acc]
    end
  end

  defp validate_commands(model) do
    commands = model.commands()
    normalized = PropertyDamage.Model.normalize_commands(commands)

    for {_weight, cmd} <- normalized,
        not Code.ensure_loaded?(cmd),
        reduce: [] do
      acc -> ["Command module #{inspect(cmd)} does not exist" | acc]
    end
  end

  defp validate_projections(model) do
    errors = []

    state_proj = model.state_projection()

    errors =
      if Code.ensure_loaded?(state_proj) do
        errors
      else
        ["State projection #{inspect(state_proj)} does not exist" | errors]
      end

    extra_projs =
      if function_exported?(model, :extra_projections, 0) do
        model.extra_projections()
      else
        []
      end

    for proj <- extra_projs, not Code.ensure_loaded?(proj), reduce: errors do
      acc -> ["Extra projection #{inspect(proj)} does not exist" | acc]
    end
  end

  defp validate_injectable_events(model, injector_adapters) do
    if function_exported?(model, :injectable_events, 0) do
      injectable = model.injectable_events()
      emitted = collect_emitted_events(injector_adapters)

      for event <- injectable, event not in emitted, reduce: [] do
        acc ->
          [
            "Injectable event #{inspect(event)} not covered by any InjectorAdapter @emits"
            | acc
          ]
      end
    else
      []
    end
  end

  defp collect_emitted_events(injector_adapters) do
    Enum.flat_map(injector_adapters, fn adapter ->
      if function_exported?(adapter, :__emits__, 0) do
        adapter.__emits__()
      else
        []
      end
    end)
  end

  defp warn_missing_downstream_observables(model) do
    commands = model.commands()
    normalized = PropertyDamage.Model.normalize_commands(commands)

    for {_weight, cmd} <- normalized,
        not function_exported?(cmd, :downstream_observables, 0),
        reduce: [] do
      acc ->
        [
          "Command #{inspect(cmd)} missing downstream_observables/0 - event coverage not verified"
          | acc
        ]
    end
  end

  defp warn_orphan_events(model) do
    commands = model.commands()
    normalized = PropertyDamage.Model.normalize_commands(commands)

    # Collect all events that commands can produce
    produced_events =
      for {_weight, cmd} <- normalized,
          function_exported?(cmd, :downstream_observables, 0),
          event <- cmd.downstream_observables() do
        event
      end
      |> Enum.uniq()

    # Collect all events handled by extra projections
    extra_projs =
      if function_exported?(model, :extra_projections, 0) do
        model.extra_projections()
      else
        []
      end

    handled_events =
      for proj <- extra_projs,
          function_exported?(proj, :__assertions__, 0),
          assertion <- proj.__assertions__(),
          %{modules: modules} <- [assertion.trigger],
          mod <- List.wrap(modules) do
        mod
      end
      |> Enum.uniq()

    # Commands are not orphan events, filter them out
    command_modules =
      for {_weight, cmd} <- normalized do
        cmd
      end

    produced_only = MapSet.new(produced_events)
    handled_set = MapSet.new(handled_events)
    commands_set = MapSet.new(command_modules)

    orphans =
      produced_only
      |> MapSet.difference(handled_set)
      |> MapSet.difference(commands_set)

    for event <- orphans, reduce: [] do
      acc ->
        [
          "Event #{inspect(event)} produced but not handled by any assertion projection check"
          | acc
        ]
    end
  end

  defp warn_no_extra_projections(model) do
    extra_projs =
      if function_exported?(model, :extra_projections, 0) do
        model.extra_projections()
      else
        []
      end

    if Enum.empty?(extra_projs) do
      [
        "Model has no extra projections - " <>
          "invariants should be defined in state_projection or extra_projections. " <>
          "Consider adding projections with assertions to verify system behavior."
      ]
    else
      []
    end
  end

  defp warn_unbalanced_weights(model) do
    commands = model.commands()
    normalized = PropertyDamage.Model.normalize_commands(commands)

    if length(normalized) >= 2 do
      weights = Enum.map(normalized, fn {weight, _cmd} -> weight end)
      total_weight = Enum.sum(weights)
      max_weight = Enum.max(weights)

      # Warn if a single command has > 80% of total weight
      if max_weight / total_weight > 0.8 do
        {_weight, dominant_cmd} =
          Enum.find(normalized, fn {w, _} -> w == max_weight end)

        [
          "Command #{inspect(dominant_cmd)} has #{Float.round(max_weight / total_weight * 100, 1)}% " <>
            "of total weight - this command will dominate test sequences. " <>
            "Consider more balanced weights for better coverage."
        ]
      else
        []
      end
    else
      []
    end
  end

  defp warn_single_command(model) do
    commands = model.commands()
    normalized = PropertyDamage.Model.normalize_commands(commands)

    if length(normalized) == 1 do
      [{_weight, cmd}] = normalized

      [
        "Model has only one command (#{inspect(cmd)}) - " <>
          "property testing is most effective with multiple commands that interact. " <>
          "Consider adding more commands to test different scenarios."
      ]
    else
      []
    end
  end
end
