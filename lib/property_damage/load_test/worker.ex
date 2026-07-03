defmodule PropertyDamage.LoadTest.Worker do
  @moduledoc false

  use GenServer

  alias PropertyDamage.Executor.Timeout
  alias PropertyDamage.{Generator, PlaceholderRegistry, Runtime, Sequence}
  alias PropertyDamage.LoadTest.Metrics
  alias PropertyDamage.Model.Projection

  defstruct [
    :worker_id,
    :model,
    :adapter,
    :adapter_config,
    :adapter_context,
    :metrics,
    :think_time_range,
    :assertion_mode,
    # Run nonce for client-minted run-scoped values (DR-034); nil until the
    # load-test harness threads one through. Each worker uses its worker_id as
    # the mint_epoch, so workers send distinct minted values regardless.
    :run_nonce,
    # Stats
    :sequences_executed,
    :commands_executed,
    :errors,
    :assertion_failures
  ]

  @type t :: %__MODULE__{}

  @type sequence_result :: %{
          commands_run: non_neg_integer(),
          errors: non_neg_integer(),
          assertion_failures: non_neg_integer()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a new worker with persistent adapter context.

  ## Options

  - `:worker_id` - Unique worker ID (required)
  - `:model` - Model module (required)
  - `:adapter` - Adapter module (required)
  - `:adapter_config` - Adapter configuration (default: %{})
  - `:metrics` - Metrics collector pid (required)
  - `:think_time_range` - {min, max} ms between commands (default: {0, 0})
  - `:assertion_mode` - How to handle assertions (default: :disabled)

  Returns `{:ok, pid}` or `{:error, reason}` if adapter setup fails.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Execute a single command sequence.

  Generates a random sequence using the model and executes it using the
  worker's persistent adapter context. This is a blocking call.

  Returns `{:ok, stats}` with execution statistics.
  """
  @spec execute_sequence(pid()) :: {:ok, sequence_result()} | {:error, term()}
  def execute_sequence(pid) do
    GenServer.call(pid, :execute_sequence, :infinity)
  end

  @doc """
  Get worker statistics.
  """
  @spec stats(pid()) :: map()
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  @doc """
  Stop the worker gracefully.

  Calls `adapter.teardown/1` to clean up the adapter context.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    worker_id = Keyword.fetch!(opts, :worker_id)
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    metrics = Keyword.fetch!(opts, :metrics)
    think_time_range = Keyword.get(opts, :think_time_range, {0, 0})
    assertion_mode = Keyword.get(opts, :assertion_mode, :disabled)
    run_nonce = Keyword.get(opts, :run_nonce)

    # Setup adapter ONCE - this context will be reused for all sequences
    case adapter.setup(adapter_config) do
      {:ok, adapter_context} ->
        state = %__MODULE__{
          worker_id: worker_id,
          model: model,
          adapter: adapter,
          adapter_config: adapter_config,
          adapter_context: adapter_context,
          metrics: metrics,
          think_time_range: think_time_range,
          assertion_mode: assertion_mode,
          run_nonce: run_nonce,
          sequences_executed: 0,
          commands_executed: 0,
          errors: 0,
          assertion_failures: 0
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:adapter_setup_failed, reason}}
    end
  end

  @impl true
  def handle_call(:execute_sequence, _from, state) do
    case run_one_sequence(state) do
      {:ok, result, new_state} ->
        {:reply, {:ok, result}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      worker_id: state.worker_id,
      sequences_executed: state.sequences_executed,
      commands_executed: state.commands_executed,
      errors: state.errors,
      assertion_failures: state.assertion_failures
    }

    {:reply, stats, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Teardown adapter context on worker shutdown
    if state.adapter_context do
      state.adapter.teardown(state.adapter_context)
    end

    :ok
  end

  # ============================================================================
  # Sequence Execution
  # ============================================================================

  defp run_one_sequence(state) do
    # Generate a full sequence using the model
    generator = Generator.generate_sequence(state.model)

    sequence =
      case Enumerable.reduce(generator, {:cont, nil}, fn val, _ -> {:halt, val} end) do
        {:halted, value} -> value
        {:done, _} -> Sequence.linear([])
      end

    # Execute sequence using persistent adapter context
    case execute_sequence_commands(sequence, state) do
      {:ok, commands_run, errors, assertion_failure_count} ->
        result = %{
          commands_run: commands_run,
          errors: errors,
          assertion_failures: assertion_failure_count
        }

        new_state = %{
          state
          | commands_executed: state.commands_executed + commands_run,
            sequences_executed: state.sequences_executed + 1,
            errors: state.errors + errors,
            assertion_failures: state.assertion_failures + assertion_failure_count
        }

        {:ok, result, new_state}

      {:error, reason} ->
        new_state = %{state | errors: state.errors + 1}
        {:error, reason, new_state}
    end
  end

  defp execute_sequence_commands(sequence, state) do
    commands = Sequence.to_list(sequence)

    # external() values a command produces resolve into later commands (DR-021).
    registry = PlaceholderRegistry.build(commands)

    # Initialize projections for this sequence
    initial_projections =
      if state.assertion_mode != :disabled do
        init_projections(state.model)
      else
        nil
      end

    initial_counters =
      if state.assertion_mode != :disabled do
        %{step: 0, command: 0, event: 0}
      else
        nil
      end

    execute_commands(
      commands,
      state,
      initial_projections,
      initial_counters,
      registry,
      0,
      0,
      0
    )
  end

  defp execute_commands(
         [],
         _state,
         _projections,
         _counters,
         _registry,
         commands_run,
         errors,
         assertion_failures
       ) do
    {:ok, commands_run, errors, assertion_failures}
  end

  defp execute_commands(
         [command | rest],
         state,
         projections,
         counters,
         registry,
         commands_run,
         errors,
         assertion_failures
       ) do
    # Apply think time between commands
    maybe_think(state.think_time_range)

    # Execute command and measure latency
    command_module = command.__struct__
    start_time = System.monotonic_time(:microsecond)

    # `commands_run` is this command's 0-based position, so capture keys its
    # produced externals at {:prefix, commands_run} (DR-021).
    {result, error_delta, events, registry} =
      case execute_single_command(command, state, registry, commands_run) do
        {:ok, returned_events, new_registry} ->
          {:ok, 0, returned_events, new_registry}

        {:error, reason} ->
          {{:error, categorize_error(reason)}, 1, [], registry}
      end

    end_time = System.monotonic_time(:microsecond)
    latency_ms = (end_time - start_time) / 1000.0

    # Report metrics
    Metrics.record_request(state.metrics, command_module, latency_ms, result)

    # Run assertions if enabled and command succeeded
    {new_projections, new_counters, assertion_failure_delta} =
      if state.assertion_mode != :disabled and result == :ok do
        run_assertions_for_command(
          command,
          events,
          projections,
          counters,
          commands_run,
          state
        )
      else
        {projections, counters, 0}
      end

    # Continue with remaining commands
    execute_commands(
      rest,
      state,
      new_projections,
      new_counters,
      registry,
      commands_run + 1,
      errors + error_delta,
      assertion_failures + assertion_failure_delta
    )
  end

  defp execute_single_command(command, state, registry, index) do
    # Each worker is a separate execution, so it derives a distinct mint_epoch
    # (its worker_id) from the run nonce (DR-034): workers send distinct
    # client-minted values rather than colliding on the shared SUT.
    mint = {state.run_nonce, state.worker_id}

    case PlaceholderRegistry.resolve_data(registry, command, mint) do
      {:ok, resolved_command} ->
        # Get timeout from adapter
        timeout_ms = Timeout.normalize_timeout(state.adapter.timeout(resolved_command))

        # Per-command injection sink (DR-027), opened via the shared
        # Runtime.InjectionWindow. The inject closure captures the sink pid, so it
        # accumulates correctly from inside the spawned timeout Task below; the
        # worker's process dictionary did not cross that boundary, which made
        # inject raise "outside adapter execution context". The window also
        # guarantees the sink is stopped even when the command times out.
        #
        # Execute with timeout - wrap in Task to enforce timeout.
        execute_fn = fn runtime ->
          task =
            Task.async(fn ->
              state.adapter.execute(resolved_command, state.adapter_context, runtime)
            end)

          case Task.yield(task, timeout_ms) || Task.shutdown(task) do
            {:ok, adapter_result} ->
              adapter_result

            nil ->
              # Timeout - raise exception (consistent with framework heuristics)
              raise PropertyDamage.CommandTimeoutError,
                command: resolved_command,
                timeout_ms: timeout_ms
          end
        end

        {result, injected_events} =
          Runtime.InjectionWindow.run_accumulating(
            execute_fn,
            "Runtime.start_poller is not supported in load-test workers"
          )

        case result do
          {:ok, returned_events} ->
            # Capture external() values from the command's real (adapter-returned)
            # events, keyed by its linear position, so later commands resolve
            # them (DR-021). Injected events are out-of-band and not captured.
            new_registry =
              PlaceholderRegistry.capture(registry, {:prefix, index}, returned_events)

            # Combine injected events (first) with returned events
            all_events = injected_events ++ returned_events
            {:ok, all_events, new_registry}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:unresolved_placeholder, reason}}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp maybe_think({0, 0}), do: :ok

  defp maybe_think({min_ms, max_ms}) do
    think_time = :rand.uniform(max_ms - min_ms + 1) + min_ms - 1
    Process.sleep(think_time)
  end

  defp categorize_error({:adapter_error, _}), do: :adapter_error
  defp categorize_error({:timeout, _}), do: :timeout
  defp categorize_error({:connection_refused, _}), do: :connection_error
  defp categorize_error(_), do: :unknown_error

  # ============================================================================
  # Assertion Support
  # ============================================================================

  defp get_module(%{__struct__: module}), do: module
  defp get_module(map) when is_map(map), do: :plain_map_event
  defp get_module(_other), do: :unknown_event

  defp init_projections(model) do
    command_sequence_projection = model.command_sequence_projection()

    assertion_projections =
      if function_exported?(model, :assertion_projections, 0) do
        model.assertion_projections()
      else
        []
      end

    all_projections = [command_sequence_projection | assertion_projections]

    for projection <- all_projections, into: %{} do
      {projection, projection.init()}
    end
  end

  defp run_assertions_for_command(command, events, projections, counters, command_index, state) do
    model = state.model
    command_module = command.__struct__

    # Update projections with command
    projections = update_projections(projections, command)

    # Update counters for command
    counters =
      counters
      |> Map.update(:step, 1, &(&1 + 1))
      |> Map.update(:command, 1, &(&1 + 1))
      |> Map.update(command_module, 1, &(&1 + 1))

    # Run command assertions
    {counters, failure_count} =
      run_assertions(
        model,
        projections,
        :command,
        command_module,
        counters,
        command_index,
        command,
        state
      )

    # Update projections and run assertions for each event
    {projections, counters, event_failures} =
      Enum.reduce(events, {projections, counters, 0}, fn event, {projs, ctrs, failures} ->
        event_module = get_module(event)
        projs = update_projections(projs, event)

        ctrs =
          ctrs
          |> Map.update(:step, 1, &(&1 + 1))
          |> Map.update(:event, 1, &(&1 + 1))
          |> Map.update(event_module, 1, &(&1 + 1))

        {ctrs, event_failure_count} =
          run_assertions(
            model,
            projs,
            :event,
            event_module,
            ctrs,
            command_index,
            event,
            state
          )

        {projs, ctrs, failures + event_failure_count}
      end)

    {projections, counters, failure_count + event_failures}
  end

  defp update_projections(projections, command_or_event) do
    for {projection_module, projection_state} <- projections, into: %{} do
      {projection_module, projection_module.apply(projection_state, command_or_event)}
    end
  end

  defp run_assertions(
         model,
         projections,
         step_type,
         module,
         counters,
         command_index,
         command_or_event,
         state
       ) do
    command_sequence_projection = model.command_sequence_projection()

    assertion_projections =
      if function_exported?(model, :assertion_projections, 0) do
        model.assertion_projections()
      else
        []
      end

    all_projections = [command_sequence_projection | assertion_projections]

    failure_count =
      Enum.reduce(all_projections, 0, fn projection, failures ->
        projection_state = Map.get(projections, projection)

        assertions =
          if function_exported?(projection, :__assertions__, 0) do
            projection.__assertions__()
          else
            []
          end

        Enum.reduce(assertions, failures, fn assertion, acc_failures ->
          if Projection.should_run?(assertion.trigger, step_type, module, counters) do
            try do
              assertion_fn = assertion.function_name
              apply(projection, assertion_fn, [projection_state, command_or_event])
              acc_failures
            rescue
              e ->
                failure = %{
                  reason: e,
                  command_index: command_index,
                  step_type: step_type,
                  module: module,
                  timestamp: System.monotonic_time(:millisecond)
                }

                Metrics.record_assertion_failure(
                  state.metrics,
                  e.__struct__,
                  module,
                  failure
                )

                acc_failures + 1
            end
          else
            acc_failures
          end
        end)
      end)

    {counters, failure_count}
  end
end
