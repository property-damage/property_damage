defmodule PropertyDamage.Executor do
  @moduledoc """
  Executes command sequences against the System Under Test.

  The Executor is the core engine that runs command sequences, resolves placeholders,
  updates projections, runs checks, and collects events from both the adapter
  and injector adapters.

  `run/4` is the one-target path without the per-root boundary drain. A run
  goes through `PropertyDamage.Runner`, not through `run/4`.

  ## Sequence Execution

  Commands are executed one after another:

      %Sequence{prefix: [cmd1, cmd2, cmd3]}

  Execution: cmd1 → cmd2 → cmd3

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

  ## Results

  Returns a result struct containing:

  - `:success` - Boolean indicating if all checks passed
  - `:event_log` - Complete event log
  - `:projections` - Final projection states
  - `:failed_at_index` - Index where check failed (nil if success)
  - `:failure_reason` - Check failure reason (nil if success)
  """

  alias PropertyDamage.{EventQueue, Failure, PlaceholderRegistry, Sequence, Stutter}

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.Log.Cap

  alias PropertyDamage.Executor.{Finalization, Phases, Step, Stepping, Timeout}
  alias PropertyDamage.Executor.Stepping.Context

  alias PropertyDamage.Runtime
  alias PropertyDamage.Sequence.Position

  @typedoc """
  Check mode controls whether and how check failures are handled.

  - `:disabled` - Skip all checks (useful for load testing focused on throughput)
  - `:halt` (default) - Stop execution at first failure, return failure
  - `:record` - Record failures and continue, return all failures at end
  - `:log` - Log failures as warnings and continue
  """
  @type check_mode :: :disabled | :halt | :record | :log

  @typedoc """
  Result of executing a command sequence.
  """
  @type result :: %{
          success: boolean(),
          event_log: [Entry.t()],
          executed: %{term() => struct()},
          projections: %{module() => any()},
          projections_before: map() | nil,
          failed_at_index: non_neg_integer() | nil,
          failure_reason: term() | nil,
          stacktrace: Exception.stacktrace() | nil,
          check_failures: [map()] | nil,
          check_counters: map(),
          command_fold_ordinals: %{term() => non_neg_integer()},
          logs: PropertyDamage.Log.logs()
        }

  @doc """
  Execute a command sequence using the given model and adapter.

  This is the one-target engine path that runs a sequence without the
  per-root boundary drain. It handles the full lifecycle (adapter setup,
  command execution, injector event draining and cleanup) and is used by the
  executor's own tests. A run does not execute this way: every run goes
  through `PropertyDamage.Runner`, which drains the event queue after each
  root.

  ## Parameters

  - `sequence` - Sequence struct to execute
  - `model` - Model module defining projections and checks
  - `adapter` - Adapter module for SUT interaction
  - `opts` - Options (see below)

  ## Options

  - `:config` - Config passed to adapter.setup/1
  - `:event_queue` - EventQueue pid for injector events (optional)
  - `:stutter_config` - Stutter.Config for idempotency testing (optional)
  - `:keep_attempts` - How many of a step's last settle or stutter attempts keep
    their log lines, besides the first attempt's (default 3, DR-054)
  - `:mock_registry` - MockServiceRegistry pid for mock service support (optional)
  - `:check_mode` - How to handle checks (`:disabled`, `:halt`, `:record`, `:log`). Default: `:halt`
  - `:telemetry` - The context command and check telemetry is emitted with
    (`PropertyDamage.Telemetry`); default `nil`, which emits none
  - `:setup_commands` - The run's setup commands (`Sequence.setup_commands/1`),
    stepped after the `@check at: :startup` checks and before the sequence;
    default `[]`
  - `:teardown_commands` - The run's teardown commands
    (`Sequence.teardown_commands/1`), stepped after the run is finalized (its
    `@check at: :teardown` checks included) and before the adapter's
    `teardown/1`; default `[]`

  ## Order

  The adapter's `setup/1`, the `@check at: :startup` checks, the setup
  commands, the sequence, the finalization (pollers awaited, queue settled, `@check at:
  :teardown` checks), the teardown commands, and the adapter's `teardown/1`.

  The teardown commands run whenever `setup/1` succeeded, whatever happened
  after it. A failure in the setup phase (a setup command that could not run,
  a check that failed on a setup command's event, an `external()` a setup
  command produces that stayed unresolved) ends the run before the sequence:
  the result has `success: false`, `failed_at_index: nil` and a
  `failure_reason` of kind `:setup_failed`. The teardown commands' event-log
  entries (`phase: :teardown`) are appended to the result's event log.

  ## Returns

  - `{:ok, result}` - Execution completed (check result.success for pass/fail)
  - `{:error, reason}` - Setup or execution infrastructure failed
  """
  @spec run(Sequence.t() | list(), module(), module(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def run(sequence_or_commands, model, adapter, opts \\ [])

  def run(%Sequence{} = sequence, model, adapter, opts) do
    case set_up_and_run(sequence, model, adapter, opts) do
      {:not_set_up, setup_result, _setup_lines} -> setup_result
      ran -> ran
    end
  end

  # Backwards compatibility: accept list of commands as linear sequence
  def run(commands, model, adapter, opts) when is_list(commands) do
    run(Sequence.linear(commands), model, adapter, opts)
  end

  # The adapter's setup/1 and teardown/1 are execution points of their own;
  # their log lines are kept under :adapter_setup and :adapter_teardown
  # (DR-054). A setup/1 that does not answer `{:ok, context}` comes back as
  # `{:not_set_up, its answer, its lines}`.
  defp set_up_and_run(sequence, model, adapter, opts) do
    config = Keyword.get(opts, :config, %{})
    {setup_result, setup_lines} = PropertyDamage.Log.inline(fn -> adapter.setup(config) end)

    case setup_result do
      {:ok, adapter_context} ->
        run_set_up(sequence, model, adapter, adapter_context, setup_lines, opts)

      not_set_up ->
        {:not_set_up, not_set_up, setup_lines}
    end
  end

  defp run_set_up(sequence, model, adapter, adapter_context, setup_lines, opts) do
    event_queue = Keyword.get(opts, :event_queue)
    stutter_config = Keyword.get(opts, :stutter_config)
    mock_registry = Keyword.get(opts, :mock_registry)
    check_mode = Keyword.get(opts, :check_mode, :halt)
    external_markers = Keyword.get(opts, :external_markers, [])
    rng_seed = Keyword.get(opts, :rng_seed)
    # Client-minted run-scoped value inputs (DR-034): the run nonce and the
    # mint epoch for this SUT execution (default epoch 0 = the recorded run).
    mint = {Keyword.get(opts, :run_nonce), Keyword.get(opts, :mint_epoch, 0)}
    telemetry = Keyword.get(opts, :telemetry)
    teardown_ctx = %Context{model: model, adapter: adapter, adapter_context: adapter_context}

    result =
      try do
        env = %{
          model: model,
          adapter: adapter,
          adapter_context: adapter_context,
          event_queue: event_queue,
          stutter_config: stutter_config,
          mock_registry: mock_registry,
          check_mode: check_mode,
          external_markers: external_markers,
          rng_seed: rng_seed,
          mint: mint,
          telemetry: telemetry,
          setup_commands: Keyword.get(opts, :setup_commands, []),
          teardown_commands: Keyword.get(opts, :teardown_commands, []),
          keep_attempts: Keyword.get(opts, :keep_attempts, Cap.default_keep_attempts()),
          logs: PropertyDamage.Log.append(%{}, :adapter_setup, setup_lines)
        }

        execute_run(sequence, env)
      catch
        kind, reason ->
          Step.teardown_adapter(teardown_ctx)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    teardown_lines = Step.teardown_adapter(teardown_ctx)

    {:ok,
     %{result | logs: PropertyDamage.Log.append(result.logs, :adapter_teardown, teardown_lines)}}
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
  - `check_mode` - How to handle check failures (optional, default: `:halt`)

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
          check_mode(),
          [atom()],
          integer() | nil,
          {non_neg_integer() | nil, non_neg_integer()},
          map() | nil
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
        check_mode \\ :halt,
        external_markers \\ [],
        rng_seed \\ nil,
        mint \\ {nil, 0},
        telemetry \\ nil
      )

  def execute_sequence(
        sequence_or_commands,
        model,
        adapter,
        adapter_context,
        event_queue,
        stutter_config,
        mock_registry,
        check_mode,
        external_markers,
        rng_seed,
        mint,
        telemetry
      ) do
    sequence =
      if is_list(sequence_or_commands),
        do: Sequence.linear(sequence_or_commands),
        else: sequence_or_commands

    execute_run(sequence, %{
      model: model,
      adapter: adapter,
      adapter_context: adapter_context,
      event_queue: event_queue,
      stutter_config: stutter_config,
      mock_registry: mock_registry,
      check_mode: check_mode,
      external_markers: external_markers,
      rng_seed: rng_seed,
      mint: mint,
      telemetry: telemetry,
      setup_commands: [],
      teardown_commands: []
    })
  end

  # ============================================================================
  # Run Phases
  # ============================================================================

  # One run against an adapter context that is already set up: the startup
  # checks, the setup commands, the sequence, the
  # finalization, then the teardown commands. `env` holds the run's inputs.
  defp execute_run(%Sequence{} = sequence, env) do
    {run_nonce, mint_epoch} = env.mint

    initial_state =
      Step.new_state(env.model,
        event_queue: env.event_queue,
        stutter_config: env.stutter_config,
        mock_registry: env.mock_registry,
        check_mode: env.check_mode,
        external_markers: env.external_markers,
        placeholder_registry: sequence.registry,
        rng_seed: env.rng_seed,
        run_nonce: run_nonce,
        mint_epoch: mint_epoch,
        telemetry: env.telemetry
      )

    # The adapter setup/1's log lines, when the run set the adapter up itself.
    initial_state = %{
      initial_state
      | logs: Map.get(env, :logs, %{}),
        keep_attempts: Map.get(env, :keep_attempts, Cap.default_keep_attempts())
    }

    ctx = %Context{
      model: env.model,
      adapter: env.adapter,
      adapter_context: env.adapter_context,
      event_queue: env.event_queue,
      target_name: env.telemetry && env.telemetry.variant.name
    }

    ended =
      with {:ok, state} <- Step.run_startup_checks(initial_state),
           {:ok, state} <- Phases.run_setup(env.setup_commands, state, ctx) do
        execute_body(sequence, state, ctx)
      else
        {:failed, nil, _failure, _state} = failed -> failed
        {:failed, failure, failed_state} -> {:failed, nil, failure, failed_state}
      end

    result = finalize_or_tear_down(ended, env, ctx)
    {state, entries} = Phases.run_teardown(env.teardown_commands, ended_state(ended), ctx)
    # The teardown commands' log lines join the result's (DR-054).
    %{
      result
      | event_log: result.event_log ++ entries,
        logs: PropertyDamage.Log.merge(result.logs, state.logs)
    }
  end

  # A raise, throw or exit during finalization still runs the teardown
  # commands before it propagates, as `teardown/1` runs on that path too.
  defp finalize_or_tear_down(ended, env, ctx) do
    ended
    |> Finalization.finalize_result()
    |> Phases.attribute(env.setup_commands)
  catch
    kind, reason ->
      Phases.run_teardown(env.teardown_commands, ended_state(ended), ctx)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp ended_state({:failed, _index, _reason, state}), do: state
  defp ended_state(state), do: state

  # The sequence itself, from the state the setup phase left, one
  # `Stepping.step/4` per command. Returns the state (or the failed tuple) to
  # finalize.
  defp execute_body(%Sequence{} = sequence, state, ctx) do
    sequence
    |> Sequence.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(state, fn {command, index}, state ->
      case Stepping.step(command, index, state, ctx) do
        {:ok, new_state, _outcome} ->
          {:cont, new_state}

        {:error, reason, failed_state, _outcome} ->
          {:halt, {:failed, index, reason, failed_state}}
      end
    end)
  end

  # ============================================================================
  # Model-Free Execution (for static regression tests)
  # ============================================================================

  @doc """
  Execute a command sequence without model projections or checks.

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
  - `{:error, %PropertyDamage.Failure{}}` - a `:adapter_error` (with `partial_events`)

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
    # %Placeholder{} keyed to its producer's linear prefix position.
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
            {:halt, {:error, Failure.adapter_error(reason, flatten_event_chunks(state.events))}}
        end
      end)

    case result do
      {:error, _} = error -> error
      %{events: chunks} -> {:ok, flatten_event_chunks(chunks)}
    end
  end

  # Collect every %Placeholder{} carried in the command list and register it, so
  # the registry's producer_link maps each producer position to its placeholder
  # ids for PlaceholderRegistry.capture/3.
  defp build_placeholder_registry(commands), do: PlaceholderRegistry.build(commands)

  # Event chunks are prepended per command (newest-first); restore execution
  # order and concatenate in a single pass.
  defp flatten_event_chunks(chunks), do: chunks |> Enum.reverse() |> Enum.concat()

  # Execute a single command in raw mode (no projections/checks)
  defp execute_raw_command(command, index, adapter, adapter_context, event_queue, registry) do
    # Resolve placeholders in command (only for structs that might carry them)
    resolved_result =
      if is_struct(command) do
        Step.resolve_placeholders(command, registry)
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
            Step.unavailable_runtime("in Executor.execute_raw/3 (no event queue configured)")
          end

        # Execute via adapter (bounded by adapter.timeout/1, DR-032). The
        # command logs into a sink of its own; raw mode builds no report, so
        # its lines are dropped (DR-054).
        {result, _lines} =
          PropertyDamage.Log.collect(fn sink ->
            runtime = %{runtime | log: PropertyDamage.Log.writer(sink, 1)}
            Timeout.execute(adapter, resolved_command, adapter_context, runtime)
          end)

        case result do
          {:ok, events} ->
            # Capture external() values this command produced, keyed by its linear
            # position, so later commands resolve them (DR-021).
            new_registry = PlaceholderRegistry.capture(registry, Position.prefix(index), events)

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
        {:error, Failure.placeholder_resolution(reason)}
    end
  end
end
