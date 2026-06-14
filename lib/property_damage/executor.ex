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

  alias PropertyDamage.{
    Ref,
    EventQueue,
    Sequence,
    Settle,
    Nemesis,
    Stutter,
    MockServiceRegistry,
    Linearization,
    StatePoller,
    ResourcePoller,
    External,
    Placeholder,
    PlaceholderRegistry
  }

  alias PropertyDamage.Model.Projection

  alias PropertyDamage.EventLog.Entry

  # Process dictionary key for injection context during adapter execution.
  # This allows adapters to inject events mid-execution using ctx.inject.(event).
  @injection_ctx_key :pd_injection_context

  # Process dictionary key for tracking resource pollers started during execute.
  # This allows collecting pollers spawned by ctx.start_poller.(opts).
  @resource_pollers_key :pd_resource_pollers

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
          refs: %{reference() => any()},
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
          {:ok, new_state} -> {:cont, new_state}
          {:error, reason, failed_state} -> {:halt, {:failed, index, reason, failed_state}}
        end
      end)

    finalize_result(result)
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
    %Sequence{prefix: prefix, branches: branches, suffix: suffix} = sequence

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
                    {:cont, new_state}

                  {:error, reason, failed_state} ->
                    {:halt, {:failed, index, reason, failed_state}}
                end
              end)

            finalize_result(suffix_result, linearization)

          {:error, branch_id, index, reason, state} ->
            finalize_result({:failed, index, {:branch_failure, branch_id, reason}, state})

          {:linearization_failed, branch_results, branch_event_logs} ->
            merged_state =
              merge_branch_states(
                prefix_state,
                branch_results,
                branch_event_logs,
                :no_linearization,
                branch_start_index
              )

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

        # Resolve each branch's commands against that branch's final refs so
        # the linearization checker (and the merge replay) sees the concrete
        # values the projections saw during execution
        resolved_branch_commands =
          Enum.map(successful_results, fn {_, state, commands} ->
            Enum.map(commands, &deep_resolve_refs(&1, state.refs, nil))
          end)

        case Linearization.check(
               resolved_branch_commands,
               Map.new(branch_event_logs),
               prefix_state.projections,
               model,
               start_index: start_index
             ) do
          {:ok, linearization} ->
            {:ok, successful_results, branch_event_logs, linearization}

          {:indeterminate, _checked} = indeterminate ->
            # Cannot verify (no simulator, or candidate cap reached): proceed
            # without claiming either way; the result records :indeterminate
            {:ok, successful_results, branch_event_logs, indeterminate}

          :no_linearization ->
            {:linearization_failed, successful_results, branch_event_logs}
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
    # Merge refs from all branches
    merged_refs =
      Enum.reduce(branch_results, prefix_state.refs, fn {_, state, _}, acc ->
        Map.merge(acc, state.refs)
      end)

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
          for {branch_id, state, commands} <- branch_results,
              {command, pos} <- Enum.with_index(commands) do
            {deep_resolve_refs(command, state.refs, nil), Map.get(observed, {branch_id, pos}, [])}
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

    # Update through the prefix state so every other key (placeholder
    # registry, stutter config, mock registry, model, external markers, ...)
    # is preserved instead of silently dropped
    %{
      prefix_state
      | event_log: merged_event_log,
        projections: merged_projections,
        projections_before: merged_projections,
        refs: merged_refs,
        step_count: total_steps,
        assertion_counters: merged_counters,
        assertion_failures: merged_failures,
        branch_id: nil,
        active_pollers: merged_pollers,
        active_resource_pollers: merged_resource_pollers
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
    # Stop any active pollers when we fail early
    pollers = Map.get(state, :active_pollers, [])
    Enum.each(pollers, &StatePoller.stop/1)

    # Stop any active resource pollers when we fail early
    resource_pollers = Map.get(state, :active_resource_pollers, [])
    Enum.each(resource_pollers, &ResourcePoller.stop/1)

    assertion_failures = Map.get(state, :assertion_failures, [])

    # Extract stacktrace from failure reason if embedded
    {normalized_reason, stacktrace} = extract_stacktrace(reason)

    %{
      success: false,
      event_log: Enum.reverse(state.event_log),
      projections: state.projections,
      projections_before: state.projections_before,
      refs: state.refs,
      failed_at_index: index,
      failure_reason: normalized_reason,
      stacktrace: stacktrace,
      linearization: linearization,
      assertion_failures: assertion_failures
    }
  end

  defp finalize_result(state, linearization) do
    # Finalize all active state pollers - wait for them to complete
    {state, assertion_failures, halt_failure} = finalize_pollers(state)

    # Check if any state poller halted the run in :halt mode. Both timeouts
    # and errors are halt-worthy; the error case previously fell through and
    # was reported as success.
    case halt_failure do
      {:timeout, _id, info} ->
        resource_pollers = Map.get(state, :active_resource_pollers, [])
        Enum.each(resource_pollers, &ResourcePoller.stop/1)
        poller_failure_result(state, {:poll_timeout, info}, linearization, assertion_failures)

      {:error, reason} ->
        resource_pollers = Map.get(state, :active_resource_pollers, [])
        Enum.each(resource_pollers, &ResourcePoller.stop/1)
        poller_failure_result(state, {:poll_error, reason}, linearization, assertion_failures)

      _ ->
        # Finalize resource pollers
        {state, resource_failures, resource_halt} = finalize_resource_pollers(state)

        combined_failures = assertion_failures ++ resource_failures

        # Check if any resource poller failed in :halt mode
        case resource_halt do
          {:error, _id, reason} ->
            poller_failure_result(
              state,
              {:resource_poller_error, reason},
              linearization,
              combined_failures
            )

          _ ->
            # In :record mode, success is false if there were any failures recorded
            success = Enum.empty?(combined_failures)

            %{
              success: success,
              event_log: Enum.reverse(state.event_log),
              projections: state.projections,
              projections_before: Map.get(state, :projections_before),
              refs: state.refs,
              failed_at_index: nil,
              failure_reason: nil,
              stacktrace: nil,
              linearization: linearization,
              assertion_failures: combined_failures
            }
        end
    end
  end

  # Shared shape for poller/record-mode failures. Crucially includes
  # :projections_before — its absence used to crash handle_failure with a
  # KeyError before any report could be built.
  defp poller_failure_result(state, failure_reason, linearization, failures) do
    %{
      success: false,
      event_log: Enum.reverse(state.event_log),
      projections: state.projections,
      projections_before: Map.get(state, :projections_before),
      refs: state.refs,
      failed_at_index: nil,
      failure_reason: failure_reason,
      stacktrace: nil,
      linearization: linearization,
      assertion_failures: failures
    }
  end

  # ============================================================================
  # Stacktrace Extraction
  # ============================================================================

  # Extract stacktrace from failure reasons that contain embedded stacktraces
  defp extract_stacktrace({:adapter_error, {exception, stacktrace}})
       when is_exception(exception) and is_list(stacktrace) do
    {{:adapter_error, exception}, stacktrace}
  end

  defp extract_stacktrace({:assertion_failed, name, {exception, stacktrace}})
       when is_exception(exception) and is_list(stacktrace) do
    {{:assertion_failed, name, exception}, stacktrace}
  end

  defp extract_stacktrace({:ref_resolution_error, {message, stacktrace}})
       when is_binary(message) and is_list(stacktrace) do
    {{:ref_resolution_error, message}, stacktrace}
  end

  defp extract_stacktrace({:branch_failure, branch_id, inner_reason}) do
    {inner_normalized, stacktrace} = extract_stacktrace(inner_reason)
    {{:branch_failure, branch_id, inner_normalized}, stacktrace}
  end

  # No embedded stacktrace
  defp extract_stacktrace(reason), do: {reason, nil}

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
    %{
      event_log: [],
      projections: init_projections(model),
      projections_before: nil,
      refs: %{},
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
      cond do
        # Check if this is a nemesis command
        Nemesis.nemesis_command?(command) ->
          execute_nemesis_command(command, index, state, model, adapter_context, event_queue)

        # Regular command
        true ->
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

  # Execute a nemesis (fault injection) command
  defp execute_nemesis_command(command, index, state, model, adapter_context, event_queue) do
    # Resolve refs/placeholders so a nemesis parameterized by a prior
    # command's output injects against the real value, not a sentinel
    placeholder_registry = Map.get(state, :placeholder_registry, PlaceholderRegistry.new())

    case resolve_refs_and_placeholders(command, state.refs, placeholder_registry) do
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
        projections = update_projections(state.projections, resolved_command)

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
          command: resolved_command,
          events: events,
          command_index: index,
          step_count: state.step_count + 1,
          projections: projections,
          branch_id: state.branch_id,
          active_faults: active_faults
        }

        case run_checks(
               model,
               projections,
               check_ctx,
               state.assertion_counters,
               assertion_mode,
               assertion_failures
             ) do
          {:ok, assertion_counters, updated_failures} ->
            new_state =
              put_state(state, %{
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
              put_state(state, %{
                event_log: event_log,
                projections: projections,
                step_count: state.step_count + 1,
                assertion_counters: assertion_counters,
                active_faults: active_faults
              })

            {:error, {:assertion_failed, assertion_name, reason}, failed_state}
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
         event_queue,
         mock_registry
       ) do
    # 0. Notify mock registry of command (before execution)
    if mock_registry do
      MockServiceRegistry.notify_command(mock_registry, command)
    end

    # Get placeholder_registry from state (may not exist in older tests)
    placeholder_registry = Map.get(state, :placeholder_registry, PlaceholderRegistry.new())

    # 1. Resolve refs and placeholders in command
    case resolve_refs_and_placeholders(command, state.refs, placeholder_registry) do
      {:ok, resolved_command} ->
        # 2. Set up injection context for mid-execution event injection
        injection_ctx = %{
          projections: state.projections,
          refs: state.refs,
          event_log: state.event_log,
          command_index: index,
          branch_id: state.branch_id,
          command: command
        }

        Process.put(@injection_ctx_key, injection_ctx)

        # 2b. Initialize resource poller tracking
        Process.put(@resource_pollers_key, [])

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

          # Track started poller in process dictionary
          pollers = Process.get(@resource_pollers_key, [])
          Process.put(@resource_pollers_key, [poller | pollers])
          poller
        end

        # Add inject function and start_poller to adapter context
        adapter_context_with_inject =
          adapter_context
          |> Map.put(:inject, &inject_event/1)
          |> Map.put(:start_poller, start_poller_fn)

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
              adapter_context_with_inject,
              command_spec
            )
          rescue
            e ->
              # Capture stacktrace for adapter exceptions
              stacktrace = __STACKTRACE__
              {:error, {e, stacktrace}}
          after
            # Always clean up - get final injection state first
            :ok
          end

        # Get accumulated state from injection context (includes any injected events)
        final_injection_ctx = Process.get(@injection_ctx_key)
        Process.delete(@injection_ctx_key)

        # Collect resource pollers started during execution
        started_resource_pollers = Process.get(@resource_pollers_key, [])
        Process.delete(@resource_pollers_key)

        # Use injection context state as base (already has injected events applied)
        base_projections = final_injection_ctx.projections
        base_refs = final_injection_ctx.refs
        base_event_log = final_injection_ctx.event_log

        assertion_mode = Map.get(state, :assertion_mode, :halt)
        assertion_failures = Map.get(state, :assertion_failures, [])

        case result do
          {:ok, events} ->
            # 4. Bind new ref if command creates one (from returned events)
            refs = maybe_bind_ref(command, events, base_refs)

            # 4b. Capture external values from real events (DR-021): resolve the
            # placeholders this command produces, found by its structured position.
            updated_registry =
              capture_externals(events, state.current_position, placeholder_registry)

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

            # 7. Drain and process injector events
            {projections, event_log} =
              process_injector_events(event_queue, event_log, projections, state.branch_id)

            # 7.5. Flush and process mock-injected events
            {projections, event_log} =
              process_mock_events(mock_registry, index, event_log, projections, state.branch_id)

            # 7.6. Update mock projections
            if mock_registry do
              MockServiceRegistry.update_projections(mock_registry, projections)
            end

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
                   state.assertion_counters,
                   assertion_mode,
                   assertion_failures
                 ) do
              {:ok, assertion_counters, updated_failures} ->
                # 9. Execute stutter retries if configured
                case maybe_execute_stutter_retries(
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
                        refs: refs,
                        placeholder_registry: updated_registry,
                        step_count: state.step_count + 1,
                        assertion_counters: assertion_counters,
                        assertion_failures: updated_failures,
                        active_resource_pollers:
                          Map.get(state, :active_resource_pollers, []) ++ started_resource_pollers
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
                        refs: refs,
                        placeholder_registry: updated_registry,
                        step_count: state.step_count + 1,
                        assertion_counters: assertion_counters,
                        assertion_failures: updated_failures,
                        active_resource_pollers:
                          Map.get(state, :active_resource_pollers, []) ++ started_resource_pollers
                      })

                    {:error, {:idempotency_violation, violation}, failed_state}

                  {:error, :stutter_execution_failed, details} ->
                    failed_state =
                      put_state(state, %{
                        event_log: event_log,
                        projections: projections,
                        refs: refs,
                        placeholder_registry: updated_registry,
                        step_count: state.step_count + 1,
                        assertion_counters: assertion_counters,
                        assertion_failures: updated_failures,
                        active_resource_pollers:
                          Map.get(state, :active_resource_pollers, []) ++ started_resource_pollers
                      })

                    {:error, {:stutter_execution_failed, details}, failed_state}
                end

              {:error, assertion_name, reason, assertion_counters} ->
                failed_state =
                  put_state(state, %{
                    event_log: event_log,
                    projections: projections,
                    refs: refs,
                    placeholder_registry: updated_registry,
                    step_count: state.step_count + 1,
                    assertion_counters: assertion_counters,
                    active_resource_pollers:
                      Map.get(state, :active_resource_pollers, []) ++ started_resource_pollers
                  })

                {:error, {:assertion_failed, assertion_name, reason}, failed_state}
            end

          {:settled, events} ->
            # Probe/async settled successfully - treat same as {:ok, events}
            refs = maybe_bind_ref(command, events, base_refs)

            # Capture external values from real events (DR-021), keyed by the
            # command's structured position.
            updated_registry =
              capture_externals(events, state.current_position, placeholder_registry)

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

            {projections, event_log} =
              process_injector_events(event_queue, event_log, projections, state.branch_id)

            # Flush and process mock-injected events
            {projections, event_log} =
              process_mock_events(mock_registry, index, event_log, projections, state.branch_id)

            # Update mock projections
            if mock_registry do
              MockServiceRegistry.update_projections(mock_registry, projections)
            end

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
                   state.assertion_counters,
                   assertion_mode,
                   assertion_failures
                 ) do
              {:ok, assertion_counters, updated_failures} ->
                # Execute stutter retries if configured (same as {:ok, events} path)
                case maybe_execute_stutter_retries(
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
                        refs: refs,
                        placeholder_registry: updated_registry,
                        step_count: state.step_count + 1,
                        assertion_counters: assertion_counters,
                        assertion_failures: updated_failures,
                        active_resource_pollers:
                          Map.get(state, :active_resource_pollers, []) ++ started_resource_pollers
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
                        refs: refs,
                        placeholder_registry: updated_registry,
                        step_count: state.step_count + 1,
                        assertion_counters: assertion_counters,
                        assertion_failures: updated_failures,
                        active_resource_pollers:
                          Map.get(state, :active_resource_pollers, []) ++ started_resource_pollers
                      })

                    {:error, {:idempotency_violation, violation}, failed_state}

                  {:error, :stutter_execution_failed, details} ->
                    failed_state =
                      put_state(state, %{
                        event_log: event_log,
                        projections: projections,
                        refs: refs,
                        placeholder_registry: updated_registry,
                        step_count: state.step_count + 1,
                        assertion_counters: assertion_counters,
                        assertion_failures: updated_failures,
                        active_resource_pollers:
                          Map.get(state, :active_resource_pollers, []) ++ started_resource_pollers
                      })

                    {:error, {:stutter_execution_failed, details}, failed_state}
                end

              {:error, assertion_name, reason, assertion_counters} ->
                failed_state =
                  put_state(state, %{
                    event_log: event_log,
                    projections: projections,
                    refs: refs,
                    placeholder_registry: updated_registry,
                    step_count: state.step_count + 1,
                    assertion_counters: assertion_counters,
                    active_resource_pollers:
                      Map.get(state, :active_resource_pollers, []) ++ started_resource_pollers
                  })

                {:error, {:assertion_failed, assertion_name, reason}, failed_state}
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
  defp execute_with_settle(command, adapter, adapter_context, spec) do
    execution = settle_execution(command, spec)

    if execution in [:probe, :async] do
      config = settle_config(command, spec)

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

  defp settle_execution(command, nil), do: Settle.get_semantics(command)
  defp settle_execution(_command, spec), do: Map.get(spec, :execution, :sync)

  defp settle_config(command, nil), do: Settle.get_config(command)
  defp settle_config(_command, %{settle: settle}) when is_map(settle), do: settle
  defp settle_config(command, _spec), do: Settle.get_config(command)

  # Resolve all refs in a command struct, skipping the creates_ref field
  defp resolve_command_refs(command, refs) do
    try do
      # Get the field to skip (the one this command creates)
      skip_field = get_creates_ref_field(command)
      resolved = deep_resolve_refs(command, refs, skip_field)
      {:ok, resolved}
    rescue
      e ->
        stacktrace = __STACKTRACE__
        {:error, {Exception.message(e), stacktrace}}
    end
  end

  # Combined resolution: resolve both refs (legacy) and placeholders (new system)
  defp resolve_refs_and_placeholders(command, refs, placeholder_registry) do
    with {:ok, refs_resolved} <- resolve_command_refs(command, refs),
         {:ok, fully_resolved} <-
           resolve_command_placeholders(refs_resolved, placeholder_registry) do
      {:ok, fully_resolved}
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

  # Bind a ref from a single event (used during injection)
  defp maybe_bind_ref_from_event(command, event, refs) do
    command_module = command.__struct__

    if function_exported?(command_module, :creates_ref, 0) do
      case command_module.creates_ref() do
        nil ->
          refs

        ref_field ->
          value = Map.get(event, ref_field)

          if value do
            # Find the ref in the command
            case Map.get(command, ref_field) do
              %Ref{} = ref -> Map.put(refs, ref.ref, value)
              _ -> refs
            end
          else
            refs
          end
      end
    else
      refs
    end
  end

  # Inject an event mid-execution from an adapter.
  # Called via ctx.inject.(event) from adapter execute/2.
  # Updates projections immediately and records in event log.
  defp inject_event(event) do
    case Process.get(@injection_ctx_key) do
      nil ->
        raise ArgumentError, "inject called outside adapter execution context"

      ctx ->
        # 1. Update projections immediately
        projections = update_projections(ctx.projections, event)

        # 2. Bind ref if event has the creates_ref field
        refs = maybe_bind_ref_from_event(ctx.command, event, ctx.refs)

        # 3. Create entry with source :injected
        entry = Entry.from_injected(event, ctx.command_index, branch_id: ctx.branch_id)

        # 4. Update process dictionary with accumulated state
        Process.put(@injection_ctx_key, %{
          ctx
          | projections: projections,
            refs: refs,
            event_log: [entry | ctx.event_log]
        })

        :ok
    end
  end

  # Update all projections with a command or event
  # apply/2 can raise to signal transition invariant violations
  defp update_projections(projections, item) do
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

  # Merge updates onto the existing state, preserving every key not being
  # changed. Replaces the old hand-rolled state-map literals that silently
  # dropped keys (placeholder_registry, stutter_config, mock_registry,
  # external_markers, active_faults, model, pollers, ...).
  defp put_state(state, updates), do: Map.merge(state, Map.new(updates))

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

  # Drain and process events from injector adapters and resource pollers
  defp process_injector_events(nil, event_log, projections, _branch_id),
    do: {projections, event_log}

  defp process_injector_events(event_queue, event_log, projections, branch_id) do
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
    # a KeyError that crashed the run on the first command.
    sync_assertions = Enum.filter(assertions, &(&1.type == :synchronous))

    Enum.reduce_while(sync_assertions, {:ok, counters}, fn assertion, {:ok, acc_counters} ->
      if Projection.should_run?(
           assertion.trigger,
           assertion_ctx.step_type,
           assertion_ctx.module,
           acc_counters
         ) do
        # Execute assertion - assertions raise on failure
        try do
          assertion_fn = assertion.function_name
          apply(projection, assertion_fn, [projection_state, assertion_ctx.command_or_event])
          # Success: no exception raised
          {:cont, {:ok, acc_counters}}
        rescue
          e ->
            # Assertion failed by raising exception - capture stacktrace
            stacktrace = __STACKTRACE__
            {:halt, {:error, assertion.name, {e, stacktrace}, acc_counters}}
        end
      else
        {:cont, {:ok, acc_counters}}
      end
    end)
  end

  # Legacy wrapper for backward compatibility
  # Maps old check_ctx format to new assertion_ctx format
  # Now accepts assertion_mode and assertion_failures from state
  defp run_checks(
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

  defp run_checks(
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
  # Stutter (Idempotency Testing) Support
  # ============================================================================

  @doc false
  # Execute stutter retries after successful first execution
  # Returns {:ok, event_log} or {:error, :idempotency_violation, details}
  defp maybe_execute_stutter_retries(
         command,
         resolved_command,
         original_events,
         index,
         event_log,
         state,
         adapter,
         adapter_context
       ) do
    stutter_config = Map.get(state, :stutter_config)

    if stutter_config && Stutter.should_stutter?(command, stutter_config) do
      execute_stutter_retries(
        resolved_command,
        original_events,
        index,
        event_log,
        stutter_config,
        adapter,
        adapter_context,
        state.branch_id
      )
    else
      {:ok, event_log}
    end
  end

  defp execute_stutter_retries(
         resolved_command,
         original_events,
         index,
         event_log,
         stutter_config,
         adapter,
         adapter_context,
         branch_id
       ) do
    retry_count = Stutter.retry_count(stutter_config)
    idempotency_key = Stutter.get_idempotency_key(resolved_command)

    # Execute retries
    retry_results =
      Enum.map(2..(retry_count + 1), fn attempt ->
        # Add delay between retries
        delay_ms = Stutter.retry_delay_ms(stutter_config)

        if delay_ms > 0 do
          Process.sleep(delay_ms)
        end

        # Build stutter context for adapter
        stutter_ctx = Stutter.build_context(attempt, true, idempotency_key)

        # Merge stutter context into adapter context
        ctx_with_stutter = Map.put(adapter_context, :stutter, stutter_ctx)

        # Execute retry
        case adapter.execute(resolved_command, ctx_with_stutter) do
          {:ok, retry_events} ->
            {:ok, attempt, retry_events}

          {:error, reason} ->
            {:error, attempt, reason}
        end
      end)

    # Process retry results and compare
    process_stutter_results(
      retry_results,
      original_events,
      resolved_command,
      index,
      event_log,
      stutter_config,
      branch_id
    )
  end

  defp process_stutter_results(
         retry_results,
         original_events,
         command,
         index,
         event_log,
         stutter_config,
         branch_id
       ) do
    # Check for execution errors
    case Enum.find(retry_results, &match?({:error, _, _}, &1)) do
      {:error, attempt, reason} ->
        {:error, :stutter_execution_failed, %{attempt: attempt, reason: reason}}

      nil ->
        # All retries succeeded - compare events
        compare_and_record_stutter_results(
          retry_results,
          original_events,
          command,
          index,
          event_log,
          stutter_config,
          branch_id
        )
    end
  end

  defp compare_and_record_stutter_results(
         retry_results,
         original_events,
         command,
         index,
         event_log,
         stutter_config,
         branch_id
       ) do
    # Compare each retry's events with original
    comparisons =
      Enum.map(retry_results, fn {:ok, attempt, retry_events} ->
        comparison =
          Stutter.compare_events(original_events, retry_events, stutter_config, command)

        {attempt, retry_events, comparison}
      end)

    # Check for any mismatches
    case Enum.find(comparisons, fn {_, _, result} -> result != :match end) do
      {_attempt, _retry_events, {:mismatch, details}} ->
        # Idempotency violation detected
        violation = %Stutter.Violation{
          command: command,
          command_index: index,
          attempts: [
            %{attempt: 1, events: original_events, is_retry: false}
            | Enum.map(retry_results, fn {:ok, att, evts} ->
                %{attempt: att, events: evts, is_retry: true}
              end)
          ],
          comparison_result: details
        }

        {:error, :idempotency_violation, violation}

      nil ->
        # All comparisons matched - record stutter entries (not applied to projections)
        updated_event_log =
          Enum.reduce(comparisons, event_log, fn {attempt, retry_events, comparison}, log ->
            # Record each retry event as a stutter entry
            Enum.reduce(retry_events, log, fn event, inner_log ->
              entry =
                Entry.from_stutter(event, index, attempt, comparison, branch_id: branch_id)

              [entry | inner_log]
            end)
          end)

        {:ok, updated_event_log}
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

      # For each event, check if any @poll_state assertions should be spawned
      new_pollers =
        for event <- events,
            event_module = event.__struct__,
            projection <- all_projections,
            function_exported?(projection, :__assertions__, 0),
            assertion <- projection.__assertions__(),
            assertion.type == :polling,
            Projection.event_matches_poll_trigger?(assertion.poll_state, event_module) do
          # Get current projection state
          projection_state = Map.get(state.projections, projection)

          # Call the assertion function to get the predicate
          predicate = apply(projection, assertion.name, [projection_state, event])

          # Build state getter for the poller
          get_state_fn = fn proj ->
            # This will be updated by the executor as state changes
            Map.get(state.projections, proj)
          end

          # Spawn the poller
          StatePoller.start(
            predicate: predicate,
            predicate_source: assertion.predicate_source,
            projection: projection,
            interval_ms: assertion.poll_state.interval_ms,
            timeout_ms: assertion.poll_state.timeout_ms,
            triggered_by: %{event: event, assertion_name: assertion.name},
            get_state_fn: get_state_fn
          )
        end

      if Enum.empty?(new_pollers) do
        state
      else
        existing_pollers = Map.get(state, :active_pollers, [])
        %{state | active_pollers: existing_pollers ++ new_pollers}
      end
    end
  end

  @doc false
  # Update state getter for all active pollers with new projection state
  defp update_poller_state_getters(state) do
    pollers = Map.get(state, :active_pollers, [])
    projections = state.projections

    for poller <- pollers do
      get_state_fn = fn proj -> Map.get(projections, proj) end
      StatePoller.update_state_getter(poller, get_state_fn)
    end

    state
  end

  @doc false
  # Finalize all active pollers - wait for them to complete or timeout
  # Returns {state, assertion_failures, halt_failure}
  defp finalize_pollers(state) do
    pollers = Map.get(state, :active_pollers, [])
    assertion_mode = Map.get(state, :assertion_mode, :halt)
    assertion_failures = Map.get(state, :assertion_failures, [])

    if Enum.empty?(pollers) do
      {state, assertion_failures, nil}
    else
      # Drain-and-refresh while awaiting: @poll_state predicates read
      # projection state, which only advances as events (from injectors and
      # resource pollers) flow in. A blind await would freeze the projection
      # snapshot, so eventual-consistency predicates could never observe
      # anything happening after the last command. Here we keep draining the
      # event queue into projections and refreshing the pollers' state
      # getters until every poller resolves.
      {results, state} = drain_and_await_pollers(pollers, state)

      # Process results
      {failed_pollers, _succeeded} =
        Enum.split_with(results, fn {_id, result} ->
          case result do
            {:timeout, _, _} -> true
            {:error, _} -> true
            _ -> false
          end
        end)

      # Handle failures based on assertion_mode
      new_failures =
        case assertion_mode do
          :halt ->
            # In halt mode, we don't record - we'll return error
            []

          :record ->
            # Record all poll timeouts
            Enum.map(failed_pollers, fn {_id, result} ->
              timeout_to_failure(result)
            end)

          :log ->
            # Log and continue
            require Logger

            for {_id, result} <- failed_pollers do
              case result do
                {:timeout, _, info} ->
                  Logger.warning(
                    "Poll timeout in #{info.triggered_by.assertion_name}: " <>
                      "#{info.predicate_source}"
                  )

                {:error, reason} ->
                  Logger.warning("Poll error: #{inspect(reason)}")
              end
            end

            []
        end

      # Check if we should halt
      halt_failure =
        if assertion_mode == :halt and not Enum.empty?(failed_pollers) do
          [{_id, first_failure} | _] = failed_pollers
          first_failure
        else
          nil
        end

      updated_state = %{state | active_pollers: []}
      {updated_state, assertion_failures ++ new_failures, halt_failure}
    end
  end

  # Tick interval for the drain-and-refresh loop (ms). Short enough to feed
  # pollers promptly, long enough not to busy-spin.
  @poller_drain_tick_ms 20

  # Await all @poll_state pollers while continuously feeding them: drain the
  # event queue into projections, refresh each poller's state getter, then
  # collect any results that arrived. Returns {results, updated_state} where
  # updated_state carries the events that arrived during the poll window.
  defp drain_and_await_pollers(pollers, state) do
    max_timeout = pollers |> Enum.map(& &1.timeout_ms) |> Enum.max(fn -> 5000 end)
    deadline = System.monotonic_time(:millisecond) + max_timeout + 1000

    drain_await_loop(pollers, [], state, deadline)
  end

  defp drain_await_loop([], results, state, _deadline), do: {results, state}

  defp drain_await_loop(pollers, results, state, deadline) do
    # 1. Drain queue into projections / event log so predicates can observe
    #    events that arrived since the last command
    {projections, event_log} =
      process_injector_events(
        Map.get(state, :event_queue),
        state.event_log,
        state.projections,
        nil
      )

    state = %{state | projections: projections, event_log: event_log}

    # 2. Refresh each poller's getter to read the freshly-updated projections
    update_poller_state_getters(%{state | active_pollers: pollers})

    # 3. Collect a result if one is ready, bounded by the tick (so we drain
    #    again soon) and the overall deadline
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.each(pollers, &StatePoller.stop/1)
      timeout_results = Enum.map(pollers, fn p -> {p.id, {:error, :await_timeout}} end)
      {results ++ timeout_results, state}
    else
      wait = min(@poller_drain_tick_ms, remaining)

      receive do
        {:poller_result, id, result} ->
          case Enum.find(pollers, &(&1.id == id)) do
            nil ->
              drain_await_loop(pollers, results, state, deadline)

            _poller ->
              remaining_pollers = Enum.reject(pollers, &(&1.id == id))
              drain_await_loop(remaining_pollers, [{id, result} | results], state, deadline)
          end
      after
        wait ->
          drain_await_loop(pollers, results, state, deadline)
      end
    end
  end

  @doc false
  # Finalize all active resource pollers - wait for them to complete or timeout/error
  # Returns {state, failures, halt_failure}
  defp finalize_resource_pollers(state) do
    pollers = Map.get(state, :active_resource_pollers, [])
    assertion_mode = Map.get(state, :assertion_mode, :halt)

    if Enum.empty?(pollers) do
      {state, [], nil}
    else
      # Wait for all resource pollers to complete
      results = ResourcePoller.await_all(pollers)

      # Process results - separate successes from failures
      {failed_pollers, _succeeded} =
        Enum.split_with(results, fn {_id, result} ->
          case result do
            {:success, _} -> false
            {:timeout_ignored, _} -> false
            {:error, _, _} -> true
          end
        end)

      # Handle failures based on assertion_mode
      new_failures =
        case assertion_mode do
          :halt ->
            # In halt mode, we don't record - we'll return error
            []

          :record ->
            # Record all resource poller errors
            Enum.map(failed_pollers, fn {_id, result} ->
              resource_poller_result_to_failure(result)
            end)

          :log ->
            # Log and continue
            require Logger

            for {_id, result} <- failed_pollers do
              case result do
                {:error, id, reason} ->
                  message = format_resource_poller_error(reason)
                  Logger.warning("Resource poller #{inspect(id)} error: #{message}")
              end
            end

            []

          :disabled ->
            []
        end

      # Check if we should halt
      halt_failure =
        if assertion_mode == :halt and not Enum.empty?(failed_pollers) do
          [{_id, first_failure} | _] = failed_pollers
          first_failure
        else
          nil
        end

      updated_state = %{state | active_resource_pollers: []}
      {updated_state, new_failures, halt_failure}
    end
  end

  defp resource_poller_result_to_failure({:error, id, reason}) do
    %{
      assertion_name: :resource_poller,
      reason: {:resource_poller_error, reason},
      command: nil,
      command_index: nil,
      step_type: :resource_poll,
      module: nil,
      timestamp: System.monotonic_time(:millisecond),
      resource_poller_id: id
    }
  end

  # Format resource poller errors for logging
  # Uses Exception.message/1 for exceptions, inspect for other terms
  defp format_resource_poller_error({:poll_fn_error, exception, _stacktrace}) do
    "poll_fn raised: #{Exception.message(exception)}"
  end

  defp format_resource_poller_error({:handler_error, exception, _stacktrace}) do
    "handler raised: #{Exception.message(exception)}"
  end

  defp format_resource_poller_error({:on_timeout_error, exception, _stacktrace}) do
    "on_timeout raised: #{Exception.message(exception)}"
  end

  defp format_resource_poller_error({:timeout, info}) do
    "timeout after #{info.elapsed_ms}ms (#{info.poll_count} polls)"
  end

  defp format_resource_poller_error(%{__exception__: true} = exception) do
    Exception.message(exception)
  end

  defp format_resource_poller_error(reason) do
    inspect(reason)
  end

  defp timeout_to_failure({:timeout, _id, info}) do
    %{
      assertion_name: info.triggered_by.assertion_name,
      reason: {:poll_timeout, info},
      command: nil,
      command_index: nil,
      step_type: :event,
      module: info.triggered_by.event.__struct__,
      timestamp: System.monotonic_time(:millisecond),
      poll_timeout_info: info
    }
  end

  defp timeout_to_failure({:error, reason}) do
    %{
      assertion_name: :unknown,
      reason: {:poll_error, reason},
      command: nil,
      command_index: nil,
      step_type: :event,
      module: nil,
      timestamp: System.monotonic_time(:millisecond)
    }
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
    - `:refs` - Initial ref resolution map (default: %{})
    - `:event_queue` - EventQueue pid for injector events (optional)

  ## Returns

  - `{:ok, event_log}` - List of EventLog.Entry structs
  - `{:error, {:adapter_error, reason, partial_events}}` - Adapter failed

  ## Example

      {:ok, adapter_ctx} = MyAdapter.setup(%{})
      {:ok, event_queue} = EventQueue.start_link()

      context = %{
        adapter_context: adapter_ctx,
        refs: %{},
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
    refs = Map.get(context, :refs, %{})
    event_queue = Map.get(context, :event_queue)

    initial_state = %{
      events: [],
      refs: refs
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
               state.refs
             ) do
          {:ok, new_events, new_refs} ->
            {:cont, %{events: state.events ++ new_events, refs: new_refs}}

          {:error, reason} ->
            {:halt, {:error, {:adapter_error, reason, state.events}}}
        end
      end)

    case result do
      {:error, _} = error -> error
      %{events: events} -> {:ok, events}
    end
  end

  # Execute a single command in raw mode (no projections/assertions)
  defp execute_raw_command(command, index, adapter, adapter_context, event_queue, refs) do
    # Resolve refs in command (only for structs that might have refs)
    resolved_result =
      if is_struct(command) do
        resolve_command_refs(command, refs)
      else
        # Plain maps don't use refs in raw mode
        {:ok, command}
      end

    case resolved_result do
      {:ok, resolved_command} ->
        # Merge event_queue into adapter_context so adapters can access it
        execute_context =
          if event_queue do
            Map.put(adapter_context, :event_queue, event_queue)
          else
            adapter_context
          end

        # Execute via adapter
        case adapter.execute(resolved_command, execute_context) do
          {:ok, events} ->
            # Bind new ref if command creates one (only for structs)
            new_refs =
              if is_struct(command) do
                maybe_bind_ref(command, events, refs)
              else
                refs
              end

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

            {:ok, entries ++ injector_entries, new_refs}

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
  # Similar to resolve_command_refs but for the new placeholder system.
  defp resolve_command_placeholders(command, registry) do
    try do
      resolved = deep_resolve_placeholders(command, registry)
      {:ok, resolved}
    rescue
      e in ArgumentError ->
        stacktrace = __STACKTRACE__
        {:error, {e.message, stacktrace}}
    end
  end

  defp deep_resolve_placeholders(%Placeholder{} = p, registry) do
    case PlaceholderRegistry.get(registry, p.id) do
      nil ->
        raise ArgumentError, "Unknown placeholder: #{inspect(p)}"

      %{resolved: nil} = placeholder ->
        raise ArgumentError,
              "Unresolved placeholder at #{inspect(placeholder.path)} " <>
                "(command #{placeholder.command_index}, event #{placeholder.event_index})"

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
  defp capture_externals(_events, nil, registry), do: registry

  defp capture_externals(events, position, registry) do
    registry
    |> PlaceholderRegistry.ids_at_position(position)
    |> Enum.reduce(registry, fn id, reg ->
      case PlaceholderRegistry.get(reg, id) do
        %Placeholder{path: path, event_index: event_index} ->
          case Enum.at(events, event_index) do
            event when is_struct(event) ->
              PlaceholderRegistry.resolve(reg, id, External.get_at_path(event, path))

            _ ->
              reg
          end

        _ ->
          reg
      end
    end)
  end
end
