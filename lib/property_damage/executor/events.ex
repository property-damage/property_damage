defmodule PropertyDamage.Executor.Events do
  @moduledoc false
  # Event folding for the executor (DR-029).
  #
  # The single home for "fold an observed item into projection state and record
  # it in the event log": `update_projections/2` (the projection reducer, which
  # turns a raising `apply/2` into a tagged `ProjectionError`) plus the four
  # source-specific drains that build the right `EventLog.Entry` and call it:
  # command-own events, injector/resource-poller queue events, and mock-service
  # events. This is a leaf module: it depends only on the event/queue/registry
  # types, not back on Executor.

  alias PropertyDamage.EventLog.Entry
  alias PropertyDamage.EventQueue
  alias PropertyDamage.MockServiceRegistry

  # Update all projections with a command or event.
  # apply/2 can raise to signal transition invariant violations.
  def update_projections(projections, item) do
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

  # Process events from command execution
  def process_events(events, source, command_index, event_log, projections, branch_id) do
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

  def process_injector_events(event_queue, event_log, projections, branch_id, matchers \\ [])

  def process_injector_events(nil, event_log, projections, _branch_id, _matchers),
    do: {projections, event_log}

  def process_injector_events(event_queue, event_log, projections, branch_id, matchers) do
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
            # Regular injector adapter entry. DR-030: correlate against the
            # registered awaits matchers, attributing the event to the declaring
            # command's index (ambient `nil` when nothing matches).
            %Entry{
              timestamp: queue_entry.timestamp,
              command_index: correlate(queue_entry.event, matchers),
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

  # DR-030 correlation: return the `command_index` of the first-registered await
  # whose `match` predicate accepts the event (deterministic tie-break). When
  # several matchers accept the same event, log an overlap diagnostic once and
  # keep the first. An event matching nothing folds as ambient (`nil`).
  defp correlate(_event, []), do: nil

  defp correlate(event, matchers) do
    case Enum.filter(matchers, fn %{match: match} -> safe_match(match, event) end) do
      [] ->
        nil

      [%{command_index: index}] ->
        index

      [%{command_index: index} = first | rest] ->
        require Logger

        Logger.warning(
          "Await overlap: #{inspect(event.__struct__)} matched #{length(rest) + 1} commands " <>
            "(indices #{inspect(Enum.map([first | rest], & &1.command_index))}); " <>
            "attributing to first-registered command #{index}."
        )

        index
    end
  end

  # A matcher must be total; guard a raising predicate so one bad matcher cannot
  # crash the drain (treat a raise as "does not match").
  defp safe_match(match, event) do
    match.(event) == true
  rescue
    _ -> false
  end

  # Flush and process events from mock service adapters
  def process_mock_events(nil, _command_index, event_log, projections, _branch_id),
    do: {projections, event_log}

  def process_mock_events(mock_registry, command_index, event_log, projections, branch_id) do
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
end
