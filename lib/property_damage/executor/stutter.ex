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
  #
  # Stutter draws come from an explicit RNG (DR-029): a fresh generator state
  # derived per command from `{state.rng_seed, index}`. Keying on the command's
  # index (not an advancing run-global stream) makes the draws index-local, so
  # shrink truncation that removes earlier commands does not perturb a surviving
  # command's stutter decisions.

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.Executor
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
    rng = stutter_rng(Map.get(state, :rng_seed), index)

    # The resolved command spec carries the static stutter metadata (DR-028):
    # `:idempotent` eligibility and `:acceptable_retry_events`. nil for plain-map
    # / spec-less commands, where the policy falls back to its defaults.
    spec =
      if is_struct(command) do
        Map.get(Map.get(state, :command_specs, %{}), command.__struct__)
      end

    {do_stutter?, rng} = Stutter.should_stutter?(command, stutter_config, rng, spec)

    if do_stutter? do
      execute_stutter_retries(
        resolved_command,
        original_events,
        index,
        event_log,
        stutter_config,
        adapter,
        adapter_context,
        state.branch_id,
        rng,
        spec
      )
    else
      {:ok, event_log}
    end
  end

  # Derive the per-command stutter RNG from the run seed and the command index.
  # phash2 folds the pair into a deterministic seed integer; a nil rng_seed
  # (stepping shell / direct executor callers that pass no seed) collapses to a
  # fixed base so draws stay deterministic.
  defp stutter_rng(rng_seed, index) do
    :rand.seed_s(:exsss, :erlang.phash2({rng_seed || 0, index}, 4_294_967_296))
  end

  defp execute_stutter_retries(
         resolved_command,
         original_events,
         index,
         event_log,
         stutter_config,
         adapter,
         adapter_context,
         branch_id,
         rng,
         spec
       ) do
    {retry_count, rng} = Stutter.retry_count(stutter_config, rng)
    idempotency_key = Stutter.get_idempotency_key(resolved_command)

    # Execute retries, threading the RNG through each retry's delay draw.
    {retry_results, _rng} =
      Enum.map_reduce(2..(retry_count + 1), rng, fn attempt, rng ->
        # Add delay between retries
        {delay_ms, rng} = Stutter.retry_delay_ms(stutter_config, rng)

        if delay_ms > 0 do
          Process.sleep(delay_ms)
        end

        # Build stutter context and a Runtime carrying it (DR-027). Stutter
        # retries run after the per-command injection window has closed, so
        # inject/start_poller raise if an adapter reaches for them here.
        stutter_ctx = Stutter.build_context(attempt, true, idempotency_key)
        runtime = Executor.inject_unavailable_runtime("during stutter retries", stutter_ctx)

        # Execute retry
        result =
          case adapter.execute(resolved_command, adapter_context, runtime) do
            {:ok, retry_events} ->
              {:ok, attempt, retry_events}

            {:error, reason} ->
              {:error, attempt, reason}
          end

        {result, rng}
      end)

    # Process retry results and compare
    process_stutter_results(
      retry_results,
      original_events,
      resolved_command,
      index,
      event_log,
      stutter_config,
      branch_id,
      spec
    )
  end

  defp process_stutter_results(
         retry_results,
         original_events,
         command,
         index,
         event_log,
         stutter_config,
         branch_id,
         spec
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
          branch_id,
          spec
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
         branch_id,
         spec
       ) do
    # Compare each retry's events with original
    comparisons =
      Enum.map(retry_results, fn {:ok, attempt, retry_events} ->
        comparison =
          Stutter.compare_events(original_events, retry_events, stutter_config, spec)

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
