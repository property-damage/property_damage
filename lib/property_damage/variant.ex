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
      :ok = Variant.run_setup(pid)                         # the setup commands
      {:ok, [{0, observation}]} = Variant.advance_to(pid, 0)
      {:ok, observations} = Variant.advance_to(pid, 3)    # resumes at index 1
      state = Variant.snapshot(pid)
      result = Variant.finish(pid)                         # what Executor.run/4 reports
      {:ok, _entries} = Variant.run_teardown(pid)          # the teardown commands
      :ok = Variant.stop(pid)

  `advance_to/2` steps every root from the next unexecuted index up to and
  including the given index, then stops; the next call resumes from the same
  state. "Boundary r" means "after root r". A root is one command, or, when
  the variant runs it as an expansion (`:roots`), the leaves of that
  expansion in order: each leaf is an executed command, stepped through
  `Stepping.step_leaf/5`.

  ## Setup and teardown commands

  `run_setup/1` steps the model's setup commands (`:setup_commands`) through
  `Stepping.step_setup/4`, drains the queue, and then checks the completion
  rule: every `external()` a setup command produces must be resolved in this
  variant's registry. `run_teardown/1` steps the teardown commands
  (`:teardown_commands`) through `Stepping.step_teardown/4` once. Every other path
  that executes a run (`PropertyDamage.Executor.run/4`,
  `PropertyDamage.Replay`) runs both phases the same way. `stop/1`
  runs them first when nobody did, so they run for every variant whose adapter
  `setup/1` succeeded, whatever happened after it, and never for one whose
  `setup/1` failed.

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
  A resource poller is registered the moment an adapter starts it, before
  `execute/3` continues, so a kill in the middle of a command (for example
  while a `:probe` command waits between settle attempts) reaps it too.

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

  ## Telemetry

  Every command the variant steps and every check it evaluates emits the
  `[:property_damage, :command, ...]` and `[:property_damage, :check, ...]`
  events (`PropertyDamage.Telemetry`) with `variant: %{index, name}` naming
  this target and the run number. Whether a handler listens is decided once,
  when the variant sets up.

  ## Randomness

  A new process draws its own entropy for `:rand`. Before anything runs, the
  variant seeds its own process RNG from the run's seed and its position among
  the targets:

      :rand.seed(:exsss, :erlang.phash2({Generator.run_seed(seed, run_number), target.index}, 4_294_967_296))

  The seed covers what runs in the variant process itself: the adapter's
  `setup/1`, `timeout/1` and `teardown/1`, injector and mock setup,
  projections, and checks. Two runs of one seed draw the same values there; two
  variants of one run draw different ones. It does not cover the adapter's
  `execute/3`, which the engine runs in a new Task per command attempt: that
  Task draws its own entropy, so a value drawn there is not reproduced by the
  seed. Stutter
  decisions use their own generator derived from the run seed (DR-029), passed
  as the executor's `rng_seed`.

  ## Observations and failures

  `advance_to/2` returns `{:ok, [{index, observation}]}` with one observation per
  stepped command:

    * `{:ok, events}` - the event values of the command's `:injected` log entries
      followed by its `:command` entries, in fold order (for a `:probe` or
      `:async` command, its settled events)

  Anything that ends the variant returns `{:failed, failure}`, where `failure`
  is `%{kind: kind, root: index | nil, reason: reason}`:

    * `kind: :execution_failed` - the adapter raised (`reason` is the exception),
      or answered `{:error, _}`, or the command could not be executed (`reason`
      is the `%PropertyDamage.Failure{}`)
    * `kind: :check_failed` - a check failed (`reason` is the
      `%PropertyDamage.Failure{}`); `root` is `nil` for a `:startup` check, and
      for a check that failed on a drained event it is the command that event
      belongs to, as `finish/1` reports it in `failed_at_index`
    * `kind: :setup_failed` - a setup command failed, a check failed on a
      setup command's event (wherever it was detected, an `@eventually` window
      opened during setup included), or the completion rule failed; `root` is
      `nil` and `reason` a `%PropertyDamage.Failure{}` of class `:setup`

  After a failure the variant steps nothing more: every later `advance_to/2`
  returns the same `{:failed, failure}`, and `finish/1` reports the failed run
  as `Executor.run/4` would. A run that goes on without the failed variant
  calls `retire/1` instead of `finish/1`.
  """

  use GenServer

  alias PropertyDamage.{
    EventQueue,
    Executor,
    Failure,
    Generator,
    ResourcePoller,
    StatePoller,
    Target,
    Telemetry
  }

  alias PropertyDamage.Executor.{Phases, Stepping}
  alias PropertyDamage.Runtime.RunServices

  @typedoc "An observation of one command, as `advance_to/2` reports it."
  @type observation :: {:ok, [struct()]}

  @typedoc "Why a variant stopped stepping."
  @type failure :: %{
          kind: :check_failed | :execution_failed | :setup_failed,
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
    * `:commands` (required) - the root commands, one per boundary
    * `:roots` - what this variant executes for each root, as a list per root
      of `{command, position}` steps: `nil` steps the root itself at its own
      position, a `PropertyDamage.Sequence.Position.leaf/2` position steps a
      leaf of the root's expansion there. Default: every root runs as itself.
    * `:placeholder_registry` (required) - this variant's copy of the registry
      built once per run from `:commands` (and from its leaves)
    * `:seed`, `:run_number` (required) - the campaign seed and the 0-based run
    * `:run_nonce` - the run nonce for client-minted values (DR-034)
    * `:mint_epoch` - the mint epoch for client-minted values (DR-034); default
      `0`, the exploration run's epoch. A re-execution of the same sequence
      passes a fresh epoch so it never sends the values an earlier execution
      sent.
    * `:stutter_config` - stutter configuration (default `nil`)
    * `:check_mode` - `:halt` | `:record` | `:log` | `:disabled` (default `:halt`)
    * `:measure_latency` - when `true`, record the wall-clock time of every
      command's `execute/3` (see `latencies/1`); default `false`
    * `:setup_commands`, `:teardown_commands` - the sequence's setup and
      teardown commands (see `run_setup/1` and `run_teardown/1`); default `[]`

  The process RNG is seeded here, before `setup/1` can call the adapter.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Start a variant process that is not linked to the caller, with the options of
  `start_link/1`.

  A crash of the variant then reaches the caller only as an exit from the call
  it is waiting on, which the caller can catch. The variant monitors the caller
  instead: when the caller exits, the variant releases everything it owns, as
  `stop/1` does, and exits too.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts), do: GenServer.start(__MODULE__, Keyword.put(opts, :owner, self()))

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
  Step the setup commands, in the variant process, after `setup/1`.

  Each one goes through `Stepping.step_setup/4`; then the event queue is
  drained, and every placeholder a setup command produces must be resolved in
  this variant's registry. Returns `:ok`, or `{:failed, failure}` with
  `kind: :setup_failed` (see the module doc); a failed variant steps nothing
  more.
  """
  @spec run_setup(pid()) :: :ok | {:failed, failure()}
  def run_setup(pid), do: GenServer.call(pid, :run_setup, :infinity)

  @doc """
  Step the teardown commands, in the variant process, once.

  Returns `{:ok, entries}`, the event-log entries the teardown commands added
  (`phase: :teardown`), and appends them to the finished result when there is
  one. A later call, and `stop/1`, run nothing more. A variant whose adapter
  `setup/1` failed has no teardown commands to run.
  """
  @spec run_teardown(pid()) :: {:ok, [PropertyDamage.EventLog.Entry.t()]}
  def run_teardown(pid), do: GenServer.call(pid, :run_teardown, :infinity)

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
  Evaluate the boundary observations `keys` (`{projection, function}`) of
  root `root` on this variant's current projection state, after `finish/1` on
  the finalized state.

  Each function is called with its projection's state and the root command.
  Returns `{:ok, %{key => result}}`, where a result is `{:value, value}`,
  `{:pending, reason}` (the function returned `{:pending, reason}`) or
  `{:raised, exception}`; or `{:failed, failure}` when the variant stopped.
  """
  @spec observe(pid(), non_neg_integer(), [{module(), atom()}]) ::
          {:ok, %{{module(), atom()} => term()}} | {:failed, failure()}
  def observe(pid, root, keys), do: GenServer.call(pid, {:observe, root, keys}, :infinity)

  @doc """
  Let the variant catch up at root `root`, the boundary it stopped at, while
  a comparison waits for it.

  With `:drain` the variant folds the events waiting in its queue
  (`Stepping.drain/2`, async checks included). With `:reread` it first
  executes root `root` again through the engine (a `:probe` read whose answer
  may have changed: its per-command settle applies, and the new events are
  appended to the log under the same command index), then drains. Either way,
  an `@eventually` check whose window expired since the last request fails
  the variant now (under `check_mode: :halt`).

  After `finish/1`, `:drain` changes nothing and returns `{:ok, 0}`, while
  `:reread` still executes the root: finalizing stopped the variant's pollers,
  not the system under test. The re-read's events are folded into the
  finished result and its checks run, as before the end; a poller it starts
  is stopped at once, since finalization already awaited the run's windows.
  `observe/3` and `finish/1` then report the result with the re-read in it.

  Returns `{:ok, delivered}`, the number of log entries the call added, or
  `{:failed, failure}`.
  """
  @spec catch_up(pid(), non_neg_integer(), :drain | :reread) ::
          {:ok, non_neg_integer()} | {:failed, failure()}
  def catch_up(pid, root, mode), do: GenServer.call(pid, {:catch_up, root, mode}, :infinity)

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
  Finalize a variant that failed, for a run that goes on without it.

  Finalizes the failed run as `finish/1` does, which stops every poller the
  variant started, then runs the model's `@check at: :teardown` checks on the
  failed state. A run that ends with its failure skips those checks, as
  `PropertyDamage.Executor.run/4` does; a retired variant runs them, because
  it leaves while the system keeps being exercised by the other targets.
  Call `stop/1` afterwards to tear the adapter down.

  Returns `{:ok, result, teardown_failures}`: the result `finish/1` reports,
  and a `%PropertyDamage.Failure{}` per `:teardown` check that failed (a
  check that raised holds `{exception, stacktrace}` as its reason). Returns
  `{:error, :not_failed}` for a variant that did not fail.
  """
  @spec retire(pid()) :: {:ok, Executor.result(), [Failure.t()]} | {:error, :not_failed}
  def retire(pid), do: GenServer.call(pid, :retire, :infinity)

  @doc """
  Release everything the variant owns, in the variant process, then exit.

  Runs the teardown commands when `run_teardown/1` did not, then stops the
  pollers, tears the mocks and injectors down, stops the event queue, and
  calls the adapter's `teardown/1` (best-effort: a raising teardown is
  logged). Returns `:ok` once all of that is done.
  """
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.call(pid, :stop, :infinity)

  @doc """
  The wall-clock time of every adapter call so far, as `[{key, microseconds}]` in
  execution order, when the variant was started with `measure_latency: true`
  (otherwise `[]`). The key is the root's index, or `{index, leaf}` for a leaf
  of the root's expansion.

  A command's time is what a client of the target experiences: the wall-clock
  of the adapter's `execute/3`, every retry of a `:probe` or `:async` command
  and the waits between them included, and nothing after the adapter answered
  (projections, checks and stutter are not timed). A command that never reached
  the adapter (a nemesis command, an unresolved placeholder) has no entry.
  """
  @spec latencies(pid()) :: [
          {non_neg_integer() | {non_neg_integer(), non_neg_integer()}, non_neg_integer()}
        ]
  def latencies(pid), do: GenServer.call(pid, :latencies, :infinity)

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

    owner_ref =
      case Keyword.get(opts, :owner) do
        nil -> nil
        owner -> Process.monitor(owner)
      end

    state = %{
      target: target,
      model: Keyword.fetch!(opts, :model),
      commands: opts |> Keyword.fetch!(:commands) |> List.to_tuple(),
      roots: opts |> Keyword.get(:roots) |> root_steps(Keyword.fetch!(opts, :commands)),
      setup_commands: Keyword.get(opts, :setup_commands, []),
      teardown_commands: Keyword.get(opts, :teardown_commands, []),
      teardown_entries: nil,
      placeholder_registry: Keyword.fetch!(opts, :placeholder_registry),
      run_seed: run_seed,
      run_number: run_number,
      run_nonce: Keyword.get(opts, :run_nonce),
      mint_epoch: Keyword.get(opts, :mint_epoch, 0),
      stutter_config: Keyword.get(opts, :stutter_config),
      check_mode: Keyword.get(opts, :check_mode, :halt),
      measure_latency: Keyword.get(opts, :measure_latency, false),
      latencies: [],
      owner_ref: owner_ref,
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

  def handle_call(:run_setup, _from, %{phase: :ready} = state) do
    {reply, state} = run_setup_commands(state)
    {:reply, reply, state}
  end

  def handle_call(:run_setup, _from, %{phase: :halted} = state),
    do: {:reply, {:failed, state.failure}, state}

  def handle_call(:run_setup, _from, state),
    do: {:reply, {:error, not_steppable(state)}, state}

  def handle_call(:run_teardown, _from, state) do
    state = run_teardown_commands(state)
    {:reply, {:ok, state.teardown_entries}, state}
  end

  def handle_call({:advance_to, boundary}, _from, %{phase: :ready} = state) do
    {reply, state} = advance(state, boundary)
    {:reply, reply, state}
  end

  def handle_call({:advance_to, _boundary}, _from, %{phase: :halted} = state),
    do: {:reply, {:failed, state.failure}, state}

  def handle_call({:advance_to, _boundary}, _from, state),
    do: {:reply, {:error, not_steppable(state)}, state}

  def handle_call({:observe, root, keys}, _from, %{phase: phase} = state)
      when phase in [:ready, :finished] do
    projections =
      if phase == :finished, do: state.result.projections, else: state.exec.projections

    command = elem(state.commands, root)
    {:reply, {:ok, Map.new(keys, &{&1, observe_key(&1, projections, command)})}, state}
  end

  def handle_call({:observe, _root, _keys}, _from, %{phase: :halted} = state),
    do: {:reply, {:failed, state.failure}, state}

  def handle_call({:catch_up, _root, :drain}, _from, %{phase: :finished} = state),
    do: {:reply, {:ok, 0}, state}

  def handle_call({:catch_up, root, :reread}, _from, %{phase: :finished} = state) do
    {reply, state} = reread_finished(state, root)
    {:reply, reply, state}
  end

  def handle_call({:catch_up, root, mode}, _from, %{phase: :ready} = state) do
    {reply, state} = catch_up_at(state, root, mode)
    {:reply, reply, state}
  end

  def handle_call({:catch_up, _root, _mode}, _from, %{phase: :halted} = state),
    do: {:reply, {:failed, state.failure}, state}

  def handle_call(:snapshot, _from, state), do: {:reply, state.exec, state}

  def handle_call(:finish, _from, %{phase: phase} = state) when phase in [:ready, :halted] do
    # Poller results that arrived between requests were taken out of the
    # mailbox; put them back so finalization's receive sees them.
    state.stash |> Enum.reverse() |> Enum.each(&send(self(), &1))

    result =
      state.halted |> Kernel.||(state.exec) |> Stepping.finalize(state.ctx) |> attribute(state)

    {:reply, result, %{state | phase: :finished, result: result, stash: []}}
  end

  def handle_call(:finish, _from, %{phase: :finished} = state),
    do: {:reply, state.result, state}

  def handle_call(:retire, _from, %{phase: :halted} = state) do
    state.stash |> Enum.reverse() |> Enum.each(&send(self(), &1))
    result = state.halted |> Stepping.finalize(state.ctx) |> attribute(state)
    failures = teardown_check_failures(state.exec)
    {:reply, {:ok, result, failures}, %{state | phase: :finished, result: result, stash: []}}
  end

  def handle_call(:retire, _from, state), do: {:reply, {:error, :not_failed}, state}

  def handle_call(:finish, _from, state), do: {:reply, {:error, :not_set_up}, state}

  def handle_call(:latencies, _from, state),
    do: {:reply, Enum.reverse(state.latencies), state}

  def handle_call(:stop, _from, state) do
    state = best_effort_teardown(state)
    release(state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({tag, _id, _result} = message, state)
      when tag in [:poller_result, :resource_poller_result] do
    {:noreply, %{state | stash: [message | state.stash]}}
  end

  # The process that started the variant with start/1 is gone: nobody will
  # call stop/1, so release everything now.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state)
      when ref != nil do
    release(state)
    {:stop, :normal, state}
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
        mint_epoch: state.mint_epoch,
        on_resource_poller_start: guard_now_fun(state.guardian),
        telemetry:
          Telemetry.engine_context(
            %{index: state.target.index, name: state.target.name},
            state.run_number
          )
      )

    ctx = %Stepping.Context{
      model: state.model,
      adapter: state.target.adapter,
      adapter_context: adapter_context,
      event_queue: state.event_queue,
      target_name: state.target.name
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
  # Setup and teardown commands
  # ==========================================================================

  # Steps every setup command, drains, then applies the completion rule
  # (`Executor.Phases.run_setup/4`). Any failure halts the variant with a
  # setup failure.
  defp run_setup_commands(state) do
    on_step = fn exec ->
      guard_pollers(%{state | exec: exec})
      exec
    end

    case Phases.run_setup(state.setup_commands, state.exec, state.ctx, on_step) do
      {:ok, exec} ->
        {:ok, %{state | exec: exec}}

      {:failed, reason, failed} ->
        halted = halt_setup(state, failed, reason)
        {{:failed, halted.failure}, halted}
    end
  end

  defp halt_setup(state, failed, reason) do
    guard_pollers(%{
      state
      | phase: :halted,
        exec: failed,
        halted: {:failed, nil, reason, failed},
        failure: %{kind: :setup_failed, root: nil, reason: reason}
    })
  end

  # Steps the teardown commands once. A variant whose adapter `setup/1`
  # failed has no context to run them in.
  defp run_teardown_commands(%{teardown_entries: entries} = state) when is_list(entries),
    do: state

  defp run_teardown_commands(%{ctx: nil} = state), do: %{state | teardown_entries: []}

  defp run_teardown_commands(state) do
    {exec, entries} = Phases.run_teardown(state.teardown_commands, state.exec, state.ctx)

    result =
      case state.result do
        nil -> nil
        result -> %{result | event_log: result.event_log ++ entries}
      end

    %{state | exec: exec, teardown_entries: entries, result: result}
  end

  # `stop/1` must reach the adapter's teardown/1 even when a teardown command
  # escapes the engine (an exit from the adapter's task).
  defp best_effort_teardown(state) do
    run_teardown_commands(state)
  rescue
    exception ->
      require Logger
      Logger.warning("Teardown commands raised: " <> Exception.message(exception))
      %{state | teardown_entries: []}
  catch
    _kind, _reason -> %{state | teardown_entries: []}
  end

  # A finished result whose failure belongs to a setup command (an
  # `@eventually` window a setup command opened, a check on its drained
  # event) reports it as the setup failure it is, with no root index.
  defp attribute(result, state), do: Phases.attribute(result, state.setup_commands)

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

  # Steps every command of root `index`: the root itself, or the leaves of the
  # expansion this variant runs for it, in order.
  defp step_root(state, index) do
    before = state.exec

    state.roots
    |> elem(index)
    |> Enum.reduce_while({:cont, state}, fn {command, position}, {:cont, state} ->
      case step_command(state, command, index, position) do
        {:cont, state} -> {:cont, {:cont, state}}
        {:halt, state} -> {:halt, {:halt, state}}
      end
    end)
    |> case do
      {:cont, state} ->
        {:cont, state, {:ok, root_events(state.exec.event_log, before.event_log, index)}}

      {:halt, state} ->
        {:halt, state}
    end
  end

  defp step_command(state, command, index, position) do
    stepped =
      case position do
        nil -> Stepping.step(command, index, state.exec, state.ctx)
        leaf -> Stepping.step_leaf(command, index, leaf, state.exec, state.ctx)
      end

    state = record_latency(state, latency_key(index, position), stepped)

    case stepped do
      {:ok, exec, _outcome} ->
        {:cont, after_step(state, exec, index)}

      {:error, failure, failed, outcome} ->
        {:halt,
         halt(state, {:failed, index, failure, failed}, failure_of(index, failure, outcome))}
    end
  end

  defp latency_key(index, nil), do: index
  defp latency_key(index, %{offset: leaf}), do: {index, leaf}

  # The commands of each root, as `{command, position}` steps: by default
  # every root runs as itself at its own position (`nil`).
  defp root_steps(nil, commands), do: commands |> Enum.map(&[{&1, nil}]) |> List.to_tuple()
  defp root_steps(roots, _commands), do: List.to_tuple(roots)

  # ==========================================================================
  # Boundary observations
  # ==========================================================================

  defp observe_key({projection, function} = _key, projections, command) do
    case apply(projection, function, [Map.fetch!(projections, projection), command]) do
      {:pending, reason} -> {:pending, reason}
      value -> {:value, value}
    end
  rescue
    exception -> {:raised, exception}
  end

  defp catch_up_at(state, root, mode) do
    log_before = length(state.exec.event_log)

    stepped =
      case mode do
        :reread -> reread_root(state, root)
        :drain -> {:cont, state}
      end

    with {:cont, state} <- stepped,
         {{:ok, _observed}, state} <- finish_advance({state, []}, root),
         {:ok, state} <- surface_expired_eventually(state) do
      {{:ok, length(state.exec.event_log) - log_before}, state}
    else
      {:halt, state} -> {{:failed, state.failure}, state}
      {{:failed, _failure} = failed, state} -> {failed, state}
    end
  end

  # Executes a root again, as `step_root/2` does, without recording its
  # latency: a re-read is the comparison's, not the client's.
  defp reread_root(state, index) do
    case step_root(%{state | measure_latency: false}, index) do
      {:cont, stepped, _observation} ->
        {:cont, %{stepped | measure_latency: state.measure_latency}}

      {:halt, halted} ->
        {:halt, %{halted | measure_latency: state.measure_latency}}
    end
  end

  # A re-read after `finish/1`. Finalizing stopped the variant's pollers, not
  # the system under test, so the root is executed again exactly as before the
  # end, on an executor state rebuilt from the finished result: settle applies,
  # the events are appended and folded, and the step's checks run. A poller
  # the re-read starts is stopped at once, because finalization already
  # awaited the run's windows and nothing would await a new one. The finished
  # result takes the new events, projections and check results, so `observe/3`
  # and `finish/1` see them; a failure turns it into the failed result.
  #
  # A variant that has not halted re-reads, as before the end. Under
  # `check_mode: :record` that includes a variant whose result holds a check
  # failure an earlier re-read recorded: the recorded failure does not stop
  # it, so every variant keeps re-reading alike.
  defp reread_finished(%{halted: nil, result: result} = state, root) do
    log_before = length(result.event_log)
    state = %{state | phase: :ready, exec: finished_exec(state.exec, result)}

    case reread_root(state, root) do
      {:cont, state} ->
        Stepping.stop_pollers(state.exec)
        exec = %{state.exec | active_pollers: [], active_resource_pollers: []}
        result = refinished_result(result, exec)
        delivered = length(result.event_log) - log_before
        {{:ok, delivered}, %{state | phase: :finished, exec: exec, result: result}}

      {:halt, state} ->
        result = Stepping.finalize(state.halted, state.ctx)
        {{:failed, state.failure}, %{state | phase: :finished, result: result}}
    end
  end

  # A variant that halted steps nothing more.
  defp reread_finished(state, _root), do: {{:ok, 0}, state}

  # The executor state a finished run left: the result holds what
  # finalization folded and checked after the last request.
  defp finished_exec(exec, result) do
    %{
      exec
      | projections: result.projections,
        event_log: Enum.reverse(result.event_log),
        check_counters: result.check_counters,
        check_failures: Enum.reverse(result.check_failures),
        command_fold_ordinals: result.command_fold_ordinals,
        fold_counter: next_fold(exec.fold_counter, result),
        active_pollers: [],
        active_resource_pollers: []
    }
  end

  # The next fold ordinal after everything finalization folded.
  defp next_fold(counter, result) do
    folded =
      for(%{fold_index: index} when is_integer(index) <- result.event_log, do: index + 1) ++
        Enum.map(Map.values(result.command_fold_ordinals), &(&1 + 1))

    Enum.max([counter | folded])
  end

  defp refinished_result(result, exec) do
    %{
      result
      | event_log: Enum.reverse(exec.event_log),
        executed: exec.executed,
        projections: exec.projections,
        check_counters: exec.check_counters,
        check_failures: Enum.reverse(exec.check_failures),
        command_fold_ordinals: exec.command_fold_ordinals,
        success: exec.check_failures == []
    }
  end

  # An `@eventually` poller whose window expired reported its timeout to this
  # process, which keeps poller results until `finish/1` replays them. Under
  # `check_mode: :halt` the timeout fails the variant now, at the command whose
  # event opened the window, instead of at the end of the run.
  defp surface_expired_eventually(%{check_mode: :halt} = state) do
    state = collect_poller_results(state)
    active = MapSet.new(state.exec.active_pollers, & &1.id)

    expired =
      Enum.find(Enum.reverse(state.stash), fn
        {:poller_result, id, {:timeout, _id, _info}} -> MapSet.member?(active, id)
        _other -> false
      end)

    case expired do
      nil ->
        {:ok, state}

      {:poller_result, id, {:timeout, _id, info} = result} ->
        failure = Failure.poll_timeout(info)
        root = Map.get(info.triggered_by, :command_index)

        exec = %{
          state.exec
          | active_pollers: Enum.reject(state.exec.active_pollers, &(&1.id == id))
        }

        state = %{state | stash: List.delete(state.stash, {:poller_result, id, result})}

        state =
          halt(state, {:failed, root, failure, exec}, %{
            kind: :check_failed,
            root: root,
            reason: failure
          })

        {{:failed, state.failure}, state}
    end
  end

  defp surface_expired_eventually(state), do: {:ok, state}

  defp collect_poller_results(state) do
    receive do
      {tag, _id, _result} = message when tag in [:poller_result, :resource_poller_result] ->
        collect_poller_results(%{state | stash: [message | state.stash]})
    after
      0 -> state
    end
  end

  defp record_latency(%{measure_latency: false} = state, _index, _stepped), do: state

  defp record_latency(state, key, stepped) do
    case elem(stepped, tuple_size(stepped) - 2).last_execute_us do
      nil -> state
      elapsed -> %{state | latencies: [{key, elapsed} | state.latencies]}
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

    failure =
      case attributed_root(failed_state, failure.root) do
        {:setup, offset} ->
          %{
            kind: :setup_failed,
            root: nil,
            reason: Phases.check_failure(state.setup_commands, offset, failure.reason)
          }

        root ->
          %{failure | root: root}
      end

    guard_pollers(%{
      state
      | phase: :halted,
        exec: failed_state,
        halted: failed,
        failure: failure
    })
  end

  # A check that fails on a drained event belongs to the command whose event it
  # was (DR-025), which may be earlier than the command being stepped. The
  # engine records that command on the failed state, and the finished result
  # reports it as `failed_at_index`; the failure's root says the same.
  defp attributed_root(%{async_failed_index: :unset}, root), do: root
  defp attributed_root(%{async_failed_index: attributed}, _root), do: attributed

  # The event values of one command's :injected entries, then its :command
  # entries, in fold order. Only entries the step added are examined.
  defp root_events(event_log, log_before, index) do
    added =
      event_log
      |> Enum.take(length(event_log) - length(log_before))
      |> Enum.reverse()
      |> Enum.filter(&(&1.phase == :root and &1.command_index == index))

    for(%{source: :injected, event: event} <- added, do: event) ++
      for %{source: :command, event: event} <- added, do: event
  end

  # The `@check at: :teardown` checks on a failed variant's state, as
  # `%Failure{}`s in check order.
  defp teardown_check_failures(exec) do
    case Executor.run_phase_checks(exec, :teardown) do
      {:halt, name, reason, _counters} ->
        [Failure.check_failed(name, reason)]

      {:ok, recorded, _counters} ->
        recorded
        |> Enum.reverse()
        |> Enum.map(&Failure.check_failed(&1.check_name, &1.reason))
    end
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

      {:guard_now, pid, from, reply_ref} ->
        send(from, {reply_ref, :guarded})
        guardian_loop(ref, MapSet.put(pids, pid))

      {:DOWN, ^ref, :process, _pid, _reason} ->
        Enum.each(pids, &Process.exit(&1, :kill))
    end
  end

  defp guard(state, pids), do: send(state.guardian, {:guard, pids})

  # A resource poller is linked to the per-command Task that started it, not to
  # the variant, and the Task may finish while the step is still running (a
  # settle retry sleeps in the variant). The engine calls this function from
  # that Task as soon as the poller started, and the Task waits until the
  # guardian holds the pid, so a kill at any later moment reaps the poller.
  defp guard_now_fun(guardian) do
    fn pid ->
      reply_ref = make_ref()
      send(guardian, {:guard_now, pid, self(), reply_ref})

      receive do
        {^reply_ref, :guarded} -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  defp guard_pollers(%{exec: exec} = state) do
    pids =
      Enum.map(exec.active_pollers, & &1.pid) ++
        Enum.map(exec.active_resource_pollers, & &1.pid)

    if pids != [], do: guard(state, pids)
    state
  end
end
