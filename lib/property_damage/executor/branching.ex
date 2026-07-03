defmodule PropertyDamage.Executor.Branching do
  @moduledoc false
  # Branching (parallel) execution for the executor (DR-029).
  #
  # Owns the three-phase branching run: execute the prefix, fork the state and run
  # each branch with synchronous assertions disabled, check linearizability of the
  # observed events against the model, then merge the branch states and run the
  # suffix. Keeps its three-outcome merge: {:ok, ...}, {:error, ...} (a branch
  # raised/errored), and {:linearization_failed, ...} (no ordering reproduces the
  # observed events while satisfying the assertions).
  #
  # The per-command/linear spine stays in PropertyDamage.Executor and is called
  # back: build_initial_state, execute_command, restore_remaining_faults,
  # run_phase_assertions. Event folds come from Executor.Events, result
  # finalization from Executor.Finalization, and auto-restore from Executor.Nemesis.

  alias PropertyDamage.Executor
  alias PropertyDamage.Executor.Events
  alias PropertyDamage.Executor.Finalization
  alias PropertyDamage.Executor.Nemesis
  alias PropertyDamage.Linearization
  alias PropertyDamage.Placeholder
  alias PropertyDamage.PlaceholderRegistry
  alias PropertyDamage.Sequence

  def execute_branching(
        sequence,
        model,
        adapter,
        adapter_context,
        event_queue,
        stutter_config,
        mock_registry,
        assertion_mode,
        external_markers,
        rng_seed \\ nil
      ) do
    initial_state =
      Executor.build_initial_state(
        model,
        event_queue,
        stutter_config,
        mock_registry,
        assertion_mode,
        external_markers,
        sequence.registry,
        rng_seed
      )

    # DR-024: @trigger at: :startup runs once on the shared initial state,
    # before any branch. A :halt failure aborts before any command runs.
    case Executor.run_phase_assertions(initial_state, :startup) do
      {:halt, name, reason, _counters} ->
        Finalization.finalize_result(
          {:failed, nil, {:assertion_failed, name, reason}, initial_state}
        )

      {:ok, startup_recorded, startup_counters} ->
        initial_state = %{
          initial_state
          | assertion_failures: startup_recorded ++ initial_state.assertion_failures,
            assertion_counters: startup_counters
        }

        execute_branching_phases(
          sequence,
          initial_state,
          model,
          adapter,
          adapter_context,
          event_queue
        )
    end
  end

  defp execute_branching_phases(
         sequence,
         initial_state,
         model,
         adapter,
         adapter_context,
         event_queue
       ) do
    %Sequence{prefix: prefix, branches: branches, suffix: suffix} = sequence

    # Phase 1: Execute prefix
    prefix_result =
      prefix
      |> Enum.with_index()
      |> Enum.reduce_while(initial_state, fn {command, index}, state ->
        # Capture projections before this command executes
        state_with_before = %{
          state
          | projections_before: state.projections,
            current_position: {:prefix, index}
        }

        case Executor.execute_command(
               command,
               index,
               state_with_before,
               model,
               adapter,
               adapter_context,
               event_queue
             ) do
          {:ok, new_state} ->
            {:cont,
             Nemesis.restore_elapsed_faults(
               new_state,
               adapter_context,
               event_queue
             )}

          {:error, reason, failed_state} ->
            {:halt, {:failed, index, reason, failed_state}}
        end
      end)

    case prefix_result do
      {:failed, index, reason, state} ->
        {:failed, index, reason, state}
        |> Executor.restore_remaining_faults(adapter_context, event_queue)
        |> Finalization.finalize_result()

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
            merged_state =
              merge_branch_states(
                prefix_state,
                branch_results,
                branch_event_logs,
                linearization,
                branch_start_index
              )

            suffix_start_index = branch_start_index + count_branch_commands(branches)

            suffix_result =
              suffix
              |> Enum.with_index(suffix_start_index)
              |> Enum.reduce_while(merged_state, fn {command, index}, state ->
                # Capture projections before this command executes
                state_with_before = %{
                  state
                  | projections_before: state.projections,
                    current_position: {:suffix, index - suffix_start_index}
                }

                case Executor.execute_command(
                       command,
                       index,
                       state_with_before,
                       model,
                       adapter,
                       adapter_context,
                       event_queue
                     ) do
                  {:ok, new_state} ->
                    {:cont,
                     Nemesis.restore_elapsed_faults(
                       new_state,
                       adapter_context,
                       event_queue
                     )}

                  {:error, reason, failed_state} ->
                    {:halt, {:failed, index, reason, failed_state}}
                end
              end)

            suffix_result
            |> Executor.restore_remaining_faults(adapter_context, event_queue)
            |> Finalization.finalize_result(linearization)

          {:error, branch_id, index, reason, state} ->
            Finalization.finalize_result(
              {:failed, index, {:branch_failure, branch_id, reason}, state}
            )

          {:linearization_failed, branch_results, branch_event_logs, refutation} ->
            merged_state =
              merge_branch_states(
                prefix_state,
                branch_results,
                branch_event_logs,
                :no_linearization,
                branch_start_index
              )

            {failed_index, reason} =
              linearization_failure(refutation, branch_start_index)

            Finalization.finalize_result({:failed, failed_index, reason, merged_state})
        end
    end
  end

  # Translate a Linearization refutation into the {failed_index, reason} the
  # report expects. When the cause is a specific synchronous assertion, mirror
  # the linear path's shape exactly ({:branch_failure, branch_id,
  # {:assertion_failed, name, {exception, stacktrace}}}) so the report,
  # shrinker, and formatter behave identically to a real assertion failure. A
  # nil refutation means every ordering failed purely on event compatibility
  # (a classic race, e.g. a lost update): report it as a linearization failure.
  defp linearization_failure(nil, branch_start_index) do
    {branch_start_index,
     {:linearization_failed, "No valid linearization found for branch execution"}}
  end

  defp linearization_failure(refutation, branch_start_index) do
    %{branch_id: branch_id, position: position, reason: reason} = refutation
    {branch_start_index + position, {:branch_failure, branch_id, reason}}
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
        # Fork state for this branch.
        #
        # Synchronous assertions are DISABLED inside branches on purpose. A
        # forked branch only sees the prefix plus its own commands, never the
        # concurrently-executing sibling branches' effects, so running
        # @trigger assertions against this partial state over-reports races
        # (e.g. a read that legally observed a sibling's write fails against a
        # model that never recorded it). Branch correctness is decided AFTER
        # all branches run, by the assertion-aware Linearization.check below,
        # which evaluates assertions against observed events and the model
        # prediction drawn from one consistent ordering. Real execution errors
        # (adapter errors, ref-resolution failures, raised transition
        # invariants) are unaffected: those still halt the branch here.
        branch_state = %{
          prefix_state
          | event_log: [],
            branch_id: branch_id,
            assertion_mode: :disabled
        }

        # Calculate command indices for this branch
        # Each branch starts from the same logical index after prefix
        branch_result =
          branch_commands
          |> Enum.with_index(start_index)
          |> Enum.reduce_while(branch_state, fn {command, index}, state ->
            # Capture projections before this command executes
            state_with_before = %{
              state
              | projections_before: state.projections,
                current_position: {:branch, branch_id, index - start_index}
            }

            case Executor.execute_command(
                   command,
                   index,
                   state_with_before,
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

        # Unresolved placeholders in branch commands are treated as wildcards by
        # the linearization checker, so the commands are passed through as-is.
        branch_commands =
          Enum.map(successful_results, fn {_, _state, commands} -> commands end)

        case Linearization.check(
               branch_commands,
               Map.new(branch_event_logs),
               prefix_state.projections,
               model,
               start_index: start_index,
               counters: prefix_state.assertion_counters
             ) do
          {:ok, linearization} ->
            {:ok, successful_results, branch_event_logs, linearization}

          {:indeterminate, _checked} = indeterminate ->
            # Cannot verify (no simulator, or candidate cap reached): proceed
            # without claiming either way; the result records :indeterminate
            {:ok, successful_results, branch_event_logs, indeterminate}

          {:no_linearization, refutation} ->
            # No ordering reproduces the observed events AND satisfies the
            # assertions. `refutation` (when present) names the synchronous
            # assertion that failed in the furthest-progressing ordering, so
            # the report can match the precision of a linear failure.
            {:linearization_failed, successful_results, branch_event_logs, refutation}
        end
    end
  end

  defp merge_branch_states(
         prefix_state,
         branch_results,
         branch_event_logs,
         linearization,
         start_index
       ) do
    observed = Linearization.observed_events_by_position(Map.new(branch_event_logs), start_index)

    # Replay every branch's (command, observed events) over the prefix
    # projections, in the verified linearization order when one exists,
    # otherwise in branch order (which is itself a valid interleaving
    # whenever branches are independent)
    replay_items =
      case linearization do
        [_ | _] = tagged ->
          Enum.map(tagged, fn {branch_id, pos, command} ->
            {command, Map.get(observed, {branch_id, pos}, [])}
          end)

        _ ->
          for {branch_id, _state, commands} <- branch_results,
              {command, pos} <- Enum.with_index(commands) do
            {command, Map.get(observed, {branch_id, pos}, [])}
          end
      end

    merged_projections =
      Enum.reduce(replay_items, prefix_state.projections, fn {command, events}, projs ->
        projs = Events.update_projections(projs, command)
        Enum.reduce(events, projs, fn event, acc -> Events.update_projections(acc, event) end)
      end)

    # The state's event_log invariant is reverse-chronological. Overall
    # chronological order is prefix ++ branch0 ++ branch1 ++ ...; so the
    # branch logs (chronological here) are reversed as a whole and prepended
    # to the still-reversed prefix log.
    merged_event_log =
      branch_event_logs
      |> Enum.flat_map(fn {_branch_id, events} -> events end)
      |> Enum.reverse()
      |> Enum.concat(prefix_state.event_log)

    # Sum step counts
    total_steps =
      Enum.reduce(branch_results, prefix_state.step_count, fn {_, state, _}, acc ->
        acc + (state.step_count - prefix_state.step_count)
      end)

    # Merge assertion counters: prefix value plus the sum of each branch's
    # delta relative to the prefix
    merged_counters =
      Enum.reduce(branch_results, prefix_state.assertion_counters, fn {_, state, _}, acc ->
        Map.merge(acc, state.assertion_counters, fn key, acc_value, branch_value ->
          acc_value + (branch_value - Map.get(prefix_state.assertion_counters, key, 0))
        end)
      end)

    # Merge assertion failures from all branches
    merged_failures =
      Enum.reduce(branch_results, prefix_state.assertion_failures, fn {_, state, _}, acc ->
        acc ++ Map.get(state, :assertion_failures, [])
      end)

    # Pollers spawned during the prefix or inside branches all stay live
    merged_pollers =
      [prefix_state | Enum.map(branch_results, fn {_, state, _} -> state end)]
      |> Enum.flat_map(&Map.get(&1, :active_pollers, []))
      |> Enum.uniq()

    merged_resource_pollers =
      [prefix_state | Enum.map(branch_results, fn {_, state, _} -> state end)]
      |> Enum.flat_map(&Map.get(&1, :active_resource_pollers, []))
      |> Enum.uniq()

    # Merge each branch's external resolutions back (DR-021): branches execute
    # in forked states, so a placeholder produced inside a branch is resolved
    # only in that branch's registry. Union the resolved values so the suffix
    # (and the report) observe them.
    merged_registry =
      merge_placeholder_registries(prefix_state.placeholder_registry, branch_results)

    # Merge the executed-command maps (DR-033). Each branch forked from
    # prefix_state, so its map is prefix ∪ that branch's `{:branch, id, i}`
    # positions; branch keys are disjoint across branches and the shared prefix
    # keys carry identical values, so unioning is conflict-free.
    merged_executed =
      Enum.reduce(branch_results, prefix_state.executed, fn {_, state, _}, acc ->
        Map.merge(acc, state.executed)
      end)

    # Update through the prefix state so every other key (stutter config, mock
    # registry, model, external markers, ...) is preserved instead of dropped
    %{
      prefix_state
      | event_log: merged_event_log,
        projections: merged_projections,
        projections_before: merged_projections,
        placeholder_registry: merged_registry,
        executed: merged_executed,
        step_count: total_steps,
        assertion_counters: merged_counters,
        assertion_failures: merged_failures,
        branch_id: nil,
        active_pollers: merged_pollers,
        active_resource_pollers: merged_resource_pollers
    }
  end

  # Combine branch registries: keep a placeholder's resolved value if any branch
  # resolved it (branches resolve disjoint placeholders, so there is no conflict).
  # The id index and producer_link are identical across branches (transported
  # from generation), so only the resolutions need merging.
  defp merge_placeholder_registries(base, branch_results) do
    Enum.reduce(branch_results, base, fn {_id, state, _commands}, acc ->
      case Map.get(state, :placeholder_registry) do
        %PlaceholderRegistry{placeholders: branch_phs} ->
          merged =
            Map.merge(acc.placeholders, branch_phs, fn _id, a, b ->
              if Placeholder.resolved?(b), do: b, else: a
            end)

          %{acc | placeholders: merged}

        _ ->
          acc
      end
    end)
  end

  defp count_branch_commands(branches) do
    Enum.sum(Enum.map(branches, &length/1))
  end
end
