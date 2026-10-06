defmodule PropertyDamage.Validation do
  @moduledoc false

  alias PropertyDamage.Error
  alias PropertyDamage.Nemesis

  # Callbacks a regular command module must implement. Single source of truth
  # shared by validate_command_callbacks!/1 and the validate!/3 command check.
  @required_command_callbacks [{:generator, 1}]

  # A nemesis module listed in commands/0 generates through `new!/2`, not
  # `generator/1` (DR-031): it does not `use PropertyDamage.Command`, and the
  # generation path (PropertyDamage.Generator.get_command_generator/3) branches
  # on nemesis_module?/1 to call new!/2. Validate the callback generation
  # actually calls, so the documented "nemesis directly in commands/0" usage
  # passes validation instead of raising a spurious missing-generator/1 error.
  @required_nemesis_callbacks [{:new!, 2}]

  @doc """
  Validate test configuration.

  Raises `ArgumentError` for fatal configuration errors.
  Returns `{:ok, warnings}` where warnings is a list of warning messages.

  ## Parameters

  - `model` - Model module
  - `adapter` - Adapter module
  - `opts` - Options:
    - `:injectors` - List of InjectorAdapter modules

  ## Returns

  - `{:ok, warnings}` - Validation passed, warnings is list of strings
  - Raises `ArgumentError` on fatal errors
  """
  @spec validate!(module(), module(), keyword()) :: {:ok, [String.t()]}
  def validate!(model, adapter, opts \\ []) do
    injectors = Keyword.get(opts, :injectors, [])

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

    # A removed lifecycle hook, or a nemesis among the setup or teardown
    # commands, fails here as it fails PropertyDamage.run/1.
    PropertyDamage.Model.check_lifecycle!(model)

    # Phase 3: Validate commands and projections (requires callbacks)
    errors = []
    errors = errors ++ validate_commands(model)
    errors = errors ++ validate_sequences(model)
    errors = errors ++ validate_projections(model)
    errors = errors ++ validate_injectable_events(model, injectors)

    unless Enum.empty?(errors) do
      error_msg = Enum.join(errors, "\n  - ")
      raise ArgumentError, "Validation failed:\n  - #{error_msg}"
    end

    # Collect warnings
    warnings = []
    warnings = warnings ++ warn_missing_downstream_observables(model)
    warnings = warnings ++ warn_orphan_events(model)
    warnings = warnings ++ warn_no_check_projections(model)
    warnings = warnings ++ warn_unbalanced_weights(model)
    warnings = warnings ++ warn_single_command(model)
    warnings = warnings ++ sequence_warnings(model)

    {:ok, warnings}
  end

  @doc """
  Warns about `when:` and `weight:` on a setup or teardown entry.

  Setup and teardown commands form a sequence: every entry runs in order, so
  `when:` and `weight:` have no effect there.
  """
  @spec sequence_warnings(module()) :: [String.t()]
  def sequence_warnings(model) do
    for callback <- [:setup_each, :teardown_each],
        function_exported?(model, callback, 0),
        {module, opts} when is_atom(module) <- Enum.map(apply(model, callback, []), &entry_opts/1),
        key <- [:when, :weight],
        Keyword.has_key?(opts, key) do
      "#{callback}/0: #{inspect(module)} sets #{key}: ignored in a sequence"
    end
  end

  defp entry_opts({module, weight}) when is_atom(module) and is_integer(weight),
    do: {module, [weight: weight]}

  defp entry_opts({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}

  defp entry_opts(%{command: module} = map),
    do: {module, map |> Map.delete(:command) |> Map.to_list()}

  defp entry_opts(module), do: {module, []}

  # Every setup and teardown entry is validated as a commands/0 entry: its
  # shape, its module, its callbacks and the keys of a map `overrides:`.
  defp validate_sequences(model) do
    for callback <- [:setup_each, :teardown_each],
        function_exported?(model, callback, 0),
        entry <- apply(model, callback, []),
        reduce: [] do
      acc ->
        validate_command_spec!(entry)
        module = PropertyDamage.Model.entry_module(entry)

        cond do
          not Code.ensure_loaded?(module) ->
            ["#{callback}/0: command module #{inspect(module)} does not exist" | acc]

          missing = missing_command_callback(module) ->
            {name, arity} = missing

            [
              "#{callback}/0: command #{inspect(module)} is missing required callback #{name}/#{arity}"
              | acc
            ]

          unknown = unknown_override_keys(module, entry) ->
            [
              "#{callback}/0: `overrides:` for #{inspect(module)} sets field(s) " <>
                "#{inspect(unknown)} the command does not define"
              | acc
            ]

          true ->
            acc
        end
    end
    |> Enum.reverse()
  end

  # The keys of a map `overrides:` the command struct does not define, or nil.
  # A function `overrides:` is checked when it runs, at generation.
  defp unknown_override_keys(module, entry) do
    {_module, opts} = entry_opts(entry)

    with %{} = overrides when map_size(overrides) > 0 <- Keyword.get(opts, :overrides),
         true <- function_exported?(module, :__struct__, 0),
         fields = module.__struct__() |> Map.from_struct() |> Map.keys(),
         [_ | _] = unknown <- Map.keys(overrides) -- fields do
      unknown
    else
      _ -> nil
    end
  end

  @doc """
  Warns about targets that would share state.

  Returns one warning for each pair of targets that use the same adapter with
  an equal `config:`. Such variants talk to the same slice of the system under
  test, so a comparison between them measures interference instead of a
  difference between variants.
  """
  @spec target_warnings([PropertyDamage.Target.t()]) :: [String.t()]
  def target_warnings(targets) do
    for %{index: i} = a <- targets,
        %{index: j} = b <- targets,
        i < j,
        a.adapter == b.adapter,
        a.config == b.config do
      "targets #{inspect(a.name)} (index #{i}) and #{inspect(b.name)} (index #{j}) " <>
        "use the same adapter #{inspect(a.adapter)} with identical `config:`; " <>
        "give each target its own `config:` (for example a tenant) so the variants " <>
        "do not share state"
    end
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

    for {_weight, cmd, _spec} <- normalized do
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

  # {module, weight} format (bare integer)
  defp validate_command_spec!({cmd, weight})
       when is_atom(cmd) and is_integer(weight) and weight > 0 do
    :ok
  end

  defp validate_command_spec!({cmd, weight}) when is_atom(cmd) and is_integer(weight) do
    raise ArgumentError, Error.format_config_error(:invalid_command_weight, {weight, cmd})
  end

  # {module, opts} format (new)
  defp validate_command_spec!({cmd, opts}) when is_atom(cmd) and is_list(opts) do
    :ok
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
    # generator/1 for regular commands, new!/2 for nemesis modules (DR-031).
    for {callback, arity} <- required_command_callbacks(cmd) do
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

    for {weight, cmd, _spec} <- normalized do
      IO.puts(io, "  - #{inspect(cmd)} (weight: #{weight})")
    end

    IO.puts(io, "")

    # Projections
    state_proj = model.command_sequence_projection()

    extra_projs =
      if function_exported?(model, :check_projections, 0) do
        model.check_projections()
      else
        []
      end

    IO.puts(io, "State Projection: #{inspect(state_proj)}")
    IO.puts(io, "Extra Projections (#{length(extra_projs)}):")

    for proj <- extra_projs do
      checks =
        if function_exported?(proj, :__checks__, 0) do
          proj.__checks__()
        else
          []
        end

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
    # check_projections is optional
    required_callbacks = [:commands, :command_sequence_projection]

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
    required_callbacks = [{:setup, 1}, {:teardown, 1}, {:execute, 3}]

    for {callback, arity} <- required_callbacks,
        not function_exported?(adapter, callback, arity),
        reduce: [] do
      acc -> ["Adapter #{inspect(adapter)} missing required callback #{callback}/#{arity}" | acc]
    end
  end

  defp validate_commands(model) do
    commands = model.commands()
    normalized = PropertyDamage.Model.normalize_commands(commands)

    for {_weight, cmd, _spec} <- normalized, reduce: [] do
      acc ->
        cond do
          not Code.ensure_loaded?(cmd) ->
            ["Command module #{inspect(cmd)} does not exist" | acc]

          missing = missing_command_callback(cmd) ->
            {callback, arity} = missing

            [
              "Command #{inspect(cmd)} is missing required callback #{callback}/#{arity}"
              | acc
            ]

          true ->
            acc
        end
    end
  end

  # First missing required command callback ({callback, arity}), or nil when the
  # command implements them all. Mirrors validate_command_callbacks!/1 but
  # accumulates rather than raising, matching the validate!/3 error-collection.
  defp missing_command_callback(cmd) do
    Enum.find(required_command_callbacks(cmd), fn {callback, arity} ->
      not function_exported?(cmd, callback, arity)
    end)
  end

  # Which callbacks a command module in commands/0 must implement. Nemesis
  # modules generate via new!/2 (DR-031); every other command via generator/1.
  defp required_command_callbacks(cmd) do
    if Nemesis.nemesis_module?(cmd) do
      @required_nemesis_callbacks
    else
      @required_command_callbacks
    end
  end

  defp validate_projections(model) do
    errors = []

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

    for proj <- extra_projs, not Code.ensure_loaded?(proj), reduce: errors do
      acc -> ["Extra projection #{inspect(proj)} does not exist" | acc]
    end
  end

  defp validate_injectable_events(model, injectors) do
    if function_exported?(model, :injectable_events, 0) do
      injectable = model.injectable_events()
      emitted = collect_emitted_events(injectors)

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

  defp collect_emitted_events(injectors) do
    Enum.flat_map(injectors, fn adapter ->
      # Ensure the module is loaded before reflecting on it: an injector adapter
      # is passed by name and may never have been called yet, and
      # function_exported?/3 reports false for an unloaded module (it does not
      # load it), which would spuriously report every injectable event uncovered.
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :__emits__, 0) do
        adapter.__emits__()
      else
        []
      end
    end)
  end

  defp warn_missing_downstream_observables(model) do
    commands = model.commands()
    normalized = PropertyDamage.Model.normalize_commands(commands)

    for {_weight, cmd, spec} <- normalized,
        Map.get(spec, :observables, []) == [],
        reduce: [] do
      acc ->
        [
          "Command #{inspect(cmd)} declares no :observables - event coverage not verified"
          | acc
        ]
    end
  end

  defp warn_orphan_events(model) do
    commands = model.commands()
    normalized = PropertyDamage.Model.normalize_commands(commands)

    # Collect all events that commands can produce
    produced_events =
      for {_weight, _cmd, spec} <- normalized,
          event <- Map.get(spec, :observables, []) do
        event
      end
      |> Enum.uniq()

    # Collect all events handled by extra projections
    extra_projs =
      if function_exported?(model, :check_projections, 0) do
        model.check_projections()
      else
        []
      end

    handled_events =
      for proj <- extra_projs,
          function_exported?(proj, :__checks__, 0),
          check <- proj.__checks__(),
          mod <- check_handled_modules(check) do
        mod
      end
      |> Enum.uniq()

    # Commands are not orphan events, filter them out
    command_modules =
      for {_weight, cmd, _spec} <- normalized do
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
          "Event #{inspect(event)} produced but not handled by any check projection"
          | acc
        ]
    end
  end

  # Events a check observes. Synchronous (@check) checks list them
  # under trigger.modules; polling (@eventually) checks are spawned by the
  # events in eventually.after (and thus observe them). Polling checks have
  # no :trigger key, so reaching for check.trigger blindly would crash.
  defp check_handled_modules(%{trigger: %{modules: modules}}), do: List.wrap(modules)

  defp check_handled_modules(%{eventually: %{after: after_events}}),
    do: List.wrap(after_events)

  defp check_handled_modules(_check), do: []

  defp warn_no_check_projections(model) do
    extra_projs =
      if function_exported?(model, :check_projections, 0) do
        model.check_projections()
      else
        []
      end

    if Enum.empty?(extra_projs) do
      [
        "Model has no extra projections - " <>
          "invariants should be defined in command_sequence_projection or check_projections. " <>
          "Consider adding check projections to verify system behavior."
      ]
    else
      []
    end
  end

  defp warn_unbalanced_weights(model) do
    commands = model.commands()
    normalized = PropertyDamage.Model.normalize_commands(commands)

    if length(normalized) >= 2 do
      weights = Enum.map(normalized, fn {weight, _cmd, _opts} -> weight end)
      total_weight = Enum.sum(weights)
      max_weight = Enum.max(weights)

      # Warn if a single command has > 80% of total weight
      if max_weight / total_weight > 0.8 do
        {_weight, dominant_cmd, _opts} =
          Enum.find(normalized, fn {w, _, _} -> w == max_weight end)

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
      [{_weight, cmd, _opts}] = normalized

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
