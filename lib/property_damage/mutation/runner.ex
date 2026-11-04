defmodule PropertyDamage.Mutation.Runner do
  @moduledoc false

  alias PropertyDamage.{Failure, FailureReport, Options, Telemetry}
  alias PropertyDamage.Mutation.{MutatingAdapter, Operator, Report}
  alias PropertyDamage.Progress
  alias PropertyDamage.Progress.{MutationResult, MutationUpdate, Reporter}

  @doc """
  Runs mutation testing against a model.

  ## Options

  - `:model` - The model module (required)
  - `:targets` - A list with exactly one entry (required): an adapter module or
    `{AdapterModule, name:, config:}`. `injectors:` and `mocks:` are not supported
    and raise. See `PropertyDamage.Target`.
  - `:operators` - List of operator names to use (default: all)
  - `:mutations_per_command` - Max mutations per operator (default: 5). A command
    gets up to this cap times the number of operators.
  - `:max_runs` - Property test runs per mutation (default: 10)
  - `:target_score` - Target mutation score (default: 0.80)
  - `:timeout_ms` - Timeout per mutation test (default: 30000)
  - `:verbose` - Print progress (default: false)
  - `:on_progress` - Progress consumer (DR-022). A 1-arity function called with a
    `%PropertyDamage.Progress{}` per mutation (`data: %MutationUpdate{}`) and once
    at the end with the terminal report (`data: %MutationResult{}`).

  ## Returns

  `{:ok, report}`, or `{:error, {:baseline_failed, command_module, message}}`
  when the unmutated baseline run for `command_module` fails with an adapter
  error or a failed setup (report kind `:execution_failed` or
  `:setup_failed`). See `PropertyDamage.Mutation`.
  """
  @spec run(keyword()) ::
          {:ok, Report.t()}
          | {:error, {:baseline_failed, module(), String.t()}}
  def run(opts) do
    opts = Options.validate_mutation!(opts)
    [target] = opts[:targets]

    Options.reject_unsupported_target_keys!(
      [target],
      [:injectors, :mocks],
      "PropertyDamage.Mutation.run/1"
    )

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
      target: target,
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
        adapter: config.target.adapter
      )

    # Get command types from the model
    commands = get_command_types(config.model)

    # Get operator modules
    operators = Operator.operators_by_name(config.operators)

    # Generate and test mutations
    result =
      Enum.reduce_while(commands, {:ok, report}, fn command, {:ok, acc_report} ->
        case test_command_mutations(command, operators, config, acc_report) do
          {:ok, _} = ok -> {:cont, ok}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, report} ->
        completed_at = DateTime.utc_now()
        report = Report.finalize(report, started_at, completed_at)

        # Terminal notification (DR-022): a copy of the authoritative report for
        # consumers. The returned `{:ok, report}` remains the source of truth.
        Reporter.emit(config.reporter, fn -> %MutationResult{report: report} end)

        {:ok, report}

      {:error, _} = error ->
        error
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # The mutation targets are the roots of commands/0, not the leaf modules of
  # expansions/0 (see the moduledoc of PropertyDamage.Mutation).
  defp get_command_types(model) do
    # Use the canonical normalizer so every command-spec shape ({module, opts},
    # bare module, map form) resolves to its module. The prior
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
    # First, run a baseline test to get sample events. A baseline that fails
    # with an adapter error or a failed setup stops the run: every mutation
    # would fail the same way.
    with {:ok, sample_events} <- get_sample_events(command, config) do
      # Generate mutations from each operator. Each operator yields up to
      # `mutations_per_command` mutations, and the command keeps up to that cap
      # times the operator count.
      mutations =
        operators
        |> Enum.flat_map(fn operator ->
          generate_mutations_for_command(operator, sample_events, config)
        end)
        |> Enum.take(config.mutations_per_command * length(operators))

      # Test each mutation
      {:ok,
       Enum.reduce(mutations, report, fn {operator, mutation}, acc_report ->
         result = test_single_mutation(command, operator, mutation, config)
         emit_progress(config.reporter, result)
         Report.record_result(acc_report, result)
       end)}
    end
  end

  defp get_sample_events(command, config) do
    # Run a single test to get sample events for this command type.
    # This gives us realistic events to mutate.
    case run_baseline_test(config) do
      {:error, message} -> {:error, {:baseline_failed, command, message}}
      {:ok, events} -> {:ok, events}
    end
  end

  defp run_baseline_test(config) do
    # Harvest realistic events to mutate by capturing a full run trace (DR-033).
    # The trace carries the complete event log regardless of outcome, so sample
    # events are available for the normal case of mutation testing: a model
    # whose suite PASSES. PropertyDamage.run's lean success result carries no
    # event log, so relying on it yielded zero events (and thus zero mutations)
    # for any passing model.
    trace =
      PropertyDamage.RunTrace.capture(
        model: config.model,
        targets: [PropertyDamage.Target.to_entry(config.target)],
        seed: :erlang.unique_integer([:positive]),
        max_commands: 10
      )

    case trace.outcome do
      {:fail, %Failure{} = failure} ->
        # An adapter error or a failed setup breaks every mutant run the same
        # way, so neither leaves anything to measure.
        if FailureReport.kind_of(failure) in [:execution_failed, :setup_failed] do
          {:error, FailureReport.failure_message(failure) || inspect(failure)}
        else
          {:ok, sample_events(trace)}
        end

      _ ->
        {:ok, sample_events(trace)}
    end
  end

  defp sample_events(trace) do
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
        inner_adapter: config.target.adapter,
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
        # Test failed. A check caught the mutation (killed), or the run broke
        # because the mutated adapter errored (killed by error), which says
        # nothing about the checks.
        %{
          mutation: mutation,
          command: command,
          operator: operator.name(),
          result: kill_outcome(failure),
          failure_message: failure_message(failure),
          duration_ms: duration_ms
        }
    end
  end

  defp run_with_timeout(mutating_adapter, config) do
    task =
      Task.async(fn ->
        # The MutatingAdapter is passed as the adapter *module* with its struct
        # threaded through the target config under :__mutating_adapter__; its
        # setup/1 extracts the struct from there (a struct cannot be a target
        # adapter, which must be a module the executor can dispatch on). The
        # wrapper keeps the user target's name.
        PropertyDamage.run(
          model: config.model,
          targets: [
            {MutatingAdapter,
             name: config.target.name,
             config: Map.put(config.target.config, :__mutating_adapter__, mutating_adapter)}
          ],
          max_runs: config.max_runs,
          max_commands: 20
        )
      end)

    case Task.yield(task, config.timeout_ms) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> :timeout
    end
  end

  defp kill_outcome(%FailureReport{kind: :execution_failed}), do: :killed_by_error
  defp kill_outcome(_failure), do: :killed

  # A failed run returns a failure report; its message names the failing check.
  # Anything else gets a readable rendering so the update is never blank.
  defp failure_message(%FailureReport{} = report) do
    FailureReport.failure_message(report) || inspect(report.failure_reason)
  end

  defp failure_message(other), do: inspect(other)

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
            :killed_by_error -> "✓ KILLED BY ERROR"
            :survived -> "✗ SURVIVED"
            :timeout -> "⏱ TIMEOUT"
          end

        IO.puts("  #{status}: #{inspect(update.command)} - #{inspect(update.mutation)}")

      %Progress{} ->
        :ok
    end
  end
end
