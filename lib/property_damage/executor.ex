defmodule PropertyDamage.Executor do
  @moduledoc """
  Executes command sequences against the System Under Test.

  The Executor is the core engine that runs command sequences, resolves placeholders,
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

  1. Resolve placeholders to concrete values
  2. Execute via adapter (command → events)
  3. Capture external() values produced by this command from its events
  4. Update projections (command first, then events)
  5. Drain injector events and process them
  6. Run triggered checks
  7. Record events in event log

  ## Placeholder Resolution

  Commands may contain placeholders for server-generated values (declared via
  `external/0` on producer events). Before execution, these are replaced with
  the concrete values captured from the producer's events. If a placeholder
  hasn't been resolved yet (its producer hasn't run), execution fails.

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
  - `:failed_at_index` - Index where check failed (nil if success)
  - `:failure_reason` - Check failure reason (nil if success)
  - `:linearization` - Selected linearization (for branching sequences)
  """

  alias PropertyDamage.{
    EventQueue,
    Linearization,
    MockServiceRegistry,
    Nemesis,
    Placeholder,
    PlaceholderRegistry,
    ResourcePoller,
    Sequence,
    Settle,
    StatePoller,
    Stutter
  }

  alias PropertyDamage.Model.Projection

  alias PropertyDamage.EventLog.Entry

  alias PropertyDamage.Executor.Finalization
  alias PropertyDamage.Executor.State

  alias PropertyDamage.Runtime

  @typedoc """
  Assertion mode controls whether and how assertion failures are handled.

  - `:disabled` - Skip all assertions (useful for load testing focused on throughput)
  - `:halt` (default) - Stop execution at first failure, return failure
  - `:record` - Record failures and continue, return all failures at end
  - `:log` - Log failures as warnings and continue
  """
  @type assertion_mode :: :disabled | :halt | :record | :log

  @typedoc """
  Result of executing a command sequence.
  """
  @type result :: %{
          success: boolean(),
          event_log: [Entry.t()],
          projections: %{module() => any()},
          failed_at_index: non_neg_integer() | nil,
          failure_reason: term() | nil,
          linearization: [struct()] | nil,
          assertion_failures: [map()] | nil
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
  - `:stutter_config` - Stutter.Config for idempotency testing (optional)
  - `:mock_registry` - MockServiceRegistry pid for mock service support (optional)
  - `:assertion_mode` - How to handle assertions (`:disabled`, `:halt`, `:record`, `:log`). Default: `:halt`

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
    stutter_config = Keyword.get(opts, :stutter_config)
    mock_registry = Keyword.get(opts, :mock_registry)
    assertion_mode = Keyword.get(opts, :assertion_mode, :halt)
    external_markers = Keyword.get(opts, :external_markers, [])

    with {:ok, adapter_context} <- adapter.setup(adapter_config) do
      try do
        result =
          execute_sequence(
            sequence,
            model,
            adapter,
            adapter_context,
            event_queue,
            stutter_config,
            mock_registry,
            assertion_mode,
            external_markers
          )

        {:ok, result}
      after
        safe_teardown(adapter, adapter_context)
      end
    end
  end

  # Backwards compatibility: accept list of commands as linear sequence
  def run(commands, model, adapter, opts) when is_list(commands) do
    run(Sequence.linear(commands), model, adapter, opts)
  end

  # Adapter teardown is best-effort (DR-027): a raising teardown logs a warning
  # but never fails the run, so a cleanup hiccup cannot mask the actual result
  # (or, during shrinking, perturb the failure being minimized).
  defp safe_teardown(adapter, user_context) do
    require Logger

    try do
      adapter.teardown(user_context)
    rescue
      e ->
        Logger.warning(
          "Adapter #{inspect(adapter)} teardown/1 raised: " <>
            Exception.format(:error, e, __STACKTRACE__)
        )

        :ok
    end
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
  - `stutter_config` - Stutter.Config for idempotency testing (optional)
  - `mock_registry` - MockServiceRegistry pid (optional)
  - `assertion_mode` - How to handle assertion failures (optional, default: `:halt`)

  ## Returns

  Result struct directly (no wrapping tuple).
  """
  @spec execute_sequence(
          Sequence.t() | list(),
          module(),
          module(),
          map(),
          pid() | nil,
          Stutter.Config.t() | nil,
          pid() | nil,
          assertion_mode(),
          [atom()]
        ) ::
          result()
  def execute_sequence(
        sequence_or_commands,
        model,
        adapter,
        adapter_context,
        event_queue \\ nil,
        stutter_config \\ nil,
        mock_registry \\ nil,
        assertion_mode \\ :halt,
        external_markers \\ []
      )

  def execute_sequence(
        %Sequence{branches: nil} = sequence,
        model,
        adapter,
        adapter_context,
        event_queue,
        stutter_config,
        mock_registry,
        assertion_mode,
        external_markers
      ) do
    # Linear sequence: just execute prefix ++ suffix
    commands = Sequence.to_list(sequence)

    execute_linear(
      commands,
      model,
      adapter,
      adapter_context,
      event_queue,
      stutter_config,
      mock_registry,
      assertion_mode,
      external_markers,
      sequence.registry
    )
  end

  def execute_sequence(
        %Sequence{} = sequence,
        model,
        adapter,
        adapter_context,
        event_queue,
        stutter_config,
        mock_registry,
        assertion_mode,
        external_markers
      ) do
    # Branching sequence: execute prefix, branches, suffix
    execute_branching(
      sequence,
      model,
      adapter,
      adapter_context,
      event_queue,
      stutter_config,
      mock_registry,
      assertion_mode,
      external_markers
    )
  end

  # Backwards compatibility: accept list of commands
  def execute_sequence(
        commands,
        model,
        adapter,
        adapter_context,
        event_queue,
        stutter_config,
        mock_registry,
        assertion_mode,
        external_markers
      )
      when is_list(commands) do
    execute_linear(
      commands,
      model,
      adapter,
      adapter_context,
      event_queue,
      stutter_config,
      mock_registry,
      assertion_mode,
      external_markers
    )
  end

  # ============================================================================
  # Linear Execution
  # ============================================================================

  defp execute_linear(
         commands,
         model,
         adapter,
         adapter_context,
         event_queue,
         stutter_config,
         mock_registry,
         assertion_mode,
         external_markers,
         registry \\ nil
       ) do
    initial_state =
      build_initial_state(
        model,
        event_queue,
        stutter_config,
        mock_registry,
        assertion_mode,
        external_markers,
        registry
      )

    # DR-024: @trigger at: :startup checks run on the initial init/0 state,
    # after setup/1 and before command 1. A :halt failure aborts before any
    # command runs.
    case run_phase_assertions(initial_state, :startup) do
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

        result =
          commands
          |> Enum.with_index()
          |> Enum.reduce_while(initial_state, fn {command, index}, state ->
            # Capture projections before this command executes
            state_with_before = %{
              state
              | projections_before: state.projections,
                current_position: {:prefix, index}
            }

            case execute_command(
                   command,
                   index,
                   state_with_before,
                   model,
                   adapter,
                   adapter_context,
                   event_queue
                 ) do
              {:ok, new_state} ->
                # Lift any auto-restoring fault whose duration has elapsed, so a
                # time-bounded fault stops affecting later commands.
                {:cont,
                 PropertyDamage.Executor.Nemesis.restore_elapsed_faults(
                   new_state,
                   adapter_context,
                   event_queue
                 )}

              {:error, reason, failed_state} ->
                {:halt, {:failed, index, reason, failed_state}}
            end
          end)

        result
        |> restore_remaining_faults(adapter_context, event_queue)
        |> Finalization.finalize_result()
    end
  end

  # Restore any still-active faults at sequence end so none leak past the run.
  # On success the restore events flow into the reported state; on failure it is
  # best-effort environment cleanup and the failed state is reported unchanged.
  defp restore_remaining_faults(
         {:failed, index, reason, failed_state},
         adapter_context,
         event_queue
       ) do
    _ =
      PropertyDamage.Executor.Nemesis.restore_all_faults(
        failed_state,
        adapter_context,
        event_queue
      )

    {:failed, index, reason, failed_state}
  end

  defp restore_remaining_faults(state, adapter_context, event_queue) do
    PropertyDamage.Executor.Nemesis.restore_all_faults(state, adapter_context, event_queue)
  end

  # ============================================================================
  # Branching Execution
  # ============================================================================

  defp execute_branching(
         sequence,
         model,
         adapter,
         adapter_context,
         event_queue,
         stutter_config,
         mock_registry,
         assertion_mode,
         external_markers
       ) do
    initial_state =
      build_initial_state(
        model,
        event_queue,
        stutter_config,
        mock_registry,
        assertion_mode,
        external_markers,
        sequence.registry
      )

    # DR-024: @trigger at: :startup runs once on the shared initial state,
    # before any branch. A :halt failure aborts before any command runs.
    case run_phase_assertions(initial_state, :startup) do
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

        case execute_command(
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
             PropertyDamage.Executor.Nemesis.restore_elapsed_faults(
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
        |> restore_remaining_faults(adapter_context, event_queue)
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

                case execute_command(
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
                     PropertyDamage.Executor.Nemesis.restore_elapsed_faults(
                       new_state,
                       adapter_context,
                       event_queue
                     )}

                  {:error, reason, failed_state} ->
                    {:halt, {:failed, index, reason, failed_state}}
                end
              end)

            suffix_result
            |> restore_remaining_faults(adapter_context, event_queue)
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

            case execute_command(
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
        projs = update_projections(projs, command)
        Enum.reduce(events, projs, fn event, acc -> update_projections(acc, event) end)
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

    # Update through the prefix state so every other key (stutter config, mock
    # registry, model, external markers, ...) is preserved instead of dropped
    %{
      prefix_state
      | event_log: merged_event_log,
        projections: merged_projections,
        projections_before: merged_projections,
        placeholder_registry: merged_registry,
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

  # ============================================================================
  # Command Execution
  # ============================================================================

  # Initialize all projection states
  defp init_projections(model) do
    cmd_seq_projection = model.command_sequence_projection()

    assertion_projections =
      if function_exported?(model, :assertion_projections, 0) do
        model.assertion_projections()
      else
        []
      end

    all_projections = [cmd_seq_projection | assertion_projections]

    for projection <- all_projections, into: %{} do
      {projection, projection.init()}
    end
  end

  # Build the executor's internal per-run state map. Shared by linear and
  # branching execution (and exposed to the stepping shell via init_state/2)
  # so the state shape lives in exactly one place.
  defp build_initial_state(
         model,
         event_queue,
         stutter_config,
         mock_registry,
         assertion_mode,
         external_markers,
         registry
       ) do
    %State{
      event_log: [],
      projections: init_projections(model),
      projections_before: nil,
      # Seed the placeholder registry from the generated sequence (DR-021); the
      # id-indexed registry + producer_link transport from generation to here.
      placeholder_registry: registry || PlaceholderRegistry.new(),
      # Structured position of the command currently executing (DR-021); set by
      # the dispatch loops so external capture keys on position, not a flat index.
      current_position: nil,
      step_count: 0,
      assertion_counters: %{step: 0, command: 0, event: 0},
      assertion_failures: [],
      assertion_mode: assertion_mode,
      branch_id: nil,
      stutter_config: stutter_config,
      mock_registry: mock_registry,
      active_pollers: [],
      active_resource_pollers: [],
      model: model,
      external_markers: external_markers,
      event_queue: event_queue,
      command_specs: build_command_specs(model)
    }
  end

  # ============================================================================
  # Stepping API (used by PropertyDamage.Replay)
  # ============================================================================

  @doc false
  # Build a fresh executor state for stepping a sequence one command at a time.
  # The caller owns the adapter lifecycle (setup/teardown) and the event queue.
  @spec init_state(module(), keyword()) :: map()
  def init_state(model, opts \\ []) do
    build_initial_state(
      model,
      Keyword.get(opts, :event_queue),
      Keyword.get(opts, :stutter_config),
      Keyword.get(opts, :mock_registry),
      Keyword.get(opts, :assertion_mode, :halt),
      Keyword.get(opts, :external_markers, []),
      Keyword.get(opts, :placeholder_registry)
    )
  end

  @doc false
  # Execute exactly one command against an existing executor state, capturing
  # the pre-command projections first (as the linear loop does). This is the
  # single per-command engine path: ref/placeholder resolution, settle, nemesis,
  # injector/mock events, projections, assertions, stutter, and pollers all run
  # exactly as in a full run. Returns {:ok, new_state} or
  # {:error, reason, failed_state}.
  @spec step_command(
          struct() | map(),
          non_neg_integer(),
          map(),
          module(),
          module(),
          map(),
          pid() | nil
        ) ::
          {:ok, map()} | {:error, term(), map()}
  def step_command(command, index, state, model, adapter, adapter_context, event_queue) do
    # Replay steps a linear sequence, so positions are {:prefix, index} (DR-021).
    state_with_before = %{
      state
      | projections_before: state.projections,
        current_position: {:prefix, index}
    }

    execute_command(
      command,
      index,
      state_with_before,
      model,
      adapter,
      adapter_context,
      event_queue
    )
  end

  @doc false
  # Stop any pollers spawned during stepping. Best-effort cleanup for the
  # stepping shell; a full run finalizes pollers through finalize_result/2.
  @spec stop_pollers(map()) :: :ok
  def stop_pollers(state) do
    Enum.each(Map.get(state, :active_pollers, []), &StatePoller.stop/1)
    Enum.each(Map.get(state, :active_resource_pollers, []), &ResourcePoller.stop/1)
    :ok
  end

  # Execute a single command
  defp execute_command(command, index, state, model, adapter, adapter_context, event_queue) do
    mock_registry = Map.get(state, :mock_registry)

    try do
      # Check if this is a nemesis command
      if Nemesis.nemesis_command?(command) do
        PropertyDamage.Executor.Nemesis.execute_nemesis_command(
          command,
          index,
          state,
          model,
          adapter_context,
          event_queue
        )
      else
        execute_regular_command(
          command,
          index,
          state,
          model,
          adapter,
          adapter_context,
          event_queue,
          mock_registry
        )
      end
    rescue
      e in PropertyDamage.ProjectionError ->
        # A projection signalled a transition invariant violation by raising.
        # Report it as a failure (with the pre-command state) rather than
        # letting it crash the run.
        {:error, {:projection_violation, e.projection, e.original}, state}
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
         event_queue,
         mock_registry
       ) do
    # 0. Notify mock registry of command (before execution)
    if mock_registry do
      MockServiceRegistry.notify_command(mock_registry, command)
    end

    # Get placeholder_registry from state (may not exist in older tests)
    placeholder_registry = Map.get(state, :placeholder_registry, PlaceholderRegistry.new())

    # 1. Resolve placeholders in command
    case resolve_command_placeholders(command, placeholder_registry) do
      {:ok, resolved_command} ->
        # 2. Per-command injection/poller sink (DR-027): an explicit Agent that
        # replaces the former @injection_ctx_key/@resource_pollers_key
        # process-dictionary channels, so inject/start_poller accumulate correctly
        # even when the adapter runs execute in a spawned process.
        {:ok, sink} = Runtime.Sink.start_link()

        Runtime.Sink.put_ctx(sink, %{
          projections: state.projections,
          event_log: state.event_log,
          injected_events: [],
          command_index: index,
          branch_id: state.branch_id,
          command: command
        })

        # Build start_poller closure for resource polling
        start_poller_fn = fn opts ->
          poller =
            ResourcePoller.start(
              Keyword.merge(opts,
                event_queue: event_queue,
                command_index: index,
                branch_id: state.branch_id
              )
            )

          Runtime.Sink.add_poller(sink, poller)
          poller
        end

        # Build the per-command Runtime handle (DR-027). user_context stays
        # exactly the adapter's setup/1 return; inject/start_poller travel here
        # over the explicit sink rather than being merged into the user's map.
        runtime = %Runtime{
          inject: fn event -> inject_event(sink, event) end,
          start_poller: start_poller_fn
        }

        # 3. Execute via adapter (with settle logic for probes/async).
        # Commands may be plain maps in low-level/test usage, hence the guard.
        command_spec =
          if is_struct(command) do
            Map.get(Map.get(state, :command_specs, %{}), command.__struct__)
          end

        result =
          try do
            execute_with_settle(
              resolved_command,
              adapter,
              adapter_context,
              runtime,
              command_spec
            )
          rescue
            e ->
              # Capture stacktrace for adapter exceptions
              stacktrace = __STACKTRACE__
              {:error, {e, stacktrace}}
          end

        # Drain the accumulated injection state (includes any injected events) and
        # the resource pollers started during execution, then stop the sink.
        final_injection_ctx = Runtime.Sink.get_ctx(sink)
        started_resource_pollers = Runtime.Sink.get_pollers(sink)
        Runtime.Sink.stop(sink)

        # Use injection context state as base (already has injected events applied)
        base_projections = final_injection_ctx.projections
        base_event_log = final_injection_ctx.event_log
        injected_events = final_injection_ctx.injected_events

        assertion_mode = Map.get(state, :assertion_mode, :halt)
        assertion_failures = Map.get(state, :assertion_failures, [])

        # Pollers started during this command's execution must be tracked even on
        # the failure branches below, so finalize_result/2 can stop them at run
        # end; otherwise an adapter that starts a poller and then errors leaks it
        # (and shrinking re-runs failures many times).
        state_with_pollers = %{
          state
          | active_resource_pollers: state.active_resource_pollers ++ started_resource_pollers
        }

        case result do
          {:ok, events} when is_list(events) ->
            # 4b. Capture external values from real events (DR-021): resolve the
            # placeholders this command produces, found by its structured position.
            # Injected events come first so externals they carry resolve too.
            updated_registry =
              capture_externals(
                injected_events ++ events,
                state.current_position,
                placeholder_registry
              )

            # 5. Update projections with command
            projections = update_projections(base_projections, resolved_command)

            # 6. Update projections with returned events and record in log
            {projections, event_log} =
              process_events(
                events,
                :command,
                index,
                base_event_log,
                projections,
                state.branch_id
              )

            # 7. Drain and process injector events. DR-025: capture the
            #    pre-drain projections/log so check_async can assert each async
            #    event on the state it produced and locate a violation at the
            #    observing event's command_index.
            projs_before_async = projections
            log_before_async = event_log

            {projections, event_log} =
              process_injector_events(event_queue, event_log, projections, state.branch_id)

            # 7.5. Flush and process mock-injected events
            {projections, event_log} =
              process_mock_events(mock_registry, index, event_log, projections, state.branch_id)

            # 7.6. Update mock projections
            if mock_registry do
              MockServiceRegistry.update_projections(mock_registry, projections)
            end

            # 7.7. DR-025: evaluate @trigger every: assertions on the async
            #      events just folded (injector + mock), incrementally.
            case check_async(
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
                  put_state(state, %{
                    event_log: event_log,
                    projections: projections,
                    placeholder_registry: updated_registry,
                    step_count: state.step_count + 1,
                    assertion_counters: async_counters,
                    active_resource_pollers:
                      Map.get(state, :active_resource_pollers, []) ++ started_resource_pollers
                  })

                {:error, {:assertion_failed, async_name, async_reason}, failed_state}

              {:ok, async_counters, async_failures} ->
                # 8. Run checks
                check_ctx = %{
                  command: resolved_command,
                  events: events,
                  command_index: index,
                  step_count: state.step_count + 1,
                  projections: projections,
                  branch_id: state.branch_id
                }

                case run_checks(
                       model,
                       projections,
                       check_ctx,
                       async_counters,
                       assertion_mode,
                       async_failures
                     ) do
                  {:ok, assertion_counters, updated_failures} ->
                    # 9. Execute stutter retries if configured
                    case PropertyDamage.Executor.Stutter.maybe_execute_stutter_retries(
                           command,
                           resolved_command,
                           events,
                           index,
                           event_log,
                           state,
                           adapter,
                           adapter_context
                         ) do
                      {:ok, final_event_log} ->
                        new_state =
                          put_state(state, %{
                            event_log: final_event_log,
                            projections: projections,
                            placeholder_registry: updated_registry,
                            step_count: state.step_count + 1,
                            assertion_counters: assertion_counters,
                            assertion_failures: updated_failures,
                            active_resource_pollers:
                              Map.get(state, :active_resource_pollers, []) ++
                                started_resource_pollers
                          })

                        # Spawn pollers for any @poll_state assertions triggered by these events
                        new_state = maybe_spawn_pollers(new_state, events, model)
                        new_state = update_poller_state_getters(new_state)

                        {:ok, new_state}

                      {:error, :idempotency_violation, violation} ->
                        failed_state =
                          put_state(state, %{
                            event_log: event_log,
                            projections: projections,
                            placeholder_registry: updated_registry,
                            step_count: state.step_count + 1,
                            assertion_counters: assertion_counters,
                            assertion_failures: updated_failures,
                            active_resource_pollers:
                              Map.get(state, :active_resource_pollers, []) ++
                                started_resource_pollers
                          })

                        {:error, {:idempotency_violation, violation}, failed_state}

                      {:error, :stutter_execution_failed, details} ->
                        failed_state =
                          put_state(state, %{
                            event_log: event_log,
                            projections: projections,
                            placeholder_registry: updated_registry,
                            step_count: state.step_count + 1,
                            assertion_counters: assertion_counters,
                            assertion_failures: updated_failures,
                            active_resource_pollers:
                              Map.get(state, :active_resource_pollers, []) ++
                                started_resource_pollers
                          })

                        {:error, {:stutter_execution_failed, details}, failed_state}
                    end

                  {:error, assertion_name, reason, assertion_counters} ->
                    failed_state =
                      put_state(state, %{
                        event_log: event_log,
                        projections: projections,
                        placeholder_registry: updated_registry,
                        step_count: state.step_count + 1,
                        assertion_counters: assertion_counters,
                        active_resource_pollers:
                          Map.get(state, :active_resource_pollers, []) ++ started_resource_pollers
                      })

                    {:error, {:assertion_failed, assertion_name, reason}, failed_state}
                end
            end

          {:settled, events} ->
            # Probe/async settled successfully - treat same as {:ok, events}
            # Capture external values from real events (DR-021), keyed by the
            # command's structured position. Injected events come first so
            # externals they carry resolve too.
            updated_registry =
              capture_externals(
                injected_events ++ events,
                state.current_position,
                placeholder_registry
              )

            projections = update_projections(base_projections, resolved_command)

            {projections, event_log} =
              process_events(
                events,
                :command,
                index,
                base_event_log,
                projections,
                state.branch_id
              )

            projs_before_async = projections
            log_before_async = event_log

            {projections, event_log} =
              process_injector_events(event_queue, event_log, projections, state.branch_id)

            # Flush and process mock-injected events
            {projections, event_log} =
              process_mock_events(mock_registry, index, event_log, projections, state.branch_id)

            # Update mock projections
            if mock_registry do
              MockServiceRegistry.update_projections(mock_registry, projections)
            end

            # DR-025: assert @trigger every: assertions on the async events folded
            # above, incrementally, before the command's own checks.
            case check_async(
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
                  put_state(state, %{
                    event_log: event_log,
                    projections: projections,
                    placeholder_registry: updated_registry,
                    step_count: state.step_count + 1,
                    assertion_counters: async_counters,
                    active_resource_pollers:
                      Map.get(state, :active_resource_pollers, []) ++ started_resource_pollers
                  })

                {:error, {:assertion_failed, async_name, async_reason}, failed_state}

              {:ok, async_counters, async_failures} ->
                check_ctx = %{
                  command: resolved_command,
                  events: events,
                  command_index: index,
                  step_count: state.step_count + 1,
                  projections: projections,
                  branch_id: state.branch_id
                }

                case run_checks(
                       model,
                       projections,
                       check_ctx,
                       async_counters,
                       assertion_mode,
                       async_failures
                     ) do
                  {:ok, assertion_counters, updated_failures} ->
                    # Execute stutter retries if configured (same as {:ok, events} path)
                    case PropertyDamage.Executor.Stutter.maybe_execute_stutter_retries(
                           command,
                           resolved_command,
                           events,
                           index,
                           event_log,
                           state,
                           adapter,
                           adapter_context
                         ) do
                      {:ok, final_event_log} ->
                        new_state =
                          put_state(state, %{
                            event_log: final_event_log,
                            projections: projections,
                            placeholder_registry: updated_registry,
                            step_count: state.step_count + 1,
                            assertion_counters: assertion_counters,
                            assertion_failures: updated_failures,
                            active_resource_pollers:
                              Map.get(state, :active_resource_pollers, []) ++
                                started_resource_pollers
                          })

                        # Spawn pollers for any @poll_state assertions triggered by these events
                        new_state = maybe_spawn_pollers(new_state, events, model)
                        new_state = update_poller_state_getters(new_state)

                        {:ok, new_state}

                      {:error, :idempotency_violation, violation} ->
                        failed_state =
                          put_state(state, %{
                            event_log: event_log,
                            projections: projections,
                            placeholder_registry: updated_registry,
                            step_count: state.step_count + 1,
                            assertion_counters: assertion_counters,
                            assertion_failures: updated_failures,
                            active_resource_pollers:
                              Map.get(state, :active_resource_pollers, []) ++
                                started_resource_pollers
                          })

                        {:error, {:idempotency_violation, violation}, failed_state}

                      {:error, :stutter_execution_failed, details} ->
                        failed_state =
                          put_state(state, %{
                            event_log: event_log,
                            projections: projections,
                            placeholder_registry: updated_registry,
                            step_count: state.step_count + 1,
                            assertion_counters: assertion_counters,
                            assertion_failures: updated_failures,
                            active_resource_pollers:
                              Map.get(state, :active_resource_pollers, []) ++
                                started_resource_pollers
                          })

                        {:error, {:stutter_execution_failed, details}, failed_state}
                    end

                  {:error, assertion_name, reason, assertion_counters} ->
                    failed_state =
                      put_state(state, %{
                        event_log: event_log,
                        projections: projections,
                        placeholder_registry: updated_registry,
                        step_count: state.step_count + 1,
                        assertion_counters: assertion_counters,
                        active_resource_pollers:
                          Map.get(state, :active_resource_pollers, []) ++ started_resource_pollers
                      })

                    {:error, {:assertion_failed, assertion_name, reason}, failed_state}
                end
            end

          {:timeout, last_reason} ->
            {:error, {:settle_timeout, last_reason}, state_with_pollers}

          {:error, reason} ->
            {:error, {:adapter_error, reason}, state_with_pollers}

          {:retry, reason} ->
            # {:retry, _} is the probe/async settle protocol: only :probe/:async
            # commands run through Settle, which consumes {:retry, _} by
            # re-invoking execute until {:settled, _} or timeout. Reaching this
            # case means a :sync command returned {:retry, _}, which it must not.
            command_module = if is_struct(resolved_command), do: resolved_command.__struct__

            {:error, {:retry_from_sync_command, %{command: command_module, reason: reason}},
             state_with_pollers}

          # Adapter returned something other than {:ok, list} / {:error, _} /
          # {:timeout, _} / {:retry, _}: report a graceful failure instead of
          # crashing the run with a CaseClauseError (this clause sits outside
          # the execute rescue).
          other ->
            {:error, {:malformed_adapter_return, other}, state_with_pollers}
        end

      {:error, reason} ->
        {:error, {:ref_resolution_error, reason}, state}
    end
  end

  # Build a %{command_module => resolved_spec} lookup so execution-time
  # settle behaviour comes from the normalized command spec (which honors
  # `use PropertyDamage.Command, execution: :probe`, model-level overrides,
  # AND legacy semantics/0 callbacks via build_spec_from_legacy) rather than
  # only the struct's legacy callbacks.
  defp build_command_specs(model) do
    model.commands()
    |> PropertyDamage.Model.normalize_commands()
    |> Map.new(fn {_weight, module, spec} -> {module, spec} end)
  rescue
    _ -> %{}
  end

  # Execute command with settle logic for probes/async, sourced from the spec
  defp execute_with_settle(command, adapter, user_context, runtime, spec) do
    execution = settle_execution(command, spec)

    if execution in [:probe, :async] do
      config = settle_config(command, spec)

      Settle.settle(
        fn -> adapter.execute(command, user_context, runtime) end,
        timeout_ms: config.timeout_ms,
        interval_ms: config.interval_ms,
        backoff: config.backoff
      )
    else
      adapter.execute(command, user_context, runtime)
    end
  end

  defp settle_execution(command, nil), do: Settle.get_semantics(command)
  defp settle_execution(_command, spec), do: Map.get(spec, :execution, :sync)

  defp settle_config(command, nil), do: Settle.get_config(command)
  defp settle_config(_command, %{settle: settle}) when is_map(settle), do: settle
  defp settle_config(command, _spec), do: Settle.get_config(command)

  # Inject an event mid-execution from an adapter.
  # Called via runtime.inject.(event) from adapter execute; `sink` is the per-command
  # Runtime.Sink (DR-027), replacing the former process-dictionary channel.
  # Updates projections immediately and records in the event log.
  defp inject_event(sink, event) do
    case Runtime.Sink.get_ctx(sink) do
      nil ->
        raise ArgumentError, "inject called outside adapter execution context"

      ctx ->
        # 1. Update projections immediately. The fold runs HERE, in the caller
        # (adapter) process, so a projection apply/2 that raises a
        # transition-invariant violation propagates into the adapter exactly as
        # before, rather than crashing the sink's Agent.
        projections = update_projections(ctx.projections, event)

        # 2. Create entry with source :injected
        entry = Entry.from_injected(event, ctx.command_index, branch_id: ctx.branch_id)

        # 3. Store the accumulated state. Injected events are accumulated in
        # injection order so external() values they carry can be captured
        # (DR-021): the producer's logical event list is the injected events
        # followed by the events returned from execute, matching the order used to
        # assign each placeholder's event_index during generation.
        Runtime.Sink.update_ctx(sink, fn ctx ->
          %{
            ctx
            | projections: projections,
              injected_events: ctx.injected_events ++ [event],
              event_log: [entry | ctx.event_log]
          }
        end)

        :ok
    end
  end

  # A %Runtime{} for execution paths that have no live injection window:
  #   * stutter retries run after the per-command sink has been drained and
  #     stopped, and
  #   * execute_raw/3 runs commands without projections to fold into.
  # Calling inject/start_poller there raises a clear ArgumentError rather than
  # the old KeyError (those keys simply weren't present in the context before).
  # Shared with PropertyDamage.Executor.Stutter (stutter retries). DR-029.
  @doc false
  def inject_unavailable_runtime(reason, stutter \\ nil) do
    %Runtime{
      inject: fn _event ->
        raise ArgumentError, "Runtime.inject is not available #{reason}"
      end,
      start_poller: fn _opts ->
        raise ArgumentError, "Runtime.start_poller is not available #{reason}"
      end,
      stutter: stutter
    }
  end

  # Update all projections with a command or event
  # apply/2 can raise to signal transition invariant violations
  # Shared with PropertyDamage.Executor.Nemesis (nemesis/restore folds). DR-029.
  @doc false
  def update_projections(projections, item) do
    for {projection, state} <- projections, into: %{} do
      new_state =
        try do
          projection.apply(state, item)
        rescue
          e ->
            # A raising apply/2 is a legitimate transition-invariant signal;
            # tag it so execute_command can report it instead of crashing.
            reraise PropertyDamage.ProjectionError,
                    [
                      projection: projection,
                      item: item,
                      original: e,
                      original_stacktrace: __STACKTRACE__
                    ],
                    __STACKTRACE__
        end

      {projection, new_state}
    end
  end

  # Apply updates onto the existing %State{}, preserving every field not being
  # changed. Uses struct!/2 so a write to an undeclared field RAISES rather than
  # silently producing a corrupt struct-shaped map (DR-029); the State struct is
  # the single source of truth for the run-state shape.
  # Shared with PropertyDamage.Executor.Nemesis (active_faults updates). DR-029.
  @doc false
  def put_state(%State{} = state, updates), do: struct!(state, updates)

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

  # Shared with PropertyDamage.Executor.Finalization (settle/drain). DR-029.
  @doc false
  def process_injector_events(nil, event_log, projections, _branch_id),
    do: {projections, event_log}

  def process_injector_events(event_queue, event_log, projections, branch_id) do
    entries = EventQueue.drain(event_queue)

    Enum.reduce(entries, {projections, event_log}, fn queue_entry, {projs, log} ->
      # Build entry based on source type
      entry =
        case queue_entry do
          %{source: :resource_poller} ->
            Entry.from_resource_poller(
              queue_entry.event,
              queue_entry.command_index,
              queue_entry.poller_id,
              timestamp: queue_entry.timestamp,
              branch_id: queue_entry.branch_id || branch_id
            )

          _ ->
            # Regular injector adapter entry
            %Entry{
              timestamp: queue_entry.timestamp,
              command_index: nil,
              event: queue_entry.event,
              source: :injector,
              injector_adapter: queue_entry.adapter_module,
              nemesis_module: nil,
              branch_id: branch_id
            }
        end

      new_projs = update_projections(projs, queue_entry.event)
      {new_projs, [entry | log]}
    end)
  end

  # Flush and process events from mock service adapters
  defp process_mock_events(nil, _command_index, event_log, projections, _branch_id),
    do: {projections, event_log}

  defp process_mock_events(mock_registry, command_index, event_log, projections, branch_id) do
    events = MockServiceRegistry.flush_events(mock_registry)

    Enum.reduce(events, {projections, event_log}, fn event, {projs, log} ->
      entry = %Entry{
        timestamp: System.monotonic_time(:millisecond),
        command_index: command_index,
        event: event,
        source: :mock,
        injector_adapter: nil,
        nemesis_module: nil,
        branch_id: branch_id
      }

      # Notify mock registry of the event so mocks can react
      MockServiceRegistry.notify_event(mock_registry, event)

      new_projs = update_projections(projs, event)
      {new_projs, [entry | log]}
    end)
  end

  # Run all triggered assertions
  # assertion_ctx contains: step_type (:command | :event), module, step_count
  # assertion_mode controls behavior: :halt, :record, or :log
  defp run_assertions(
         model,
         projections,
         assertion_ctx,
         assertion_counters,
         assertion_mode,
         assertion_failures,
         check_ctx
       ) do
    require Logger

    # Get all projections that may have assertions
    cmd_seq_projection = model.command_sequence_projection()

    assertion_projections =
      if function_exported?(model, :assertion_projections, 0) do
        model.assertion_projections()
      else
        []
      end

    all_projections = [cmd_seq_projection | assertion_projections]

    result =
      Enum.reduce_while(
        all_projections,
        {:ok, assertion_counters, assertion_failures},
        fn projection, {:ok, counters, failures} ->
          projection_state = Map.get(projections, projection)

          # Only projections that use PropertyDamage.Model.Projection have __assertions__/0
          assertions =
            if function_exported?(projection, :__assertions__, 0) do
              projection.__assertions__()
            else
              []
            end

          case run_projection_assertions(
                 projection,
                 projection_state,
                 assertions,
                 assertion_ctx,
                 counters
               ) do
            {:ok, new_counters} ->
              {:cont, {:ok, new_counters, failures}}

            {:error, assertion_name, reason, new_counters} ->
              # Handle based on assertion_mode
              case assertion_mode do
                :halt ->
                  {:halt, {:error, assertion_name, reason, new_counters}}

                :record ->
                  # Record failure and continue
                  failure = %{
                    assertion_name: assertion_name,
                    reason: reason,
                    command: Map.get(check_ctx, :command),
                    command_index: Map.get(check_ctx, :command_index),
                    step_type: assertion_ctx.step_type,
                    module: assertion_ctx.module,
                    timestamp: System.monotonic_time(:millisecond)
                  }

                  {:cont, {:ok, new_counters, [failure | failures]}}

                :log ->
                  # Log warning and continue
                  Logger.warning("Assertion failed: #{assertion_name} - #{inspect(reason)}")
                  {:cont, {:ok, new_counters, failures}}
              end
          end
        end
      )

    # Normalize result format
    case result do
      {:ok, counters, failures} -> {:ok, counters, failures}
      {:error, _, _, _} = error -> error
    end
  end

  defp run_projection_assertions(
         projection,
         projection_state,
         assertions,
         assertion_ctx,
         counters
       ) do
    alias PropertyDamage.Model.Projection

    # Only synchronous (@trigger) assertions run here; polling (@poll_state)
    # assertions have no :trigger key and are handled by the pollers. Without
    # this filter, accessing assertion.trigger on a polling assertion raised
    # a KeyError that crashed the run on the first command. Lifecycle-boundary
    # assertions (@trigger at:, DR-024) are also synchronous but fire only at a
    # phase boundary, not during the command loop, so they are excluded here and
    # dispatched separately by run_phase_assertions/2.
    sync_assertions =
      Enum.filter(assertions, fn assertion ->
        assertion.type == :synchronous and not match?(%{type: :at}, assertion.trigger)
      end)

    Enum.reduce_while(sync_assertions, {:ok, counters}, fn assertion, {:ok, acc_counters} ->
      if Projection.should_run?(
           assertion.trigger,
           assertion_ctx.step_type,
           assertion_ctx.module,
           acc_counters
         ) do
        # The assertion runs: record the firing (DR-026) before invoking it, so
        # a failing assertion still counts as exercised. This single site covers
        # both the synchronous command/event path and the asynchronous
        # observation path (DR-025), which dispatches through run_assertions/7.
        fired = bump_fired(acc_counters, projection, assertion.name)

        # Execute assertion - assertions raise on failure
        try do
          assertion_fn = assertion.function_name
          apply(projection, assertion_fn, [projection_state, assertion_ctx.command_or_event])
          # Success: no exception raised
          {:cont, {:ok, fired}}
        rescue
          e ->
            # Assertion failed by raising exception - capture stacktrace
            stacktrace = __STACKTRACE__
            {:halt, {:error, assertion.name, {e, stacktrace}, fired}}
        end
      else
        {:cont, {:ok, acc_counters}}
      end
    end)
  end

  # Record one firing of an assertion (DR-026). Per-assertion fire counts are
  # colocated as {:fired, projection, name} keys inside the existing
  # assertion_counters map: inert to should_run?/4 (which does only point
  # lookups, never iterates) and carried for free by the additive branch merge
  # in merge_branch_states/5.
  defp bump_fired(counters, projection, name) do
    Map.update(counters, {:fired, projection, name}, 1, &(&1 + 1))
  end

  # ============================================================================
  # Lifecycle-Boundary Assertions (@trigger at:, DR-024)
  # ============================================================================

  # Run every @trigger at: <phase> assertion once on the given projection state.
  # Unlike during-run (every:) assertions there is no step counter and no
  # should_run?/4 sampling: the timing IS the phase boundary. The triggering
  # command/event slot carries the phase atom (:startup | :teardown) so a
  # state-only check ignores it.
  #
  # Returns one of:
  #   {:ok, recorded_failures}  -- recorded_failures are the :record-mode
  #                                failures from this phase, newest-first; empty
  #                                on a clean pass and under :log/:disabled.
  #   {:halt, name, {exception, stacktrace}} -- first failure under :halt mode.
  #
  # Returns one of (DR-026 threads the fire counters through so lifecycle
  # firings are recorded, since these assertions never pass through the
  # during-run counter path):
  #   {:ok, recorded_failures, counters}
  #   {:halt, name, {exception, stacktrace}, counters}
  # Shared with PropertyDamage.Executor.Finalization (:teardown checkpoint). DR-029.
  @doc false
  def run_phase_assertions(state, phase) do
    assertion_mode = Map.get(state, :assertion_mode, :halt)
    counters = Map.get(state, :assertion_counters, %{})

    if assertion_mode == :disabled do
      {:ok, [], counters}
    else
      model = Map.fetch!(state, :model)
      projections = state.projections

      Enum.reduce_while(projection_modules(model), {:ok, [], counters}, fn projection,
                                                                           {:ok, recorded,
                                                                            acc_counters} ->
        projection_state = Map.get(projections, projection)
        assertions = phase_assertions(projection, phase)

        case run_phase_projection_assertions(
               projection,
               projection_state,
               assertions,
               phase,
               assertion_mode,
               recorded,
               acc_counters
             ) do
          {:ok, new_recorded, new_counters} -> {:cont, {:ok, new_recorded, new_counters}}
          {:halt, name, reason, halt_counters} -> {:halt, {:halt, name, reason, halt_counters}}
        end
      end)
    end
  end

  defp run_phase_projection_assertions(
         projection,
         projection_state,
         assertions,
         phase,
         assertion_mode,
         recorded,
         counters
       ) do
    require Logger

    Enum.reduce_while(assertions, {:ok, recorded, counters}, fn assertion,
                                                                {:ok, acc_recorded, acc_counters} ->
      # Record the firing (DR-026) before invoking, so a failing lifecycle check
      # still counts as exercised.
      fired = bump_fired(acc_counters, projection, assertion.name)

      try do
        apply(projection, assertion.function_name, [projection_state, phase])
        {:cont, {:ok, acc_recorded, fired}}
      rescue
        e ->
          stacktrace = __STACKTRACE__

          case assertion_mode do
            :halt ->
              {:halt, {:halt, assertion.name, {e, stacktrace}, fired}}

            :record ->
              failure = %{
                assertion_name: assertion.name,
                reason: {e, stacktrace},
                command: nil,
                command_index: nil,
                step_type: phase,
                module: nil,
                timestamp: System.monotonic_time(:millisecond)
              }

              {:cont, {:ok, [failure | acc_recorded], fired}}

            :log ->
              Logger.warning("Assertion failed at #{phase}: #{assertion.name} - #{inspect(e)}")

              {:cont, {:ok, acc_recorded, fired}}
          end
      end
    end)
  end

  # The @trigger at: <phase> assertions declared on a projection. Lifecycle
  # assertions stay type: :synchronous; the at: phase lives in the trigger spec.
  defp phase_assertions(projection, phase) do
    if function_exported?(projection, :__assertions__, 0) do
      Enum.filter(projection.__assertions__(), fn assertion ->
        assertion.type == :synchronous and
          match?(%{type: :at, phase: ^phase}, Map.get(assertion, :trigger))
      end)
    else
      []
    end
  end

  # The full projection list a model exposes: the command-sequence projection
  # plus any assertion projections.
  defp projection_modules(model) do
    assertion_projections =
      if function_exported?(model, :assertion_projections, 0) do
        model.assertion_projections()
      else
        []
      end

    [model.command_sequence_projection() | assertion_projections]
    |> Enum.uniq()
  end

  # Legacy wrapper for backward compatibility
  # Maps old check_ctx format to new assertion_ctx format
  # Now accepts assertion_mode and assertion_failures from state
  # Shared with PropertyDamage.Executor.Nemesis (nemesis-command checks). DR-029.
  @doc false
  def run_checks(
        _model,
        _projections,
        _check_ctx,
        assertion_counters,
        :disabled,
        assertion_failures
      ) do
    # When disabled, skip all assertions and just return success
    {:ok, assertion_counters, assertion_failures}
  end

  def run_checks(
        model,
        projections,
        check_ctx,
        assertion_counters,
        assertion_mode,
        assertion_failures
      ) do
    command_module = check_ctx.command.__struct__

    # Update counters
    counters =
      assertion_counters
      |> Map.update(:step, 1, &(&1 + 1))
      |> Map.update(:command, 1, &(&1 + 1))
      |> Map.update(command_module, 1, &(&1 + 1))

    # Run assertions for command
    assertion_ctx = %{
      step_type: :command,
      module: command_module,
      command_or_event: check_ctx.command
    }

    case run_assertions(
           model,
           projections,
           assertion_ctx,
           counters,
           assertion_mode,
           assertion_failures,
           check_ctx
         ) do
      {:ok, counters_after_cmd, updated_failures} ->
        # Now run assertions for each event
        run_event_assertions(
          model,
          projections,
          check_ctx.events,
          counters_after_cmd,
          assertion_mode,
          updated_failures,
          check_ctx
        )

      error ->
        error
    end
  end

  defp run_event_assertions(
         _model,
         _projections,
         [],
         counters,
         _assertion_mode,
         failures,
         _check_ctx
       ),
       do: {:ok, counters, failures}

  defp run_event_assertions(
         model,
         projections,
         [event | rest],
         counters,
         assertion_mode,
         failures,
         check_ctx
       ) do
    event_module = event.__struct__

    # Update counters for this event
    counters =
      counters
      |> Map.update(:step, 1, &(&1 + 1))
      |> Map.update(:event, 1, &(&1 + 1))
      |> Map.update(event_module, 1, &(&1 + 1))

    assertion_ctx = %{
      step_type: :event,
      module: event_module,
      command_or_event: event
    }

    case run_assertions(
           model,
           projections,
           assertion_ctx,
           counters,
           assertion_mode,
           failures,
           check_ctx
         ) do
      {:ok, new_counters, updated_failures} ->
        run_event_assertions(
          model,
          projections,
          rest,
          new_counters,
          assertion_mode,
          updated_failures,
          check_ctx
        )

      error ->
        error
    end
  end

  # ============================================================================
  # Continuous async-observation checking (DR-025)
  # ============================================================================
  #
  # The asynchronous event paths (resource-poller / injector-adapter events,
  # mock-service events, nemesis events, and the finalize-time drains) fold
  # events into projection state. DR-025 additionally evaluates `@trigger every:`
  # assertions on those events, so a violation is reported AT the offending event
  # (with that event's `command_index`) rather than only at the
  # `@trigger at: :teardown` settled checkpoint, giving the shrinker a tight
  # truncation target.
  #
  # Evaluation is INCREMENTAL: each event is asserted on the state produced by
  # folding *that* event, not the final drained state. `check_async/7` recovers
  # each event's state by re-folding from `projs_before` over the entries the
  # processor just prepended to the event log (one event at a time), and leaves
  # the already-folded `projections` untouched. The distinction is load-bearing
  # for shrink convergence: asserting against the final drained state would report
  # at the *first* matching event in a batch rather than the causal one, so the
  # reported `command_index` would not reproduce on truncation. Command-own events
  # keep their existing batch-against-final timing (run_checks); only the async
  # paths are incremental (the documented asymmetry, DR-025).

  # Run `@trigger every:` assertions on the events folded since `log_before`
  # (newest-first prepended to `event_log`), incrementally on each event's
  # post-fold state. Returns `{:ok, counters, failures}`, or under `:halt`
  # `{:halt, name, reason, command_index, counters}` where `command_index`
  # locates the offending event for the shrinker (nil for a pure injector event).
  # Shared with PropertyDamage.Executor.Finalization (settle/drain). DR-029.
  @doc false
  def check_async(_model, _projs_before, _log_before, _event_log, counters, :disabled, failures),
    do: {:ok, counters, failures}

  def check_async(model, projs_before, log_before, event_log, counters, mode, failures) do
    new_count = length(event_log) - length(log_before)

    new_entries = event_log |> Enum.take(new_count) |> Enum.reverse()

    folded =
      Enum.reduce_while(new_entries, {projs_before, counters, failures}, fn entry,
                                                                            {projs, c, f} ->
        projs = update_projections(projs, entry.event)

        case check_async_event(model, projs, entry.event, entry.command_index, c, mode, f) do
          {:ok, c, f} -> {:cont, {projs, c, f}}
          {:halt, name, reason, c} -> {:halt, {:halt, name, reason, entry.command_index, c}}
        end
      end)

    case folded do
      {_projs, c, f} -> {:ok, c, f}
      {:halt, name, reason, idx, c} -> {:halt, name, reason, idx, c}
    end
  end

  # Evaluate the synchronous (`@trigger every:`) dispatch for a single
  # asynchronously-observed event, on its post-fold `projections`. Mirrors
  # `run_event_assertions`' counter bumps (`:step` / `:event` / module) so
  # `every: N` sampling counts async observations. `step_type` is `:event`, so
  # `every: :command` assertions do NOT fire (the opt-out) while `every: :event`
  # / `every: 1` / `every: Module` do.
  defp check_async_event(model, projections, event, command_index, counters, mode, failures) do
    module = event.__struct__

    counters =
      counters
      |> Map.update(:step, 1, &(&1 + 1))
      |> Map.update(:event, 1, &(&1 + 1))
      |> Map.update(module, 1, &(&1 + 1))

    assertion_ctx = %{step_type: :event, module: module, command_or_event: event}
    check_ctx = %{command: nil, command_index: command_index}

    case run_assertions(model, projections, assertion_ctx, counters, mode, failures, check_ctx) do
      {:ok, counters, failures} -> {:ok, counters, failures}
      {:error, name, reason, counters} -> {:halt, name, reason, counters}
    end
  end

  # ============================================================================
  # State Poller Support
  # ============================================================================

  @doc false
  # Spawn pollers for any @poll_state assertions triggered by the given events
  defp maybe_spawn_pollers(state, events, model) do
    assertion_mode = Map.get(state, :assertion_mode, :halt)

    # Skip if assertions are disabled
    if assertion_mode == :disabled do
      state
    else
      # Get all projections
      cmd_seq_projection = model.command_sequence_projection()

      assertion_projections =
        if function_exported?(model, :assertion_projections, 0) do
          model.assertion_projections()
        else
          []
        end

      all_projections = [cmd_seq_projection | assertion_projections]

      # For each event, check if any @poll_state assertions should be spawned.
      # Each spawned poller is paired with its (projection, assertion name) so
      # the spawn can be recorded as a firing (DR-026): spawning IS firing for a
      # liveness check (the after: event arrived and verification began), so a
      # timed-out or still-pending poller still counts as exercised.
      spawned =
        for event <- events,
            event_module = event.__struct__,
            projection <- all_projections,
            function_exported?(projection, :__assertions__, 0),
            assertion <- projection.__assertions__(),
            assertion.type == :polling,
            Projection.event_matches_poll_trigger?(assertion.poll_state, event_module) do
          # Get current projection state
          projection_state = Map.get(state.projections, projection)

          # Call the assertion function to get the predicate. Dispatch by
          # function_name (the actual def), since :name is the logical
          # (assert_-stripped) name shared with synchronous assertions.
          predicate = apply(projection, assertion.function_name, [projection_state, event])

          # Build state getter for the poller
          get_state_fn = fn proj ->
            # This will be updated by the executor as state changes
            Map.get(state.projections, proj)
          end

          # Spawn the poller
          poller =
            StatePoller.start(
              predicate: predicate,
              predicate_source: assertion.predicate_source,
              projection: projection,
              interval_ms: assertion.poll_state.interval_ms,
              timeout_ms: assertion.poll_state.timeout_ms,
              triggered_by: %{event: event, assertion_name: assertion.name},
              get_state_fn: get_state_fn
            )

          {projection, assertion.name, poller}
        end

      if Enum.empty?(spawned) do
        state
      else
        new_pollers = Enum.map(spawned, fn {_proj, _name, poller} -> poller end)

        counters =
          Enum.reduce(spawned, Map.get(state, :assertion_counters, %{}), fn {proj, name, _poller},
                                                                            acc ->
            bump_fired(acc, proj, name)
          end)

        existing_pollers = Map.get(state, :active_pollers, [])
        %{state | active_pollers: existing_pollers ++ new_pollers, assertion_counters: counters}
      end
    end
  end

  @doc false
  # Update state getter for all active pollers with new projection state.
  # Shared with PropertyDamage.Executor.Finalization (drain). DR-029.
  def update_poller_state_getters(state) do
    pollers = Map.get(state, :active_pollers, [])
    projections = state.projections

    for poller <- pollers do
      get_state_fn = fn proj -> Map.get(projections, proj) end
      StatePoller.update_state_getter(poller, get_state_fn)
    end

    state
  end

  # ============================================================================
  # Model-Free Execution (for static regression tests)
  # ============================================================================

  @doc """
  Execute a command sequence without model projections or assertions.

  This is a simplified execution path for static regression tests where you want
  to run a fixed command sequence and assert on the raw event log directly,
  without using model-defined projections or checks.

  ## Parameters

  - `sequence` - Sequence struct or list of commands to execute
  - `adapter` - Adapter module for SUT interaction
  - `context` - Execution context map containing:
    - `:adapter_context` - Pre-established adapter context from adapter.setup/1
    - `:event_queue` - EventQueue pid for injector events (optional)

  ## Returns

  - `{:ok, event_log}` - List of EventLog.Entry structs
  - `{:error, {:adapter_error, reason, partial_events}}` - Adapter failed

  ## Example

      {:ok, adapter_ctx} = MyAdapter.setup(%{})
      {:ok, event_queue} = EventQueue.start_link()

      context = %{
        adapter_context: adapter_ctx,
        event_queue: event_queue
      }

      {:ok, events} = Executor.execute_raw(commands, MyAdapter, context)
  """
  @spec execute_raw(Sequence.t() | list(), module(), map()) ::
          {:ok, [Entry.t()]} | {:error, term()}
  def execute_raw(sequence_or_commands, adapter, context)

  def execute_raw(%Sequence{} = sequence, adapter, context) do
    commands = Sequence.to_list(sequence)
    execute_raw(commands, adapter, context)
  end

  def execute_raw(commands, adapter, context) when is_list(commands) do
    event_queue = Map.get(context, :event_queue)

    # Build a placeholder registry from the commands so external() values
    # produced by one command resolve in later ones (DR-021). Consumers carry a
    # %Placeholder{} keyed to its producer's linear {:prefix, index} position.
    registry = build_placeholder_registry(commands)

    initial_state = %{
      events: [],
      registry: registry
    }

    result =
      commands
      |> Enum.with_index()
      |> Enum.reduce_while(initial_state, fn {command, index}, state ->
        case execute_raw_command(
               command,
               index,
               adapter,
               context.adapter_context,
               event_queue,
               state.registry
             ) do
          {:ok, new_events, new_registry} ->
            # Accumulate event chunks newest-first and flatten once at the end,
            # rather than `++`-ing onto the growing list each step (which copies
            # the whole accumulator every command, an O(n^2) cost).
            {:cont, %{events: [new_events | state.events], registry: new_registry}}

          {:error, reason} ->
            {:halt, {:error, {:adapter_error, reason, flatten_event_chunks(state.events)}}}
        end
      end)

    case result do
      {:error, _} = error -> error
      %{events: chunks} -> {:ok, flatten_event_chunks(chunks)}
    end
  end

  # Collect every %Placeholder{} carried in the command list and register it, so
  # the registry's producer_link maps each producer position to its placeholder
  # ids for capture_externals/3.
  defp build_placeholder_registry(commands), do: PlaceholderRegistry.build(commands)

  # Event chunks are prepended per command (newest-first); restore execution
  # order and concatenate in a single pass.
  defp flatten_event_chunks(chunks), do: chunks |> Enum.reverse() |> Enum.concat()

  # Execute a single command in raw mode (no projections/assertions)
  defp execute_raw_command(command, index, adapter, adapter_context, event_queue, registry) do
    # Resolve placeholders in command (only for structs that might carry them)
    resolved_result =
      if is_struct(command) do
        resolve_command_placeholders(command, registry)
      else
        # Plain maps don't carry placeholders in raw mode
        {:ok, command}
      end

    case resolved_result do
      {:ok, resolved_command} ->
        # Raw mode has no projections to fold, but it does drain the event_queue
        # for injector events below, so `runtime.inject` routes there (DR-027):
        # an adapter emits an out-of-band event via `runtime.inject.(event)`
        # rather than reaching into a framework key on its user_context. With no
        # event_queue configured, inject/start_poller raise a clear error.
        # start_poller has no home in raw mode either way.
        runtime =
          if event_queue do
            %Runtime{
              inject: fn event -> EventQueue.push(event_queue, adapter, event) end,
              start_poller: fn _opts ->
                raise ArgumentError,
                      "Runtime.start_poller is not available in Executor.execute_raw/3"
              end
            }
          else
            inject_unavailable_runtime("in Executor.execute_raw/3 (no event queue configured)")
          end

        # Execute via adapter
        case adapter.execute(resolved_command, adapter_context, runtime) do
          {:ok, events} ->
            # Capture external() values this command produced, keyed by its linear
            # position, so later commands resolve them (DR-021).
            new_registry = capture_externals(events, {:prefix, index}, registry)

            # Create event log entries
            entries =
              Enum.map(events, fn event ->
                Entry.from_command(event, index)
              end)

            # Drain and add injector events if event_queue provided
            injector_entries =
              if event_queue do
                event_queue
                |> EventQueue.drain()
                |> Enum.map(fn queue_entry ->
                  %Entry{
                    timestamp: queue_entry.timestamp,
                    command_index: nil,
                    event: queue_entry.event,
                    source: :injector,
                    injector_adapter: queue_entry.adapter_module
                  }
                end)
              else
                []
              end

            {:ok, entries ++ injector_entries, new_registry}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:ref_resolution_error, reason}}
    end
  end

  # ============================================================================
  # External/Placeholder Support
  # ============================================================================

  # Resolve placeholders in a command before execution.
  # Shared with PropertyDamage.Executor.Nemesis (nemesis placeholder resolution). DR-029.
  @doc false
  def resolve_command_placeholders(command, registry) do
    resolved = deep_resolve_placeholders(command, registry)
    {:ok, resolved}
  rescue
    e in ArgumentError ->
      stacktrace = __STACKTRACE__
      {:error, {e.message, stacktrace}}
  end

  defp deep_resolve_placeholders(%Placeholder{} = p, registry) do
    case PlaceholderRegistry.get(registry, p.id) do
      nil ->
        raise ArgumentError, "Unknown placeholder: #{inspect(p)}"

      %{resolved: nil} = placeholder ->
        raise ArgumentError,
              "Unresolved placeholder at #{inspect(placeholder.path)} " <>
                "(position #{inspect(placeholder.position)}, event #{placeholder.event_index})"

      %{resolved: value} ->
        value
    end
  end

  defp deep_resolve_placeholders(%{__struct__: mod} = struct, registry) do
    struct
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {k, deep_resolve_placeholders(v, registry)} end)
    |> Map.new()
    |> then(&struct(mod, &1))
  end

  defp deep_resolve_placeholders(map, registry) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {deep_resolve_placeholders(k, registry), deep_resolve_placeholders(v, registry)}
    end)
  end

  defp deep_resolve_placeholders(list, registry) when is_list(list) do
    Enum.map(list, &deep_resolve_placeholders(&1, registry))
  end

  defp deep_resolve_placeholders(tuple, registry) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&deep_resolve_placeholders(&1, registry))
    |> List.to_tuple()
  end

  defp deep_resolve_placeholders(other, _registry), do: other

  # Capture real external values from a command's events into the registry
  # (DR-021). The command's structured `position` selects the placeholders it
  # produces (via the registry's producer_link); each is resolved by id with the
  # value found at its recorded path/event_index in the real events. This is
  # position-driven, so it is correct under branching (distinct branch positions)
  # and shrinking (the position is rebuilt per run, never a stale generation key).
  defp capture_externals(events, position, registry) do
    PlaceholderRegistry.capture(registry, position, events)
  end
end
