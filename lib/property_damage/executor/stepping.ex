defmodule PropertyDamage.Executor.Stepping do
  @moduledoc """
  The supported interface for executing a command sequence *one command at a
  time* against a live System Under Test.

  A full run (`PropertyDamage.run/1`) drives the whole sequence internally. Some
  callers instead need to advance a sequence step by step while inspecting state
  between commands: `PropertyDamage.Replay` walks a shrunk failure command by
  command so a human can watch it reproduce. This module is that seam.

  ## Lifecycle

  The caller owns setup and teardown; stepping only advances execution:

      # 1. caller sets up the adapter and (if needed) an event queue
      {:ok, adapter_context} = MyAdapter.setup(config)
      {:ok, event_queue} = PropertyDamage.EventQueue.start_link()

      # 2. build a fresh executor state and a per-run context
      state = Stepping.init_state(MyModel, event_queue: event_queue)
      ctx = %Stepping.Context{
        model: MyModel,
        adapter: MyAdapter,
        adapter_context: adapter_context,
        event_queue: event_queue
      }

      # 3. step each command, threading the returned state forward; the
      #    outcome is what the adapter answered
      {:ok, state, {:ok, _events}} = Stepping.step(command_0, 0, state, ctx)
      {:ok, state, _outcome} = Stepping.step(command_1, 1, state, ctx)

      # 4. optionally fold events that arrived since the last step
      {:ok, state} = Stepping.drain(state, ctx)

      # 5. either finalize the run into the result a full run reports ...
      result = Stepping.finalize(state, ctx)

      # ... or just stop the pollers; then the caller tears everything down
      Stepping.stop_pollers(state)
      PropertyDamage.EventQueue.stop(event_queue)
      MyAdapter.teardown(adapter_context)

  ## Guarantees

  `step/4` runs **the single per-command engine path**: ref/placeholder
  resolution, settle, nemesis, injector/mock events, projections, checks,
  stutter, and pollers all run exactly as they do inside a full run. It is the
  same engine primitive the full-run loop uses, so stepping cannot diverge from
  running.

  Two duties of the full-run loop stay with the caller, because a stepping
  caller may want them at different points: `@check at: :startup` checks
  before the first command, and lifting auto-restoring faults whose duration
  elapsed after each command. `PropertyDamage.Variant` does both.

  Stepping assumes a **linear** sequence: each command's position is
  `Position.prefix(index)` (DR-021), where `index` is its 0-based offset. Do not
  use this API for branching/parallel sequences.
  """

  alias PropertyDamage.Executor
  alias PropertyDamage.Executor.{Events, Finalization}
  alias PropertyDamage.Failure
  alias PropertyDamage.MockServiceRegistry
  alias PropertyDamage.ResourcePoller
  alias PropertyDamage.Sequence.Position
  alias PropertyDamage.StatePoller

  defmodule Context do
    @moduledoc """
    The per-run inputs shared by every `step/4` of one sequence.

    These do not change from one command to the next, so they are bundled once
    rather than passed on every call: the `model` orchestrating the run, the
    `adapter` bridging to the SUT and the `adapter_context` its `setup/1`
    returned, and the `event_queue` async/injected events flow through (`nil`
    when the run has no injector adapters).
    """

    @enforce_keys [:model, :adapter, :adapter_context]
    defstruct [:model, :adapter, :adapter_context, :event_queue]

    @type t :: %__MODULE__{
            model: module(),
            adapter: module(),
            adapter_context: term(),
            event_queue: pid() | nil
          }
  end

  @doc """
  Build a fresh executor state for stepping a sequence.

  Options:

    * `:event_queue` - the async/injected event queue (default `nil`)
    * `:stutter_config` - stutter/idempotency configuration (default `nil`)
    * `:mock_registry` - mock service registry (default `nil`)
    * `:check_mode` - `:halt` | `:record` | `:log` | `:disabled` (default `:halt`)
    * `:external_markers` - external value markers (default `[]`)
    * `:placeholder_registry` - registry seeded from the generated sequence (DR-021)
    * `:rng_seed` - explicit stutter RNG base (DR-029)
    * `:run_nonce` - run nonce seeding `mint_per_run` resolution (DR-034)
    * `:mint_epoch` - SUT-execution epoch for minted values (DR-034, default 0)
  """
  @spec init_state(module(), keyword()) :: map()
  def init_state(model, opts \\ []) do
    Executor.build_initial_state(
      model,
      Keyword.get(opts, :event_queue),
      Keyword.get(opts, :stutter_config),
      Keyword.get(opts, :mock_registry),
      Keyword.get(opts, :check_mode, :halt),
      Keyword.get(opts, :external_markers, []),
      Keyword.get(opts, :placeholder_registry),
      Keyword.get(opts, :rng_seed),
      {Keyword.get(opts, :run_nonce), Keyword.get(opts, :mint_epoch, 0)}
    )
  end

  @typedoc """
  What the adapter answered for one command, so a caller comparing answers does
  not rebuild them from the state:

    * `{:ok, events}` - the events the adapter returned; for a `:probe` or
      `:async` command, the settled events; for a nemesis command, the events
      its `inject/2` returned
    * `{:error, reason}` - the adapter's own error term (a nemesis command's
      `inject/2` error likewise). A `:probe`/`:async` command that never
      settled is `{:error, {:timeout, last_reason}}`, and a return outside the
      adapter protocol is `{:error, return_value}`.
    * `{:raised, exception}` - `execute/3` raised
    * `:not_called` - a placeholder in the command could not be resolved, so
      the adapter was never called
  """
  @type outcome ::
          {:ok, [struct()]} | {:error, term()} | {:raised, Exception.t()} | :not_called

  @doc """
  Execute exactly one command against an existing stepping state.

  Captures the pre-command projections first (as the linear run loop does) and
  positions the command at `Position.prefix(index)`. Returns
  `{:ok, new_state, outcome}` or `{:error, %PropertyDamage.Failure{}, failed_state, outcome}`;
  see `t:outcome/0`. The failure and the failed state are what a full run
  reports for the same command. In particular an adapter raise is reported as
  an `:adapter_error` failure whose detail is `{exception, stacktrace}`; only
  the `{:raised, exception}` outcome tells it apart from an adapter that
  returned `{:error, {exception, stacktrace}}`.
  """
  @spec step(struct() | map(), non_neg_integer(), map(), Context.t()) ::
          {:ok, map(), outcome()} | {:error, Failure.t(), map(), outcome()}
  def step(command, index, state, %Context{} = ctx) do
    # Linear stepping: positions are prefix positions (DR-021).
    state_with_before = %{
      state
      | projections_before: state.projections,
        current_position: Position.prefix(index)
    }

    Executor.execute_command_with_outcome(
      command,
      index,
      state_with_before,
      ctx.model,
      ctx.adapter,
      ctx.adapter_context,
      ctx.event_queue
    )
  end

  @doc """
  Fold the events already waiting in the context's event queue into the state.

  Between two steps, injectors and resource pollers keep delivering into the
  queue; a full run folds those events at the start of its next command's
  drain. `drain/2` folds them now, so the state reflects every event delivered
  so far. Injector events are logged with source `:injector` (attributed to a
  command through its declared awaits, DR-030), resource-poller events keep
  their own source and command index. Each drained event is checked by
  `@check every:` checks as it folds (DR-025), and running `@eventually`
  pollers read the new projections afterwards.

  Returns `{:ok, state}`, or `{:error, %PropertyDamage.Failure{}, failed_state}`
  when a check fails on a drained event; the failed state records the
  offending event's command index as the place a full run would report.
  """
  @spec drain(map(), Context.t()) :: {:ok, map()} | {:error, Failure.t(), map()}
  def drain(state, %Context{} = ctx) do
    projections_before = state.projections
    log_before = state.event_log

    {projections, event_log, fold_counter} =
      Events.process_injector_events(
        ctx.event_queue,
        log_before,
        projections_before,
        state.branch_id,
        state.fold_counter,
        state.await_matchers
      )

    if state.mock_registry do
      MockServiceRegistry.update_projections(state.mock_registry, projections)
    end

    drained = %{
      state
      | projections: projections,
        event_log: event_log,
        fold_counter: fold_counter
    }

    case Executor.check_async(
           ctx.model,
           projections_before,
           log_before,
           event_log,
           state.check_counters,
           state.check_mode,
           state.check_failures
         ) do
      {:ok, counters, failures} ->
        drained = %{drained | check_counters: counters, check_failures: failures}
        {:ok, Executor.update_poller_state_getters(drained)}

      {:halt, name, reason, command_index, counters} ->
        failed = %{drained | check_counters: counters, async_failed_index: command_index}
        {:error, Failure.check_failed(name, reason), failed}
    end
  end

  @doc """
  Finish a stepped run and return the result a full run reports.

  Takes either the last state, or the failed tuple
  `{:failed, index, %PropertyDamage.Failure{}, failed_state}` for a run that
  stopped at `index` (`nil` when no command was to blame). Faults still active
  are restored through the context's adapter context first, then the run is
  finalized exactly as `PropertyDamage.Executor.run/4` finalizes it: await the
  `@eventually` pollers, settle the queue, run `@check at: :teardown` checks,
  and stop every poller. Returns the result map `Executor.run/4` reports.
  """
  @spec finalize(map() | {:failed, non_neg_integer() | nil, Failure.t(), map()}, Context.t()) ::
          Executor.result()
  def finalize(state_or_failed, %Context{} = ctx) do
    state_or_failed
    |> Executor.restore_remaining_faults(ctx.adapter_context, ctx.event_queue)
    |> Finalization.finalize_result()
  end

  @doc """
  Stop any pollers spawned during stepping.

  Best-effort cleanup for the stepping shell; a full run finalizes pollers
  through its own finalization path.
  """
  @spec stop_pollers(map()) :: :ok
  def stop_pollers(state) do
    Enum.each(Map.get(state, :active_pollers, []), &StatePoller.stop/1)
    Enum.each(Map.get(state, :active_resource_pollers, []), &ResourcePoller.stop/1)
    :ok
  end
end
