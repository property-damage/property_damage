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
    show_original = Keyword.get(opts, :show_original, true)
    max_events = Keyword.get(opts, :max_events, 50)

    # Shrunk info first (primary focus), original second (for reference)
    sections = [
      terminal_header(report, color),
      terminal_location(report, color),
      terminal_failure_explanation(report, color),
      terminal_shrunk_sequence(report, opts),
      if(show_state, do: terminal_state_transition(report, color), else: nil),
      if(show_event_log, do: terminal_event_log(report, max_events, color), else: nil),
      terminal_reproduction(report, color),
      terminal_shrinking_stats(report, color),
      if(show_original, do: terminal_original_sequence(report, opts), else: nil)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp terminal_header(report, color) do
    type_summary = FailureReport.failure_type_summary(report)

    # Check if this is a test code error
    case report.error_origin do
      :test_code_error ->
        terminal_header_test_code_error(report, color, type_summary)

      _ ->
        terminal_header_sut_error(report, color, type_summary)
    end
  end

  defp terminal_header_test_code_error(report, color, type_summary) do
    header =
      if color do
        """
        #{yellow(true)}╔══════════════════════════════════════════════════════════════════════╗
        ║#{reset()}#{bold()}#{yellow(true)}                      TEST CODE ERROR                               #{reset()}#{yellow(true)}║
        ║#{reset()}#{dim(true)}              (Not a bug in your SUT - fix your test!)              #{reset()}#{yellow(true)}║
        ╚══════════════════════════════════════════════════════════════════════╝#{reset()}
        """
      else
        """
        ╔══════════════════════════════════════════════════════════════════════╗
        ║                      TEST CODE ERROR                                 ║
        ║              (Not a bug in your SUT - fix your test!)                ║
        ╚══════════════════════════════════════════════════════════════════════╝
        """
      end

    header <>
      "\n#{dim(color)}#{type_summary}#{reset()}\n" <>
      terminal_test_code_error_hint(report, color)
  end

  defp terminal_header_sut_error(_report, color, type_summary) do
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

  defp terminal_test_code_error_hint(report, color) do
    case report.error_origin_details do
      %{reason: reason, evidence: evidence, confidence: confidence} ->
        hint = Map.get(evidence, :hint, nil)
        stacktrace_hint = Map.get(evidence, :stacktrace_hint, nil)

        hint_text =
          cond do
            hint != nil ->
              "\n#{yellow(color)}Hint:#{reset()} #{hint}"

            stacktrace_hint != nil ->
              "\n#{yellow(color)}Location:#{reset()} #{stacktrace_hint}"

            true ->
              ""
          end

        confidence_text =
          case confidence do
            :high -> ""
            :medium -> " #{dim(color)}(medium confidence)#{reset()}"
            :low -> " #{dim(color)}(low confidence - could be SUT bug)#{reset()}"
          end

        """

        #{yellow(color)}What went wrong:#{reset()} #{reason}#{confidence_text}#{hint_text}
        """

      _ ->
        ""
    end
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

  defp terminal_failure_explanation(report, color) do
    # Build the "Why It Failed" explanation
    {reason_text, why_text} =
      case report.failure_type do
        :check_failed ->
          reason = """
          #{label("Check", color)}         #{cyan(color)}#{report.check_name}#{reset()}
          #{label("Message", color)}
          #{indent_text(report.failure_message, "    ")}
          """

          why = build_check_explanation(report, color)
          {reason, why}

        :idempotency_violation ->
          {format_idempotency_terminal(report, color), nil}

        :linearization_failed ->
          reason = """
          #{label("Type", color)}          Linearization Failed
          #{label("Details", color)}
          #{indent_text(report.failure_message, "    ")}
          """

          why = """
          #{yellow(color)}Why it failed:#{reset()} No sequential ordering of the parallel commands
          could explain the observed results. The system behavior is non-linearizable.
          """

          {reason, why}

        :branch_failure ->
          reason = """
          #{label("Type", color)}          Branch Execution Failed
          #{label("Branch ID", color)}     #{report.branch_id}
          #{label("Details", color)}
          #{indent_text(report.failure_message, "    ")}
          """

          {reason, nil}

        :poll_timeout ->
          {format_poll_timeout_terminal(report, color), nil}

        _ ->
          reason = """
          #{label("Reason", color)}
          #{indent_text(inspect(report.failure_reason, pretty: true), "    ")}
          """

          {reason, nil}
      end

    why_section = if why_text, do: "\n#{why_text}", else: ""

    """
    #{section_header("What Failed", color)}
    #{reason_text}#{why_section}
    """
  end

  defp build_check_explanation(report, color) do
    # Get the failing command
    failed_cmd = report.command_at_failure

    if failed_cmd do
      cmd_name = module_name(failed_cmd.__struct__)

      """
      #{yellow(color)}Why it failed:#{reset()} Command #{cyan(color)}#{cmd_name}#{reset()} at index #{report.failed_at_index}
      violated the #{cyan(color)}#{report.check_name}#{reset()} invariant.
      """
    else
      nil
    end
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

  defp format_poll_timeout_terminal(report, color) do
    info = report.poll_timeout_info

    if info do
      trigger_event = info.triggered_by.event
      event_name = module_name(trigger_event.__struct__)

      """
      #{label("Type", color)}          Poll Timeout
      #{label("Assertion", color)}     #{cyan(color)}#{info.triggered_by.assertion_name}#{reset()}
      #{label("Timeout", color)}       #{info.elapsed_ms}ms
      #{label("Poll Attempts", color)} #{info.poll_count}

      #{yellow(color)}Trigger Event:#{reset()}
        #{cyan(color)}#{event_name}#{reset()}
        #{dim(color)}#{inspect(trigger_event, pretty: true, limit: 5)}#{reset()}

      #{yellow(color)}Predicate:#{reset()}
        #{cyan(color)}#{info.predicate_source || "unknown"}#{reset()}

      #{yellow(color)}Final State:#{reset()}
        #{dim(color)}#{inspect(info.final_state, pretty: true, limit: 10)}#{reset()}

      #{yellow(color)}Why it failed:#{reset()} The predicate never returned true within the
      timeout period. The temporal assertion expected the state to eventually
      satisfy the condition, but it did not.
      """
    else
      """
      #{label("Type", color)}          Poll Timeout
      #{label("Details", color)}
      #{indent_text(report.failure_message, "    ")}
      """
    end
  end

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

  defp terminal_shrunk_sequence(report, opts) do
    color = Keyword.get(opts, :color, true)
    max_commands = Keyword.get(opts, :max_commands, 30)
    commands = Sequence.to_list(report.shrunk_sequence)
    refs = report.refs_at_failure || %{}

    # Calculate failed_at for shrunk sequence (may differ from original)
    shrunk_len = length(commands)
    failed_at = min(report.failed_at_index, shrunk_len - 1)

    commands_text =
      commands
      |> Enum.take(max_commands)
      |> Enum.with_index()
      |> Enum.map(fn {cmd, idx} ->
        is_failure = idx == failed_at
        marker = if is_failure, do: "#{red(color)}►#{reset()}", else: " "
        idx_color = if is_failure, do: red(color), else: dim(color)
        failure_label = if is_failure, do: " #{red(color)}◄── FAILURE#{reset()}", else: ""

        "#{marker} #{idx_color}[#{idx}]#{reset()} #{format_command_with_refs(cmd, refs, color)}#{failure_label}"
      end)
      |> Enum.join("\n")

    truncated =
      if length(commands) > max_commands do
        "\n#{dim(color)}  ... and #{length(commands) - max_commands} more commands#{reset()}"
      else
        ""
      end

    """
    #{section_header("Minimal Reproduction (#{length(commands)} commands)", color)}
    #{commands_text}#{truncated}
    """
  end

  defp terminal_original_sequence(report, opts) do
    color = Keyword.get(opts, :color, true)
    max_commands = Keyword.get(opts, :max_commands, 30)
    commands = Sequence.to_list(report.original_sequence)
    refs = report.refs_at_failure || %{}

    # Only show if different from shrunk
    shrunk_count = Sequence.command_count(report.shrunk_sequence)

    if length(commands) == shrunk_count do
      nil
    else
      commands_text =
        commands
        |> Enum.take(max_commands)
        |> Enum.with_index()
        |> Enum.map(fn {cmd, idx} ->
          is_failure = idx == report.failed_at_index
          marker = if is_failure, do: "#{red(color)}►#{reset()}", else: " "
          idx_color = if is_failure, do: red(color), else: dim(color)
          failure_label = if is_failure, do: " #{red(color)}◄── FAILURE#{reset()}", else: ""

          "#{marker} #{idx_color}[#{idx}]#{reset()} #{format_command_with_refs(cmd, refs, color)}#{failure_label}"
        end)
        |> Enum.join("\n")

      truncated =
        if length(commands) > max_commands do
          "\n#{dim(color)}  ... and #{length(commands) - max_commands} more commands#{reset()}"
        else
          ""
        end

      """
      #{section_header("Original Sequence (#{length(commands)} commands)", color)}
      #{dim(color)}For reference - the full sequence before shrinking#{reset()}

      #{commands_text}#{truncated}
      """
    end
  end

  defp format_command_with_refs(cmd, refs, color) do
    name = module_name(cmd.__struct__)
    fields = cmd |> Map.from_struct() |> format_fields_with_refs(refs)
    "#{cyan(color)}#{name}#{reset()} #{dim(color)}#{fields}#{reset()}"
  end

  defp format_fields_with_refs(fields, refs) do
    fields
    |> Enum.map(fn {k, v} -> "#{k}: #{inspect_with_ref(v, refs)}" end)
    |> Enum.join(", ")
    |> then(&"{#{&1}}")
  end

  defp inspect_with_ref(%PropertyDamage.Ref{ref: erlang_ref, label: label}, refs) do
    # It's a Ref struct - show label and resolved value
    case Map.get(refs, erlang_ref) do
      nil -> "<#{label}>"
      resolved -> "<#{label}> → #{inspect_short(resolved)}"
    end
  end

  defp inspect_with_ref(ref, refs) when is_reference(ref) do
    case Map.get(refs, ref) do
      nil -> inspect_short(ref)
      resolved -> "#{inspect_short(ref)} → #{inspect_short(resolved)}"
    end
  end

  defp inspect_with_ref(value, _refs), do: inspect_short(value)

  defp terminal_state_transition(report, color) do
    has_after = report.state_at_failure != nil and map_size(report.state_at_failure) > 0
    has_before = report.state_before_failure != nil and map_size(report.state_before_failure) > 0

    cond do
      has_before and has_after ->
        # Show transition view
        transition_text =
          report.state_at_failure
          |> Enum.map(fn {projection, after_state} ->
            proj_name = module_name(projection)
            before_state = Map.get(report.state_before_failure, projection, %{})

            before_summary = summarize_state(before_state)
            after_summary = summarize_state(after_state)

            changes = diff_states(before_state, after_state)

            change_text =
              if changes != "",
                do: "\n    #{yellow(color)}Changes:#{reset()}\n#{indent_text(changes, "      ")}",
                else: ""

            """
              #{cyan(color)}#{proj_name}#{reset()}
                #{dim(color)}Before:#{reset()}
            #{indent_text(before_summary, "      ")}
                #{dim(color)}After:#{reset()}
            #{indent_text(after_summary, "      ")}#{change_text}
            """
          end)
          |> Enum.join("\n")

        """
        #{section_header("State Transition", color)}
        #{transition_text}
        """

      has_after ->
        # Only show after state
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

      true ->
        nil
    end
  end

  defp diff_states(before, after_state) when is_map(before) and is_map(after_state) do
    all_keys = MapSet.union(MapSet.new(Map.keys(before)), MapSet.new(Map.keys(after_state)))

    all_keys
    |> Enum.filter(fn key ->
      Map.get(before, key) != Map.get(after_state, key)
    end)
    |> Enum.map(fn key ->
      before_val = Map.get(before, key)
      after_val = Map.get(after_state, key)
      "#{key}: #{summarize_value(before_val)} → #{summarize_value(after_val)}"
    end)
    |> Enum.join("\n")
  end

  defp diff_states(_, _), do: ""

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

    case report.error_origin do
      :test_code_error ->
        hint = get_in(report.error_origin_details, [:evidence, :hint]) || ""
        hint_section = if hint != "", do: "\n**Hint:** #{hint}\n", else: ""

        """
        # ⚠️ Test Code Error

        > This is NOT a bug in your SUT - fix your test code!

        **Issue:** #{type_summary}
        **Reason:** #{report.error_origin_details.reason}
        #{hint_section}
        **Timestamp:** #{DateTime.to_string(report.timestamp)}
        """

      _ ->
        """
        # 🐛 Bug Detected: #{type_summary}

        **Timestamp:** #{DateTime.to_string(report.timestamp)}
        """
    end
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

        :poll_timeout ->
          format_poll_timeout_markdown(report)

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

  defp format_poll_timeout_markdown(report) do
    info = report.poll_timeout_info

    if info do
      trigger_event = info.triggered_by.event
      event_name = module_name(trigger_event.__struct__)

      """
      **Type:** Poll Timeout

      **Assertion:** `#{info.triggered_by.assertion_name}`

      | Property | Value |
      |----------|-------|
      | Timeout | #{info.elapsed_ms}ms |
      | Poll Attempts | #{info.poll_count} |

      ### Trigger Event

      `#{event_name}`

      ```elixir
      #{inspect(trigger_event, pretty: true, limit: 10)}
      ```

      ### Predicate

      ```elixir
      #{info.predicate_source || "unknown"}
      ```

      ### Final State

      ```elixir
      #{inspect(info.final_state, pretty: true, limit: 10)}
      ```
      """
    else
      """
      **Type:** Poll Timeout

      #{report.failure_message}
      """
    end
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
      "error_origin" => %{
        "origin" => report.error_origin && to_string(report.error_origin),
        "reason" => get_in(report.error_origin_details, [:reason]),
        "confidence" =>
          report.error_origin_details && to_string(report.error_origin_details.confidence),
        "hint" => get_in(report.error_origin_details, [:evidence, :hint]),
        "is_test_code_error" => report.error_origin == :test_code_error
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

    origin_tag =
      case report.error_origin do
        :test_code_error -> "[TEST CODE ERROR]"
        :sut_error -> "[SUT BUG]"
        _ -> "[FAIL]"
      end

    "#{origin_tag} #{type} | run=#{report.run_number + 1} cmd=#{report.failed_at_index} " <>
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
