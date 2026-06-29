defmodule PropertyDamage.Executor.Nemesis do
  @moduledoc false
  # Nemesis (fault injection) execution for the executor (DR-029).
  #
  # Owns the nemesis-command path and the auto-restore lifecycle, and is the sole
  # owner of the run-state's `active_faults` map (keyed by {nemesis_module, index}
  # with :command/:started_at/:duration_ms). The pure fault-injection behaviour
  # (inject/2, restore/2, auto_restores?, ...) lives in PropertyDamage.Nemesis and
  # the individual nemesis modules; this module is the executor-side glue that
  # drives them, folds their events, and runs assertions.
  #
  # Shared command-processing helpers (resolve_command_placeholders,
  # update_projections, run_checks, check_async, process_injector_events,
  # put_state) stay in PropertyDamage.Executor and are called back here.

  alias PropertyDamage.Executor
  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.Nemesis
  alias PropertyDamage.PlaceholderRegistry

  # Execute a nemesis (fault injection) command
  def execute_nemesis_command(command, index, state, model, adapter_context, event_queue) do
    # Resolve placeholders so a nemesis parameterized by a prior
    # command's output injects against the real value, not a sentinel
    placeholder_registry = Map.get(state, :placeholder_registry, PlaceholderRegistry.new())

    case Executor.resolve_command_placeholders(command, placeholder_registry) do
      {:ok, resolved_command} ->
        do_execute_nemesis_command(
          command,
          resolved_command,
          index,
          state,
          model,
          adapter_context,
          event_queue
        )

      {:error, reason} ->
        {:error, {:ref_resolution_error, reason}, state}
    end
  end

  defp do_execute_nemesis_command(
         command,
         resolved_command,
         index,
         state,
         model,
         adapter_context,
         event_queue
       ) do
    nemesis_module = command.__struct__

    # Build context for nemesis
    nemesis_context = %{
      adapter_context: adapter_context,
      event_queue: event_queue,
      active_faults: Map.get(state, :active_faults, %{})
    }

    assertion_mode = Map.get(state, :assertion_mode, :halt)
    assertion_failures = Map.get(state, :assertion_failures, [])

    case nemesis_module.inject(resolved_command, nemesis_context) do
      {:ok, events} ->
        # Update projections with nemesis command
        projections = Executor.update_projections(state.projections, resolved_command)

        # DR-025: capture pre-drain state so check_async can locate an async
        # violation at the observing event's command_index.
        projs_before_async = projections
        log_before_async = state.event_log

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
          Executor.process_injector_events(event_queue, event_log, projections, state.branch_id)

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

        # DR-025: assert @trigger every: on the nemesis + injector events folded
        # above, incrementally, before the command's own checks.
        case Executor.check_async(
               model,
               projs_before_async,
               log_before_async,
               event_log,
               state.assertion_counters,
               assertion_mode,
               assertion_failures
             ) do
          {:halt, async_name, async_reason, _idx, async_counters} ->
            failed_state =
              Executor.put_state(state, %{
                event_log: event_log,
                projections: projections,
                step_count: state.step_count + 1,
                assertion_counters: async_counters,
                active_faults: active_faults
              })

            {:error, {:assertion_failed, async_name, async_reason}, failed_state}

          {:ok, async_counters, async_failures} ->
            # Run checks
            check_ctx = %{
              command: resolved_command,
              events: events,
              command_index: index,
              step_count: state.step_count + 1,
              projections: projections,
              branch_id: state.branch_id,
              active_faults: active_faults
            }

            case Executor.run_checks(
                   model,
                   projections,
                   check_ctx,
                   async_counters,
                   assertion_mode,
                   async_failures
                 ) do
              {:ok, assertion_counters, updated_failures} ->
                new_state =
                  Executor.put_state(state, %{
                    event_log: event_log,
                    projections: projections,
                    step_count: state.step_count + 1,
                    assertion_counters: assertion_counters,
                    assertion_failures: updated_failures,
                    active_faults: active_faults
                  })

                {:ok, new_state}

              {:error, assertion_name, reason, assertion_counters} ->
                failed_state =
                  Executor.put_state(state, %{
                    event_log: event_log,
                    projections: projections,
                    step_count: state.step_count + 1,
                    assertion_counters: assertion_counters,
                    active_faults: active_faults
                  })

                {:error, {:assertion_failed, assertion_name, reason}, failed_state}
            end
        end

      {:error, reason} ->
        {:error, {:nemesis_error, reason}, state}
    end
  end

  # ============================================================================
  # Nemesis Auto-Restore
  # ============================================================================
  #
  # Faults are injected and tracked in `active_faults` (keyed by
  # {nemesis_module, index} with :command, :started_at and :duration_ms), but
  # the behaviour + moduledoc promise that auto-restoring faults lift on their
  # own. These two helpers keep that promise: `restore_elapsed_faults/3` runs
  # after each command so a time-bounded fault lifts mid-sequence, and
  # `restore_all_faults/3` runs at sequence end so no fault leaks past the run.
  #
  # inject/2 and restore/2 both run in the executor loop process (linear and
  # branching alike execute commands synchronously here), so process-dictionary
  # backed faults (CPUStress, MemoryPressure, ...) clean up in the same process
  # that created them.

  @doc false
  # Restore every auto-restoring fault whose duration has elapsed.
  @spec restore_elapsed_faults(map(), map(), pid() | nil) :: map()
  def restore_elapsed_faults(state, adapter_context, event_queue) do
    now = System.monotonic_time(:millisecond)

    state
    |> Map.get(:active_faults, %{})
    |> Enum.filter(fn {_key, fault} -> fault_elapsed?(fault, now) end)
    |> restore_faults(state, adapter_context, event_queue)
  end

  @doc false
  # Restore every still-active fault, regardless of elapsed time (sequence end).
  @spec restore_all_faults(map(), map(), pid() | nil) :: map()
  def restore_all_faults(state, adapter_context, event_queue) do
    state
    |> Map.get(:active_faults, %{})
    |> Map.to_list()
    |> restore_faults(state, adapter_context, event_queue)
  end

  defp fault_elapsed?(%{duration_ms: duration, started_at: started}, now)
       when is_integer(duration) and is_integer(started),
       do: now - started >= duration

  defp fault_elapsed?(_fault, _now), do: false

  defp restore_faults([], state, _adapter_context, _event_queue), do: state

  defp restore_faults(faults, state, adapter_context, event_queue) do
    Enum.reduce(faults, state, fn {{nemesis_module, index} = key, fault}, acc ->
      nemesis_context = %{
        adapter_context: adapter_context,
        event_queue: event_queue,
        active_faults: Map.get(acc, :active_faults, %{})
      }

      result =
        try do
          nemesis_module.restore(fault.command, nemesis_context)
        rescue
          e -> {:error, {:restore_raised, e}}
        end

      case result do
        {:ok, events} ->
          # DR-025 boundary: auto-restore re-injection is fault CLEARING (the
          # fault lifting on its own), not a SUT effect under test, so these
          # events are folded into projection state but not separately evaluated
          # against @trigger every: assertions. The nemesis command-injection
          # path (execute_nemesis_command) is where injected-fault events are
          # asserted. This reduce is best-effort cleanup with no failure channel.
          {projections, event_log} =
            process_nemesis_events(
              events,
              nemesis_module,
              index,
              acc.event_log,
              acc.projections,
              acc.branch_id
            )

          acc
          |> Executor.put_state(%{projections: projections, event_log: event_log})
          |> drop_active_fault(key)

        {:error, _reason} ->
          # Best-effort cleanup: drop the tracking entry so we never retry it
          # endlessly, but leave the run result otherwise intact.
          drop_active_fault(acc, key)
      end
    end)
  end

  defp drop_active_fault(state, key) do
    faults = state |> Map.get(:active_faults, %{}) |> Map.delete(key)
    Executor.put_state(state, %{active_faults: faults})
  end

  # Fold nemesis events (source: :nemesis) into projections and the event log.
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

      new_projs = Executor.update_projections(projs, event)
      {new_projs, [entry | log]}
    end)
  end
end
