defmodule PropertyDamage.FailureReport.Timeline do
  @moduledoc false

  alias PropertyDamage.{FailureReport, Sequence}

  @default_column_width 20

  @doc """
  Format a timeline visualization for a failure report.

  ## Options

  - `:color` - Use ANSI colors (default: true)
  - `:column_width` - Width of each branch column (default: 20)
  - `:show_events` - Show events alongside commands (default: false)
  """
  @spec format(FailureReport.t(), keyword()) :: String.t()
  def format(%FailureReport{} = report, opts \\ []) do
    sequence = report.shrunk_sequence
    color = Keyword.get(opts, :color, true)
    column_width = Keyword.get(opts, :column_width, @default_column_width)

    # The failure marker is resolved once, branch-aware, via the failing step's
    # canonical position (nil for a non-localized failure). Renderers compare
    # each command's position to it rather than comparing a flattened ordinal to
    # the executor `failed_at_index` (which diverge for branch failures).
    failed? = failed_position_predicate(report)

    if Sequence.branching?(sequence) do
      format_branching_sequence(sequence, failed?, color, column_width)
    else
      format_linear_sequence(sequence, failed?, color)
    end
  end

  @doc """
  Format a timeline directly from a sequence.

  Useful for visualizing sequences without a full failure report.
  """
  @spec format_sequence(Sequence.t(), keyword()) :: String.t()
  def format_sequence(%Sequence{} = sequence, opts \\ []) do
    color = Keyword.get(opts, :color, true)
    column_width = Keyword.get(opts, :column_width, @default_column_width)
    failed_at_index = Keyword.get(opts, :failed_at_index)

    # Without a report there is no branch attribution, so the raw index is
    # treated as an executor command index and marks every branch that has a
    # command there.
    failed? = executor_index_predicate(sequence, failed_at_index)

    if Sequence.branching?(sequence) do
      format_branching_sequence(sequence, failed?, color, column_width)
    else
      format_linear_sequence(sequence, failed?, color)
    end
  end

  # A predicate `(Position.t() -> boolean())` marking the single failed position,
  # resolved via `failure_step/1`. A non-localized failure yields a predicate
  # that is false everywhere.
  defp failed_position_predicate(%FailureReport{} = report) do
    case FailureReport.failure_step(report) do
      %FailureReport.Step{position: position} -> &(&1 == position)
      nil -> fn _position -> false end
    end
  end

  # A predicate treating `index` as an executor command index (prefix commands
  # `0..len-1`; every branch continues from `len(prefix)`; suffix after the sum
  # of branch lengths), matching any branch at that offset. Used by the
  # report-less `format_sequence/2` path.
  defp executor_index_predicate(_sequence, nil), do: fn _position -> false end

  defp executor_index_predicate(%Sequence{} = sequence, index) do
    prefix_len = length(sequence.prefix)

    branch_count =
      case sequence.branches do
        nil -> 0
        branches -> branches |> Enum.map(&length/1) |> Enum.sum()
      end

    fn
      %Sequence.Position{section: :prefix, offset: offset} ->
        offset == index

      %Sequence.Position{section: {:branch, _b}, offset: offset} ->
        prefix_len + offset == index

      %Sequence.Position{section: :suffix, offset: offset} ->
        prefix_len + branch_count + offset == index
    end
  end

  # ============================================================================
  # Linear Timeline
  # ============================================================================

  defp format_linear_sequence(sequence, failed?, color) do
    indexed = Sequence.indexed(sequence)
    count = length(indexed)

    header = """
    #{bold(color)}Timeline (Linear Execution)#{reset()}
    #{dim(color)}════════════════════════════════════════════════════#{reset()}

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

    header <> body <> "\n\n#{dim(color)}► = Failure point#{reset()}"
  end

  defp format_linear_command(cmd, idx, is_failure, is_last, color) do
    connector = if is_last, do: "└─", else: "├─"
    marker = if is_failure, do: " #{red(color)}►#{reset()}", else: ""
    idx_str = "[#{idx}]"
    cmd_name = short_module_name(cmd.__struct__)
    fields = format_fields_short(cmd)

    "#{connector}#{idx_str} #{cyan(color)}#{cmd_name}#{reset()} #{dim(color)}#{fields}#{reset()}#{marker}"
  end

  # ============================================================================
  # Branching Timeline
  # ============================================================================

  defp format_branching_sequence(sequence, failed?, color, column_width) do
    %Sequence{prefix: prefix, branches: branches, suffix: suffix} = sequence

    sections = []

    # Header
    sections = [
      """
      #{bold(color)}Timeline (Parallel Execution)#{reset()}
      #{dim(color)}════════════════════════════════════════════════════#{reset()}
      """
      | sections
    ]

    # Prefix section
    sections =
      if prefix != [] do
        prefix_text = format_prefix_section(prefix, failed?, color)

        [
          "\n#{yellow(color)}PREFIX#{reset()} #{dim(color)}(sequential)#{reset()}\n#{prefix_text}"
          | sections
        ]
      else
        sections
      end

    # Branches section
    sections =
      if branches && branches != [] do
        prefix_len = length(prefix)

        branch_text =
          format_branches_section(
            branches,
            prefix_len,
            failed?,
            color,
            column_width
          )

        [
          "\n#{yellow(color)}BRANCHES#{reset()} #{dim(color)}(parallel)#{reset()}\n#{branch_text}"
          | sections
        ]
      else
        sections
      end

    # Suffix section. Executor suffix indices continue after the SUM of all
    # branch lengths (each branch restarts at prefix_len, but the suffix
    # does not).
    sections =
      if suffix != [] do
        prefix_len = length(prefix)
        branch_cmd_count = if branches, do: Enum.map(branches, &length/1) |> Enum.sum(), else: 0
        suffix_start = prefix_len + branch_cmd_count
        suffix_text = format_suffix_section(suffix, suffix_start, failed?, color)

        [
          "\n#{yellow(color)}SUFFIX#{reset()} #{dim(color)}(sequential)#{reset()}\n#{suffix_text}"
          | sections
        ]
      else
        sections
      end

    # Legend
    sections = ["\n#{dim(color)}► = Failure point#{reset()}" | sections]

    sections
    |> Enum.reverse()
    |> Enum.join("")
  end

  defp format_prefix_section(prefix, failed?, color) do
    prefix
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {cmd, idx} ->
      position = %Sequence.Position{section: :prefix, offset: idx}
      format_linear_command(cmd, idx, failed?.(position), idx == length(prefix) - 1, color)
    end)
  end

  defp format_branches_section(
         branches,
         prefix_len,
         failed?,
         color,
         column_width
       ) do
    num_branches = length(branches)

    # Find max branch length
    max_len = branches |> Enum.map(&length/1) |> Enum.max()

    # Header row
    header_cells =
      branches
      |> Enum.with_index()
      |> Enum.map(fn {_, idx} ->
        pad_cell("Branch #{idx}", column_width)
      end)

    header =
      "┌" <>
        Enum.join(List.duplicate(String.duplicate("─", column_width), num_branches), "┬") <> "┐\n"

    header = header <> "│" <> Enum.join(header_cells, "│") <> "│\n"

    header =
      header <>
        "├" <>
        Enum.join(List.duplicate(String.duplicate("─", column_width), num_branches), "┼") <> "┤\n"

    # Command rows
    rows =
      for row_idx <- 0..(max_len - 1) do
        cells =
          branches
          |> Enum.with_index()
          |> Enum.map(fn {branch_cmds, branch_idx} ->
            # The cell displays the executor command index (branches restart at
            # prefix_len); the failure marker is decided by the cell's canonical
            # position, so overlapping branch indices stay disambiguated.
            cmd_idx = prefix_len + row_idx
            position = %Sequence.Position{section: {:branch, branch_idx}, offset: row_idx}

            case Enum.at(branch_cmds, row_idx) do
              nil ->
                pad_cell("", column_width)

              cmd ->
                format_branch_cell(cmd, cmd_idx, failed?.(position), color, column_width)
            end
          end)

        "│" <> Enum.join(cells, "│") <> "│"
      end

    footer =
      "└" <>
        Enum.join(List.duplicate(String.duplicate("─", column_width), num_branches), "┴") <> "┘"

    header <> Enum.join(rows, "\n") <> "\n" <> footer
  end

  defp format_branch_cell(cmd, idx, is_failure, color, column_width) do
    marker = if is_failure, do: " #{red(color)}►#{reset()}", else: ""
    cmd_name = short_module_name(cmd.__struct__)

    # Calculate visible length
    visible_len = String.length("[#{idx}] #{cmd_name}") + if(is_failure, do: 2, else: 0)

    if visible_len > column_width - 2 do
      truncated = String.slice("[#{idx}] #{cmd_name}", 0, column_width - 5) <> ".."

      " #{cyan(color)}#{truncated}#{reset()}#{marker}" <>
        String.duplicate(" ", max(0, column_width - visible_len - 1))
    else
      " #{cyan(color)}[#{idx}] #{cmd_name}#{reset()}#{marker}" <>
        String.duplicate(" ", column_width - visible_len - 1)
    end
  end

  defp format_suffix_section(suffix, start_idx, failed?, color) do
    suffix
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {cmd, offset} ->
      position = %Sequence.Position{section: :suffix, offset: offset}

      format_linear_command(
        cmd,
        start_idx + offset,
        failed?.(position),
        offset == length(suffix) - 1,
        color
      )
    end)
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
    #{bold(color)}Command → Event Timeline#{reset()}
    #{dim(color)}════════════════════════════════════════════════════#{reset()}

    """

    # This is the entry-level view: unlike the plain command timeline it renders
    # each event's source badge (CMD/NEM/MOC/STU/INJ) and branch. It reads the
    # command-attributed entries straight off `FailureReport.steps/1` — each
    # `Step.entries` is the full, branch-aware-grouped `EventLog.Entry` list, so
    # the per-event provenance (source, branch_id) and the failure marker
    # (`step.failed?`) come from the failure-query interface rather than from a
    # private re-walk of `event_log`.
    body = format_event_timeline_body(report, max_events, color)

    # Events from injectors and other async sources carry command_index: nil;
    # they belong to no command but must still appear rather than vanish.
    async_entries = Enum.filter(report.event_log, &(&1.command_index == nil))
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
        "    #{source} #{green(color)}→#{reset()} #{event_name}"
      end)

    truncated =
      if length(events) > max_events do
        "\n    #{dim(color)}... and #{length(events) - max_events} more events#{reset()}"
      else
        ""
      end

    "\n\n#{bold(color)}ASYNC#{reset()} #{dim(color)}(no command index)#{reset()}\n" <>
      events_text <> truncated
  end

  # `events` are the full log entries attributed to this command (by
  # command_index), which INCLUDE command output plus any mock/nemesis/stutter
  # events recorded against it — so each is rendered with its source badge and
  # branch, keeping fault-injected/retry events visually distinct from SUT
  # output.
  defp format_command_with_events(cmd, idx, events, is_failure, max_events, color) do
    marker = if is_failure, do: " #{red(color)}► FAILURE#{reset()}", else: ""
    cmd_name = short_module_name(cmd.__struct__)
    cmd_line = "#{bold(color)}[#{idx}]#{reset()} #{cyan(color)}#{cmd_name}#{reset()}#{marker}"

    if events == [] do
      cmd_line <> "\n    #{dim(color)}(no events)#{reset()}"
    else
      events_text =
        events
        |> Enum.take(max_events)
        |> Enum.map_join("\n", fn entry ->
          event_name = short_module_name(entry.event.__struct__)
          source = format_source_badge(entry.source, color)
          branch = if entry.branch_id, do: " #{dim(color)}B#{entry.branch_id}#{reset()}", else: ""
          "    #{source}#{branch} #{green(color)}→#{reset()} #{event_name}"
        end)

      truncated =
        if length(events) > max_events do
          "\n    #{dim(color)}... and #{length(events) - max_events} more events#{reset()}"
        else
          ""
        end

      cmd_line <> "\n" <> events_text <> truncated
    end
  end

  defp format_source_badge(source, color) do
    case source do
      :command -> "#{green(color)}CMD#{reset()}"
      :injector -> "#{yellow(color)}INJ#{reset()}"
      :nemesis -> "#{red(color)}NEM#{reset()}"
      :mock -> "#{magenta(color)}MOC#{reset()}"
      :stutter -> "#{blue(color)}STU#{reset()}"
      _ -> "#{dim(color)}???#{reset()}"
    end
  end

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

  defp pad_cell(text, width) do
    visible_len = String.length(text)
    padding = max(0, width - visible_len - 1)
    " #{text}" <> String.duplicate(" ", padding)
  end

  # ANSI helpers
  defp red(true), do: "\e[31m"
  defp red(false), do: ""

  defp green(true), do: "\e[32m"
  defp green(false), do: ""

  defp yellow(true), do: "\e[33m"
  defp yellow(false), do: ""

  defp blue(true), do: "\e[34m"
  defp blue(false), do: ""

  defp magenta(true), do: "\e[35m"
  defp magenta(false), do: ""

  defp cyan(true), do: "\e[36m"
  defp cyan(false), do: ""

  defp bold(true), do: "\e[1m"
  defp bold(false), do: ""

  defp dim(true), do: "\e[2m"
  defp dim(false), do: ""

  defp reset, do: "\e[0m"
end
