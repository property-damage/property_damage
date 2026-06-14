defmodule PropertyDamage.Diff do
  @moduledoc """
  Diff-based debugging for comparing passing and failing test runs.

  When a test fails intermittently or after code changes, understanding
  exactly what changed between a passing and failing run is crucial.
  This module provides tools to capture execution traces and compare them.

  ## Workflow

  1. **Capture traces** during execution (passing and failing)
  2. **Compare traces** to find divergence points
  3. **Display differences** in a clear, actionable format

  ## Usage

  ### Compare Two Failure Reports

      passing_report = PropertyDamage.run(model: M, adapter: A, seed: 123)
      failing_report = PropertyDamage.run(model: M, adapter: A, seed: 456)

      diff = PropertyDamage.Diff.compare_reports(passing_report, failing_report)
      IO.puts(PropertyDamage.Diff.format(diff))

  ### Compare Event Logs

      diff = PropertyDamage.Diff.compare_events(passing_events, failing_events)

  ### Compare States

      diff = PropertyDamage.Diff.compare_states(state_before, state_after)

  ## Output Example

      ╔══════════════════════════════════════════════════════════════╗
      ║                    EXECUTION DIFF                            ║
      ╚══════════════════════════════════════════════════════════════╝

      Divergence at command 3: Withdraw(amount: 150)

      ┌─ Events ──────────────────────────────────────────────────────┐
      │ PASS: [WithdrawSucceeded(balance: 50)]                        │
      │ FAIL: [WithdrawFailed(reason: :insufficient_funds)]           │
      └───────────────────────────────────────────────────────────────┘

      ┌─ State Before Command 3 ──────────────────────────────────────┐
      │   balance: 200 → 50                                           │
      │   + pending_withdrawals: 150                                  │
      └───────────────────────────────────────────────────────────────┘
  """

  alias PropertyDamage.{FailureReport, Sequence, EventLog.Entry}

  @type trace :: %{
          commands: [struct()],
          events: [Entry.t()],
          states: [map()],
          result: :pass | {:fail, term()}
        }

  @type diff_result :: %{
          divergence_index: non_neg_integer() | nil,
          divergence_command: struct() | nil,
          command_diffs: [command_diff()],
          event_diffs: [event_diff()],
          state_diffs: [state_diff()],
          summary: String.t()
        }

  @type command_diff :: %{
          index: non_neg_integer(),
          left: struct() | nil,
          right: struct() | nil,
          status: :same | :different | :missing_left | :missing_right
        }

  @type event_diff :: %{
          command_index: non_neg_integer(),
          left_events: [struct()],
          right_events: [struct()],
          status: :same | :different | :extra_left | :extra_right
        }

  @type state_diff :: %{
          command_index: non_neg_integer(),
          field: atom(),
          left_value: term(),
          right_value: term(),
          status: :same | :changed | :added | :removed
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Compare two failure reports to find differences.

  ## Parameters

  - `left` - First report (typically passing or earlier)
  - `right` - Second report (typically failing or later)

  ## Returns

  A diff_result map with divergence information.
  """
  @spec compare_reports(FailureReport.t() | map(), FailureReport.t() | map()) :: diff_result()
  def compare_reports(left, right) do
    left_trace = trace_from_report(left)
    right_trace = trace_from_report(right)
    compare_traces(left_trace, right_trace)
  end

  @doc """
  Compare two execution traces.

  ## Parameters

  - `left` - First trace
  - `right` - Second trace

  ## Returns

  A diff_result map.
  """
  @spec compare_traces(trace(), trace()) :: diff_result()
  def compare_traces(left, right) do
    command_diffs = compare_commands(left.commands, right.commands)
    event_diffs = compare_event_logs(left.events, right.events)
    state_diffs = compare_state_sequences(left.states, right.states)

    divergence_index = find_divergence_index(command_diffs, event_diffs)

    divergence_command =
      if divergence_index do
        Enum.at(right.commands, divergence_index) || Enum.at(left.commands, divergence_index)
      end

    summary = generate_summary(divergence_index, divergence_command, event_diffs, state_diffs)

    %{
      divergence_index: divergence_index,
      divergence_command: divergence_command,
      command_diffs: command_diffs,
      event_diffs: event_diffs,
      state_diffs: state_diffs,
      summary: summary
    }
  end

  @doc """
  Compare two event logs.

  Groups events by command index and compares each group.
  """
  @spec compare_events([Entry.t()], [Entry.t()]) :: [event_diff()]
  def compare_events(left_events, right_events) do
    compare_event_logs(left_events, right_events)
  end

  @doc """
  Compare two state maps.

  Returns a list of field-level differences.
  """
  @spec compare_states(map(), map()) :: [state_diff()]
  def compare_states(left_state, right_state) do
    compare_state_maps(left_state, right_state, 0)
  end

  @doc """
  Format a diff result for display.

  ## Options

  - `:format` - Output format (`:terminal`, `:markdown`, `:json`)
  - `:max_value_length` - Truncate values longer than this (default: 60)
  - `:show_same` - Show identical items (default: false)
  """
  @spec format(diff_result(), keyword()) :: String.t()
  def format(diff, opts \\ []) do
    format_type = Keyword.get(opts, :format, :terminal)

    case format_type do
      :terminal -> format_terminal(diff, opts)
      :markdown -> format_markdown(diff, opts)
      :json -> format_json(diff)
    end
  end

  @doc """
  Create a trace from execution results.

  ## Parameters

  - `commands` - List of executed commands
  - `events` - Event log entries
  - `states` - List of state snapshots (one per command)
  - `result` - `:pass` or `{:fail, reason}`
  """
  @spec create_trace([struct()], [Entry.t()], [map()], :pass | {:fail, term()}) :: trace()
  def create_trace(commands, events, states, result) do
    %{
      commands: commands,
      events: events,
      states: states,
      result: result
    }
  end

  # ============================================================================
  # Comparison Logic
  # ============================================================================

  defp trace_from_report(%FailureReport{} = report) do
    commands = Sequence.to_list(report.shrunk_sequence)

    %{
      commands: commands,
      events: report.event_log,
      states: extract_state_sequence(report),
      result: {:fail, report.failure_reason}
    }
  end

  defp trace_from_report(%{} = map) do
    commands =
      if map[:shrunk_sequence] do
        Sequence.to_list(map.shrunk_sequence)
      else
        map[:commands] || []
      end

    %{
      commands: commands,
      events: map[:event_log] || map[:events] || [],
      states: map[:states] || [],
      result: map[:result] || :pass
    }
  end

  defp extract_state_sequence(%FailureReport{} = report) do
    # Build state sequence from what we have
    if report.state_before_failure && report.state_at_failure do
      [report.state_before_failure, report.state_at_failure]
    else
      []
    end
  end

  defp compare_commands(left, right) do
    max_len = max(length(left), length(right))

    for i <- 0..(max_len - 1) do
      left_cmd = Enum.at(left, i)
      right_cmd = Enum.at(right, i)

      status =
        cond do
          left_cmd == nil -> :missing_left
          right_cmd == nil -> :missing_right
          commands_equal?(left_cmd, right_cmd) -> :same
          true -> :different
        end

      %{
        index: i,
        left: left_cmd,
        right: right_cmd,
        status: status
      }
    end
  end

  defp commands_equal?(left, right) do
    left.__struct__ == right.__struct__ &&
      Map.delete(Map.from_struct(left), :__struct__) ==
        Map.delete(Map.from_struct(right), :__struct__)
  end

  defp compare_event_logs(left_events, right_events) do
    left_grouped = group_events_by_command(left_events)
    right_grouped = group_events_by_command(right_events)

    all_indices =
      (Map.keys(left_grouped) ++ Map.keys(right_grouped))
      |> Enum.uniq()
      |> Enum.sort()

    for idx <- all_indices do
      left_evts = Map.get(left_grouped, idx, [])
      right_evts = Map.get(right_grouped, idx, [])

      status =
        cond do
          left_evts == [] and right_evts != [] -> :extra_right
          left_evts != [] and right_evts == [] -> :extra_left
          events_equal?(left_evts, right_evts) -> :same
          true -> :different
        end

      %{
        command_index: idx,
        left_events: left_evts,
        right_events: right_evts,
        status: status
      }
    end
  end

  defp group_events_by_command(events) do
    events
    |> Enum.filter(&(&1.command_index != nil))
    |> Enum.group_by(& &1.command_index)
    |> Enum.map(fn {k, entries} -> {k, Enum.map(entries, & &1.event)} end)
    |> Map.new()
  end

  defp events_equal?(left, right) do
    length(left) == length(right) &&
      Enum.zip(left, right)
      |> Enum.all?(fn {l, r} ->
        l.__struct__ == r.__struct__ &&
          Map.delete(Map.from_struct(l), :__struct__) ==
            Map.delete(Map.from_struct(r), :__struct__)
      end)
  end

  defp compare_state_sequences(left_states, right_states) do
    max_len = max(length(left_states), length(right_states))

    for i <- 0..(max_len - 1)//1, reduce: [] do
      acc ->
        left_state = Enum.at(left_states, i, %{})
        right_state = Enum.at(right_states, i, %{})
        diffs = compare_state_maps(left_state, right_state, i)
        acc ++ diffs
    end
  end

  defp compare_state_maps(left, right, command_index) do
    all_keys = (Map.keys(left) ++ Map.keys(right)) |> Enum.uniq()

    for key <- all_keys, reduce: [] do
      acc ->
        left_val = Map.get(left, key)
        right_val = Map.get(right, key)

        status =
          cond do
            left_val == nil and right_val != nil -> :added
            left_val != nil and right_val == nil -> :removed
            left_val == right_val -> :same
            true -> :changed
          end

        if status == :same do
          acc
        else
          [
            %{
              command_index: command_index,
              field: key,
              left_value: left_val,
              right_value: right_val,
              status: status
            }
            | acc
          ]
        end
    end
  end

  defp find_divergence_index(command_diffs, event_diffs) do
    # Find first different command
    cmd_divergence =
      command_diffs
      |> Enum.find(fn d -> d.status != :same end)
      |> case do
        nil -> nil
        d -> d.index
      end

    # Find first different event
    event_divergence =
      event_diffs
      |> Enum.find(fn d -> d.status != :same end)
      |> case do
        nil -> nil
        d -> d.command_index
      end

    # Return the earliest divergence
    case {cmd_divergence, event_divergence} do
      {nil, nil} -> nil
      {nil, e} -> e
      {c, nil} -> c
      {c, e} -> min(c, e)
    end
  end

  defp generate_summary(divergence_index, divergence_command, event_diffs, state_diffs) do
    cond do
      divergence_index == nil ->
        "No differences found between traces."

      divergence_command != nil ->
        cmd_name =
          divergence_command.__struct__
          |> Module.split()
          |> List.last()

        event_diff = Enum.find(event_diffs, &(&1.command_index == divergence_index))

        event_summary =
          if event_diff && event_diff.status == :different do
            left_names = Enum.map_join(event_diff.left_events, ", ", &event_name/1)
            right_names = Enum.map_join(event_diff.right_events, ", ", &event_name/1)
            "Events differ: [#{left_names}] vs [#{right_names}]"
          else
            ""
          end

        state_changes =
          state_diffs
          |> Enum.filter(&(&1.command_index == divergence_index and &1.status != :same))
          |> length()

        state_summary =
          if state_changes > 0, do: "#{state_changes} state field(s) differ", else: ""

        parts =
          ["Divergence at command #{divergence_index}: #{cmd_name}", event_summary, state_summary]
          |> Enum.reject(&(&1 == ""))

        Enum.join(parts, ". ")

      true ->
        "Divergence at command #{divergence_index}"
    end
  end

  defp event_name(event) do
    event.__struct__ |> Module.split() |> List.last()
  end

  # ============================================================================
  # Formatting
  # ============================================================================

  defp format_terminal(diff, opts) do
    show_same = Keyword.get(opts, :show_same, false)
    max_len = Keyword.get(opts, :max_value_length, 60)

    header = """
    ╔══════════════════════════════════════════════════════════════════════╗
    ║                         EXECUTION DIFF                               ║
    ╚══════════════════════════════════════════════════════════════════════╝

    """

    summary = "Summary: #{diff.summary}\n\n"

    # Event differences
    event_section =
      diff.event_diffs
      |> Enum.filter(fn d -> show_same or d.status != :same end)
      |> format_event_diffs_terminal(max_len)

    # State differences
    state_section =
      diff.state_diffs
      |> Enum.filter(fn d -> show_same or d.status != :same end)
      |> format_state_diffs_terminal(max_len)

    header <> summary <> event_section <> state_section
  end

  defp format_event_diffs_terminal([], _max_len), do: ""

  defp format_event_diffs_terminal(diffs, max_len) do
    header = "┌─ Event Differences ─────────────────────────────────────────────────┐\n"

    rows =
      diffs
      |> Enum.map_join("", fn d ->
        left_str = format_events_short(d.left_events, max_len)
        right_str = format_events_short(d.right_events, max_len)
        status_icon = status_icon(d.status)

        "│ Cmd #{d.command_index} #{status_icon}: LEFT: #{left_str}\n│         RIGHT: #{right_str}\n"
      end)

    footer = "└──────────────────────────────────────────────────────────────────────┘\n\n"

    header <> rows <> footer
  end

  defp format_state_diffs_terminal([], _max_len), do: ""

  defp format_state_diffs_terminal(diffs, max_len) do
    header = "┌─ State Differences ─────────────────────────────────────────────────┐\n"

    rows =
      diffs
      |> Enum.group_by(& &1.command_index)
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map_join("", fn {idx, field_diffs} ->
        field_rows =
          field_diffs
          |> Enum.map_join("", fn d ->
            left_str = truncate(inspect(d.left_value), max_len)
            right_str = truncate(inspect(d.right_value), max_len)

            case d.status do
              :changed -> "│   #{d.field}: #{left_str} → #{right_str}\n"
              :added -> "│   + #{d.field}: #{right_str}\n"
              :removed -> "│   - #{d.field}: #{left_str}\n"
              _ -> ""
            end
          end)

        "│ After command #{idx}:\n#{field_rows}"
      end)

    footer = "└──────────────────────────────────────────────────────────────────────┘\n"

    header <> rows <> footer
  end

  defp format_events_short(events, max_len) do
    events
    |> Enum.map_join(", ", &event_name/1)
    |> truncate(max_len)
    |> case do
      "" -> "(none)"
      s -> "[#{s}]"
    end
  end

  defp status_icon(:same), do: "="
  defp status_icon(:different), do: "≠"
  defp status_icon(:extra_left), do: "←"
  defp status_icon(:extra_right), do: "→"
  defp status_icon(:added), do: "+"
  defp status_icon(:removed), do: "-"
  defp status_icon(:changed), do: "~"
  defp status_icon(_), do: "?"

  defp format_markdown(diff, opts) do
    show_same = Keyword.get(opts, :show_same, false)
    max_len = Keyword.get(opts, :max_value_length, 60)

    header = "# Execution Diff\n\n"
    summary = "**Summary:** #{diff.summary}\n\n"

    event_section =
      diff.event_diffs
      |> Enum.filter(fn d -> show_same or d.status != :same end)
      |> format_event_diffs_markdown(max_len)

    state_section =
      diff.state_diffs
      |> Enum.filter(fn d -> show_same or d.status != :same end)
      |> format_state_diffs_markdown(max_len)

    header <> summary <> event_section <> state_section
  end

  defp format_event_diffs_markdown([], _max_len), do: ""

  defp format_event_diffs_markdown(diffs, max_len) do
    header =
      "## Event Differences\n\n| Command | Status | Left Events | Right Events |\n|---------|--------|-------------|---------------|\n"

    rows =
      diffs
      |> Enum.map_join("\n", fn d ->
        left_str = format_events_short(d.left_events, max_len)
        right_str = format_events_short(d.right_events, max_len)
        "| #{d.command_index} | #{d.status} | #{left_str} | #{right_str} |"
      end)

    header <> rows <> "\n\n"
  end

  defp format_state_diffs_markdown([], _max_len), do: ""

  defp format_state_diffs_markdown(diffs, max_len) do
    header =
      "## State Differences\n\n| Command | Field | Status | Left | Right |\n|---------|-------|--------|------|-------|\n"

    rows =
      diffs
      |> Enum.map_join("\n", fn d ->
        left_str = truncate(inspect(d.left_value), max_len)
        right_str = truncate(inspect(d.right_value), max_len)
        "| #{d.command_index} | #{d.field} | #{d.status} | #{left_str} | #{right_str} |"
      end)

    header <> rows <> "\n"
  end

  defp format_json(diff) do
    %{
      divergence_index: diff.divergence_index,
      divergence_command:
        if(diff.divergence_command, do: inspect(diff.divergence_command), else: nil),
      summary: diff.summary,
      event_diffs:
        Enum.map(diff.event_diffs, fn d ->
          %{
            command_index: d.command_index,
            status: d.status,
            left_events: Enum.map(d.left_events, &inspect/1),
            right_events: Enum.map(d.right_events, &inspect/1)
          }
        end),
      state_diffs:
        Enum.map(diff.state_diffs, fn d ->
          %{
            command_index: d.command_index,
            field: d.field,
            status: d.status,
            left_value: inspect(d.left_value),
            right_value: inspect(d.right_value)
          }
        end)
    }
    |> Jason.encode!(pretty: true)
  end

  defp truncate(str, max_len) when byte_size(str) <= max_len, do: str
  defp truncate(str, max_len), do: String.slice(str, 0, max_len - 3) <> "..."
end
