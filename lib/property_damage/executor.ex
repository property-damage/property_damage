defmodule PropertyDamage.Executor do
  @moduledoc """
  Executes command sequences against the System Under Test.

  The Executor is the core engine that runs command sequences, manages refs,
  updates projections, runs checks, and collects events from both the adapter
  and injector adapters.

  ## Sequence Execution

  The Executor handles both linear and branching sequences:

  ### Linear Sequences

  Commands are executed sequentially:

      %Sequence{prefix: [cmd1, cmd2, cmd3], branches: nil, suffix: []}

  Execution: cmd1 → cmd2 → cmd3

  ### Branching Sequences

  Commands with parallel branches:

      %Sequence{
        prefix: [cmd1],
        branches: [[cmd2a, cmd3a], [cmd2b]],
        suffix: [cmd4]
      }

  Execution:
  1. Execute prefix: cmd1
  2. Fork state at branch point
  3. Execute branch A: cmd2a → cmd3a
  4. Execute branch B: cmd2b
  5. Verify linearizability of branch execution
  6. Merge state, execute suffix: cmd4

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
  - Branch ID for parallel execution tracking

  ## Results

  Returns a result struct containing:

  - `:success` - Boolean indicating if all checks passed
  - `:event_log` - Complete event log
  - `:projections` - Final projection states
  - `:refs` - Ref resolution map
  - `:failed_at_index` - Index where check failed (nil if success)
  - `:failure_reason` - Check failure reason (nil if success)
  - `:linearization` - Selected linearization (for branching sequences)
  """

  alias PropertyDamage.{Ref, EventQueue, Sequence, Settle, Nemesis}
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
          failure_reason: term() | nil,
          linearization: [struct()] | nil
        }

  @doc """
  Execute a command sequence using the given model and adapter.

  This is the main entry point for execution. It handles the full lifecycle:
  adapter setup, command execution, injector event draining, and cleanup.

  ## Parameters

  - `sequence` - Sequence struct to execute (linear or branching)
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
  @spec run(Sequence.t() | list(), module(), module(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def run(sequence_or_commands, model, adapter, opts \\ [])

  def run(%Sequence{} = sequence, model, adapter, opts) do
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    event_queue = Keyword.get(opts, :event_queue)

    with {:ok, adapter_context} <- adapter.setup(adapter_config) do
      try do
        result = execute_sequence(sequence, model, adapter, adapter_context, event_queue)
        {:ok, result}
      after
        adapter.teardown(adapter_context)
      end
    end
  end

  # Backwards compatibility: accept list of commands as linear sequence
  def run(commands, model, adapter, opts) when is_list(commands) do
    run(Sequence.linear(commands), model, adapter, opts)
  end

  @doc """
  Execute a command sequence with pre-established contexts.

  Lower-level API when you've already set up the adapter. Useful for shrinking
  where you want to reuse contexts across multiple execution attempts.

  ## Parameters

  - `sequence` - Sequence struct to execute
  - `model` - Model module
  - `adapter` - Adapter module
  - `adapter_context` - Pre-established adapter context
  - `event_queue` - EventQueue pid (optional)

  ## Returns

  Result struct directly (no wrapping tuple).
  """
  @spec execute_sequence(Sequence.t() | list(), module(), module(), map(), pid() | nil) ::
          result()
  def execute_sequence(sequence_or_commands, model, adapter, adapter_context, event_queue \\ nil)

  def execute_sequence(
        %Sequence{branches: nil} = sequence,
        model,
        adapter,
        adapter_context,
        event_queue
      ) do
    # Linear sequence: just execute prefix ++ suffix
    commands = Sequence.to_list(sequence)
    execute_linear(commands, model, adapter, adapter_context, event_queue)
  end

  def execute_sequence(%Sequence{} = sequence, model, adapter, adapter_context, event_queue) do
    # Branching sequence: execute prefix, branches, suffix
    execute_branching(sequence, model, adapter, adapter_context, event_queue)
  end

  # Backwards compatibility: accept list of commands
  def execute_sequence(commands, model, adapter, adapter_context, event_queue)
      when is_list(commands) do
    execute_linear(commands, model, adapter, adapter_context, event_queue)
  end

  # ============================================================================
  # Linear Execution
  # ============================================================================

  defp execute_linear(commands, model, adapter, adapter_context, event_queue) do
    initial_state = %{
      event_log: [],
      projections: init_projections(model),
      refs: %{},
      step_count: 0,
      check_counters: %{},
      branch_id: nil
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

    finalize_result(result)
  end

  # ============================================================================
  # Branching Execution
  # ============================================================================

  defp execute_branching(sequence, model, adapter, adapter_context, event_queue) do
    %Sequence{prefix: prefix, branches: branches, suffix: suffix} = sequence

    initial_state = %{
      event_log: [],
      projections: init_projections(model),
      refs: %{},
      step_count: 0,
      check_counters: %{},
      branch_id: nil
    }

    # Phase 1: Execute prefix
    prefix_result =
      prefix
      |> Enum.with_index()
      |> Enum.reduce_while(initial_state, fn {command, index}, state ->
        case execute_command(command, index, state, model, adapter, adapter_context, event_queue) do
          {:ok, new_state} -> {:cont, new_state}
          {:error, reason, failed_state} -> {:halt, {:failed, index, reason, failed_state}}
        end
      end)

    case prefix_result do
      {:failed, index, reason, state} ->
        finalize_result({:failed, index, reason, state})

      prefix_state ->
        # Phase 2: Execute branches from forked state
        branch_start_index = length(prefix)

        case execute_all_branches(
               branches,
               branch_start_index,
               prefix_state,
               model,
               adapter,
               adapter_context,
               event_queue
             ) do
          {:ok, branch_results, branch_event_logs, linearization} ->
            # Phase 3: Merge branch states and execute suffix
            merged_state = merge_branch_states(prefix_state, branch_results, branch_event_logs)

            suffix_start_index = branch_start_index + count_branch_commands(branches)

            suffix_result =
              suffix
              |> Enum.with_index(suffix_start_index)
              |> Enum.reduce_while(merged_state, fn {command, index}, state ->
                case execute_command(
                       command,
                       index,
                       state,
                       model,
                       adapter,
                       adapter_context,
                       event_queue
                     ) do
                  {:ok, new_state} ->
                    {:cont, new_state}

                  {:error, reason, failed_state} ->
                    {:halt, {:failed, index, reason, failed_state}}
                end
              end)

            finalize_result(suffix_result, linearization)

          {:error, branch_id, index, reason, state} ->
            finalize_result({:failed, index, {:branch_failure, branch_id, reason}, state})

          {:linearization_failed, branch_results, branch_event_logs} ->
            merged_state = merge_branch_states(prefix_state, branch_results, branch_event_logs)

            finalize_result(
              {:failed, branch_start_index,
               {:linearization_failed, "No valid linearization found for branch execution"},
               merged_state}
            )
        end
    end
  end

  defp execute_all_branches(
         branches,
         start_index,
         prefix_state,
         model,
         adapter,
         adapter_context,
         event_queue
       ) do
    # Execute each branch independently from the same starting state
    branch_results =
      branches
      |> Enum.with_index()
      |> Enum.map(fn {branch_commands, branch_id} ->
        # Fork state for this branch
        branch_state = %{
          prefix_state
          | event_log: [],
            branch_id: branch_id
        }

        # Calculate command indices for this branch
        # Each branch starts from the same logical index after prefix
        branch_result =
          branch_commands
          |> Enum.with_index(start_index)
          |> Enum.reduce_while(branch_state, fn {command, index}, state ->
            case execute_command(
                   command,
                   index,
                   state,
                   model,
                   adapter,
                   adapter_context,
                   event_queue
                 ) do
              {:ok, new_state} -> {:cont, new_state}
              {:error, reason, failed_state} -> {:halt, {:failed, index, reason, failed_state}}
            end
          end)

        {branch_id, branch_result, branch_commands}
      end)

    # Check for any branch failures
    case Enum.find(branch_results, fn {_, result, _} -> match?({:failed, _, _, _}, result) end) do
      {branch_id, {:failed, index, reason, state}, _} ->
        {:error, branch_id, index, reason, state}

      nil ->
        # All branches succeeded - collect results
        successful_results =
          Enum.map(branch_results, fn {branch_id, state, commands} ->
            {branch_id, state, commands}
          end)

        branch_event_logs =
          Enum.map(successful_results, fn {branch_id, state, _} ->
            {branch_id, Enum.reverse(state.event_log)}
          end)

        # Try to find a valid linearization
        branch_commands = Enum.map(successful_results, fn {_, _, commands} -> commands end)

        case find_linearization(
               branch_commands,
               branch_event_logs,
               prefix_state.projections,
               model
             ) do
          {:ok, linearization} ->
            {:ok, successful_results, branch_event_logs, linearization}

          :no_linearization ->
            {:linearization_failed, successful_results, branch_event_logs}
        end
    end
  end

  defp find_linearization(branch_commands, _branch_event_logs, _projections, _model) do
    # For now, use a simple interleaving (round-robin)
    # The full linearization checker (M3) will replace this
    linearization = interleave_branches(branch_commands)
    {:ok, linearization}
  end

  defp interleave_branches(branches) do
    # Simple round-robin interleaving
    # This will be replaced by proper linearization checking in M3
    branches
    |> Enum.map(&Enum.with_index/1)
    |> List.flatten()
    |> Enum.sort_by(fn {_cmd, idx} -> idx end)
    |> Enum.map(fn {cmd, _idx} -> cmd end)
  end

  defp merge_branch_states(prefix_state, branch_results, branch_event_logs) do
    # Merge refs from all branches
    merged_refs =
      Enum.reduce(branch_results, prefix_state.refs, fn {_, state, _}, acc ->
        Map.merge(acc, state.refs)
      end)

    # Merge projections - use the projections from the last command
    # This is a simplification; proper merge semantics depend on linearization
    merged_projections =
      Enum.reduce(branch_results, prefix_state.projections, fn {_, state, _}, _acc ->
        state.projections
      end)

    # Combine all branch event logs with branch IDs
    merged_event_log =
      branch_event_logs
      |> Enum.flat_map(fn {_branch_id, events} -> events end)
      |> Enum.concat(prefix_state.event_log)

    # Sum step counts
    total_steps =
      Enum.reduce(branch_results, prefix_state.step_count, fn {_, state, _}, acc ->
        acc + (state.step_count - prefix_state.step_count)
      end)

    # Merge check counters
    merged_counters =
      Enum.reduce(branch_results, prefix_state.check_counters, fn {_, state, _}, acc ->
        Map.merge(acc, state.check_counters, fn _k, v1, v2 -> max(v1, v2) end)
      end)

    %{
      event_log: merged_event_log,
      projections: merged_projections,
      refs: merged_refs,
      step_count: total_steps,
      check_counters: merged_counters,
      branch_id: nil
    }
  end

  defp count_branch_commands(branches) do
    Enum.sum(Enum.map(branches, &length/1))
  end

  # ============================================================================
  # Result Finalization
  # ============================================================================

  defp finalize_result(result, linearization \\ nil)

  defp finalize_result({:failed, index, reason, state}, linearization) do
    %{
      success: false,
      event_log: Enum.reverse(state.event_log),
      projections: state.projections,
      refs: state.refs,
      failed_at_index: index,
      failure_reason: reason,
      linearization: linearization
    }
  end

  defp finalize_result(state, linearization) do
    %{
      success: true,
      event_log: Enum.reverse(state.event_log),
      projections: state.projections,
      refs: state.refs,
      failed_at_index: nil,
      failure_reason: nil,
      linearization: linearization
    }
  end

  # ============================================================================
  # Command Execution
  # ============================================================================

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
    # Check if this is a nemesis command
    if Nemesis.nemesis_command?(command) do
      execute_nemesis_command(command, index, state, model, adapter_context, event_queue)
    else
      execute_regular_command(command, index, state, model, adapter, adapter_context, event_queue)
    end
  end

  # Execute a nemesis (fault injection) command
  defp execute_nemesis_command(command, index, state, model, adapter_context, event_queue) do
    nemesis_module = command.__struct__

    # Build context for nemesis
    nemesis_context = %{
      adapter_context: adapter_context,
      event_queue: event_queue,
      active_faults: Map.get(state, :active_faults, %{})
    }

    case nemesis_module.inject(command, nemesis_context) do
      {:ok, events} ->
        # Update projections with nemesis command
        projections = update_projections(state.projections, command)

        # Process nemesis events with source: :nemesis
        {projections, event_log} =
          process_nemesis_events(
            events,
            nemesis_module,
            index,
            state.event_log,
            projections,
            state.branch_id
          )

        # Drain and process injector events
        {projections, event_log} =
          process_injector_events(event_queue, event_log, projections, state.branch_id)

        # Track active fault if auto-restoring
        active_faults = Map.get(state, :active_faults, %{})

        active_faults =
          if Nemesis.auto_restores?(command) do
            Map.put(active_faults, {nemesis_module, index}, %{
              command: command,
              started_at: System.monotonic_time(:millisecond),
              duration_ms: Nemesis.get_duration_ms(command)
            })
          else
            active_faults
          end

        # Run checks
        check_ctx = %{
          command: command,
          events: events,
          command_index: index,
          step_count: state.step_count + 1,
          projections: projections,
          branch_id: state.branch_id,
          active_faults: active_faults
        }

        case run_checks(model, projections, check_ctx, state.check_counters) do
          {:ok, check_counters} ->
            new_state = %{
              event_log: event_log,
              projections: projections,
              refs: state.refs,
              step_count: state.step_count + 1,
              check_counters: check_counters,
              branch_id: state.branch_id,
              active_faults: active_faults
            }

            {:ok, new_state}

          {:error, check_name, reason, check_counters} ->
            failed_state = %{
              event_log: event_log,
              projections: projections,
              refs: state.refs,
              step_count: state.step_count + 1,
              check_counters: check_counters,
              branch_id: state.branch_id,
              active_faults: active_faults
            }

            {:error, {:check_failed, check_name, reason}, failed_state}
        end

      {:error, reason} ->
        {:error, {:nemesis_error, reason}, state}
    end
  end

  # Execute a regular (non-nemesis) command
  defp execute_regular_command(
         command,
         index,
         state,
         model,
         adapter,
         adapter_context,
         event_queue
       ) do
    # 1. Resolve refs in command
    case resolve_command_refs(command, state.refs) do
      {:ok, resolved_command} ->
        # 2. Execute via adapter (with settle logic for probes/bridges)
        case execute_with_settle(resolved_command, adapter, adapter_context) do
          {:ok, events} ->
            # 3. Bind new ref if command creates one
            refs = maybe_bind_ref(command, events, state.refs)

            # 4. Update projections with command
            projections = update_projections(state.projections, resolved_command)

            # 5. Update projections with events and record in log
            {projections, event_log} =
              process_events(
                events,
                :command,
                index,
                state.event_log,
                projections,
                state.branch_id
              )

            # 6. Drain and process injector events
            {projections, event_log} =
              process_injector_events(event_queue, event_log, projections, state.branch_id)

            # 7. Run checks
            check_ctx = %{
              command: resolved_command,
              events: events,
              command_index: index,
              step_count: state.step_count + 1,
              projections: projections,
              branch_id: state.branch_id
            }

            case run_checks(model, projections, check_ctx, state.check_counters) do
              {:ok, check_counters} ->
                new_state = %{
                  event_log: event_log,
                  projections: projections,
                  refs: refs,
                  step_count: state.step_count + 1,
                  check_counters: check_counters,
                  branch_id: state.branch_id
                }

                {:ok, new_state}

              {:error, check_name, reason, check_counters} ->
                failed_state = %{
                  event_log: event_log,
                  projections: projections,
                  refs: refs,
                  step_count: state.step_count + 1,
                  check_counters: check_counters,
                  branch_id: state.branch_id
                }

                {:error, {:check_failed, check_name, reason}, failed_state}
            end

          {:settled, events} ->
            # Probe/bridge settled successfully - treat same as {:ok, events}
            refs = maybe_bind_ref(command, events, state.refs)
            projections = update_projections(state.projections, resolved_command)

            {projections, event_log} =
              process_events(
                events,
                :command,
                index,
                state.event_log,
                projections,
                state.branch_id
              )

            {projections, event_log} =
              process_injector_events(event_queue, event_log, projections, state.branch_id)

            check_ctx = %{
              command: resolved_command,
              events: events,
              command_index: index,
              step_count: state.step_count + 1,
              projections: projections,
              branch_id: state.branch_id
            }

            case run_checks(model, projections, check_ctx, state.check_counters) do
              {:ok, check_counters} ->
                new_state = %{
                  event_log: event_log,
                  projections: projections,
                  refs: refs,
                  step_count: state.step_count + 1,
                  check_counters: check_counters,
                  branch_id: state.branch_id
                }

                {:ok, new_state}

              {:error, check_name, reason, check_counters} ->
                failed_state = %{
                  event_log: event_log,
                  projections: projections,
                  refs: refs,
                  step_count: state.step_count + 1,
                  check_counters: check_counters,
                  branch_id: state.branch_id
                }

                {:error, {:check_failed, check_name, reason}, failed_state}
            end

          {:timeout, last_reason} ->
            {:error, {:settle_timeout, last_reason}, state}

          {:error, reason} ->
            {:error, {:adapter_error, reason}, state}
        end

      {:error, reason} ->
        {:error, {:ref_resolution_error, reason}, state}
    end
  end

  # Execute command with settle logic for probes/bridges
  defp execute_with_settle(command, adapter, adapter_context) do
    if Settle.requires_settling?(command) do
      config = Settle.get_config(command)

      Settle.settle(
        fn -> adapter.execute(command, adapter_context) end,
        timeout_ms: config.timeout_ms,
        interval_ms: config.interval_ms,
        backoff: config.backoff
      )
    else
      adapter.execute(command, adapter_context)
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
    case command do
      %{__struct__: command_module} ->
        if function_exported?(command_module, :creates_ref, 0) do
          command_module.creates_ref()
        else
          nil
        end

      _ ->
        # Plain map or non-struct - no creates_ref
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
  defp process_events(events, source, command_index, event_log, projections, branch_id) do
    Enum.reduce(events, {projections, event_log}, fn event, {projs, log} ->
      entry = %Entry{
        timestamp: System.monotonic_time(:millisecond),
        command_index: command_index,
        event: event,
        source: source,
        injector_adapter: nil,
        nemesis_module: nil,
        branch_id: branch_id
      }

      new_projs = update_projections(projs, event)
      {new_projs, [entry | log]}
    end)
  end

  # Process events from nemesis (fault injection) commands
  defp process_nemesis_events(
         events,
         nemesis_module,
         command_index,
         event_log,
         projections,
         branch_id
       ) do
    Enum.reduce(events, {projections, event_log}, fn event, {projs, log} ->
      entry = Entry.from_nemesis(event, command_index, nemesis_module, branch_id: branch_id)

      new_projs = update_projections(projs, event)
      {new_projs, [entry | log]}
    end)
  end

  # Drain and process events from injector adapters
  defp process_injector_events(nil, event_log, projections, _branch_id),
    do: {projections, event_log}

  defp process_injector_events(event_queue, event_log, projections, branch_id) do
    entries = EventQueue.drain(event_queue)

    Enum.reduce(entries, {projections, event_log}, fn queue_entry, {projs, log} ->
      entry = %Entry{
        timestamp: queue_entry.timestamp,
        command_index: nil,
        event: queue_entry.event,
        source: :injector,
        injector_adapter: queue_entry.adapter_module,
        nemesis_module: nil,
        branch_id: branch_id
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
