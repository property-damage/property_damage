defmodule PropertyDamage.Executor.Step do
  @moduledoc """
  The step primitives every executor path builds on: one command executed
  against the System Under Test, and the checks, pollers and placeholders
  around it.

  `PropertyDamage.Executor.Stepping` composes these primitives into a step;
  `PropertyDamage.Executor`, `PropertyDamage.Variant` and the executor's
  finalization and stutter modules call them too. This module calls none of
  the executor modules back, so it is the leaf they depend on.

  Every function takes the executor state (`PropertyDamage.Executor.State`)
  and, where it needs the run's model, adapter or event queue, a
  `PropertyDamage.Executor.Stepping.Context`. Anything else a call needs goes
  in one keyword of options.

  The primitives:

    * `new_state/2` builds the state a run threads through its steps.
    * `execute/4` runs one command: the mocks are told of it, its
      placeholders resolve, the adapter executes it inside an injection
      window, its events and the queued injector and mock events fold into
      the projections, and the checks the step triggers run. Stutter retries
      and `@eventually` pollers come after it (`spawn_pollers/4`).
    * `check_async/2` runs `@check every:` checks on events folded outside a
      command's own answer (DR-025).
    * `run_startup_checks/1` and `run_phase_checks/2` run the
      `@check at:` checks of a lifecycle phase (DR-024).
    * `refresh_pollers/1` hands running `@eventually` pollers the current
      projections.
    * `resolve_placeholders/3` swaps placeholders and mint markers in a
      command for their values (DR-021, DR-034).
    * `unavailable_runtime/2` builds a runtime handle for a path with no
      injection window.
    * `mock_events_failure/1` names the failure of a mock event that could not
      be folded.
    * `teardown_adapter/1` calls the adapter's `teardown/1`, best-effort.
  """

  alias PropertyDamage.{
    Failure,
    PlaceholderRegistry,
    ResourcePoller,
    Runtime,
    StatePoller,
    Verdict
  }

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.Executor.{Events, Settle, State, StepObserver}
  alias PropertyDamage.Log.Cap
  alias PropertyDamage.Model.Projection
  alias PropertyDamage.Model.Projection.Checks

  @typedoc "What the adapter answered for one command (see `PropertyDamage.Executor.Stepping`)."
  @type outcome ::
          {:ok, [struct()]} | {:error, term()} | {:raised, Exception.t()} | :not_called

  # ============================================================================
  # State
  # ============================================================================

  @doc """
  Builds a fresh executor state for `model`.

  Options:

    * `:event_queue` - the async/injected event queue (default `nil`)
    * `:stutter_config` - stutter/idempotency configuration (default `nil`)
    * `:step_observer` - the step observer, `{module, observer}`
      (`PropertyDamage.Executor.StepObserver`); default `nil`, none
    * `:check_mode` - `:halt` | `:record` | `:log` | `:disabled` (default `:halt`)
    * `:external_markers` - external value markers (default `[]`)
    * `:placeholder_registry` - registry seeded from the generated sequence
      (DR-021); a new empty registry when absent
    * `:rng_seed` - explicit stutter RNG base (DR-029)
    * `:run_nonce` - run nonce seeding `mint_per_run` resolution (DR-034)
    * `:mint_epoch` - SUT-execution epoch for minted values (DR-034, default 0)
    * `:on_resource_poller_start` - called with each resource poller's pid as
      soon as an adapter starts it (default `nil`)
    * `:telemetry` - the context command and check telemetry is emitted with
      (default `nil`, which emits none)
    * `:keep_attempts` - how many of a step's last settle or stutter attempts
      keep their log lines, besides the first attempt's (default 3, DR-054)
  """
  @spec new_state(module(), keyword()) :: State.t()
  def new_state(model, opts \\ []) do
    %State{
      event_log: [],
      projections: init_projections(model),
      projections_before: nil,
      # Explicit stutter RNG base (DR-029); the per-command generator is derived
      # from {rng_seed, index} in PropertyDamage.Executor.Stutter.
      rng_seed: Keyword.get(opts, :rng_seed),
      # Client-minted run-scoped value inputs (DR-034); consulted only when a
      # command carries a mint_per_run marker.
      run_nonce: Keyword.get(opts, :run_nonce),
      mint_epoch: Keyword.get(opts, :mint_epoch, 0),
      # Seed the placeholder registry from the generated sequence (DR-021); the
      # id-indexed registry + producer_link transport from generation to here.
      placeholder_registry: Keyword.get(opts, :placeholder_registry) || PlaceholderRegistry.new(),
      # Structured position of the command currently executing (DR-021); set by
      # the dispatch loops so external capture keys on position, not a flat index.
      current_position: nil,
      step_count: 0,
      check_counters: %{step: 0, command: 0, event: 0},
      check_failures: [],
      check_mode: Keyword.get(opts, :check_mode, :halt),
      stutter_config: Keyword.get(opts, :stutter_config),
      step_observer: Keyword.get(opts, :step_observer),
      active_pollers: [],
      active_resource_pollers: [],
      model: model,
      external_markers: Keyword.get(opts, :external_markers, []),
      event_queue: Keyword.get(opts, :event_queue),
      command_specs: PropertyDamage.Model.spec_table(model),
      telemetry: Keyword.get(opts, :telemetry),
      on_resource_poller_start: Keyword.get(opts, :on_resource_poller_start),
      keep_attempts: Keyword.get(opts, :keep_attempts, Cap.default_keep_attempts())
    }
  end

  defp init_projections(model) do
    for projection <- PropertyDamage.Model.projection_modules(model), into: %{} do
      {projection, projection.init()}
    end
  end

  # Apply updates onto the existing %State{}, preserving every field not being
  # changed. Uses struct!/2 so a write to an undeclared field raises rather
  # than producing a corrupt struct-shaped map (DR-029).
  defp put_state(%State{} = state, updates), do: struct!(state, updates)

  # ============================================================================
  # Command execution
  # ============================================================================

  @doc """
  Executes `command` at `index` against `state`, the caller having set the
  state's `current_position` and `projections_before`.

  `index` is the root's index, or `{:setup, offset}` for a setup command.
  The mocks are told of the command first; its placeholders resolve; the
  adapter executes it through settle inside an injection window; its events,
  then the queued injector events, then the events the mocks pushed fold into
  the projections; `@check every:` checks run on the queued and mock events
  as each folds, then on the command and its own events.

  Returns `{:ok, state, outcome}` or `{:error, %PropertyDamage.Failure{},
  failed_state, outcome}`. Stutter retries and `@eventually` pollers are the
  caller's next steps (the stutter module, then `spawn_pollers/4`).
  """
  @spec execute(struct() | map(), term(), State.t(), map()) ::
          {:ok, State.t(), outcome()} | {:error, Failure.t(), State.t(), outcome()}
  def execute(command, index, state, ctx) do
    # Only a command that reaches the adapter's execute/3 records a time.
    state = %{state | last_execute_us: nil, last_command_index: index}

    # An observer that refused the command (a mock's on_command/2 that
    # raised) fails the step before the adapter is called, as an adapter error whose detail names the mock and the
    # callback, the shape a raising execute/3 gets.
    case notify_observer(state, command) do
      {:ok, state} -> execute_notified(command, index, state, ctx)
      {:error, reason, state} -> {:error, Failure.adapter_error(reason), state, :not_called}
    end
  end

  # The step observer hears of the command under a scope of its own; its lines
  # go under the command's step (DR-054). For the mocks, a callback that
  # raised, exited or threw comes back as the registry's
  # `{:error, {module, :on_command, reason}}`.
  defp notify_observer(%{step_observer: nil} = state, _command), do: {:ok, state}

  defp notify_observer(state, command) do
    {notified, lines} =
      PropertyDamage.Log.collect(fn sink ->
        StepObserver.before_command(
          state.step_observer,
          command,
          PropertyDamage.Log.writer(sink, 1)
        )
      end)

    state = %{state | logs: PropertyDamage.Log.append(state.logs, state.current_position, lines)}

    case notified do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp execute_notified(command, index, state, ctx) do
    # Resolve placeholders and mint markers in the command (DR-021/DR-034).
    case resolve_placeholders(command, state.placeholder_registry,
           run_nonce: state.run_nonce,
           mint_epoch: state.mint_epoch
         ) do
      {:ok, resolved} ->
        call_adapter(%{command: command, resolved: resolved, index: index}, state, ctx)

      {:error, reason} ->
        {:error, Failure.placeholder_resolution(reason), state, :not_called}
    end
  end

  # The adapter call inside the per-command injection window (DR-027), then
  # the outcome. `step` holds the command, its resolved form and its index.
  defp call_adapter(step, state, ctx) do
    %{command: command, resolved: resolved_command, index: index} = step

    # The window's initial context: an inject folds projections into it.
    initial_ctx = %{
      projections: state.projections,
      event_log: state.event_log,
      injected_events: [],
      command_index: index,
      command: command,
      # DR-040: seed the fold counter so injected events folded during
      # adapter execution take real fold ordinals ahead of the command fold.
      fold_counter: state.fold_counter
    }

    build_runtime = runtime_builder(index, state, ctx)

    # The resolved command spec drives settle; commands may be plain maps in
    # low-level/test usage.
    command_spec = PropertyDamage.Model.spec_for(state.command_specs, command)

    # The adapter's wall-clock, every settle attempt and the waits between
    # them included, is timed here and nothing after it answered.
    # Each settle attempt gets the runtime with its own attempt number on
    # the lines it logs (DR-054), all written into the one sink.
    execute_fn = fn runtime, sink ->
      started = System.monotonic_time(:microsecond)

      runtime_for = fn attempt ->
        %{runtime | log: PropertyDamage.Log.writer(sink, attempt)}
      end

      result =
        try do
          Settle.execute_with_settle(
            resolved_command,
            ctx.adapter,
            ctx.adapter_context,
            runtime_for,
            command_spec
          )
        rescue
          # A raise outside the adapter's Task (for example in its timeout/1)
          # is tagged like one inside it.
          e -> {:raised, e, __STACKTRACE__}
        end

      {result, System.monotonic_time(:microsecond) - started}
    end

    # The window drains the accumulated injection context, any resource
    # pollers started during execution and the log lines written, then
    # stops the sink (even if the adapter raises). The lines move under
    # the command's position on every outcome path below (DR-054).
    {{result, execute_us}, final_injection_ctx, started_resource_pollers, lines} =
      Runtime.InjectionWindow.run_logged(
        initial_ctx,
        build_runtime,
        execute_fn,
        keep_attempts: state.keep_attempts
      )

    started_resource_pollers = drop_timed_out_pollers(result, started_resource_pollers)

    state = %{
      state
      | last_execute_us: execute_us,
        logs: PropertyDamage.Log.append(state.logs, state.current_position, lines)
    }

    # Pollers started during this command's execution must be tracked even on
    # the failure branches below, so finalization can stop them at run end;
    # otherwise an adapter that starts a poller and then errors leaks it.
    state_with_pollers = %{
      state
      | active_resource_pollers: state.active_resource_pollers ++ started_resource_pollers,
        # The command was resolved and sent to the adapter even on these
        # error arms, so record it by position (DR-033) like the success path.
        executed: Map.put(state.executed, state.current_position, resolved_command)
    }

    # The inputs of the post-events pipeline. The injection context already
    # has the injected events applied, so it is the base of the fold.
    event_ctx = %{
      state: state,
      command: command,
      resolved_command: resolved_command,
      index: index,
      injected_events: final_injection_ctx.injected_events,
      base_projections: final_injection_ctx.projections,
      base_event_log: final_injection_ctx.event_log,
      started_resource_pollers: started_resource_pollers,
      # DR-040: the fold counter after any injected events folded during
      # adapter execution; the command fold continues from here.
      base_fold_counter: final_injection_ctx.fold_counter
    }

    case result do
      # Sync commands return {:ok, events}; probe/async commands that settle
      # return {:settled, events}. Both run the one post-events pipeline. The
      # non-success arms stay here so a {:retry, _} from a sync command is
      # still rejected.
      {:ok, events} when is_list(events) ->
        fold_command_events(events, event_ctx, ctx)

      {:settled, events} ->
        fold_command_events(events, event_ctx, ctx)

      {:timeout, last_reason} ->
        {:error, Failure.settle_timeout(last_reason), state_with_pollers, {:error, result}}

      {:error, reason} ->
        {:error, Failure.adapter_error(reason), state_with_pollers, result}

      # The report keeps the shape a raise has always had,
      # {exception, stacktrace}; only the outcome tells it apart from an
      # adapter that returned {:error, {exception, stacktrace}}.
      {:raised, exception, stacktrace} ->
        {:error, Failure.adapter_error({exception, stacktrace}), state_with_pollers,
         {:raised, exception}}

      {:retry, reason} ->
        # {:retry, _} is the probe/async settle protocol: only :probe/:async
        # commands run through Settle, which consumes {:retry, _} by
        # re-invoking execute until {:settled, _} or timeout. Reaching this
        # case means a :sync command returned {:retry, _}, which it must not.
        command_module = if is_struct(resolved_command), do: resolved_command.__struct__

        {:error, Failure.retry_from_sync_command(%{command: command_module, reason: reason}),
         state_with_pollers, {:error, result}}

      # Adapter returned something other than {:ok, list} / {:error, _} /
      # {:timeout, _} / {:retry, _}: report a graceful failure instead of
      # crashing the run with a CaseClauseError.
      other ->
        {:error, Failure.malformed_adapter_return(other), state_with_pollers, {:error, other}}
    end
  end

  # The per-command Runtime handle (DR-027), built over the window's sink.
  # user_context stays exactly the adapter's setup/1 return; inject and
  # start_poller travel here over the explicit sink.
  defp runtime_builder(index, state, ctx) do
    # Capture the run process now: `runtime.start_poller` is invoked from
    # inside adapter.execute/3, which (DR-032) runs in a child Task; the
    # poller must route its result to this stable mailbox, not the
    # short-lived Task's.
    poller_owner = self()
    poller_started = state.on_resource_poller_start
    event_queue = ctx.event_queue
    observer = state.step_observer

    fn sink ->
      start_poller_fn = fn opts ->
        poller =
          ResourcePoller.start(
            Keyword.merge(opts,
              event_queue: event_queue,
              command_index: index,
              caller: poller_owner
            )
          )

        Runtime.Sink.add_poller(sink, poller)
        if poller_started, do: poller_started.(poller.pid)
        poller
      end

      # The step observer may hand the adapter what it needs to reach it:
      # the mocks put their registry on the handle, so an adapter can drive a
      # mocked third party's handle_request/2 during execute/3.
      StepObserver.runtime(observer, %Runtime{
        inject: fn event -> inject_event(sink, event) end,
        start_poller: start_poller_fn,
        # DR-054: the first attempt's log lines go into the same sink.
        log: PropertyDamage.Log.writer(sink, 1)
      })
    end
  end

  # A timed-out attempt's Task is shut down, and the resource pollers started
  # inside it die with it through their link. They leave the active list here,
  # each stopped first so that none outlives the list. The command has failed,
  # so the pollers of its earlier settle attempts go too.
  defp drop_timed_out_pollers({:error, %PropertyDamage.CommandTimeoutError{}}, pollers) do
    Enum.each(pollers, &ResourcePoller.stop/1)
    []
  end

  defp drop_timed_out_pollers(_result, pollers), do: pollers

  # Run the post-events pipeline for a command whose adapter answered with
  # `events`, and attach that answer as the outcome. A projection that signals
  # a transition-invariant violation by raising is reported as a failure
  # carrying the pre-command state, rather than crashing the run.
  defp fold_command_events(events, event_ctx, ctx) do
    case handle_command_events(events, event_ctx, ctx) do
      {:ok, new_state} -> {:ok, new_state, {:ok, events}}
      {:error, reason, failed_state} -> {:error, reason, failed_state, {:ok, events}}
    end
  rescue
    e in PropertyDamage.ProjectionError ->
      {:error, Failure.projection_violation(e.projection, e.original), event_ctx.state,
       {:ok, events}}

    # A mock event the mocks or the projections refused; the lines the mocks'
    # on_event/2 wrote stay under the step (DR-054).
    e in Events.MockEventsError ->
      state = event_ctx.state
      logs = PropertyDamage.Log.append(state.logs, state.current_position, e.lines)
      {:error, mock_events_failure(e.error), %{state | logs: logs}, {:ok, events}}
  end

  @doc """
  The failure of a step whose mock events could not be folded: a mock's
  `on_event/2` that raised is an adapter error naming the mock and the
  callback, as for `on_command/2`; a projection that rejected a mock event is
  a projection violation.
  """
  @spec mock_events_failure(term()) :: Failure.t()
  def mock_events_failure({:mock_callback, reason}), do: Failure.adapter_error(reason)

  def mock_events_failure({:projection, e, _stacktrace}),
    do: Failure.projection_violation(e.projection, e.original)

  # The post-events pipeline: capture externals, fold the command and its
  # events, register awaits, fold the queued injector and mock events, check
  # those asynchronously, then run the step's checks. `ev` is the event_ctx
  # map call_adapter/3 assembled.
  defp handle_command_events(events, ev, ctx) do
    state = ev.state
    index = ev.index

    # Capture external values from real events (DR-021): resolve the
    # placeholders this command produces, found by its structured position.
    # Injected events come first so externals they carry resolve too.
    updated_registry =
      PlaceholderRegistry.capture(
        state.placeholder_registry,
        state.current_position,
        ev.injected_events ++ events
      )

    # Update projections with the command. Record the command's own fold
    # ordinal (DR-040) keyed by its position, then advance the run counter.
    # Injected events already folded during adapter execution took earlier
    # ordinals, so `base_fold_counter` is the ordinal of the command fold.
    command_fold_ordinal = ev.base_fold_counter
    fold_counter = ev.base_fold_counter + 1

    command_fold_ordinals =
      Map.put(state.command_fold_ordinals, state.current_position, command_fold_ordinal)

    projections = Events.update_projections(ev.base_projections, ev.resolved_command)

    # Update projections with the returned events and record them in the log.
    {projections, event_log, fold_counter} =
      Events.process_events(events, :command, index, ev.base_event_log, projections, fold_counter)

    # DR-030: register this command's awaits matchers (post-capture, so the
    # match predicate can close over captured response values). They stay on
    # the state so later drains (finalize included) still correlate.
    state = register_awaits(state, ev.resolved_command, index, {ctx.model, projections})

    # Drain and fold injector events. DR-025: keep the pre-drain projections
    # and log so check_async/2 can assert each async event on the state it
    # produced and locate a violation at the observing event's command_index.
    projs_before_async = projections
    log_before_async = event_log

    {projections, event_log, fold_counter} =
      Events.process_injector_events(
        ctx.event_queue,
        event_log,
        projections,
        fold_counter,
        state.await_matchers
      )

    # Fold the events the step observer holds (the mocks' pushed events); the
    # lines its on_event/3 writes go under this command's step (DR-054).
    {projections, event_log, fold_counter, mock_lines} =
      state.step_observer
      |> Events.process_mock_events(index, event_log, projections, fold_counter)
      |> Events.folded_or_raise!()

    state = %{
      state
      | logs: PropertyDamage.Log.append(state.logs, state.current_position, mock_lines)
    }

    :ok = StepObserver.after_fold(state.step_observer, projections, :step)

    # Every outcome path writes the same post-events fields; only the check
    # counters, and whether check_failures is set, differ. put_state/2 is
    # struct!/2, so omitting :check_failures keeps the prior value.
    pack = fn fields ->
      put_state(
        state,
        Map.merge(
          %{
            event_log: event_log,
            projections: projections,
            placeholder_registry: updated_registry,
            # Record the concrete resolved command by its structured position
            # (DR-033), on every outcome path (the failing command included).
            executed: Map.put(state.executed, state.current_position, ev.resolved_command),
            step_count: state.step_count + 1,
            active_resource_pollers: state.active_resource_pollers ++ ev.started_resource_pollers,
            # DR-040: persist the advanced fold counter and this command's
            # recorded fold ordinal on every outcome path.
            fold_counter: fold_counter,
            command_fold_ordinals: command_fold_ordinals
          },
          fields
        )
      )
    end

    # DR-025: evaluate @check every: checks on the async events just folded
    # (injector and mock), incrementally.
    case check_async(%{state | event_log: event_log},
           since: {projs_before_async, log_before_async},
           model: ctx.model
         ) do
      {:halt, async_name, async_projection, async_reason, async_index, async_counters} ->
        # DR-025: attribute the failure to the offending event's command_index
        # (`async_index`), which may be an earlier command than the one
        # executing (or nil for an ambient injector event). Finalization reads
        # this to set `failed_at_index`.
        failed_state = pack.(%{check_counters: async_counters, async_failed_index: async_index})
        {:error, Failure.check_failed(async_name, async_reason, async_projection), failed_state}

      {:ok, async_counters, async_failures} ->
        check_ctx = %{
          command: ev.resolved_command,
          events: events,
          command_index: index,
          projections: projections,
          sampling: sampling?(index)
        }

        case run_checks(check_ctx, {async_counters, async_failures}, checker(state, ctx.model)) do
          {:ok, check_counters, updated_failures} ->
            {:ok, pack.(%{check_counters: check_counters, check_failures: updated_failures})}

          {:error, check_name, projection, reason, check_counters} ->
            failed_state = pack.(%{check_counters: check_counters})
            {:error, Failure.check_failed(check_name, reason, projection), failed_state}
        end
    end
  end

  # Whether a step advances the check sampling counters: a root does, a setup
  # command does not (its `every: N` triggers neither count nor fire).
  defp sampling?({:setup, _offset}), do: false
  defp sampling?(_index), do: true

  # Inject an event mid-execution from an adapter, through
  # `runtime.inject.(event)`; `sink` is the per-command Runtime.Sink (DR-027).
  # Updates projections immediately and records the event in the log.
  defp inject_event(sink, event) do
    case Runtime.Sink.get_ctx(sink) do
      nil ->
        raise ArgumentError, "inject called outside adapter execution context"

      ctx ->
        # The fold runs here, in the adapter's process, so a projection apply/2
        # that raises a transition-invariant violation propagates into the
        # adapter rather than crashing the sink's Agent.
        projections = Events.update_projections(ctx.projections, event)

        # The entry has source :injected and its fold ordinal (DR-040) from the
        # sink's threaded counter.
        entry =
          Entry.from_injected(event, ctx.command_index)
          |> Map.put(:fold_index, ctx.fold_counter)

        # Injected events accumulate in injection order so external() values
        # they carry can be captured (DR-021): the producer's logical event
        # list is the injected events followed by the events returned from
        # execute, the order generation assigned each placeholder's
        # event_index in.
        Runtime.Sink.update_ctx(sink, fn ctx ->
          %{
            ctx
            | projections: projections,
              injected_events: ctx.injected_events ++ [event],
              event_log: [entry | ctx.event_log],
              fold_counter: ctx.fold_counter + 1
          }
        end)

        :ok
    end
  end

  @doc """
  A `PropertyDamage.Runtime` for a path with no live injection window: a
  stutter retry, a teardown command, or `PropertyDamage.Executor.execute_raw/3`.

  Its `inject` and `start_poller` raise an `ArgumentError` naming `reason`.
  Option `:stutter` sets the runtime's stutter context (default `nil`).
  """
  @spec unavailable_runtime(String.t(), keyword()) :: Runtime.t()
  def unavailable_runtime(reason, opts \\ []) do
    %Runtime{
      inject: fn _event ->
        raise ArgumentError, "Runtime.inject is not available #{reason}"
      end,
      start_poller: fn _opts ->
        raise ArgumentError, "Runtime.start_poller is not available #{reason}"
      end,
      stutter: Keyword.get(opts, :stutter)
    }
  end

  @doc """
  Calls `teardown/1` of the context's adapter with its adapter context,
  best-effort, and returns the log lines it wrote (DR-054).

  A raising teardown logs a warning but never fails the run (DR-027), so a
  cleanup hiccup cannot mask the actual result or, during shrinking, perturb
  the failure being minimized.
  """
  @spec teardown_adapter(map()) :: [term()]
  def teardown_adapter(ctx) do
    {:ok, lines} =
      PropertyDamage.Log.inline(fn -> try_teardown(ctx.adapter, ctx.adapter_context) end)

    lines
  end

  defp try_teardown(adapter, user_context) do
    require Logger

    try do
      adapter.teardown(user_context)
      :ok
    rescue
      e ->
        Logger.warning(
          "Adapter #{inspect(adapter)} teardown/1 raised: " <>
            Exception.format(:error, e, __STACKTRACE__)
        )

        :ok
    catch
      # A BEAM exit/throw from teardown/1 bypasses `rescue`; teardown stays
      # best-effort for those too.
      kind, reason ->
        Logger.warning(
          "Adapter #{inspect(adapter)} teardown/1 escaped via #{kind}: " <>
            Exception.format(kind, reason, __STACKTRACE__)
        )

        :ok
    end
  end

  # ============================================================================
  # Step checks
  # ============================================================================

  # What a check run needs from the run: the model whose projections hold the
  # checks, the check mode and the telemetry context.
  defp checker(state, model),
    do: %{model: model, mode: state.check_mode, telemetry: state.telemetry}

  # Run the checks a command step triggers: the command's, then each event's.
  defp run_checks(_check_ctx, {counters, failures}, %{mode: :disabled}),
    do: {:ok, counters, failures}

  defp run_checks(check_ctx, {counters, failures}, checker) do
    command_module = check_ctx.command.__struct__
    sampling = Map.get(check_ctx, :sampling, true)
    counters = bump_sampling(counters, sampling, [:step, :command, command_module])

    step_ctx = %{
      step_type: :command,
      module: command_module,
      command_or_event: check_ctx.command,
      sampling: sampling
    }

    case run_step_checks(step_ctx, check_ctx, {counters, failures}, checker) do
      {:ok, counters, failures} ->
        run_event_checks(check_ctx.events, check_ctx, {counters, failures}, checker)

      error ->
        error
    end
  end

  defp run_event_checks([], _check_ctx, {counters, failures}, _checker),
    do: {:ok, counters, failures}

  defp run_event_checks([event | rest], check_ctx, {counters, failures}, checker) do
    event_module = event.__struct__
    sampling = Map.get(check_ctx, :sampling, true)
    counters = bump_sampling(counters, sampling, [:step, :event, event_module])

    step_ctx = %{
      step_type: :event,
      module: event_module,
      command_or_event: event,
      sampling: sampling
    }

    case run_step_checks(step_ctx, check_ctx, {counters, failures}, checker) do
      {:ok, counters, failures} ->
        run_event_checks(rest, check_ctx, {counters, failures}, checker)

      error ->
        error
    end
  end

  # Run every projection's `@check every:` checks triggered by one step, on
  # `check_ctx.projections`. Under :halt the first failure stops the run;
  # :record keeps it and goes on; :log warns and goes on.
  defp run_step_checks(step_ctx, check_ctx, {counters, failures}, checker) do
    require Logger

    step_ctx = Map.put(step_ctx, :telemetry, checker.telemetry)

    checker.model
    |> PropertyDamage.Model.projection_modules()
    |> Enum.reduce_while({:ok, counters, failures}, fn projection, {:ok, counters, failures} ->
      projection_state = Map.get(check_ctx.projections, projection)

      case Checks.step_checks(projection, projection_state, step_ctx, counters) do
        {:ok, new_counters} ->
          {:cont, {:ok, new_counters, failures}}

        {:error, check_name, reason, new_counters} ->
          case checker.mode do
            :halt ->
              {:halt, {:error, check_name, projection, reason, new_counters}}

            :record ->
              failure = %{
                check_name: check_name,
                projection: projection,
                reason: reason,
                command: Map.get(check_ctx, :command),
                command_index: Map.get(check_ctx, :command_index),
                step_type: step_ctx.step_type,
                module: step_ctx.module,
                timestamp: System.monotonic_time(:millisecond)
              }

              {:cont, {:ok, new_counters, [failure | failures]}}

            :log ->
              Logger.warning("Check failed: #{check_name} - #{inspect(reason)}")
              {:cont, {:ok, new_counters, failures}}
          end
      end
    end)
  end

  # Advance the sampling counters `keys` by one, unless the step does not
  # sample (a setup command's step, whose `every: N` triggers neither count
  # nor fire).
  defp bump_sampling(counters, false, _keys), do: counters

  defp bump_sampling(counters, true, keys),
    do: Enum.reduce(keys, counters, fn key, acc -> Map.update(acc, key, 1, &(&1 + 1)) end)

  # ============================================================================
  # Lifecycle-boundary checks (@check at:, DR-024)
  # ============================================================================

  @doc """
  Runs the `@check at: :startup` checks on `state`, the initial `init/0`
  projections, before the first command.

  Returns `{:ok, state}` with any recorded failures and the fire counters
  folded in, or, when a check halts, `{:failed, nil, failure, state}`, the
  failed tuple finalization reports with no command index.
  """
  @spec run_startup_checks(State.t()) :: {:ok, State.t()} | {:failed, nil, Failure.t(), State.t()}
  def run_startup_checks(state) do
    case run_phase_checks(state, :startup) do
      {:halt, name, projection, reason, _counters} ->
        {:failed, nil, Failure.check_failed(name, reason, projection), state}

      {:ok, startup_recorded, startup_counters} ->
        {:ok,
         %{
           state
           | check_failures: startup_recorded ++ state.check_failures,
             check_counters: startup_counters
         }}
    end
  end

  @doc """
  Runs every `@check at: phase` check once on the state's projections.

  Unlike `@check every:` checks there is no step counter and no sampling:
  the timing is the phase boundary. The check's second argument is the phase
  atom (`:startup` or `:teardown`). Each check counts as fired before it runs
  (DR-026), so a failing lifecycle check still counts as exercised.

  Returns `{:ok, recorded_failures, counters}`, where the recorded failures
  are this phase's `:record`-mode failures, newest first, or
  `{:halt, name, projection, {exception, stacktrace}, counters}` for the
  first failure under `:halt`.
  """
  @spec run_phase_checks(State.t(), :startup | :teardown) ::
          {:ok, [map()], map()} | {:halt, atom(), module(), term(), map()}
  def run_phase_checks(state, phase) do
    counters = state.check_counters

    if state.check_mode == :disabled do
      {:ok, [], counters}
    else
      state.model
      |> PropertyDamage.Model.projection_modules()
      |> Enum.reduce_while({:ok, [], counters}, fn projection, {:ok, recorded, acc_counters} ->
        case run_phase_projection_checks(projection, phase, {recorded, acc_counters}, state) do
          {:ok, new_recorded, new_counters} ->
            {:cont, {:ok, new_recorded, new_counters}}

          {:halt, name, halt_projection, reason, halt_counters} ->
            {:halt, {:halt, name, halt_projection, reason, halt_counters}}
        end
      end)
    end
  end

  defp run_phase_projection_checks(projection, phase, {recorded, counters}, state) do
    require Logger

    projection_state = Map.get(state.projections, projection)
    checks = Checks.phase_checks(projection, phase)

    Enum.reduce_while(checks, {:ok, recorded, counters}, fn check,
                                                            {:ok, acc_recorded, acc_counters} ->
      fired = Checks.record_fire(acc_counters, projection, check.name)

      case PropertyDamage.Telemetry.check_span(state.telemetry, projection, check.name, fn ->
             projection
             |> apply(check.function_name, [projection_state, phase])
             |> Verdict.check(check.name)
           end) do
        :ok ->
          {:cont, {:ok, acc_recorded, fired}}

        {:failed, e, stacktrace} ->
          case state.check_mode do
            :halt ->
              {:halt, {:halt, check.name, projection, {e, stacktrace}, fired}}

            :record ->
              failure = %{
                check_name: check.name,
                projection: projection,
                reason: {e, stacktrace},
                command: nil,
                command_index: nil,
                step_type: phase,
                module: nil,
                timestamp: System.monotonic_time(:millisecond)
              }

              {:cont, {:ok, [failure | acc_recorded], fired}}

            :log ->
              Logger.warning("Check failed at #{phase}: #{check.name} - #{inspect(e)}")
              {:cont, {:ok, acc_recorded, fired}}
          end
      end
    end)
  end

  # ============================================================================
  # Continuous async-observation checking (DR-025)
  # ============================================================================
  #
  # The asynchronous event paths (resource-poller and injector-adapter events,
  # mock-service events, and the finalize-time drains) fold events into
  # projection state, and `@check every:` checks run on each of those events,
  # so a violation is reported at the offending event (with that event's
  # `command_index`) rather than only at the `@check at: :teardown` settled
  # checkpoint. That gives the shrinker a tight truncation target.
  #
  # The evaluation is incremental: each event is asserted on the state that
  # folding that event produced, not on the final drained state. Asserting
  # against the final state would report at the first matching event of a
  # batch rather than at the causal one, and the reported `command_index`
  # would not reproduce on truncation. Command-own events keep their
  # batch-against-final timing (run_checks); only the async paths are
  # incremental (the documented asymmetry, DR-025).

  @doc """
  Runs `@check every:` checks on the events folded into `state.event_log`
  since a snapshot, one event at a time on the projections that event
  produced (DR-025). `state.projections` is left untouched.

  Options:

    * `:since` (required) - `{projections, event_log}` before the fold; the
      events are the entries prepended to the log since then
    * `:failures` - the `:record` failures to add to (default
      `state.check_failures`)
    * `:model` - the model whose projections hold the checks (default
      `state.model`)

  Returns `{:ok, counters, failures}`, or under `:halt`
  `{:halt, name, projection, reason, command_index, counters}`, where
  `command_index` locates the offending event for the shrinker (nil for a
  pure injector event).
  """
  @spec check_async(State.t(), keyword()) ::
          {:ok, map(), [map()]} | {:halt, atom(), module(), term(), term(), map()}
  def check_async(state, opts) do
    {projs_before, log_before} = Keyword.fetch!(opts, :since)
    failures = Keyword.get(opts, :failures, state.check_failures)
    checker = checker(state, Keyword.get(opts, :model, state.model))

    if checker.mode == :disabled do
      {:ok, state.check_counters, failures}
    else
      new_count = length(state.event_log) - length(log_before)
      new_entries = state.event_log |> Enum.take(new_count) |> Enum.reverse()

      folded =
        Enum.reduce_while(new_entries, {projs_before, state.check_counters, failures}, fn entry,
                                                                                          {projs,
                                                                                           c, f} ->
          projs = Events.update_projections(projs, entry.event)

          case check_async_event(entry, projs, {c, f}, checker) do
            {:ok, c, f} ->
              {:cont, {projs, c, f}}

            {:halt, name, projection, reason, c} ->
              {:halt, {:halt, name, projection, reason, Entry.attribution(entry), c}}
          end
        end)

      case folded do
        {_projs, c, f} -> {:ok, c, f}
        {:halt, name, projection, reason, idx, c} -> {:halt, name, projection, reason, idx, c}
      end
    end
  end

  # Evaluate the `@check every:` dispatch for one asynchronously observed
  # event, on its post-fold `projections`. Mirrors run_event_checks' counter
  # bumps (`:step`, `:event`, module) so `every: N` sampling counts async
  # observations. `step_type` is `:event`, so `every: :command` checks do not
  # fire (the opt-out) while `every: :event`, `every: 1` and
  # `every: Module` do.
  defp check_async_event(entry, projections, {counters, failures}, checker) do
    event = entry.event
    module = event.__struct__
    # An event of a setup command does not advance the sampling counters.
    sampling = entry.phase == :root

    counters = bump_sampling(counters, sampling, [:step, :event, module])

    step_ctx = %{step_type: :event, module: module, command_or_event: event, sampling: sampling}

    check_ctx = %{
      command: nil,
      command_index: Entry.attribution(entry),
      projections: projections
    }

    case run_step_checks(step_ctx, check_ctx, {counters, failures}, checker) do
      {:ok, counters, failures} -> {:ok, counters, failures}
      {:error, name, projection, reason, counters} -> {:halt, name, projection, reason, counters}
    end
  end

  # ============================================================================
  # Awaits and pollers
  # ============================================================================

  # DR-030: build and register the awaits matchers a command declares. Pure
  # correlation: each %Await{match} becomes a registry entry carrying the
  # command's index, appended in registration order (so first-registered
  # wins on overlap). A matcher persists for the rest of the run, so a late
  # injector event still correlates to the command that claimed it. Plain-map
  # commands (low-level/test usage) and commands without awaits/2 are no-ops.
  defp register_awaits(state, command, index, {model, projections}) do
    if is_struct(command) and awaits?(command.__struct__) do
      module = command.__struct__
      model_state = Map.get(projections, model.command_sequence_projection())

      new_matchers =
        for %PropertyDamage.Await{match: match} <- module.awaits(model_state, command) do
          %{command_index: index, match: match}
        end

      %{state | await_matchers: state.await_matchers ++ new_matchers}
    else
      state
    end
  end

  defp awaits?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :awaits, 2)
  end

  @doc """
  Starts a poller for every `@eventually` check one of `events` triggers.

  The check function's return must be the 1-arity predicate the poller
  calls; any other return is a check failure at this step, handled under the
  run's `check_mode:` like a synchronous check that failed. Starting a
  poller counts as its check firing (DR-026).

  Options: `:command`, the resolved command the events answered, and
  `:index`, its index; both name the step in a failure.

  Returns `{:ok, state}` or `{:error, %PropertyDamage.Failure{}, state}`.
  """
  @spec spawn_pollers([struct()], State.t(), map(), keyword()) ::
          {:ok, State.t()} | {:error, Failure.t(), State.t()}
  def spawn_pollers(events, state, ctx, opts) do
    if state.check_mode == :disabled do
      {:ok, state}
    else
      # For each event, the @eventually checks it triggers, each with the
      # value its check function returned. Dispatch by function_name (the
      # actual def), since :name is the logical (assert_-stripped) name shared
      # with synchronous checks.
      triggered =
        for event <- events,
            event_module = event.__struct__,
            projection <- PropertyDamage.Model.projection_modules(ctx.model),
            check <- Checks.eventually_checks(projection),
            Projection.event_matches_poll_trigger?(check.eventually, event_module) do
          projection_state = Map.get(state.projections, projection)
          returned = apply(projection, check.function_name, [projection_state, event])
          {projection, check, event, returned}
        end

      {predicates, others} =
        Enum.split_with(triggered, fn {_projection, _check, _event, returned} ->
          is_function(returned, 1)
        end)

      case reject_non_predicates(state, others, opts[:command], opts[:index]) do
        {:ok, state} ->
          {:ok, start_pollers(state, predicates, opts[:index])}

        {:error, check_name, projection, reason, failed_state} ->
          {:error, Failure.check_failed(check_name, reason, projection), failed_state}
      end
    end
  end

  # The `@eventually` functions that returned something other than a
  # predicate, judged under the run's `check_mode:`: `:halt` ends the run at
  # the first, `:record` records each and goes on, `:log` warns and goes on.
  defp reject_non_predicates(state, [], _command, _command_index), do: {:ok, state}

  defp reject_non_predicates(state, others, command, command_index) do
    require Logger

    Enum.reduce_while(others, {:ok, state}, fn {projection, check, event, returned},
                                               {:ok, state} ->
      reason =
        "@eventually #{check.name} must return a 1-arity predicate function " <>
          "for the poller to call; it returned #{inspect(returned)}"

      case state.check_mode do
        :halt ->
          {:halt, {:error, check.name, projection, reason, state}}

        :record ->
          failure = %{
            check_name: check.name,
            projection: projection,
            reason: reason,
            command: command,
            command_index: command_index,
            step_type: :event,
            module: event.__struct__,
            timestamp: System.monotonic_time(:millisecond)
          }

          {:cont, {:ok, %{state | check_failures: [failure | state.check_failures]}}}

        :log ->
          Logger.warning("Check failed: #{check.name} - #{reason}")
          {:cont, {:ok, state}}
      end
    end)
  end

  defp start_pollers(state, [], _command_index), do: state

  defp start_pollers(state, predicates, command_index) do
    # Each started poller is paired with its (projection, check name) so the
    # start can be recorded as a firing (DR-026): starting is firing for a
    # liveness check (the after: event arrived and verification began), so a
    # timed-out or still-pending poller still counts as exercised.
    started =
      for {projection, check, event, predicate} <- predicates do
        # The state getter; refresh_pollers/1 replaces it as the state changes.
        get_state_fn = fn proj -> Map.get(state.projections, proj) end

        poller =
          StatePoller.start(
            predicate: predicate,
            predicate_source: check.predicate_source,
            projection: projection,
            interval_ms: check.eventually.interval_ms,
            timeout_ms: check.eventually.timeout_ms,
            triggered_by: %{
              event: event,
              check_name: check.name,
              command_index: command_index
            },
            get_state_fn: get_state_fn,
            telemetry: state.telemetry
          )

        {projection, check.name, poller}
      end

    new_pollers = Enum.map(started, fn {_proj, _name, poller} -> poller end)

    counters =
      Enum.reduce(started, state.check_counters, fn {proj, name, _poller}, acc ->
        Checks.record_fire(acc, proj, name)
      end)

    %{state | active_pollers: state.active_pollers ++ new_pollers, check_counters: counters}
  end

  @doc """
  Hands every running `@eventually` poller a state getter that reads
  `state.projections`. Returns `state`.
  """
  @spec refresh_pollers(State.t()) :: State.t()
  def refresh_pollers(state) do
    projections = state.projections

    for poller <- state.active_pollers do
      StatePoller.update_state_getter(poller, fn proj -> Map.get(projections, proj) end)
    end

    state
  end

  # ============================================================================
  # Placeholders
  # ============================================================================

  @doc """
  Replaces every placeholder in `command` with the value `registry` holds for
  it (DR-021), and every mint marker with its run-scoped value (DR-034).

  Options `:run_nonce` (default `nil`) and `:mint_epoch` (default 0) are the
  inputs of minted values.

  Returns `{:ok, resolved_command}`, or `{:error, message}` when a
  placeholder is unknown or not resolved yet.
  """
  @spec resolve_placeholders(term(), term(), keyword()) ::
          {:ok, term()} | {:error, String.t()}
  def resolve_placeholders(command, registry, opts \\ []) do
    mint = {Keyword.get(opts, :run_nonce), Keyword.get(opts, :mint_epoch, 0)}
    # The message alone is the reason: the stacktrace is the framework's own
    # resolution frames, and a failure compared across targets must not
    # differ by them.
    PlaceholderRegistry.resolve_data(registry, command, mint)
  end
end
