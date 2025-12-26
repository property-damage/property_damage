defmodule PropertyDamage.FailureReport.Formatter do
  @moduledoc """
  Format failure reports for different output targets.

  Supports multiple output formats:

  - `:terminal` - ANSI-colored output for terminal display
  - `:markdown` - GitHub-flavored markdown for documentation
  - `:json` - Structured JSON for CI integration
  - `:compact` - Single-line summary for logs

  ## Usage

      # Terminal output (default)
      output = Formatter.format(report)
      IO.puts(output)

      # Markdown for GitHub issues
      markdown = Formatter.format(report, :markdown)
      File.write!("failure_report.md", markdown)

      # JSON for CI
      json = Formatter.format(report, :json)
      File.write!("failure_report.json", json)

  ## Customization

  You can customize formatting with options:

      Formatter.format(report, :terminal,
        show_event_log: true,
        show_state: true,
        max_events: 20,
        color: true
      )
  """

  alias PropertyDamage.{FailureReport, Sequence}

  @type format :: :terminal | :markdown | :json | :compact

  @doc """
  Format a failure report.

  ## Options

  - `:show_event_log` - Include full event log (default: true)
  - `:show_state` - Include projection states (default: true)
  - `:max_events` - Maximum events to show (default: 50)
  - `:max_commands` - Maximum commands to show in sequence (default: 20)
  - `:color` - Use ANSI colors for terminal (default: true)
  - `:indent` - Indentation for JSON (default: 2)
  """
  @spec format(FailureReport.t(), format(), keyword()) :: String.t()
  def format(report, format \\ :terminal, opts \\ [])

  def format(report, :terminal, opts), do: format_terminal(report, opts)
  def format(report, :markdown, opts), do: format_markdown(report, opts)
  def format(report, :json, opts), do: format_json(report, opts)
  def format(report, :compact, _opts), do: format_compact(report)

  # ============================================================================
  # Terminal Format (ANSI Colors)
  # ============================================================================

  defp format_terminal(report, opts) do
    color = Keyword.get(opts, :color, true)
    show_event_log = Keyword.get(opts, :show_event_log, true)
    show_state = Keyword.get(opts, :show_state, true)
    max_events = Keyword.get(opts, :max_events, 50)

    sections = [
      terminal_header(report, color),
      terminal_location(report, color),
      terminal_failure_reason(report, color),
      terminal_shrinking_stats(report, color),
      terminal_command_sequence(report, opts),
      if(show_state, do: terminal_state(report, color), else: nil),
      if(show_event_log, do: terminal_event_log(report, max_events, color), else: nil),
      terminal_reproduction(report, color)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp terminal_header(report, color) do
    type_summary = FailureReport.failure_type_summary(report)

    header =
      if color do
        """
        #{red()}╔══════════════════════════════════════════════════════════════════════╗
        ║#{reset()}#{bold()}#{red()}                         BUG DETECTED!                              #{reset()}#{red()}║
        ╚══════════════════════════════════════════════════════════════════════╝#{reset()}
        """
      else
        """
        ╔══════════════════════════════════════════════════════════════════════╗
        ║                         BUG DETECTED!                                ║
        ╚══════════════════════════════════════════════════════════════════════╝
        """
      end

    header <> "\n#{dim(color)}#{type_summary}#{reset()}\n"
  end

  defp terminal_location(report, color) do
    """
    #{section_header("Failure Location", color)}
    #{label("Run Number", color)}    #{report.run_number + 1}
    #{label("Command Index", color)} #{report.failed_at_index}
    #{label("Random Seed", color)}   #{report.seed}
    #{label("Timestamp", color)}     #{DateTime.to_string(report.timestamp)}
    """
  end

  defp terminal_failure_reason(report, color) do
    reason_text =
      case report.failure_type do
        :check_failed ->
          """
          #{label("Check", color)}         #{cyan(color)}#{report.check_name}#{reset()}
          #{label("Message", color)}
          #{indent_text(report.failure_message, "    ")}
          """

        :idempotency_violation ->
          format_idempotency_terminal(report, color)

        :linearization_failed ->
          """
          #{label("Type", color)}          Linearization Failed
          #{label("Details", color)}
          #{indent_text(report.failure_message, "    ")}
          """

        :branch_failure ->
          """
          #{label("Type", color)}          Branch Execution Failed
          #{label("Branch ID", color)}     #{report.branch_id}
          #{label("Details", color)}
          #{indent_text(report.failure_message, "    ")}
          """

        _ ->
          """
          #{label("Reason", color)}
          #{indent_text(inspect(report.failure_reason, pretty: true), "    ")}
          """
      end

    """
    #{section_header("Failure Details", color)}
    #{reason_text}
    """
  end

  defp format_idempotency_terminal(report, color) do
    violation = report.idempotency_violation

    if violation do
      attempts_text =
        violation.attempts
        |> Enum.map(fn att ->
          retry_label = if att.is_retry, do: " (retry)", else: " (original)"
          events_summary = Enum.map(att.events, &event_summary/1) |> Enum.join(", ")
          "  Attempt #{att.attempt}#{retry_label}: [#{events_summary}]"
        end)
        |> Enum.join("\n")

      diff_text = format_comparison_diff(violation.comparison_result, color)

      """
      #{label("Type", color)}          Idempotency Violation
      #{label("Command", color)}       #{module_name(violation.command.__struct__)}

      #{yellow(color)}Attempts:#{reset()}
      #{attempts_text}

      #{yellow(color)}Difference:#{reset()}
      #{diff_text}
      """
    else
      """
      #{label("Type", color)}          Idempotency Violation
      #{label("Details", color)}
      #{indent_text(report.failure_message, "    ")}
      """
    end
  end

  defp format_comparison_diff(result, color) when is_map(result) do
    result
    |> Enum.map(fn {key, value} ->
      "  #{yellow(color)}#{key}:#{reset()} #{inspect(value)}"
    end)
    |> Enum.join("\n")
  end

  defp format_comparison_diff(result, _color), do: "  #{inspect(result)}"

  defp terminal_shrinking_stats(report, color) do
    original_count = Sequence.command_count(report.original_sequence)
    shrunk_count = Sequence.command_count(report.shrunk_sequence)
    removed = original_count - shrunk_count

    reduction_pct =
      if original_count > 0, do: Float.round(removed / original_count * 100, 1), else: 0

    """
    #{section_header("Shrinking Statistics", color)}
    #{label("Original Commands", color)}  #{original_count}
    #{label("Shrunk Commands", color)}    #{shrunk_count} #{dim(color)}(#{reduction_pct}% reduction)#{reset()}
    #{label("Shrink Iterations", color)}  #{report.shrink_iterations}
    #{label("Shrink Time", color)}        #{report.shrink_time_ms}ms
    """
  end

  defp terminal_command_sequence(report, opts) do
    color = Keyword.get(opts, :color, true)
    max_commands = Keyword.get(opts, :max_commands, 20)
    commands = Sequence.to_list(report.shrunk_sequence)

    commands_text =
      commands
      |> Enum.take(max_commands)
      |> Enum.with_index()
      |> Enum.map(fn {cmd, idx} ->
        marker =
          if idx == report.failed_at_index,
            do: "#{red(color)}►#{reset()}",
            else: " "

        idx_color = if idx == report.failed_at_index, do: red(color), else: dim(color)
        "#{marker} #{idx_color}[#{idx}]#{reset()} #{format_command_terminal(cmd, color)}"
      end)
      |> Enum.join("\n")

    truncated =
      if length(commands) > max_commands do
        "\n#{dim(color)}  ... and #{length(commands) - max_commands} more commands#{reset()}"
      else
        ""
      end

    """
    #{section_header("Minimal Reproduction Sequence", color)}
    #{commands_text}#{truncated}
    """
  end

  defp format_command_terminal(cmd, color) do
    name = module_name(cmd.__struct__)
    fields = cmd |> Map.from_struct() |> format_fields_inline()
    "#{cyan(color)}#{name}#{reset()} #{dim(color)}#{fields}#{reset()}"
  end

  defp terminal_state(report, color) do
    if report.state_at_failure && map_size(report.state_at_failure) > 0 do
      state_text =
        report.state_at_failure
        |> Enum.map(fn {projection, state} ->
          proj_name = module_name(projection)
          state_summary = summarize_state(state)
          "  #{cyan(color)}#{proj_name}#{reset()}\n#{indent_text(state_summary, "    ")}"
        end)
        |> Enum.join("\n\n")

      """
      #{section_header("Projection States at Failure", color)}
      #{state_text}
      """
    else
      nil
    end
  end

  defp terminal_event_log(report, max_events, color) do
    if length(report.event_log) > 0 do
      events_text =
        report.event_log
        |> Enum.take(max_events)
        |> Enum.with_index()
        |> Enum.map(fn {entry, idx} ->
          source_badge = source_badge(entry.source, color)
          cmd_idx = if entry.command_index, do: "[#{entry.command_index}]", else: "[?]"
          event_name = module_name(entry.event.__struct__)
          branch = if entry.branch_id, do: " B#{entry.branch_id}", else: ""

          "  #{dim(color)}#{String.pad_leading("#{idx}", 3)}#{reset()} #{source_badge} #{dim(color)}#{cmd_idx}#{branch}#{reset()} #{event_name}"
        end)
        |> Enum.join("\n")

      truncated =
        if length(report.event_log) > max_events do
          "\n#{dim(color)}  ... and #{length(report.event_log) - max_events} more events#{reset()}"
        else
          ""
        end

      """
      #{section_header("Event Log", color)}
      #{events_text}#{truncated}
      """
    else
      nil
    end
  end

  defp source_badge(source, color) do
    case source do
      :command -> "#{green(color)}CMD#{reset()}"
      :injector -> "#{yellow(color)}INJ#{reset()}"
      :nemesis -> "#{red(color)}NEM#{reset()}"
      :mock -> "#{magenta(color)}MOC#{reset()}"
      :stutter -> "#{blue(color)}STU#{reset()}"
      _ -> "#{dim(color)}???#{reset()}"
    end
  end

  defp terminal_reproduction(report, color) do
    cmd = FailureReport.reproduction_command(report)

    """
    #{section_header("Reproduction", color)}
    #{green(color)}#{cmd}#{reset()}
    """
  end

  # ============================================================================
  # Markdown Format
  # ============================================================================

  defp format_markdown(report, opts) do
    show_event_log = Keyword.get(opts, :show_event_log, true)
    show_state = Keyword.get(opts, :show_state, true)
    max_events = Keyword.get(opts, :max_events, 50)

    sections = [
      markdown_header(report),
      markdown_location(report),
      markdown_failure_reason(report),
      markdown_shrinking_stats(report),
      markdown_command_sequence(report, opts),
      if(show_state, do: markdown_state(report), else: nil),
      if(show_event_log, do: markdown_event_log(report, max_events), else: nil),
      markdown_reproduction(report)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp markdown_header(report) do
    type_summary = FailureReport.failure_type_summary(report)

    """
    # Bug Detected: #{type_summary}

    **Timestamp:** #{DateTime.to_string(report.timestamp)}
    """
  end

  defp markdown_location(report) do
    """
    ## Failure Location

    | Property | Value |
    |----------|-------|
    | Run Number | #{report.run_number + 1} |
    | Command Index | #{report.failed_at_index} |
    | Random Seed | `#{report.seed}` |
    """
  end

  defp markdown_failure_reason(report) do
    reason_text =
      case report.failure_type do
        :check_failed ->
          """
          **Check:** `#{report.check_name}`

          **Message:**
          ```
          #{report.failure_message}
          ```
          """

        :idempotency_violation ->
          format_idempotency_markdown(report)

        _ ->
          """
          **Details:**
          ```
          #{report.failure_message || inspect(report.failure_reason, pretty: true)}
          ```
          """
      end

    """
    ## Failure Details

    #{reason_text}
    """
  end

  defp format_idempotency_markdown(report) do
    violation = report.idempotency_violation

    if violation do
      attempts_text =
        violation.attempts
        |> Enum.map(fn att ->
          retry_label = if att.is_retry, do: "(retry)", else: "(original)"
          events = Enum.map(att.events, &event_summary/1) |> Enum.join(", ")
          "| #{att.attempt} | #{retry_label} | #{events} |"
        end)
        |> Enum.join("\n")

      """
      **Type:** Idempotency Violation

      **Command:** `#{module_name(violation.command.__struct__)}`

      ### Attempts

      | Attempt | Type | Events |
      |---------|------|--------|
      #{attempts_text}

      ### Difference

      ```elixir
      #{inspect(violation.comparison_result, pretty: true)}
      ```
      """
    else
      """
      **Type:** Idempotency Violation

      #{report.failure_message}
      """
    end
  end

  defp markdown_shrinking_stats(report) do
    original_count = Sequence.command_count(report.original_sequence)
    shrunk_count = Sequence.command_count(report.shrunk_sequence)

    """
    ## Shrinking Statistics

    | Metric | Value |
    |--------|-------|
    | Original Commands | #{original_count} |
    | Shrunk Commands | #{shrunk_count} |
    | Commands Removed | #{original_count - shrunk_count} |
    | Shrink Iterations | #{report.shrink_iterations} |
    | Shrink Time | #{report.shrink_time_ms}ms |
    """
  end

  defp markdown_command_sequence(report, opts) do
    max_commands = Keyword.get(opts, :max_commands, 20)
    commands = Sequence.to_list(report.shrunk_sequence)

    commands_text =
      commands
      |> Enum.take(max_commands)
      |> Enum.with_index()
      |> Enum.map(fn {cmd, idx} ->
        marker = if idx == report.failed_at_index, do: "► ", else: "  "

        "#{marker}# [#{idx}] #{module_name(cmd.__struct__)}\n#{marker}#{inspect(cmd, pretty: true)}"
      end)
      |> Enum.join("\n\n")

    truncated =
      if length(commands) > max_commands do
        "\n# ... and #{length(commands) - max_commands} more commands"
      else
        ""
      end

    """
    ## Minimal Reproduction Sequence

    ```elixir
    #{commands_text}#{truncated}
    ```
    """
  end

  defp markdown_state(report) do
    if report.state_at_failure && map_size(report.state_at_failure) > 0 do
      state_text =
        report.state_at_failure
        |> Enum.map(fn {projection, state} ->
          """
          ### #{module_name(projection)}

          ```elixir
          #{inspect(state, pretty: true, limit: 20)}
          ```
          """
        end)
        |> Enum.join("\n")

      """
      ## Projection States at Failure

      #{state_text}
      """
    else
      nil
    end
  end

  defp markdown_event_log(report, max_events) do
    if length(report.event_log) > 0 do
      events_text =
        report.event_log
        |> Enum.take(max_events)
        |> Enum.map(fn entry ->
          source = String.upcase(to_string(entry.source))
          cmd_idx = entry.command_index || "?"
          event_name = module_name(entry.event.__struct__)
          branch = if entry.branch_id, do: " (B#{entry.branch_id})", else: ""
          "| #{source} | #{cmd_idx}#{branch} | `#{event_name}` |"
        end)
        |> Enum.join("\n")

      truncated =
        if length(report.event_log) > max_events do
          "\n\n*... and #{length(report.event_log) - max_events} more events*"
        else
          ""
        end

      """
      ## Event Log

      | Source | Cmd | Event |
      |--------|-----|-------|
      #{events_text}#{truncated}
      """
    else
      nil
    end
  end

  defp markdown_reproduction(report) do
    cmd = FailureReport.reproduction_command(report)

    """
    ## Reproduction

    ```elixir
    #{cmd}
    ```
    """
  end

  # ============================================================================
  # JSON Format
  # ============================================================================

  defp format_json(report, opts) do
    indent = Keyword.get(opts, :indent, 2)

    data = %{
      "type" => "property_damage_failure_report",
      "version" => "1.0",
      "timestamp" => DateTime.to_iso8601(report.timestamp),
      "location" => %{
        "run_number" => report.run_number,
        "failed_at_index" => report.failed_at_index,
        "seed" => report.seed
      },
      "failure" => %{
        "type" => to_string(report.failure_type),
        "check_name" => report.check_name && to_string(report.check_name),
        "message" => report.failure_message,
        "summary" => FailureReport.failure_type_summary(report)
      },
      "shrinking" => %{
        "original_commands" => Sequence.command_count(report.original_sequence),
        "shrunk_commands" => Sequence.command_count(report.shrunk_sequence),
        "iterations" => report.shrink_iterations,
        "time_ms" => report.shrink_time_ms
      },
      "sequence" => serialize_sequence(report.shrunk_sequence),
      "reproduction" => FailureReport.reproduction_command(report)
    }

    # Add optional sections
    data =
      if report.state_at_failure && map_size(report.state_at_failure) > 0 do
        Map.put(data, "projections", serialize_projections(report.state_at_failure))
      else
        data
      end

    data =
      if length(report.event_log) > 0 do
        Map.put(data, "event_log", serialize_event_log(report.event_log))
      else
        data
      end

    data =
      if report.idempotency_violation do
        Map.put(
          data,
          "idempotency_violation",
          serialize_idempotency(report.idempotency_violation)
        )
      else
        data
      end

    Jason.encode!(data, pretty: indent > 0)
  end

  defp serialize_sequence(sequence) do
    sequence
    |> Sequence.to_list()
    |> Enum.with_index()
    |> Enum.map(fn {cmd, idx} ->
      %{
        "index" => idx,
        "type" => module_name(cmd.__struct__),
        "fields" => cmd |> Map.from_struct() |> serialize_map()
      }
    end)
  end

  defp serialize_projections(projections) do
    for {projection, state} <- projections, into: %{} do
      {module_name(projection), serialize_value(state)}
    end
  end

  defp serialize_event_log(event_log) do
    Enum.map(event_log, fn entry ->
      %{
        "source" => to_string(entry.source),
        "command_index" => entry.command_index,
        "branch_id" => entry.branch_id,
        "event_type" => module_name(entry.event.__struct__),
        "event" => entry.event |> Map.from_struct() |> serialize_map()
      }
    end)
  end

  defp serialize_idempotency(violation) do
    %{
      "command" => module_name(violation.command.__struct__),
      "command_index" => violation.command_index,
      "attempts" =>
        Enum.map(violation.attempts, fn att ->
          %{
            "attempt" => att.attempt,
            "is_retry" => att.is_retry,
            "events" => Enum.map(att.events, &module_name(&1.__struct__))
          }
        end),
      "comparison_result" => serialize_value(violation.comparison_result)
    }
  end

  defp serialize_map(map) when is_map(map) do
    for {k, v} <- map, into: %{} do
      {to_string(k), serialize_value(v)}
    end
  end

  defp serialize_value(%{__struct__: mod} = struct) do
    %{"_type" => module_name(mod), "_fields" => struct |> Map.from_struct() |> serialize_map()}
  end

  defp serialize_value(map) when is_map(map), do: serialize_map(map)
  defp serialize_value(list) when is_list(list), do: Enum.map(list, &serialize_value/1)

  defp serialize_value(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> serialize_value()

  defp serialize_value(atom) when is_atom(atom), do: to_string(atom)
  defp serialize_value(ref) when is_reference(ref), do: inspect(ref)
  defp serialize_value(other), do: other

  # ============================================================================
  # Compact Format
  # ============================================================================

  defp format_compact(report) do
    type = FailureReport.failure_type_summary(report)
    cmd_count = Sequence.command_count(report.shrunk_sequence)

    "[FAIL] #{type} | run=#{report.run_number + 1} cmd=#{report.failed_at_index} " <>
      "shrunk=#{cmd_count} seed=#{report.seed}"
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp module_name(module) when is_atom(module) do
    module |> Module.split() |> List.last()
  end

  defp event_summary(event) do
    module_name(event.__struct__)
  end

  defp format_fields_inline(fields) do
    fields
    |> Enum.map(fn {k, v} -> "#{k}: #{inspect_short(v)}" end)
    |> Enum.join(", ")
    |> then(&"{#{&1}}")
  end

  defp inspect_short(value) when is_binary(value) and byte_size(value) > 20 do
    "\"#{String.slice(value, 0, 17)}...\""
  end

  defp inspect_short(value) do
    value
    |> inspect(limit: 3)
    |> String.slice(0, 30)
  end

  defp summarize_state(state) when is_map(state) do
    state
    |> Enum.map(fn {k, v} ->
      "#{k}: #{summarize_value(v)}"
    end)
    |> Enum.join("\n")
  end

  defp summarize_state(other), do: inspect(other, limit: 5)

  defp summarize_value(map) when is_map(map) and not is_struct(map) do
    "#{map_size(map)} items"
  end

  defp summarize_value(list) when is_list(list), do: "#{length(list)} items"
  defp summarize_value(other), do: inspect(other, limit: 3)

  defp indent_text(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map(&"#{prefix}#{&1}")
    |> Enum.join("\n")
  end

  defp section_header(title, color) do
    "#{bold(color)}#{yellow(color)}## #{title}#{reset()}\n"
  end

  defp label(text, color) do
    "#{dim(color)}#{String.pad_trailing(text <> ":", 20)}#{reset()}"
  end

  # ANSI color helpers
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

  # No-arg versions for concatenation (used in string interpolation)
  defp red, do: "\e[31m"
  defp bold, do: "\e[1m"
end
