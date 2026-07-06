defmodule PropertyDamage.Executor.Finalization do
  @moduledoc false
  # Run-result finalization for the executor (DR-029).
  #
  # Owns the finalize chain that runs after the last command of a (linear or
  # merged-branch) run, in order:
  #
  #   finalize_pollers (@poll_state drain + async checks)
  #     -> finalize_resource_pollers
  #     -> settle_event_queue (drain queued injector/poller events + async checks)
  #     -> finalize_after_settle
  #     -> Executor.run_phase_assertions(:teardown)
  #
  # and the strict precedence among competing finalize-time failures (locked by
  # test/property_damage/executor/finalize_ordering_test.exs):
  #
  #   async-halt(drain) > poll-timeout > settle-halt > resource-error > teardown
  #
  # Each clause takes a %PropertyDamage.Executor.State{} and returns either the
  # run-result map or the rich tagged tuple its job needs (finalize keeps its
  # five-outcome return including the async-halt command_index precedence and the
  # :record accumulator). Shared helpers that the live command path also uses
  # (run_phase_assertions, check_async, process_injector_events,
  # update_poller_state_getters) remain in PropertyDamage.Executor and are called
  # back here; this module owns only the finalize-exclusive logic.

  alias PropertyDamage.{Executor, Failure, ResourcePoller, StatePoller}

  # ============================================================================
  # Result Finalization
  # ============================================================================

  def finalize_result(result, linearization \\ nil)

  def finalize_result({:failed, index, reason, state}, linearization) do
    # Stop any active pollers when we fail early
    pollers = Map.get(state, :active_pollers, [])
    Enum.each(pollers, &StatePoller.stop/1)

    # Stop any active resource pollers when we fail early
    resource_pollers = Map.get(state, :active_resource_pollers, [])
    Enum.each(resource_pollers, &ResourcePoller.stop/1)

    assertion_failures = Map.get(state, :assertion_failures, [])

    # Extract stacktrace from failure reason if embedded
    {normalized_reason, stacktrace} = extract_stacktrace(reason)

    # DR-025: a failing state may carry an attributed index (the offending async
    # event's command_index) that differs from the loop `index` of the command
    # that was executing when the assertion tripped. Honor it so the report names
    # the right command; `:unset` means no override.
    failed_at_index =
      case Map.get(state, :async_failed_index, :unset) do
        :unset -> index
        attributed -> attributed
      end

    %{
      success: false,
      event_log: Enum.reverse(state.event_log),
      executed: state.executed,
      projections: state.projections,
      projections_before: state.projections_before,
      failed_at_index: failed_at_index,
      failure_reason: normalized_reason,
      stacktrace: stacktrace,
      linearization: linearization,
      assertion_failures: assertion_failures,
      assertion_counters: Map.get(state, :assertion_counters, %{}),
      command_fold_ordinals: Map.get(state, :command_fold_ordinals, %{})
    }
  end

  def finalize_result(state, linearization) do
    # Finalize all active state pollers - wait for them to complete. The drain
    # also evaluates async @trigger every: assertions on events that arrive
    # during the @poll_state await window (DR-025); a :halt violation there is
    # surfaced as state.async_halt.
    {state, assertion_failures, halt_failure} = finalize_pollers(state)

    case Map.get(state, :async_halt) do
      # DR-025: an async every: assertion tripped during the @poll_state await
      # drain under :halt mode. Report it at the observing event's command_index,
      # ahead of any poll timeout (a more proximate, more actionable failure).
      {name, reason, command_index} ->
        resource_pollers = Map.get(state, :active_resource_pollers, [])
        Enum.each(resource_pollers, &ResourcePoller.stop/1)
        {normalized, stacktrace} = extract_stacktrace(Failure.assertion_failed(name, reason))

        async_failure_result(
          state,
          normalized,
          stacktrace,
          command_index,
          linearization,
          Enum.reverse(assertion_failures)
        )

      nil ->
        finalize_after_pollers(state, assertion_failures, halt_failure, linearization)
    end
  end

  defp finalize_after_pollers(state, assertion_failures, halt_failure, linearization) do
    # Check if any state poller halted the run in :halt mode. Both timeouts
    # and errors are halt-worthy; the error case previously fell through and
    # was reported as success.
    case halt_failure do
      {:timeout, _id, info} ->
        resource_pollers = Map.get(state, :active_resource_pollers, [])
        Enum.each(resource_pollers, &ResourcePoller.stop/1)

        poller_failure_result(
          state,
          Failure.poll_timeout(info),
          linearization,
          assertion_failures
        )

      {:error, reason} ->
        resource_pollers = Map.get(state, :active_resource_pollers, [])
        Enum.each(resource_pollers, &ResourcePoller.stop/1)

        poller_failure_result(
          state,
          Failure.poll_error(reason),
          linearization,
          assertion_failures
        )

      _ ->
        # Finalize resource pollers
        {state, resource_failures, resource_halt} = finalize_resource_pollers(state)

        # Fold any remaining queued events into the projections so the settled
        # state is complete (DR-024), evaluating async `@trigger every:`
        # assertions on each as it is folded (DR-025). When @poll_state pollers
        # ran, drain_await_loop already folded events as they arrived; this final
        # drain catches the last resource-poller emissions and also covers runs
        # that have resource pollers but no @poll_state poller to drive a drain.
        # `assertion_failures` carries the run's :record failures so far (newest
        # first); the async check prepends any it records.
        case settle_event_queue(state, assertion_failures) do
          # DR-025: an async every: assertion tripped on a drained event under
          # :halt mode — report it at the observing event's command_index.
          {:halt, name, reason, command_index, state, failures} ->
            {normalized, stacktrace} = extract_stacktrace(Failure.assertion_failed(name, reason))
            combined_failures = Enum.reverse(failures) ++ resource_failures

            async_failure_result(
              state,
              normalized,
              stacktrace,
              command_index,
              linearization,
              combined_failures
            )

          {:ok, state, failures} ->
            finalize_after_settle(
              state,
              failures,
              resource_failures,
              resource_halt,
              linearization
            )
        end
    end
  end

  # The clean-completion tail after the settle drain (DR-024 teardown checkpoint
  # path). Split out so the DR-025 async-halt branch in settle can short-circuit.
  # `failures` is the run's accumulated :record failures (newest first).
  defp finalize_after_settle(state, failures, resource_failures, resource_halt, linearization) do
    # Reverse so they read in chronological order, like the event log.
    combined_failures = Enum.reverse(failures) ++ resource_failures

    # Check if any resource poller failed in :halt mode
    case resource_halt do
      {:error, _id, reason} ->
        poller_failure_result(
          state,
          Failure.resource_poller_error(reason),
          linearization,
          combined_failures
        )

      _ ->
        # DR-024: the @trigger at: :teardown checkpoint runs here, on the
        # fully-settled state (after both poller-finalize steps), on the
        # clean-completion path only and before Adapter.teardown/1. A genuine
        # @poll_state liveness timeout has already preempted it above (no
        # hoist): a liveness timeout is itself a not-settled outcome, so
        # there is no settled state to check.
        case Executor.run_phase_assertions(state, :teardown) do
          {:halt, name, reason, teardown_counters} ->
            {normalized, stacktrace} =
              extract_stacktrace(Failure.assertion_failed(name, reason))

            teardown_failure_result(
              %{state | assertion_counters: teardown_counters},
              normalized,
              stacktrace,
              linearization,
              combined_failures
            )

          {:ok, teardown_recorded, teardown_counters} ->
            # teardown_recorded is newest-first and chronologically last;
            # reverse to chronological order and append after everything else.
            all_failures = combined_failures ++ Enum.reverse(teardown_recorded)

            # In :record mode, success is false if any failures were recorded.
            success = Enum.empty?(all_failures)

            %{
              success: success,
              event_log: Enum.reverse(state.event_log),
              executed: state.executed,
              projections: state.projections,
              projections_before: Map.get(state, :projections_before),
              failed_at_index: nil,
              failure_reason: nil,
              stacktrace: nil,
              linearization: linearization,
              assertion_failures: all_failures,
              assertion_counters: teardown_counters,
              command_fold_ordinals: Map.get(state, :command_fold_ordinals, %{})
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
      executed: state.executed,
      projections: state.projections,
      projections_before: Map.get(state, :projections_before),
      # DR-030: a @poll_state liveness timeout reports at the command whose event
      # opened the window (nil for poll errors / resource pollers / older info).
      failed_at_index: poller_failure_index(failure_reason),
      failure_reason: failure_reason,
      stacktrace: nil,
      linearization: linearization,
      assertion_failures: failures,
      assertion_counters: Map.get(state, :assertion_counters, %{}),
      command_fold_ordinals: Map.get(state, :command_fold_ordinals, %{})
    }
  end

  defp poller_failure_index(%Failure{
         type: %Failure.Assertion{kind: :poll_timeout, detail: info}
       }),
       do: Map.get(info.triggered_by, :command_index)

  defp poller_failure_index(_), do: nil

  # Result shape for a failing @trigger at: :teardown safety check (DR-024).
  # Like poller_failure_result but carries the assertion's named failure reason
  # and its stacktrace, so it reports as a synchronous assertion failure on the
  # settled state (failed_at_index nil — no command failed), distinct from a
  # poll timeout. Adapter.teardown/1 still runs afterward (it is owned by run/4's
  # `after` block), so a failing safety check never leaks SUT resources.
  defp teardown_failure_result(state, failure_reason, stacktrace, linearization, failures) do
    %{
      success: false,
      event_log: Enum.reverse(state.event_log),
      executed: state.executed,
      projections: state.projections,
      projections_before: Map.get(state, :projections_before),
      failed_at_index: nil,
      failure_reason: failure_reason,
      stacktrace: stacktrace,
      linearization: linearization,
      assertion_failures: failures,
      assertion_counters: Map.get(state, :assertion_counters, %{}),
      command_fold_ordinals: Map.get(state, :command_fold_ordinals, %{})
    }
  end

  # Result for a failing `@trigger every:` assertion observed asynchronously
  # during a finalize-time drain (DR-025). Like teardown_failure_result, but
  # carries the observing event's `command_index` as `failed_at_index` so the
  # shrinker can truncate to the command that caused it (nil for a pure injector
  # event, which the shrinker tolerates by falling back to its sequence search).
  defp async_failure_result(
         state,
         failure_reason,
         stacktrace,
         command_index,
         linearization,
         failures
       ) do
    %{
      success: false,
      event_log: Enum.reverse(state.event_log),
      executed: state.executed,
      projections: state.projections,
      projections_before: Map.get(state, :projections_before),
      failed_at_index: command_index,
      failure_reason: failure_reason,
      stacktrace: stacktrace,
      linearization: linearization,
      assertion_failures: failures,
      assertion_counters: Map.get(state, :assertion_counters, %{}),
      command_fold_ordinals: Map.get(state, :command_fold_ordinals, %{})
    }
  end

  # ============================================================================
  # Stacktrace Extraction
  # ============================================================================

  # Split an embedded {exception, stacktrace} out of a %Failure{}'s detail,
  # returning the failure with a bare-exception (or bare-message) detail plus the
  # separated stacktrace. The envelope's `branch_id` rides along untouched, so a
  # branch failure is normalized by the same clauses as a linear one.
  defp extract_stacktrace(
         %Failure{
           type: %Failure.Execution{kind: :adapter_error, detail: {exception, stacktrace}} = t
         } =
           f
       )
       when is_exception(exception) and is_list(stacktrace) do
    {%{f | type: %{t | detail: exception}}, stacktrace}
  end

  defp extract_stacktrace(
         %Failure{
           type: %Failure.Assertion{kind: :assertion_failed, detail: {exception, stacktrace}} = t
         } = f
       )
       when is_exception(exception) and is_list(stacktrace) do
    {%{f | type: %{t | detail: exception}}, stacktrace}
  end

  defp extract_stacktrace(
         %Failure{
           type:
             %Failure.Framework{kind: :placeholder_resolution, detail: {message, stacktrace}} = t
         } = f
       )
       when is_binary(message) and is_list(stacktrace) do
    {%{f | type: %{t | detail: message}}, stacktrace}
  end

  # No embedded stacktrace
  defp extract_stacktrace(reason), do: {reason, nil}

  # ============================================================================
  # Settle Drain
  # ============================================================================

  # Drain any events still queued (typically late resource-poller emissions
  # that arrived after the last command) into the projections and event log, so
  # the settled state used by the @trigger at: :teardown checkpoint and the
  # reported result reflects every observed event (DR-024). A no-op when the
  # queue is absent or empty.
  # Threads the run's accumulated :record `failures` (newest-first) through the
  # async check. Returns {:ok, state, failures} on a clean drain, or
  # {:halt, name, reason, command_index, state, failures} when an async
  # `@trigger every:` assertion fails under :halt mode on a drained event
  # (DR-025). In :record/:log/:disabled modes it never halts; any :record
  # failures are prepended onto `failures`.
  defp settle_event_queue(state, failures) do
    projs_before = state.projections
    log_before = state.event_log
    mode = Map.get(state, :assertion_mode, :halt)

    {projections, event_log, fold_counter} =
      Executor.Events.process_injector_events(
        Map.get(state, :event_queue),
        log_before,
        projs_before,
        Map.get(state, :branch_id),
        Map.get(state, :fold_counter, 0),
        Map.get(state, :await_matchers, [])
      )

    state = %{state | projections: projections, event_log: event_log, fold_counter: fold_counter}

    case Executor.check_async(
           Map.fetch!(state, :model),
           projs_before,
           log_before,
           event_log,
           state.assertion_counters,
           mode,
           failures
         ) do
      {:ok, counters, failures} ->
        {:ok, %{state | assertion_counters: counters}, failures}

      {:halt, name, reason, command_index, counters} ->
        {:halt, name, reason, command_index, %{state | assertion_counters: counters}, failures}
    end
  end

  # ============================================================================
  # Poller Finalization
  # ============================================================================

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
      # Use the post-drain failures so async @trigger every: violations recorded
      # during the await drain (DR-025, :record mode) are not dropped. Equal to
      # the pre-drain `assertion_failures` when the drain recorded nothing.
      {updated_state, Map.get(updated_state, :assertion_failures, []) ++ new_failures,
       halt_failure}
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
    #    events that arrived since the last command, asserting @trigger every:
    #    assertions on each event as it folds (DR-025).
    projs_before = state.projections
    log_before = state.event_log
    mode = Map.get(state, :assertion_mode, :halt)

    {projections, event_log, fold_counter} =
      Executor.Events.process_injector_events(
        Map.get(state, :event_queue),
        log_before,
        projs_before,
        nil,
        Map.get(state, :fold_counter, 0),
        Map.get(state, :await_matchers, [])
      )

    case Executor.check_async(
           Map.fetch!(state, :model),
           projs_before,
           log_before,
           event_log,
           state.assertion_counters,
           mode,
           Map.get(state, :assertion_failures, [])
         ) do
      # DR-025: an async every: assertion tripped during the await window under
      # :halt mode. Stop pollers and surface via :async_halt (checked in
      # finalize_result, ahead of any poll timeout).
      {:halt, name, reason, idx, counters} ->
        Enum.each(pollers, &StatePoller.stop/1)

        halted_state = %{
          state
          | projections: projections,
            event_log: event_log,
            assertion_counters: counters,
            async_halt: {name, reason, idx},
            fold_counter: fold_counter
        }

        {results, halted_state}

      {:ok, counters, failures} ->
        state = %{
          state
          | projections: projections,
            event_log: event_log,
            assertion_counters: counters,
            assertion_failures: failures,
            fold_counter: fold_counter
        }

        # 2. Refresh each poller's getter to read the freshly-updated projections
        Executor.update_poller_state_getters(%{state | active_pollers: pollers})

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
  end

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
      reason: Failure.resource_poller_error(reason),
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
      reason: Failure.poll_timeout(info),
      command: nil,
      # DR-030: attribute the liveness timeout to the command whose event opened
      # the @poll_state window, so the shrinker keeps locality (nil for older
      # poll info that predates command_index threading).
      command_index: Map.get(info.triggered_by, :command_index),
      step_type: :event,
      module: info.triggered_by.event.__struct__,
      timestamp: System.monotonic_time(:millisecond),
      poll_timeout_info: info
    }
  end

  defp timeout_to_failure({:error, reason}) do
    %{
      assertion_name: :unknown,
      reason: Failure.poll_error(reason),
      command: nil,
      command_index: nil,
      step_type: :event,
      module: nil,
      timestamp: System.monotonic_time(:millisecond)
    }
  end
end
