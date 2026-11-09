defmodule PropertyDamage.Executor do
  @moduledoc """
  Executes command sequences against the System Under Test.

  A run goes through `PropertyDamage.Runner`. The commands of a run execute one
  at a time through `PropertyDamage.Executor.Stepping`, which resolves
  placeholders, updates projections, runs checks, and collects events from both
  the adapter and injector adapters. This module holds the result and check mode
  types of a run, and `execute_raw/3`, which runs commands without a model.

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

  alias PropertyDamage.{EventQueue, Failure, PlaceholderRegistry, Sequence}

  alias PropertyDamage.EventLog.Entry

  alias PropertyDamage.Executor.{Step, Timeout}

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
