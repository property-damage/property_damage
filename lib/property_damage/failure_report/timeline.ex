defmodule PropertyDamage.FailureReport.Timeline do
  @moduledoc false

  alias PropertyDamage.{FailureReport, RunTrace, Sequence}
  alias PropertyDamage.FailureReport.SourceBadge

  @doc """
  Format a timeline visualization for a failure report.

  ## Options

  - `:color` - Use ANSI colors (default: true)
  - `:show_events` - Show events alongside commands (default: false)
  """
  @spec format(FailureReport.t(), keyword()) :: String.t()
  def format(%FailureReport{} = report, opts \\ []) do
    sequence = FailureReport.shrunk_sequence(report)
    color = Keyword.get(opts, :color, true)

    # The failure marker is resolved once via the failing step's canonical
    # position (nil for a non-localized failure).
    failed? = failed_position_predicate(report)

    format_linear_sequence(sequence, failed?, color)
  end

  @doc """
  Format a timeline directly from a sequence.

  Useful for visualizing sequences without a full failure report.
  """
  @spec format_sequence(Sequence.t(), keyword()) :: String.t()
  def format_sequence(%Sequence{} = sequence, opts \\ []) do
    color = Keyword.get(opts, :color, true)
    failed_at_index = Keyword.get(opts, :failed_at_index)
    failed? = executor_index_predicate(failed_at_index)

    format_linear_sequence(sequence, failed?, color)
  end

  # A predicate `(Position.t() -> boolean())` marking the single failed position,
  # resolved via `failure_step/1`. A non-localized failure yields a predicate
  # that is false everywhere.
  defp failed_position_predicate(%FailureReport{} = report) do
    case FailureReport.failure_step(report) do
      %RunTrace.Step{position: position} -> &(&1 == position)
      nil -> fn _position -> false end
    end
  end

  # A predicate treating `index` as an executor command index. Used by the
  # report-less `format_sequence/2` path.
  defp executor_index_predicate(nil), do: fn _position -> false end

  defp executor_index_predicate(index) do
    fn
      %Sequence.Position{section: :prefix, offset: offset} ->
        offset == index

      # Setup and teardown commands are not roots: no root index names them.
      %Sequence.Position{} ->
        false
    end
  end

  # ============================================================================
  # Linear Timeline
  # ============================================================================

  defp format_linear_sequence(sequence, failed?, color) do
    indexed = Sequence.indexed(sequence)
    count = length(indexed)

    header = """
    #{bold(color)}Timeline (Linear Execution)#{reset(color)}
    #{dim(color)}════════════════════════════════════════════════════#{reset(color)}

    """

    body =
      indexed
      |> Enum.map_join("\n", fn {position, idx, cmd} ->
        format_linear_command(
          cmd,
          idx,
          failed?.(position),
          idx == count - 1,
          color
        )
      end)

    header <> body <> "\n\n#{dim(color)}► = Failure point#{reset(color)}"
  end

  defp format_linear_command(cmd, idx, is_failure, is_last, color) do
    connector = if is_last, do: "└─", else: "├─"
    marker = if is_failure, do: " #{red(color)}►#{reset(color)}", else: ""
    idx_str = "[#{idx}]"
    cmd_name = short_module_name(cmd.__struct__)
    fields = format_fields_short(cmd)

    "#{connector}#{idx_str} #{cyan(color)}#{cmd_name}#{reset(color)} #{dim(color)}#{fields}#{reset(color)}#{marker}"
  end

  # ============================================================================
  # Event Timeline (shows events alongside commands)
  # ============================================================================

  @doc """
  Format an event timeline showing commands and their resulting events.

  This is useful for understanding the causal relationship between
  commands and the events they produced.

  ## Options

  - `:color` - Use ANSI colors (default: true)
  - `:max_events_per_command` - Max events to show per command (default: 5)
  """
  @spec format_event_timeline(FailureReport.t(), keyword()) :: String.t()
  def format_event_timeline(%FailureReport{} = report, opts \\ []) do
    color = Keyword.get(opts, :color, true)
    max_events = Keyword.get(opts, :max_events_per_command, 5)

    header = """
    #{bold(color)}Command → Event Timeline#{reset(color)}
    #{dim(color)}════════════════════════════════════════════════════#{reset(color)}

    """

    # This is the entry-level view: unlike the plain command timeline it renders
    # each event's source badge (see `FailureReport.SourceBadge`). It reads the
    # command-attributed entries straight off `FailureReport.steps/1` — each
    # `Step.entries` is the full `EventLog.Entry` list, so the per-event
    # provenance (source) and the failure marker
    # (`step.failed?`) come from the failure-query interface rather than from a
    # private re-walk of `event_log`.
    body = format_event_timeline_body(report, max_events, color)

    # Events from injectors and other async sources carry command_index: nil;
    # they belong to no command but must still appear rather than vanish.
    async_entries = FailureReport.async_entries(report)
    async_section = format_async_events(async_entries, max_events, color)

    header <> body <> async_section
  end

  defp format_event_timeline_body(report, max_events, color) do
    report
    |> FailureReport.steps()
    |> Enum.map_join("\n\n", fn step ->
      format_command_with_events(
        step.command,
        step.flattened_index,
        step.entries,
        step.failed?,
        max_events,
        color
      )
    end)
  end

  defp format_async_events([], _max_events, _color), do: ""

  defp format_async_events(events, max_events, color) do
    events_text =
      events
      |> Enum.take(max_events)
      |> Enum.map_join("\n", fn entry ->
        event_name = short_module_name(entry.event.__struct__)
        source = format_source_badge(entry.source, color)
        "    #{source} #{green(color)}→#{reset(color)} #{event_name}"
      end)

    truncated =
      if length(events) > max_events do
        "\n    #{dim(color)}... and #{length(events) - max_events} more events#{reset(color)}"
      else
        ""
      end

    "\n\n#{bold(color)}ASYNC#{reset(color)} #{dim(color)}(no command index)#{reset(color)}\n" <>
      events_text <> truncated
  end

  # `events` are the full log entries attributed to this command (by
  # command_index), which INCLUDE command output plus any mock/stutter
  # events recorded against it — so each is rendered with its source badge,
  # keeping retry events visually distinct from SUT output.
  defp format_command_with_events(cmd, idx, events, is_failure, max_events, color) do
    marker = if is_failure, do: " #{red(color)}► FAILURE#{reset(color)}", else: ""
    cmd_name = short_module_name(cmd.__struct__)

    cmd_line =
      "#{bold(color)}[#{idx}]#{reset(color)} #{cyan(color)}#{cmd_name}#{reset(color)}#{marker}"

    if events == [] do
      cmd_line <> "\n    #{dim(color)}(no events)#{reset(color)}"
    else
      events_text =
        events
        |> Enum.take(max_events)
        |> Enum.map_join("\n", fn entry ->
          event_name = short_module_name(entry.event.__struct__)
          source = format_source_badge(entry.source, color)

          "    #{source} #{green(color)}→#{reset(color)} #{event_name}"
        end)

      truncated =
        if length(events) > max_events do
          "\n    #{dim(color)}... and #{length(events) - max_events} more events#{reset(color)}"
        else
          ""
        end

      cmd_line <> "\n" <> events_text <> truncated
    end
  end

  defp format_source_badge(source, color), do: SourceBadge.badge(source, color)

  # ============================================================================
  # Helpers
  # ============================================================================

  defp short_module_name(module) do
    module |> Module.split() |> List.last()
  end

  defp format_fields_short(cmd) do
    fields =
      cmd
      |> Map.from_struct()
      |> Enum.take(3)
      |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{inspect_very_short(v)}" end)

    "{#{fields}}"
  end

  defp inspect_very_short(value) when is_binary(value) and byte_size(value) > 10 do
    "\"#{String.slice(value, 0, 7)}...\""
  end

  defp inspect_very_short(value) do
    value |> inspect(limit: 2) |> String.slice(0, 15)
  end

  # ANSI helpers
  defp red(true), do: "\e[31m"
  defp red(false), do: ""

  defp green(true), do: "\e[32m"
  defp green(false), do: ""

  defp cyan(true), do: "\e[36m"
  defp cyan(false), do: ""

  defp bold(true), do: "\e[1m"
  defp bold(false), do: ""

  defp dim(true), do: "\e[2m"
  defp dim(false), do: ""

  defp reset(true), do: "\e[0m"
  defp reset(false), do: ""
end
