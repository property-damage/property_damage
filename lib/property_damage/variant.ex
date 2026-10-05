defmodule PropertyDamage.Variant do
  @moduledoc """
  One target running one concrete command sequence in its own process.

  A variant is the unit a multi-target run is made of: every target of the run
  gets a variant over the same command list, and the variants are advanced
  side by side so their answers can be compared command by command. Each
  variant runs the full per-command engine path (`PropertyDamage.Executor.Stepping`):
  placeholder resolution, settle, nemesis, injector and mock events, projections,
  checks, stutter and pollers all work exactly as in `PropertyDamage.run/1`.

  ## Lifecycle

      {:ok, pid} = Variant.start_link(target: target, model: MyModel, commands: commands,
                                      placeholder_registry: PlaceholderRegistry.build(commands),
                                      seed: seed, run_number: run, run_nonce: nonce)
      :ok = Variant.setup(pid)
      {:ok, [{0, observation}]} = Variant.advance_to(pid, 0)
      {:ok, observations} = Variant.advance_to(pid, 3)    # resumes at index 1
      state = Variant.snapshot(pid)
      result = Variant.finish(pid)                         # what Executor.run/4 reports
      :ok = Variant.stop(pid)

  `advance_to/2` steps every command from the next unexecuted index up to and
  including the given index, then stops; the next call resumes from the same
  state. Every command of the sequence is one root, so "boundary r" means
  "after command r".

  ## What a variant owns

  Everything the run writes lives in the variant process and nowhere else: the
  executor state (projections, event log, its own copy of the placeholder
  registry), the event queue, the target's injectors and mocks, and every
  `@eventually` state poller and resource poller its commands start. Pollers
  report to the process that runs the step, so the variant must run every step
  itself; a caller only sends it requests.

  When the variant process exits for any reason, `Process.exit(pid, :kill)`
  included, none of those processes survive. A kill cannot be intercepted by the
  dying process, so a separate guardian process monitors the variant and kills
  every poller, the queue and the mock registry the variant registered with it.

  ## The boundary drain

  Injectors and resource pollers deliver events into the queue at any time. A
  full run folds them when its next command drains the queue. A variant also
  drains after the last step of every `advance_to/2` (`Stepping.drain/2`), so
  the state at a boundary holds every event delivered so far. Drained events
  are not part of any command's observation.

  ## Engine duties outside `Stepping`

  Setup runs the model's `@check at: :startup` checks after the adapter's
  `setup/1` and before command 0, and every step is followed by lifting the
  auto-restoring faults whose duration elapsed, as the linear engine does. A
  one-variant run therefore folds the same events in the same order as
  `PropertyDamage.Executor.run/4` on the same sequence.

  ## Randomness

  A new process draws its own entropy for `:rand`, so an adapter that draws
  random values in `setup/1` or `execute/3` would see different values every
  time the same seed is replayed. Before anything runs, the variant seeds its
  process RNG from the run's seed and its own position among the targets:

      :rand.seed(:exsss, :erlang.phash2({Generator.run_seed(seed, run_number), target.index}, 4_294_967_296))

  Two runs of one seed draw the same values; two variants of one run draw
  different ones. Stutter decisions use their own generator derived from the
  run seed (DR-029), passed as the executor's `rng_seed`.

  ## Observations and failures

  `advance_to/2` returns `{:ok, [{index, observation}]}` with one observation per
  stepped command:

    * `{:ok, events}` - the event values of the command's `:injected` log entries
      followed by its `:command` entries, in fold order (for a `:probe` or
      `:async` command, its settled events)
    * `{:error, reason}` - the adapter's error term, reported only under
      `on_adapter_error: :continue`, where the variant keeps going from the
      failed command's state

  Anything that ends the variant returns `{:failed, failure}`, where `failure`
  is `%{kind: kind, root: index | nil, reason: reason}`:

    * `kind: :execution_failed` - the adapter raised (`reason` is the exception),
      or answered `{:error, _}` under `on_adapter_error: :halt`, or the command
      could not be executed (`reason` is the `%PropertyDamage.Failure{}`)
    * `kind: :check_failed` - a check failed (`reason` is the
      `%PropertyDamage.Failure{}`); `root` is `nil` for a `:startup` check

  After a failure the variant steps nothing more: every later `advance_to/2`
  returns the same `{:failed, failure}`, and `finish/1` reports the failed run
  as `Executor.run/4` would.
  """

  use GenServer

  alias PropertyDamage.{
    EventQueue,
    Executor,
    Failure,
    Generator,
    ResourcePoller,
    StatePoller,
    Target
  }

  alias PropertyDamage.Executor.Stepping
  alias PropertyDamage.Runtime.RunServices

  @typedoc "An observation of one command, as `advance_to/2` reports it."
  @type observation :: {:ok, [struct()]} | {:error, term()}

  @typedoc "Why a variant stopped stepping."
  @type failure :: %{
          kind: :check_failed | :execution_failed,
          root: non_neg_integer() | nil,
          reason: Failure.t() | Exception.t()
        }

  # ==========================================================================
  # Public API
  # ==========================================================================

  @doc """
  Start a variant process linked to the caller.

  Options:

    * `:target` (required) - the `%PropertyDamage.Target{}` to run
    * `:model` (required) - the model module
    * `:commands` (required) - the concrete command list
    * `:placeholder_registry` (required) - this variant's copy of the registry
      built from `:commands` (`PropertyDamage.PlaceholderRegistry.build/1`)
    * `:seed`, `:run_number` (required) - the campaign seed and the 0-based run
    * `:run_nonce` - the run nonce for client-minted values (DR-034)
    * `:stutter_config` - stutter configuration (default `nil`)
    * `:check_mode` - `:halt` | `:record` | `:log` | `:disabled` (default `:halt`)
    * `:on_adapter_error` - `:halt` (default) ends the variant at an adapter
      `{:error, _}`, as the linear engine does; `:continue` reports it as an
      observation and keeps stepping from the failed command's state

  The process RNG is seeded here, before `setup/1` can call the adapter.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Set the variant up, in the variant process.

  Starts the event queue, sets the target's injectors and mocks up against it,
  calls the adapter's `setup/1` with the target's config, builds the executor
  state, and runs `@check at: :startup` checks. A failing startup check does not
  fail setup; the first `advance_to/2` reports it.

  Returns `:ok`, or `{:error, reason}` when `setup/1` returned `{:error, reason}`
  (any other non-`{:ok, _}` return is the reason itself), or
  `{:error, {:raised, exception}}` when setup raised. After an error the
  queue, injectors and mocks are released again, the adapter's `teardown/1` is
  not called, and the variant only accepts `stop/1`.
  """
  @spec setup(pid()) :: :ok | {:error, term()}
  def setup(pid), do: GenServer.call(pid, :setup, :infinity)

  @doc """
  Step every command from the next unexecuted index up to and including
  `boundary`, then drain the event queue.

  Returns `{:ok, [{index, observation}]}` in index order (empty when `boundary`
  is below the next index), or `{:failed, failure}`; see the module doc.
  """
  @spec advance_to(pid(), integer()) ::
          {:ok, [{non_neg_integer(), observation()}]} | {:failed, failure()}
  def advance_to(pid, boundary), do: GenServer.call(pid, {:advance_to, boundary}, :infinity)

  @doc """
  The variant's executor state: `:projections`, `:event_log` (newest first),
  `:placeholder_registry`, `:active_pollers`, `:active_resource_pollers`,
  `:step_count`, `:event_queue` and the rest of the state map. After a failure
  it is the failed state. `nil` before `setup/1`.
  """
  @spec snapshot(pid()) :: map() | nil
  def snapshot(pid), do: GenServer.call(pid, :snapshot, :infinity)

  @doc """
  Finalize the run in the variant process and return the result
  `PropertyDamage.Executor.run/4` reports for it (see `Stepping.finalize/2`).

  Calling it again returns the same result.
  """
  @spec finish(pid()) :: Executor.result() | {:error, :not_set_up}
  def finish(pid), do: GenServer.call(pid, :finish, :infinity)

  @doc """
  Release everything the variant owns, in the variant process, then exit.

  Stops the pollers, tears the mocks and injectors down, stops the event queue,
  then calls the adapter's `teardown/1` (best-effort: a raising teardown is
  logged). Returns `:ok` once all of that is done.
  """
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.call(pid, :stop, :infinity)

  # ==========================================================================
  # Process
  # ==========================================================================

  @impl true
  def init(opts) do
    %Target{} = target = Keyword.fetch!(opts, :target)
    seed = Keyword.fetch!(opts, :seed)
    run_number = Keyword.fetch!(opts, :run_number)
    run_seed = Generator.run_seed(seed, run_number)

    # Seed before anything can draw: setup/1 is the first adapter call.
    :rand.seed(:exsss, :erlang.phash2({run_seed, target.index}, 4_294_967_296))

    state = %{
      target: target,
      model: Keyword.fetch!(opts, :model),
      commands: opts |> Keyword.fetch!(:commands) |> List.to_tuple(),
      placeholder_registry: Keyword.fetch!(opts, :placeholder_registry),
      run_seed: run_seed,
      run_nonce: Keyword.get(opts, :run_nonce),
      stutter_config: Keyword.get(opts, :stutter_config),
      check_mode: Keyword.get(opts, :check_mode, :halt),
      on_adapter_error: Keyword.get(opts, :on_adapter_error, :halt),
      guardian: start_guardian(self()),
      phase: :new,
      event_queue: nil,
      injectors_up: false,
      mock_registry: nil,
      mock_contexts: [],
      ctx: nil,
      exec: nil,
      next: 0,
      halted: nil,
      failure: nil,
      result: nil,
      stash: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:setup, _from, %{phase: :new} = state) do
    case bring_up(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, %{state | phase: :setup_failed}}
    end
  end

  def handle_call(:setup, _from, state), do: {:reply, {:error, :already_set_up}, state}

  def handle_call({:advance_to, boundary}, _from, %{phase: :ready} = state) do
    {reply, state} = advance(state, boundary)
    {:reply, reply, state}
  end

  def handle_call({:advance_to, _boundary}, _from, %{phase: :halted} = state),
    do: {:reply, {:failed, state.failure}, state}

  def handle_call({:advance_to, _boundary}, _from, state),
    do: {:reply, {:error, not_steppable(state)}, state}

  def handle_call(:snapshot, _from, state), do: {:reply, state.exec, state}

  def handle_call(:finish, _from, %{phase: phase} = state) when phase in [:ready, :halted] do
    # Poller results that arrived between requests were taken out of the
    # mailbox; put them back so finalization's receive sees them.
    state.stash |> Enum.reverse() |> Enum.each(&send(self(), &1))

    result = Stepping.finalize(state.halted || state.exec, state.ctx)
    {:reply, result, %{state | phase: :finished, result: result, stash: []}}
  end

  def handle_call(:finish, _from, %{phase: :finished} = state),
    do: {:reply, state.result, state}

  def handle_call(:finish, _from, state), do: {:reply, {:error, :not_set_up}, state}

  def handle_call(:stop, _from, state) do
    release(state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({tag, _id, _result} = message, state)
      when tag in [:poller_result, :resource_poller_result] do
    {:noreply, %{state | stash: [message | state.stash]}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ==========================================================================
  # Setup
  # ==========================================================================

  defp bring_up(state) do
    {:ok, queue} = EventQueue.start_link()
    guard(state, [queue])
    state = %{state | event_queue: queue}

    case start_services_and_adapter(state) do
      {:ok, state, adapter_context} ->
        {:ok, build_ready_state(state, adapter_context)}

      {:error, reason, state} ->
        release_services(state)
        {:error, reason, state}
    end
  end

  defp start_services_and_adapter(state) do
    target = state.target
    RunServices.setup_injectors(target.injectors, state.event_queue)
    state = %{state | injectors_up: true}

    {registry, contexts} = RunServices.setup_mocks(target.mocks, state.event_queue)
    if registry, do: guard(state, [registry])
    state = %{state | mock_registry: registry, mock_contexts: contexts}

    case call_adapter_setup(target) do
      {:ok, adapter_context} -> {:ok, state, adapter_context}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp call_adapter_setup(target) do
    case target.adapter.setup(target.config) do
      {:ok, adapter_context} -> {:ok, adapter_context}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    exception -> {:error, {:raised, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp build_ready_state(state, adapter_context) do
    exec =
      Stepping.init_state(state.model,
        event_queue: state.event_queue,
        stutter_config: state.stutter_config,
        mock_registry: state.mock_registry,
        check_mode: state.check_mode,
        placeholder_registry: state.placeholder_registry,
        rng_seed: state.run_seed,
        run_nonce: state.run_nonce,
        mint_epoch: 0
      )

    ctx = %Stepping.Context{
      model: state.model,
      adapter: state.target.adapter,
      adapter_context: adapter_context,
      event_queue: state.event_queue
    }

    state = %{state | ctx: ctx}

    case Executor.run_startup_checks(exec) do
      {:ok, exec} ->
        %{state | phase: :ready, exec: exec}

      {:failed, nil, failure, exec} = failed ->
        %{
          state
          | phase: :halted,
            exec: exec,
            halted: failed,
            failure: %{kind: :check_failed, root: nil, reason: failure}
        }
    end
  end

  # ==========================================================================
  # Stepping
  # ==========================================================================

  defp advance(state, boundary) do
    last = min(boundary, tuple_size(state.commands) - 1)

    if last < state.next do
      {{:ok, []}, state}
    else
      state.next..last
      |> Enum.reduce_while({state, []}, fn index, {state, observed} ->
        case step_root(state, index) do
          {:cont, state, observation} -> {:cont, {state, [{index, observation} | observed]}}
          {:halt, state} -> {:halt, {state, :halted}}
        end
      end)
      |> finish_advance(last)
    end
  end

  defp finish_advance({state, :halted}, _last), do: {{:failed, state.failure}, state}

  defp finish_advance({state, observed}, last) do
    case Stepping.drain(state.exec, state.ctx) do
      {:ok, exec} ->
        {{:ok, Enum.reverse(observed)}, guard_pollers(%{state | exec: exec})}

      {:error, failure, failed} ->
        state = halt(state, {:failed, last, failure, failed}, failure_of(last, failure, nil))
        {{:failed, state.failure}, state}
    end
  end

  defp step_root(state, index) do
    command = elem(state.commands, index)
    before = state.exec

    case Stepping.step(command, index, before, state.ctx) do
      {:ok, exec, _outcome} ->
        observation = {:ok, root_events(exec.event_log, before.event_log, index)}
        {:cont, after_step(state, exec, index), observation}

      {:error, _failure, failed, {:error, reason}}
      when state.on_adapter_error == :continue ->
        {:cont, after_step(state, failed, index), {:error, reason}}

      {:error, failure, failed, outcome} ->
        {:halt,
         halt(state, {:failed, index, failure, failed}, failure_of(index, failure, outcome))}
    end
  end

  # Lift faults whose duration elapsed, as the linear engine does after every
  # command, and hand any new pollers to the guardian.
  defp after_step(state, exec, index) do
    exec =
      Executor.Nemesis.restore_elapsed_faults(
        exec,
        state.ctx.adapter_context,
        state.event_queue
      )

    guard_pollers(%{state | exec: exec, next: index + 1})
  end

  defp halt(state, failed, failure) do
    {:failed, _index, _reason, failed_state} = failed

    guard_pollers(%{
      state
      | phase: :halted,
        exec: failed_state,
        halted: failed,
        failure: failure
    })
  end

  # The event values of one command's :injected entries, then its :command
  # entries, in fold order. Only entries the step added are examined.
  defp root_events(event_log, log_before, index) do
    added =
      event_log
      |> Enum.take(length(event_log) - length(log_before))
      |> Enum.reverse()
      |> Enum.filter(&(&1.command_index == index))

    for(%{source: :injected, event: event} <- added, do: event) ++
      for %{source: :command, event: event} <- added, do: event
  end

  defp failure_of(index, _failure, {:raised, exception}),
    do: %{kind: :execution_failed, root: index, reason: exception}

  defp failure_of(index, failure, {:error, _reason}),
    do: %{kind: :execution_failed, root: index, reason: failure}

  defp failure_of(index, %Failure{type: %Failure.Check{}} = failure, _outcome),
    do: %{kind: :check_failed, root: index, reason: failure}

  defp failure_of(index, failure, _outcome),
    do: %{kind: :execution_failed, root: index, reason: failure}

  defp not_steppable(%{phase: :new}), do: :not_set_up
  defp not_steppable(%{phase: :setup_failed}), do: :not_set_up
  defp not_steppable(%{phase: :finished}), do: :finished

  # ==========================================================================
  # Teardown
  # ==========================================================================

  defp release(state) do
    if state.exec, do: stop_pollers(state.exec)
    release_services(state)

    if state.ctx do
      Executor.safe_teardown(state.ctx.adapter, state.ctx.adapter_context)
    end

    :ok
  end

  defp stop_pollers(exec) do
    for poller <- exec.active_pollers, do: best_effort(fn -> StatePoller.stop(poller) end)

    for poller <- exec.active_resource_pollers,
        do: best_effort(fn -> ResourcePoller.stop(poller) end)
  end

  defp release_services(state) do
    best_effort(fn -> RunServices.teardown_mocks(state.mock_registry, state.mock_contexts) end)

    if state.injectors_up do
      best_effort(fn -> RunServices.teardown_injectors(state.target.injectors) end)
    end

    if state.event_queue, do: best_effort(fn -> EventQueue.stop(state.event_queue) end)
    :ok
  end

  # Cleanup must reach the adapter's teardown even when an earlier step fails,
  # for example a poller that exited between the liveness check and the stop.
  defp best_effort(fun) do
    fun.()
  rescue
    exception ->
      require Logger
      Logger.warning("Variant cleanup raised: " <> Exception.message(exception))
  catch
    _kind, _reason -> :ok
  end

  # ==========================================================================
  # Guardian
  # ==========================================================================

  # The guardian outlives a killed variant: it is not linked to it, it monitors
  # it, and on the :DOWN it kills every process registered with it.
  defp start_guardian(owner) do
    spawn(fn ->
      ref = Process.monitor(owner)
      guardian_loop(ref, MapSet.new())
    end)
  end

  defp guardian_loop(ref, pids) do
    receive do
      {:guard, new_pids} ->
        guardian_loop(ref, Enum.into(new_pids, pids))

      {:DOWN, ^ref, :process, _pid, _reason} ->
        Enum.each(pids, &Process.exit(&1, :kill))
    end
  end

  defp guard(state, pids), do: send(state.guardian, {:guard, pids})

  defp guard_pollers(%{exec: exec} = state) do
    pids =
      Enum.map(exec.active_pollers, & &1.pid) ++
        Enum.map(exec.active_resource_pollers, & &1.pid)

    if pids != [], do: guard(state, pids)
    state
  end
end
