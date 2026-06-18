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

    if Sequence.branching?(sequence) do
      format_branching_timeline(sequence, report, color, column_width)
    else
      format_linear_timeline(sequence, report, color)
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

    if Sequence.branching?(sequence) do
      # Without a report there is no branch attribution; nil marks the
      # failing index in every branch that has a command there
      format_branching_sequence(sequence, failed_at_index, nil, color, column_width)
    else
      format_linear_sequence(sequence, failed_at_index, color)
    end
  end

  # ============================================================================
  # Linear Timeline
  # ============================================================================

  defp format_linear_timeline(sequence, report, color) do
    format_linear_sequence(sequence, report.failed_at_index, color)
  end

  defp format_linear_sequence(sequence, failed_at_index, color) do
    commands = Sequence.to_list(sequence)

    header = """
    #{bold(color)}Timeline (Linear Execution)#{reset()}
    #{dim(color)}════════════════════════════════════════════════════#{reset()}

    """

    body =
      commands
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {cmd, idx} ->
        format_linear_command(
          cmd,
          idx,
          idx == failed_at_index,
          idx == length(commands) - 1,
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

  defp format_branching_timeline(sequence, report, color, column_width) do
    format_branching_sequence(
      sequence,
      report.failed_at_index,
      report.branch_id,
      color,
      column_width
    )
  end

  defp format_branching_sequence(sequence, failed_at_index, failed_branch_id, color, column_width) do
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
        prefix_text = format_prefix_section(prefix, failed_at_index, color)

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
            failed_at_index,
            failed_branch_id,
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
        suffix_text = format_suffix_section(suffix, suffix_start, failed_at_index, color)

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

  defp format_prefix_section(prefix, failed_at_index, color) do
    prefix
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {cmd, idx} ->
      format_linear_command(cmd, idx, idx == failed_at_index, idx == length(prefix) - 1, color)
    end)
  end

  defp format_branches_section(
         branches,
         prefix_len,
         failed_at_index,
         failed_branch_id,
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
            cmd_idx = prefix_len + row_idx

            case Enum.at(branch_cmds, row_idx) do
              nil ->
                pad_cell("", column_width)

              cmd ->
                # Branch indices overlap, so the marker needs branch
                # attribution when available
                is_failure =
                  cmd_idx == failed_at_index and
                    (failed_branch_id == nil or branch_idx == failed_branch_id)

                format_branch_cell(cmd, cmd_idx, is_failure, color, column_width)
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

  defp format_suffix_section(suffix, start_idx, failed_at_index, color) do
    suffix
    |> Enum.with_index(start_idx)
    |> Enum.map_join("\n", fn {cmd, idx} ->
      format_linear_command(
        cmd,
        idx,
        idx == failed_at_index,
        idx == start_idx + length(suffix) - 1,
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

    commands = Sequence.to_list(report.shrunk_sequence)

    # Group events by command index
    events_by_cmd =
      report.event_log
      |> Enum.group_by(& &1.command_index)

    header = """
    #{bold(color)}Command → Event Timeline#{reset()}
    #{dim(color)}════════════════════════════════════════════════════#{reset()}

    """

    body =
      commands
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn {cmd, idx} ->
        events = Map.get(events_by_cmd, idx, [])
        is_failure = idx == report.failed_at_index
        format_command_with_events(cmd, idx, events, is_failure, max_events, color)
      end)

    # Events from injectors and other async sources carry command_index: nil;
    # they are not attributable to a command but must still appear, not vanish.
    async_section = format_async_events(Map.get(events_by_cmd, nil, []), max_events, color)

    header <> body <> async_section
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
