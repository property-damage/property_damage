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

    {:ok, warnings}
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
    assertion_projs = model.assertion_projections()
    IO.puts(io, "State Projection: #{inspect(state_proj)}")
    IO.puts(io, "Assertion Projections (#{length(assertion_projs)}):")

    for proj <- assertion_projs do
      checks = proj.__checks__()
      IO.puts(io, "  - #{inspect(proj)} (#{length(checks)} checks)")
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

  # Validation helpers

  defp validate_model_exists(model) do
    if Code.ensure_loaded?(model) do
      []
    else
      ["Model module #{inspect(model)} does not exist"]
    end
  end

  defp validate_model_callbacks(model) do
    required_callbacks = [:commands, :state_projection, :assertion_projections]

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

    assertion_projs = model.assertion_projections()

    for proj <- assertion_projs, not Code.ensure_loaded?(proj), reduce: errors do
      acc -> ["Assertion projection #{inspect(proj)} does not exist" | acc]
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

    # Collect all events handled by assertion projections
    assertion_projs = model.assertion_projections()

    handled_events =
      for proj <- assertion_projs,
          check <- proj.__checks__(),
          {:after, modules} <- List.wrap(check.trigger),
          mod <- modules do
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
end
