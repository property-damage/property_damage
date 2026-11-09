defmodule PropertyDamage.LoadTest.Worker do
  @moduledoc false

  # Sequence generation is a pure function of the run seed, the worker id and
  # the sequence number. A worker's own seed is `worker_seed(run_seed,
  # worker_id)`, a hash of the pair. Its nth sequence (0-based) is drawn with
  # `Generator.generate_value/2` from `Generator.run_seed(worker_seed, n)`, the
  # same sized and seeded path `PropertyDamage.run/1` uses for its runs.

  use GenServer

  alias PropertyDamage.{EventQueue, Failure, Generator, PlaceholderRegistry, Runtime, Sequence}
  alias PropertyDamage.Executor.{Phases, Stepping, Timeout}
  alias PropertyDamage.LoadTest.Metrics
  alias PropertyDamage.Model.Projection.Checks
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.Telemetry

  defstruct [
    :worker_id,
    :model,
    :target,
    :adapter_context,
    :metrics,
    :think_time_range,
    :check_mode,
    # Run nonce for client-minted run-scoped values (DR-034); nil until the
    # load-test harness threads one through. Each worker uses its worker_id as
    # the mint_epoch, so workers send distinct minted values regardless.
    :run_nonce,
    # Seed of this worker's sequences, from `worker_seed/2`.
    :seed,
    # How a sequence runs: `:legacy` (the worker's own loop) or `:stepping`
    # (a stepping session over the engine's per-command path).
    :session,
    # Stepping session only: the `Stepping.Context`, built once per worker.
    :context,
    # Stats
    :sequences_executed,
    :commands_executed,
    :errors,
    :check_failures
  ]

  @type t :: %__MODULE__{}

  @type sequence_result :: %{
          commands_run: non_neg_integer(),
          errors: non_neg_integer(),
          check_failures: non_neg_integer()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a new worker with persistent adapter context.

  ## Options

  - `:worker_id` - Unique worker ID (required)
  - `:model` - Model module (required)
  - `:target` - `PropertyDamage.Target` to run against (required)
  - `:metrics` - Metrics collector pid (required)
  - `:think_time_range` - {min, max} ms between commands (default: {0, 0})
  - `:check_mode` - How to handle checks (default: :disabled)
  - `:seed` - Run seed the worker's sequences derive from (default: random)
  - `:session` - Internal. `:legacy` (default) runs a sequence through the
    worker's own loop; `:stepping` runs it as a stepping session over the
    engine's per-command path

  Returns `{:ok, pid}` or `{:error, reason}` if adapter setup fails.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  @spec worker_seed(integer(), non_neg_integer()) :: non_neg_integer()
  def worker_seed(run_seed, worker_id) when is_integer(run_seed) do
    :erlang.phash2({run_seed, worker_id}, 4_294_967_296)
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
    target = Keyword.fetch!(opts, :target)
    metrics = Keyword.fetch!(opts, :metrics)
    think_time_range = Keyword.get(opts, :think_time_range, {0, 0})
    check_mode = Keyword.get(opts, :check_mode, :disabled)
    run_nonce = Keyword.get(opts, :run_nonce)
    run_seed = opts[:seed] || :rand.uniform(1_000_000_000)

    # Setup adapter ONCE - this context will be reused for all sequences. It
    # runs in a scope of its own; a load test builds no failure report, so
    # its log lines are dropped (DR-054).
    {set_up, _lines} = PropertyDamage.Log.inline(fn -> target.adapter.setup(target.config) end)

    case set_up do
      {:ok, adapter_context} ->
        state = %__MODULE__{
          worker_id: worker_id,
          model: model,
          target: target,
          adapter_context: adapter_context,
          metrics: metrics,
          think_time_range: think_time_range,
          check_mode: check_mode,
          run_nonce: run_nonce,
          seed: worker_seed(run_seed, worker_id),
          sequences_executed: 0,
          commands_executed: 0,
          errors: 0,
          check_failures: 0
        }

        {:ok, with_session(state, Keyword.get(opts, :session, :legacy))}

      {:error, reason} ->
        {:stop, PropertyDamage.Failure.setup_failed(reason)}
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
      check_failures: state.check_failures
    }

    {:reply, stats, state}
  end

  # A stepping session owns an event queue for the life of the worker.
  defp with_session(state, :legacy), do: %{state | session: :legacy}

  defp with_session(state, :stepping) do
    {:ok, event_queue} = EventQueue.start_link()

    context = %Stepping.Context{
      model: state.model,
      adapter: state.target.adapter,
      adapter_context: state.adapter_context,
      event_queue: event_queue,
      target_name: state.target.name
    }

    %{state | session: :stepping, context: context}
  end

  @impl true
  def terminate(_reason, state) do
    if state.context, do: EventQueue.stop(state.context.event_queue)

    # Teardown adapter context on worker shutdown
    if state.adapter_context do
      PropertyDamage.Log.inline(fn -> state.target.adapter.teardown(state.adapter_context) end)
    end

    :ok
  end

  # ============================================================================
  # Sequence Execution
  # ============================================================================

  defp run_one_sequence(state) do
    # Generate a full sequence using the model
    generator = Generator.generate_sequence(state.model)
    sequence_seed = Generator.run_seed(state.seed, state.sequences_executed)
    sequence = Generator.generate_value(generator, sequence_seed)

    # Execute sequence using persistent adapter context
    case run_sequence(sequence, sequence_seed, state) do
      {:ok, commands_run, errors, check_failure_count} ->
        result = %{
          commands_run: commands_run,
          errors: errors,
          check_failures: check_failure_count
        }

        new_state = %{
          state
          | commands_executed: state.commands_executed + commands_run,
            sequences_executed: state.sequences_executed + 1,
            errors: state.errors + errors,
            check_failures: state.check_failures + check_failure_count
        }

        {:ok, result, new_state}

      {:error, reason} ->
        new_state = %{state | errors: state.errors + 1}
        {:error, reason, new_state}
    end
  end

  defp run_sequence(sequence, _seed, %{session: :legacy} = state),
    do: execute_sequence_commands(sequence, state)

  defp run_sequence(sequence, seed, %{session: :stepping} = state),
    do: execute_stepped_sequence(sequence, seed, state)

  defp execute_sequence_commands(sequence, state) do
    commands = Sequence.to_list(sequence)

    # external() values a command produces resolve into later commands (DR-021).
    registry = PlaceholderRegistry.build(commands)

    # Initialize projections for this sequence
    initial_projections =
      if state.check_mode != :disabled do
        init_projections(state.model)
      else
        nil
      end

    initial_counters =
      if state.check_mode != :disabled do
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
         check_failures
       ) do
    {:ok, commands_run, errors, check_failures}
  end

  defp execute_commands(
         [command | rest],
         state,
         projections,
         counters,
         registry,
         commands_run,
         errors,
         check_failures
       ) do
    # Apply think time between commands
    maybe_think(state.think_time_range)

    # Execute command and measure latency
    command_module = command.__struct__
    start_time = System.monotonic_time(:microsecond)

    # `commands_run` is this command's 0-based position, so capture keys its
    # produced externals at `Position.prefix(commands_run)` (DR-021).
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

    # Run checks if enabled and command succeeded
    {new_projections, new_counters, check_failure_delta} =
      if state.check_mode != :disabled and result == :ok do
        run_checks_for_command(
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
      check_failures + check_failure_delta
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
        timeout_ms = Timeout.normalize_timeout(state.target.adapter.timeout(resolved_command))

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
              # Capture adapter failures inside the task and convert them to an
              # error result. Task.async links the task to this worker, so an
              # uncaught raise/throw/exit here would otherwise cascade
              # worker -> pool -> runner -> caller instead of being recorded as a
              # single failed command.
              try do
                state.target.adapter.execute(resolved_command, state.adapter_context, runtime)
              rescue
                exception -> {:error, {:adapter_error, exception}}
              catch
                kind, reason -> {:error, {:adapter_error, {kind, reason}}}
              end
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
              PlaceholderRegistry.capture(registry, Position.prefix(index), returned_events)

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
  # Stepping session
  # ============================================================================

  # One sequence as a stepping session: the engine's startup checks, setup
  # commands, each root through `Stepping.step/4` (timed), a drain after each
  # root, finalization, then teardown commands. The tally counts commands
  # stepped, errors and check failures.
  defp execute_stepped_sequence(sequence, seed, state) do
    ctx = state.context

    # The teardown commands are drawn after the roots, as a property run does.
    sequence = Generator.teardown_commands(state.model, sequence, seed)

    exec =
      Stepping.init_state(state.model,
        event_queue: ctx.event_queue,
        check_mode: state.check_mode,
        placeholder_registry: sequence.registry,
        rng_seed: seed,
        run_nonce: state.run_nonce,
        mint_epoch: state.worker_id,
        telemetry:
          Telemetry.engine_context(
            %{index: state.target.index, name: state.target.name},
            state.sequences_executed
          )
      )

    tally = %{commands_run: 0, errors: 0, check_failures: 0, seen: 0}

    {outcome, tally} =
      case Stepping.run_startup_checks(exec) do
        {:ok, exec} ->
          run_stepped_phases(sequence, exec, tally, state)

        {:failed, nil, failure, failed} ->
          tally = count_check_failure(tally, failure, nil, state)
          {{:failed, nil, failure, failed}, tally}
      end

    {result, tally} = finish_session(outcome, tally, ctx, state)

    # A startup failure ran no setup command, so no teardown command runs.
    if not match?({:failed, nil, _, _}, outcome) do
      Phases.run_teardown(sequence.teardown, result.exec, ctx)
    end

    {:ok, tally.commands_run, tally.errors, tally.check_failures}
  end

  defp run_stepped_phases(sequence, exec, tally, state) do
    case Phases.run_setup(sequence.setup, exec, state.context) do
      {:ok, exec} ->
        sequence
        |> Sequence.to_list()
        |> Enum.with_index()
        |> Enum.reduce_while({exec, tally}, &step_root(&1, &2, state))

      {:failed, reason, failed} ->
        {{:failed, nil, reason, failed}, %{tally | errors: tally.errors + 1}}
    end
  end

  # One root: think, then time the engine step, record the request, fold the
  # check failures the step recorded and drain the event queue. Returns
  # `{:cont, {exec, tally}}` to go on or `{:halt, {{:failed, ...}, tally}}` to
  # end the sequence.
  defp step_root({command, index}, {exec, tally}, state) do
    maybe_think(state.think_time_range)

    started = System.monotonic_time(:microsecond)
    stepped = Stepping.step(command, index, exec, state.context)
    latency_ms = (System.monotonic_time(:microsecond) - started) / 1000.0
    tally = %{tally | commands_run: tally.commands_run + 1}
    module = command.__struct__

    case stepped do
      {:ok, exec, _outcome} ->
        Metrics.record_request(state.metrics, module, latency_ms, :ok)
        {exec, tally} = fold_recorded(exec, tally, state)
        drain_root(exec, tally, index, state)

      # A check that halted: the command itself succeeded.
      {:error, failure, failed, {:ok, _events}} ->
        Metrics.record_request(state.metrics, module, latency_ms, :ok)

        if Failure.class(failure) == :check do
          tally = count_check_failure(tally, failure, module, state)
          {:halt, {{:failed, index, failure, failed}, tally}}
        else
          # Not a check (a projection rejected an event): the step failed.
          error_request(state, module, 0)
          {:halt, {{:failed, index, failure, failed}, %{tally | errors: tally.errors + 1}}}
        end

      # The adapter errored or raised, or a placeholder did not resolve. The
      # failed state is the state before the command with its adapter time
      # and logs, so the session goes on from it, as the worker's own loop does.
      {:error, _failure, failed, outcome} ->
        Metrics.record_request(
          state.metrics,
          module,
          latency_ms,
          {:error, categorize_outcome(outcome)}
        )

        drain_root(failed, %{tally | errors: tally.errors + 1}, index, state)
    end
  end

  defp error_request(state, module, latency_ms),
    do: Metrics.record_request(state.metrics, module, latency_ms, {:error, :unknown_error})

  defp drain_root(exec, tally, index, state) do
    case Stepping.drain(exec, state.context) do
      {:ok, drained} ->
        {:cont, {drained, tally}}

      {:error, failure, failed} ->
        tally = count_check_failure(tally, failure, nil, state)
        {:halt, {{:failed, index, failure, failed}, tally}}
    end
  end

  # The outcome the engine reports for a command that was not answered `{:ok, _}`,
  # in the categories of `categorize_error/1`.
  defp categorize_outcome({:error, reason}), do: categorize_error(reason)
  defp categorize_outcome({:raised, _exception}), do: :adapter_error
  defp categorize_outcome(:not_called), do: :unknown_error

  # Finalizes the session and counts what finalization reports: recorded
  # failures not yet counted and, for a run that did not already fail, the
  # failure that ended it (an unsettled eventual check, a teardown check).
  defp finish_session(outcome, tally, ctx, state) do
    result = Stepping.finalize(outcome, ctx)

    tally =
      result.check_failures
      |> Enum.drop(tally.seen)
      |> Enum.reduce(tally, &record_recorded(&2, &1, state))

    tally =
      if result.failure_reason != nil and not match?({:failed, _, _, _}, outcome),
        do: count_check_failure(tally, result.failure_reason, nil, state),
        else: tally

    {Map.put(result, :exec, final_state(outcome)), tally}
  end

  defp final_state({:failed, _index, _failure, state}), do: state
  defp final_state(state), do: state

  # Folds the failures a `:record`-mode step added to the state.
  defp fold_recorded(exec, tally, state) do
    added = length(exec.check_failures) - tally.seen

    tally =
      exec.check_failures
      |> Enum.take(added)
      |> Enum.reverse()
      |> Enum.reduce(tally, &record_recorded(&2, &1, state))

    {exec, tally}
  end

  defp record_recorded(tally, recorded, state) do
    {exception, _stacktrace} = split_reason(recorded.reason)
    failure = Map.put(recorded, :reason, exception)
    Metrics.record_check_failure(state.metrics, exception.__struct__, recorded.module, failure)
    %{tally | check_failures: tally.check_failures + 1, seen: tally.seen + 1}
  end

  # A failure the engine halted on.
  defp count_check_failure(tally, %Failure{} = failure, module, state) do
    exception =
      case Failure.detail(failure) do
        {exception, _stacktrace} when is_exception(exception) -> exception
        exception when is_exception(exception) -> exception
        other -> %RuntimeError{message: inspect(other)}
      end

    record = %{
      reason: exception,
      command_index: tally.commands_run - 1,
      step_type: :command,
      module: module,
      timestamp: System.monotonic_time(:millisecond)
    }

    Metrics.record_check_failure(state.metrics, exception.__struct__, module, record)
    %{tally | check_failures: tally.check_failures + 1}
  end

  defp split_reason({exception, stacktrace}) when is_exception(exception),
    do: {exception, stacktrace}

  defp split_reason(exception) when is_exception(exception), do: {exception, []}
  defp split_reason(other), do: {%RuntimeError{message: inspect(other)}, []}

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
  # Check Support
  # ============================================================================

  defp get_module(%{__struct__: module}), do: module
  defp get_module(map) when is_map(map), do: :plain_map_event
  defp get_module(_other), do: :unknown_event

  defp init_projections(model) do
    for projection <- PropertyDamage.Model.projection_modules(model), into: %{} do
      {projection, projection.init()}
    end
  end

  defp run_checks_for_command(command, events, projections, counters, command_index, state) do
    model = state.model
    command_module = command.__struct__

    # Fold the command AND all of its events into the projections BEFORE running
    # any check, mirroring the main Executor (which asserts against the
    # post-events state; see Executor.Step.execute/4, which runs the step checks with projections that
    # already have both the command and its events applied). A command-level
    # `@check every: Cmd` therefore observes this command's own events — e.g. a
    # read-consistency check sees the value just retrieved. Folding events one at
    # a time and asserting in between (the prior behavior) made such checks read
    # stale state and misfire.
    projections = update_projections(projections, command)
    projections = Enum.reduce(events, projections, &update_projections(&2, &1))

    # Command counters + command checks
    counters =
      counters
      |> Map.update(:step, 1, &(&1 + 1))
      |> Map.update(:command, 1, &(&1 + 1))
      |> Map.update(command_module, 1, &(&1 + 1))

    {counters, command_failures} =
      run_step_checks(
        model,
        projections,
        :command,
        command_module,
        counters,
        command_index,
        command,
        state
      )

    # Per-event counters + event checks, all against the fully-folded
    # projections (again matching the Executor's event-check pass).
    {counters, event_failures} =
      Enum.reduce(events, {counters, 0}, fn event, {ctrs, failures} ->
        event_module = get_module(event)

        ctrs =
          ctrs
          |> Map.update(:step, 1, &(&1 + 1))
          |> Map.update(:event, 1, &(&1 + 1))
          |> Map.update(event_module, 1, &(&1 + 1))

        {ctrs, event_failure_count} =
          run_step_checks(
            model,
            projections,
            :event,
            event_module,
            ctrs,
            command_index,
            event,
            state
          )

        {ctrs, failures + event_failure_count}
      end)

    {projections, counters, command_failures + event_failures}
  end

  defp update_projections(projections, command_or_event) do
    for {projection_module, projection_state} <- projections, into: %{} do
      {projection_module, projection_module.apply(projection_state, command_or_event)}
    end
  end

  defp run_step_checks(
         model,
         projections,
         step_type,
         module,
         counters,
         command_index,
         command_or_event,
         state
       ) do
    all_projections = PropertyDamage.Model.projection_modules(model)

    step_ctx = %{step_type: step_type, module: module, command_or_event: command_or_event}

    failure_count =
      Enum.reduce(all_projections, 0, fn projection, failures ->
        projection_state = Map.get(projections, projection)

        case Checks.step_checks(projection, projection_state, step_ctx, counters) do
          {:ok, _counters} ->
            failures

          {:error, _check_name, {e, _stacktrace}, _counters} ->
            failure = %{
              reason: e,
              command_index: command_index,
              step_type: step_type,
              module: module,
              timestamp: System.monotonic_time(:millisecond)
            }

            Metrics.record_check_failure(state.metrics, e.__struct__, module, failure)

            failures + 1
        end
      end)

    {counters, failure_count}
  end
end
