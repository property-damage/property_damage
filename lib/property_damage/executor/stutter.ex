defmodule PropertyDamage.Executor.Stutter do
  @moduledoc false
  # Stutter (idempotency testing) execution for the executor (DR-029).
  #
  # Owns the per-command stutter-retry runner: after a command's first execution
  # succeeds, re-run it `retry_count` times with a stutter Runtime and compare the
  # events against the original to detect idempotency violations. The pure stutter
  # policy (should_stutter?/retry_count/compare_events/Config/Violation) lives in
  # PropertyDamage.Stutter; this module is the execution glue (it drives
  # adapter.execute/3, records stutter entries, and reports violations).
  #
  # `inject_unavailable_runtime/2` is shared with Executor.execute_raw/3 and stays
  # in PropertyDamage.Executor; it is called back here (stutter retries run after
  # the per-command injection window has closed).

  alias PropertyDamage.Executor
  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.Stutter

  @doc false
  # Execute stutter retries after successful first execution
  # Returns {:ok, event_log} or {:error, :idempotency_violation, details}
  def maybe_execute_stutter_retries(
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

        # Build stutter context and a Runtime carrying it (DR-027). Stutter
        # retries run after the per-command injection window has closed, so
        # inject/start_poller raise if an adapter reaches for them here.
        stutter_ctx = Stutter.build_context(attempt, true, idempotency_key)
        runtime = Executor.inject_unavailable_runtime("during stutter retries", stutter_ctx)

        # Execute retry
        case adapter.execute(resolved_command, adapter_context, runtime) do
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
end
