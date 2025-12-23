defmodule PropertyDamage.Executor do
  @moduledoc """
  Executes command sequences against the System Under Test.

  The Executor is the core engine that runs command sequences, manages refs,
  updates projections, runs checks, and collects events from both the adapter
  and injector adapters.

  ## Execution Flow

  For each command in the sequence:

  1. Resolve symbolic refs to concrete values
  2. Execute via adapter (command → events)
  3. If creates_ref/0 defined and events produced, bind new ref
  4. Update projections (command first, then events)
  5. Drain injector events and process them
  6. Run triggered checks
  7. Record events in event log

  ## Ref Resolution

  Commands may contain symbolic refs (created via `Ref.symbolic/1`). Before
  execution, these are replaced with their concrete values. If a ref hasn't
  been resolved yet (its producer hasn't run), execution fails.

  ## Event Log

  All events are recorded in the event log with metadata:

  - Command events: source = :command, command_index set
  - Injector events: source = :injector, injector_adapter set

  ## Projection Updates

  Projections receive both commands and events via `apply/2`:

  1. `projection.apply(state, command)` - for tracking command execution
  2. `projection.apply(state, event)` - for each event produced

  ## Check Execution

  After each step, triggered checks are evaluated:

  - `:always` checks run after every step
  - `after: Module` checks run when Module was the command or event type
  - `sample: N` throttles check execution to every Nth trigger

  ## Results

  Returns a result struct containing:

  - `:success` - Boolean indicating if all checks passed
  - `:event_log` - Complete event log
  - `:projections` - Final projection states
  - `:refs` - Ref resolution map
  - `:failed_at_index` - Index where check failed (nil if success)
  - `:failure_reason` - Check failure reason (nil if success)
  """

  alias PropertyDamage.{Ref, EventQueue}
  alias PropertyDamage.EventLog.Entry

  @typedoc """
  Result of executing a command sequence.
  """
  @type result :: %{
          success: boolean(),
          event_log: [Entry.t()],
          projections: %{module() => any()},
          refs: %{reference() => any()},
          failed_at_index: non_neg_integer() | nil,
          failure_reason: term() | nil
        }

  @doc """
  Execute a command sequence using the given model and adapter.

  This is the main entry point for execution. It handles the full lifecycle:
  adapter setup, command execution, injector event draining, and cleanup.

  ## Parameters

  - `commands` - List of command structs to execute
  - `model` - Model module defining projections and checks
  - `adapter` - Adapter module for SUT interaction
  - `opts` - Options (see below)

  ## Options

  - `:adapter_config` - Config passed to adapter.setup/1
  - `:event_queue` - EventQueue pid for injector events (optional)
  - `:injector_adapters` - List of injector adapter modules (optional)

  ## Returns

  - `{:ok, result}` - Execution completed (check result.success for pass/fail)
  - `{:error, reason}` - Setup or execution infrastructure failed
  """
  @spec run(list(), module(), module(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(commands, model, adapter, opts \\ []) do
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    event_queue = Keyword.get(opts, :event_queue)

    with {:ok, adapter_context} <- adapter.setup(adapter_config) do
      try do
        result = execute_sequence(commands, model, adapter, adapter_context, event_queue)
        {:ok, result}
      after
        adapter.teardown(adapter_context)
      end
    end
  end

  @doc """
  Execute a command sequence with pre-established contexts.

  Lower-level API when you've already set up the adapter. Useful for shrinking
  where you want to reuse contexts across multiple execution attempts.

  ## Parameters

  - `commands` - List of command structs to execute
  - `model` - Model module
  - `adapter` - Adapter module
  - `adapter_context` - Pre-established adapter context
  - `event_queue` - EventQueue pid (optional)

  ## Returns

  Result struct directly (no wrapping tuple).
  """
  @spec execute_sequence(list(), module(), module(), map(), pid() | nil) :: result()
  def execute_sequence(commands, model, adapter, adapter_context, event_queue \\ nil) do
    initial_state = %{
      event_log: [],
      projections: init_projections(model),
      refs: %{},
      step_count: 0,
      check_counters: %{}
    }

    result =
      commands
      |> Enum.with_index()
      |> Enum.reduce_while(initial_state, fn {command, index}, state ->
        case execute_command(command, index, state, model, adapter, adapter_context, event_queue) do
          {:ok, new_state} -> {:cont, new_state}
          {:error, reason, failed_state} -> {:halt, {:failed, index, reason, failed_state}}
        end
      end)

    case result do
      {:failed, index, reason, state} ->
        %{
          success: false,
          event_log: Enum.reverse(state.event_log),
          projections: state.projections,
          refs: state.refs,
          failed_at_index: index,
          failure_reason: reason
        }

      state ->
        %{
          success: true,
          event_log: Enum.reverse(state.event_log),
          projections: state.projections,
          refs: state.refs,
          failed_at_index: nil,
          failure_reason: nil
        }
    end
  end

  # Initialize all projection states
  defp init_projections(model) do
    state_projection = model.state_projection()
    assertion_projections = model.assertion_projections()

    all_projections = [state_projection | assertion_projections]

    for projection <- all_projections, into: %{} do
      {projection, projection.init()}
    end
  end

  # Execute a single command
  defp execute_command(command, index, state, model, adapter, adapter_context, event_queue) do
    # 1. Resolve refs in command
    case resolve_command_refs(command, state.refs) do
      {:ok, resolved_command} ->
        # 2. Execute via adapter
        case adapter.execute(resolved_command, adapter_context) do
          {:ok, events} ->
            # 3. Bind new ref if command creates one
            refs = maybe_bind_ref(command, events, state.refs)

            # 4. Update projections with command
            projections = update_projections(state.projections, resolved_command)

            # 5. Update projections with events and record in log
            {projections, event_log} =
              process_events(events, :command, index, state.event_log, projections)

            # 6. Drain and process injector events
            {projections, event_log} =
              process_injector_events(event_queue, event_log, projections)

            # 7. Run checks
            check_ctx = %{
              command: resolved_command,
              events: events,
              command_index: index,
              step_count: state.step_count + 1,
              projections: projections
            }

            case run_checks(model, projections, check_ctx, state.check_counters) do
              {:ok, check_counters} ->
                new_state = %{
                  event_log: event_log,
                  projections: projections,
                  refs: refs,
                  step_count: state.step_count + 1,
                  check_counters: check_counters
                }

                {:ok, new_state}

              {:error, check_name, reason, check_counters} ->
                failed_state = %{
                  event_log: event_log,
                  projections: projections,
                  refs: refs,
                  step_count: state.step_count + 1,
                  check_counters: check_counters
                }

                {:error, {:check_failed, check_name, reason}, failed_state}
            end

          {:error, reason} ->
            {:error, {:adapter_error, reason}, state}
        end

      {:error, reason} ->
        {:error, {:ref_resolution_error, reason}, state}
    end
  end

  # Resolve all refs in a command struct, skipping the creates_ref field
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
    command_module = command.__struct__

    if function_exported?(command_module, :creates_ref, 0) do
      command_module.creates_ref()
    else
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

  # Bind a new ref if the command creates one
  defp maybe_bind_ref(command, events, refs) do
    command_module = command.__struct__

    if function_exported?(command_module, :creates_ref, 0) do
      case command_module.creates_ref() do
        nil ->
          refs

        ref_field ->
          # Find the value in the first event
          case events do
            [first_event | _] ->
              value = Map.get(first_event, ref_field)

              # Find the ref in the command
              case Map.get(command, ref_field) do
                %Ref{} = ref -> Map.put(refs, ref.ref, value)
                _ -> refs
              end

            [] ->
              refs
          end
      end
    else
      refs
    end
  end

  # Update all projections with a command or event
  defp update_projections(projections, item) do
    for {projection, state} <- projections, into: %{} do
      {projection, projection.apply(state, item)}
    end
  end

  # Process events from command execution
  defp process_events(events, source, command_index, event_log, projections) do
    Enum.reduce(events, {projections, event_log}, fn event, {projs, log} ->
      entry = %Entry{
        timestamp: System.monotonic_time(:millisecond),
        command_index: command_index,
        event: event,
        source: source,
        injector_adapter: nil
      }

      new_projs = update_projections(projs, event)
      {new_projs, [entry | log]}
    end)
  end

  # Drain and process events from injector adapters
  defp process_injector_events(nil, event_log, projections), do: {projections, event_log}

  defp process_injector_events(event_queue, event_log, projections) do
    entries = EventQueue.drain(event_queue)

    Enum.reduce(entries, {projections, event_log}, fn queue_entry, {projs, log} ->
      entry = %Entry{
        timestamp: queue_entry.timestamp,
        command_index: nil,
        event: queue_entry.event,
        source: :injector,
        injector_adapter: queue_entry.adapter_module
      }

      new_projs = update_projections(projs, queue_entry.event)
      {new_projs, [entry | log]}
    end)
  end

  # Run all triggered checks
  defp run_checks(model, projections, check_ctx, check_counters) do
    assertion_projections = model.assertion_projections()

    Enum.reduce_while(assertion_projections, {:ok, check_counters}, fn projection,
                                                                       {:ok, counters} ->
      projection_state = Map.get(projections, projection)
      checks = projection.__checks__()

      case run_projection_checks(projection, projection_state, checks, check_ctx, counters) do
        {:ok, new_counters} ->
          {:cont, {:ok, new_counters}}

        {:error, check_name, reason, new_counters} ->
          {:halt, {:error, check_name, reason, new_counters}}
      end
    end)
  end

  defp run_projection_checks(projection, projection_state, checks, check_ctx, counters) do
    Enum.reduce_while(checks, {:ok, counters}, fn check, {:ok, acc_counters} ->
      if should_run_check?(check, check_ctx) do
        check_key = {projection, check.name}
        current_count = Map.get(acc_counters, check_key, 0) + 1
        new_counters = Map.put(acc_counters, check_key, current_count)

        if rem(current_count, check.sample) == 0 do
          case projection.check(check.name, projection_state, check_ctx) do
            :ok ->
              {:cont, {:ok, new_counters}}

            {:error, reason} ->
              {:halt, {:error, check.name, reason, new_counters}}
          end
        else
          {:cont, {:ok, new_counters}}
        end
      else
        {:cont, {:ok, acc_counters}}
      end
    end)
  end

  defp should_run_check?(%{trigger: :always}, _ctx), do: true

  defp should_run_check?(%{trigger: [{:after, modules}]}, ctx) do
    command_module = ctx.command.__struct__
    event_modules = Enum.map(ctx.events, & &1.__struct__)

    Enum.any?(modules, fn trigger_module ->
      trigger_module == command_module or trigger_module in event_modules
    end)
  end

  defp should_run_check?(_, _ctx), do: false
end
