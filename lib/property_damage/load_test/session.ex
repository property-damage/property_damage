defmodule PropertyDamage.LoadTest.Session do
  @moduledoc """
  A single load test session (simulated user).

  Each session:
  1. Generates a command sequence using the model
  2. Executes commands against the SUT via the adapter
  3. Reports metrics after each command
  4. Optionally waits (think time) between commands
  5. Loops: generates new sequences until stopped

  ## Architecture

  Sessions are lightweight GenServers that run independently.
  They report metrics to a shared Metrics collector and can be
  started/stopped by the Runner.

  ## Usage

      {:ok, session} = Session.start_link(
        model: MyModel,
        adapter: HTTPAdapter,
        adapter_config: %{base_url: "http://localhost:4000"},
        metrics: metrics_pid,
        session_id: 1,
        commands_range: {10, 50},
        think_time_range: {100, 500}
      )

      Session.stop(session)
  """

  use GenServer

  require Logger

  alias PropertyDamage.LoadTest.Metrics
  alias PropertyDamage.{AssertionProjection, Generator, Ref, Sequence}

  # Process dictionary key for injection context during adapter execution
  @injection_ctx_key :property_damage_load_test_injection_ctx

  defstruct [
    :model,
    :adapter,
    :adapter_config,
    :metrics,
    :session_id,
    :commands_range,
    :think_time_range,
    :rate_limiter,
    :run_assertions,
    :running,
    :commands_executed,
    :sequences_completed,
    :errors,
    :assertion_failures
  ]

  @type t :: %__MODULE__{}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a new session.

  ## Options

  - `:model` - Model module (required)
  - `:adapter` - Adapter module (required)
  - `:adapter_config` - Adapter configuration (default: %{})
  - `:metrics` - Metrics collector pid (required)
  - `:session_id` - Unique session ID (required)
  - `:commands_range` - {min, max} commands per sequence (default: {10, 50})
  - `:think_time_range` - {min, max} ms between commands (default: {0, 0})
  - `:rate_limiter` - Optional rate limiter pid
  - `:run_assertions` - Whether to run model assertions during execution (default: false)
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stop a session gracefully.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  @doc """
  Get session statistics.
  """
  @spec stats(pid()) :: map()
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    metrics = Keyword.fetch!(opts, :metrics)
    session_id = Keyword.fetch!(opts, :session_id)
    commands_range = Keyword.get(opts, :commands_range, {10, 50})
    think_time_range = Keyword.get(opts, :think_time_range, {0, 0})
    rate_limiter = Keyword.get(opts, :rate_limiter)
    run_assertions = Keyword.get(opts, :run_assertions, false)

    state = %__MODULE__{
      model: model,
      adapter: adapter,
      adapter_config: adapter_config,
      metrics: metrics,
      session_id: session_id,
      commands_range: commands_range,
      think_time_range: think_time_range,
      rate_limiter: rate_limiter,
      run_assertions: run_assertions,
      running: true,
      commands_executed: 0,
      sequences_completed: 0,
      errors: 0,
      assertion_failures: 0
    }

    # Notify metrics that session started
    Metrics.session_started(metrics)

    # Start the execution loop
    send(self(), :run_sequence)

    {:ok, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    Metrics.session_completed(state.metrics)
    {:stop, :normal, :ok, %{state | running: false}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      session_id: state.session_id,
      commands_executed: state.commands_executed,
      sequences_completed: state.sequences_completed,
      errors: state.errors,
      assertion_failures: state.assertion_failures,
      running: state.running
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:run_sequence, %{running: false} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:run_sequence, state) do
    case run_one_sequence(state) do
      {:ok, new_state} ->
        # Schedule next sequence immediately
        send(self(), :run_sequence)
        {:noreply, new_state}

      {:error, reason, new_state} ->
        Logger.warning("Session #{state.session_id} sequence error: #{inspect(reason)}")
        # Continue despite errors
        send(self(), :run_sequence)
        {:noreply, new_state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.running do
      Metrics.session_completed(state.metrics)
    end

    :ok
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp run_one_sequence(state) do
    {min_commands, max_commands} = state.commands_range
    num_commands = :rand.uniform(max_commands - min_commands + 1) + min_commands - 1

    # Generate sequence
    generator = Generator.generate_sequence(state.model, max_commands: num_commands)

    sequence =
      case Enumerable.reduce(generator, {:cont, nil}, fn val, _ -> {:halt, val} end) do
        {:halted, value} -> value
        {:done, _} -> Sequence.linear([])
      end

    # Execute sequence with metrics collection
    case execute_sequence_with_metrics(sequence, state) do
      {:ok, commands_run, errors, assertion_failure_count} ->
        new_state = %{
          state
          | commands_executed: state.commands_executed + commands_run,
            sequences_completed: state.sequences_completed + 1,
            errors: state.errors + errors,
            assertion_failures: state.assertion_failures + assertion_failure_count
        }

        {:ok, new_state}

      {:error, reason} ->
        new_state = %{state | errors: state.errors + 1}
        {:error, reason, new_state}
    end
  end

  defp execute_sequence_with_metrics(sequence, state) do
    commands = Sequence.to_list(sequence)

    # Setup adapter once for the sequence
    case state.adapter.setup(state.adapter_config) do
      {:ok, adapter_context} ->
        try do
          # Initialize refs map and projections for this sequence
          initial_projections =
            if state.run_assertions do
              init_projections(state.model)
            else
              nil
            end

          initial_counters =
            if state.run_assertions do
              %{step: 0, command: 0, event: 0}
            else
              nil
            end

          execute_commands(
            commands,
            adapter_context,
            state,
            _refs = %{},
            initial_projections,
            initial_counters,
            0,
            0,
            0
          )
        after
          state.adapter.teardown(adapter_context)
        end

      {:error, reason} ->
        {:error, {:adapter_setup_failed, reason}}
    end
  end

  defp execute_commands(
         [],
         _adapter_context,
         _state,
         _refs,
         _projections,
         _counters,
         commands_run,
         errors,
         assertion_failures
       ) do
    {:ok, commands_run, errors, assertion_failures}
  end

  defp execute_commands(
         [command | rest],
         adapter_context,
         state,
         refs,
         projections,
         counters,
         commands_run,
         errors,
         assertion_failures
       ) do
    # Apply think time
    maybe_think(state.think_time_range)

    # Apply rate limiting
    maybe_rate_limit(state.rate_limiter)

    # Execute command and measure latency
    command_module = command.__struct__
    start_time = System.monotonic_time(:microsecond)

    {result, error_delta, new_refs, events} =
      case execute_single_command(command, state.adapter, adapter_context, refs) do
        {:ok, returned_events, updated_refs} ->
          {:ok, 0, updated_refs, returned_events}

        {:error, reason, updated_refs} ->
          # Preserve refs from injected events even on error
          {{:error, categorize_error(reason)}, 1, updated_refs, []}

        {:error, reason} ->
          # No ref updates (e.g., ref resolution failed)
          {{:error, categorize_error(reason)}, 1, refs, []}
      end

    end_time = System.monotonic_time(:microsecond)
    latency_ms = (end_time - start_time) / 1000.0

    # Report metrics
    Metrics.record_request(state.metrics, command_module, latency_ms, result)

    # Run assertions if enabled and command succeeded
    {new_projections, new_counters, assertion_failure_delta} =
      if state.run_assertions and result == :ok do
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

    # Continue with remaining commands, threading updated refs and projections
    execute_commands(
      rest,
      adapter_context,
      state,
      new_refs,
      new_projections,
      new_counters,
      commands_run + 1,
      errors + error_delta,
      assertion_failures + assertion_failure_delta
    )
  end

  defp execute_single_command(command, adapter, adapter_context, refs) do
    # Resolve refs using proper lookup (like executor.ex)
    case resolve_command_refs(command, refs) do
      {:ok, resolved_command} ->
        # Set up injection context in process dictionary
        Process.put(@injection_ctx_key, %{events: [], command: command, refs: refs})

        # Add inject function to adapter context
        adapter_context_with_inject = Map.put(adapter_context, :inject, &inject_event/1)

        result =
          try do
            adapter.execute(resolved_command, adapter_context_with_inject)
          after
            :ok
          end

        # Get injected events from context
        injection_ctx = Process.get(@injection_ctx_key)
        Process.delete(@injection_ctx_key)
        injected_events = Enum.reverse(injection_ctx.events)

        case result do
          {:ok, returned_events} ->
            # Combine injected events (first) with returned events
            all_events = injected_events ++ returned_events

            # Bind refs from all events
            new_refs = bind_refs_from_events(command, all_events, refs)
            {:ok, all_events, new_refs}

          {:error, reason} ->
            # Still bind refs from injected events so subsequent commands can use them
            new_refs = bind_refs_from_events(command, injected_events, refs)
            {:error, reason, new_refs}
        end

      {:error, reason} ->
        {:error, {:ref_resolution_failed, reason}}
    end
  end

  # Resolve symbolic refs in command using the refs map (mirrors executor.ex)
  defp resolve_command_refs(command, refs) do
    try do
      # Get the field to skip (the one this command creates)
      skip_field = get_creates_ref_field(command)
      resolved = deep_resolve_refs(command, refs, skip_field)
      {:ok, resolved}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp get_creates_ref_field(command) do
    case command do
      %{__struct__: command_module} ->
        if function_exported?(command_module, :creates_ref, 0) do
          command_module.creates_ref()
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp deep_resolve_refs(%Ref{} = ref, refs, _skip_field) do
    case Map.get(refs, ref.ref) do
      nil ->
        raise "Unresolved ref: #{inspect(ref)}"

      value ->
        value
    end
  end

  defp deep_resolve_refs(%{__struct__: _} = struct, refs, skip_field) do
    struct
    |> Map.from_struct()
    |> Enum.map(fn {k, v} ->
      if k == skip_field do
        # Don't resolve the creates_ref field - keep the Ref as-is
        {k, v}
      else
        {k, deep_resolve_refs(v, refs, nil)}
      end
    end)
    |> Map.new()
    |> then(&struct(struct.__struct__, &1))
  end

  defp deep_resolve_refs(map, refs, skip_field) when is_map(map) do
    for {k, v} <- map, into: %{} do
      {deep_resolve_refs(k, refs, skip_field), deep_resolve_refs(v, refs, skip_field)}
    end
  end

  defp deep_resolve_refs(list, refs, skip_field) when is_list(list) do
    Enum.map(list, &deep_resolve_refs(&1, refs, skip_field))
  end

  defp deep_resolve_refs(tuple, refs, skip_field) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> deep_resolve_refs(refs, skip_field)
    |> List.to_tuple()
  end

  defp deep_resolve_refs(other, _refs, _skip_field), do: other

  # Bind refs from all events (handles injected + returned events)
  defp bind_refs_from_events(command, events, refs) do
    command_module = command.__struct__

    if function_exported?(command_module, :creates_ref, 0) do
      case command_module.creates_ref() do
        nil ->
          refs

        ref_field ->
          # Find the ref in the command
          case Map.get(command, ref_field) do
            %Ref{} = ref ->
              # Find the value in the first event that has this field set
              value = find_ref_value_in_events(events, ref_field)
              if value, do: Map.put(refs, ref.ref, value), else: refs

            _ ->
              refs
          end
      end
    else
      refs
    end
  end

  defp find_ref_value_in_events(events, ref_field) do
    Enum.find_value(events, fn event ->
      case Map.get(event, ref_field) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp maybe_think({0, 0}), do: :ok

  defp maybe_think({min_ms, max_ms}) do
    think_time = :rand.uniform(max_ms - min_ms + 1) + min_ms - 1
    Process.sleep(think_time)
  end

  defp maybe_rate_limit(nil), do: :ok

  defp maybe_rate_limit(rate_limiter) do
    # Simple token bucket rate limiting
    GenServer.call(rate_limiter, :acquire)
  end

  defp categorize_error({:adapter_error, _}), do: :adapter_error
  defp categorize_error({:timeout, _}), do: :timeout
  defp categorize_error({:connection_refused, _}), do: :connection_error
  defp categorize_error(_), do: :unknown_error

  # Inject function for adapter use - stores events in process dictionary
  defp inject_event(event) do
    case Process.get(@injection_ctx_key) do
      nil ->
        raise ArgumentError, "inject called outside adapter execution context"

      ctx ->
        # Accumulate injected event
        Process.put(@injection_ctx_key, %{ctx | events: [event | ctx.events]})
        :ok
    end
  end

  # ============================================================================
  # Assertion Support
  # ============================================================================

  # Get module from struct or fallback for plain maps
  defp get_module(%{__struct__: module}), do: module
  defp get_module(map) when is_map(map), do: :plain_map_event
  defp get_module(_other), do: :unknown_event

  # Initialize all projections for a model
  defp init_projections(model) do
    state_projection = model.state_projection()
    assertion_projections = model.assertion_projections()
    all_projections = [state_projection | assertion_projections]

    for projection <- all_projections, into: %{} do
      {projection, projection.init()}
    end
  end

  # Update projections and run assertions for a command and its events
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
      run_assertions(model, projections, :command, command_module, counters, command_index, state)

    # Update projections and run assertions for each event
    {projections, counters, event_failures} =
      Enum.reduce(events, {projections, counters, 0}, fn event, {projs, ctrs, failures} ->
        # Handle both struct events and plain map events
        event_module = get_module(event)

        # Update projections with event
        projs = update_projections(projs, event)

        # Update counters for event
        ctrs =
          ctrs
          |> Map.update(:step, 1, &(&1 + 1))
          |> Map.update(:event, 1, &(&1 + 1))
          |> Map.update(event_module, 1, &(&1 + 1))

        # Run event assertions
        {ctrs, event_failure_count} =
          run_assertions(model, projs, :event, event_module, ctrs, command_index, state)

        {projs, ctrs, failures + event_failure_count}
      end)

    {projections, counters, failure_count + event_failures}
  end

  # Update all projections with a command or event
  defp update_projections(projections, command_or_event) do
    for {projection_module, projection_state} <- projections, into: %{} do
      {projection_module, projection_module.apply(projection_state, command_or_event)}
    end
  end

  # Run assertions and record failures
  defp run_assertions(model, projections, step_type, module, counters, command_index, state) do
    assertion_projections = model.assertion_projections()

    failure_count =
      Enum.reduce(assertion_projections, 0, fn projection, failures ->
        projection_state = Map.get(projections, projection)
        assertions = projection.__assertions__()

        Enum.reduce(assertions, failures, fn assertion, acc_failures ->
          if AssertionProjection.should_run?(assertion.trigger, step_type, module, counters) do
            result =
              if function_exported?(projection, :assert, 2) do
                projection.assert(assertion.name, projection_state)
              else
                # Legacy fallback
                projection.check(assertion.name, projection_state, %{})
              end

            case result do
              :ok ->
                acc_failures

              {:error, reason} ->
                # Record failure to metrics
                failure = %{
                  reason: reason,
                  command_index: command_index,
                  step_type: step_type,
                  module: module,
                  timestamp: System.monotonic_time(:millisecond)
                }

                Metrics.record_assertion_failure(
                  state.metrics,
                  assertion.name,
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
