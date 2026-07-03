defmodule PropertyDamage.Mutation.Runner do
  @moduledoc false

  alias PropertyDamage.Mutation.{MutatingAdapter, Operator, Report}
  alias PropertyDamage.{Options, Telemetry}
  alias PropertyDamage.Progress
  alias PropertyDamage.Progress.{MutationResult, MutationUpdate, Reporter}

  @doc """
  Runs mutation testing against a model.

  ## Options

  - `:model` - The model module (required)
  - `:adapter` - The adapter module (required)
  - `:adapter_config` - Configuration for the adapter
  - `:operators` - List of operator names to use (default: all)
  - `:mutations_per_command` - Max mutations per command type (default: 5)
  - `:max_runs` - Property test runs per mutation (default: 10)
  - `:target_score` - Target mutation score (default: 0.80)
  - `:timeout_ms` - Timeout per mutation test (default: 30000)
  - `:verbose` - Print progress (default: false)
  - `:on_progress` - Progress consumer (DR-022). A 1-arity function called with a
    `%PropertyDamage.Progress{}` per mutation (`data: %MutationUpdate{}`) and once
    at the end with the terminal report (`data: %MutationResult{}`).
  """
  @spec run(keyword()) :: {:ok, Report.t()} | {:error, term()}
  def run(opts) do
    opts = Options.validate_mutation!(opts)

    # Unified progress projection (DR-022): one reporter fans out to the verbose
    # printer (if any), the user `on_progress:` callback (if any), and telemetry
    # (only when a handler is attached). With no consumers it is inert and no
    # %Progress{} is built.
    reporter =
      Reporter.new([
        if(opts[:verbose], do: verbose_consumer()),
        opts[:on_progress],
        Telemetry.progress_consumer([:mutation])
      ])

    config = %{
      model: opts[:model],
      adapter: opts[:adapter],
      adapter_config: opts[:adapter_config],
      operators: opts[:operators],
      mutations_per_command: opts[:mutations_per_command],
      max_runs: opts[:max_runs],
      target_score: opts[:target_score],
      timeout_ms: opts[:timeout_ms],
      reporter: reporter
    }

    started_at = DateTime.utc_now()

    report =
      Report.new(
        target_score: config.target_score,
        model: config.model,
        adapter: config.adapter
      )

    # Get command types from the model
    commands = get_command_types(config.model)

    # Get operator modules
    operators = Operator.operators_by_name(config.operators)

    # Generate and test mutations
    report =
      Enum.reduce(commands, report, fn command, acc_report ->
        test_command_mutations(command, operators, config, acc_report)
      end)

    completed_at = DateTime.utc_now()
    report = Report.finalize(report, started_at, completed_at)

    # Terminal notification (DR-022): a copy of the authoritative report for
    # consumers. The returned `{:ok, report}` remains the source of truth.
    Reporter.emit(config.reporter, fn -> %MutationResult{report: report} end)

    {:ok, report}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_command_types(model) do
    # Use the canonical normalizer so every command-spec shape ({module, opts},
    # {module, weight}, bare module, map form) resolves to its module. The prior
    # ad-hoc `{_weight, cmd}` match destructured the standard `{module, opts}`
    # spec backwards, yielding the opts keyword list as the "command"; that
    # invalid target then crashed the MutatingAdapter and every mutant was
    # spuriously reported killed regardless of the model's invariants.
    model.commands()
    |> PropertyDamage.Model.normalize_commands()
    |> Enum.map(fn {_weight, module, _spec} -> module end)
    |> Enum.uniq()
  end

  defp test_command_mutations(command, operators, config, report) do
    # First, run a baseline test to get sample events
    sample_events = get_sample_events(command, config)

    # Generate mutations from each operator
    mutations =
      operators
      |> Enum.flat_map(fn operator ->
        generate_mutations_for_command(operator, sample_events, config)
      end)
      |> Enum.take(config.mutations_per_command * length(operators))

    # Test each mutation
    Enum.reduce(mutations, report, fn {operator, mutation}, acc_report ->
      result = test_single_mutation(command, operator, mutation, config)
      emit_progress(config.reporter, result)
      Report.record_result(acc_report, result)
    end)
  end

  defp get_sample_events(command, config) do
    # Run a single test to get sample events for this command type.
    # This gives us realistic events to mutate.
    run_baseline_test(command, config)
  end

  defp run_baseline_test(_command, config) do
    # Harvest realistic events to mutate by capturing a full run trace (DR-033).
    # The trace carries the complete event log regardless of outcome, so sample
    # events are available for the normal case of mutation testing: a model
    # whose suite PASSES. PropertyDamage.run's lean success result carries no
    # event log, so relying on it yielded zero events (and thus zero mutations)
    # for any passing model.
    trace =
      PropertyDamage.RunTrace.capture(
        model: config.model,
        adapter: config.adapter,
        adapter_config: config.adapter_config,
        seed: :erlang.unique_integer([:positive]),
        max_commands: 10
      )

    Enum.flat_map(trace.event_log, fn
      %{event: event} -> [event]
      _ -> []
    end)
  end

  defp generate_mutations_for_command(operator, events, config) do
    if events == [] do
      []
    else
      mutations =
        operator.generate_mutations(events,
          max_mutations: config.mutations_per_command
        )

      Enum.map(mutations, fn mutation -> {operator, mutation} end)
    end
  end

  defp test_single_mutation(command, operator, mutation, config) do
    start_time = System.monotonic_time(:millisecond)

    # Create a mutating adapter
    mutating_adapter =
      MutatingAdapter.new(
        inner_adapter: config.adapter,
        target_command: command,
        mutation: mutation,
        operator: operator
      )

    # Run PropertyDamage with the mutating adapter
    result =
      try do
        run_with_timeout(mutating_adapter, config)
      catch
        :exit, {:timeout, _} ->
          :timeout
      end

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    # Determine if mutation was killed or survived
    case result do
      :timeout ->
        %{
          mutation: mutation,
          command: command,
          operator: operator.name(),
          result: :timeout,
          failure_message: nil,
          duration_ms: duration_ms
        }

      {:ok, _} ->
        # Test passed = mutation survived (bad)
        %{
          mutation: mutation,
          command: command,
          operator: operator.name(),
          result: :survived,
          failure_message: nil,
          duration_ms: duration_ms
        }

      {:error, failure} ->
        # Test failed = mutation killed (good)
        %{
          mutation: mutation,
          command: command,
          operator: operator.name(),
          result: :killed,
          failure_message: failure_message(failure),
          duration_ms: duration_ms
        }
    end
  end

  defp run_with_timeout(mutating_adapter, config) do
    task =
      Task.async(fn ->
        # The MutatingAdapter is passed as the adapter *module* with its struct
        # threaded through adapter_config under :__mutating_adapter__; its setup/1
        # extracts the struct from there (a struct cannot be an :adapter value,
        # which must be a module the executor can dispatch on).
        PropertyDamage.run(
          model: config.model,
          adapter: MutatingAdapter,
          adapter_config: Map.put(config.adapter_config, :__mutating_adapter__, mutating_adapter),
          max_runs: config.max_runs,
          max_commands: 20
        )
      end)

    case Task.yield(task, config.timeout_ms) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> :timeout
    end
  end

  defp failure_message(%{failure_message: msg}) when is_binary(msg), do: msg
  defp failure_message(%{failure_type: type}), do: to_string(type)
  defp failure_message(_), do: "Unknown failure"

  # Emit a per-mutation update (DR-022). `result` is the raw result map recorded
  # in the report; the projection wraps the relevant fields in a MutationUpdate.
  defp emit_progress(reporter, result) do
    Reporter.emit(reporter, fn ->
      %MutationUpdate{
        command: result.command,
        operator: result.operator,
        mutation: result.mutation,
        result: result.result,
        failure_message: result.failure_message,
        duration_ms: result.duration_ms
      }
    end)
  end

  # The `verbose:` consumer: one status line per mutation, matching the prior
  # inline output exactly. The terminal MutationResult has no verbose rendering.
  defp verbose_consumer do
    fn
      %Progress{data: %MutationUpdate{} = update} ->
        status =
          case update.result do
            :killed -> "✓ KILLED"
            :survived -> "✗ SURVIVED"
            :timeout -> "⏱ TIMEOUT"
          end

        IO.puts("  #{status}: #{inspect(update.command)} - #{inspect(update.mutation)}")

      %Progress{} ->
        :ok
    end
  end
end
