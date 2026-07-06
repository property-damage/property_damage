defmodule PropertyDamage.Diagram do
  @moduledoc """
  Generate visual sequence diagrams from test executions.

  Transforms command sequences and event logs into sequence diagrams
  in multiple formats for documentation, debugging, and visualization.

  ## Supported Formats

  - `:mermaid` - Mermaid sequence diagrams (GitHub, GitLab, Notion compatible)
  - `:plantuml` - PlantUML sequence diagrams
  - `:websequence` - sequencediagram.org format

  ## Usage

  ### From a Failure Report

      report = PropertyDamage.run(...) |> elem(1)
      diagram = PropertyDamage.Diagram.from_failure_report(report, :mermaid)
      IO.puts(diagram)

  ### From a Sequence and Event Log

      diagram = PropertyDamage.Diagram.generate(
        sequence,
        event_log,
        format: :plantuml,
        title: "Account Creation Flow",
        show_state: true
      )

  ## Example Output (Mermaid)

      ```mermaid
      sequenceDiagram
          participant Test
          participant SUT
          participant State

          Test->>SUT: CreateAccount(name: "Alice")
          SUT-->>Test: AccountCreated(id: "acc_123")
          Test->>State: balance: 0

          Test->>SUT: Deposit(amount: 100)
          SUT-->>Test: DepositSucceeded(new_balance: 100)
          Test->>State: balance: 100

          Note over Test,SUT: ❌ FAILURE at command 2
          Test-xSUT: Withdraw(amount: 200)
          Note right of SUT: NonNegativeBalance violated
      ```

  ## Options

  - `:title` - Diagram title (default: "PropertyDamage Sequence")
  - `:show_state` - Include state changes (default: false)
  - `:show_timestamps` - Include timestamps (default: false)
  - `:max_value_length` - Truncate long values (default: 50)
  - `:highlight_failure` - Highlight failure point (default: true)
  - `:show_branches` - Show parallel branches (default: true)
  """

  alias PropertyDamage.{EventLog.Entry, FailureReport, RunTrace, Sequence}

  @type format :: :mermaid | :plantuml | :websequence
  @type options :: [
          title: String.t(),
          show_state: boolean(),
          show_timestamps: boolean(),
          max_value_length: pos_integer(),
          highlight_failure: boolean(),
          show_branches: boolean()
        ]

  @default_options [
    title: nil,
    show_state: false,
    show_timestamps: false,
    max_value_length: 50,
    highlight_failure: true,
    show_branches: true
  ]

  @default_title "PropertyDamage Sequence"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Generate a sequence diagram from a failure report.

  ## Parameters

  - `report` - A PropertyDamage.FailureReport struct
  - `format` - Output format (`:mermaid`, `:plantuml`, `:websequence`)
  - `opts` - Options (see module docs)

  ## Returns

  A string containing the diagram in the specified format.
  """
  @spec from_failure_report(FailureReport.t(), format(), options()) :: String.t()
  def from_failure_report(%FailureReport{} = report, format, opts \\ []) do
    opts =
      @default_options
      |> Keyword.merge(opts)
      |> Keyword.put(:failure_message, FailureReport.failure_message(report))
      |> Keyword.put(:failure_type, FailureReport.failure_type(report))

    title =
      Keyword.get(opts, :title) ||
        "Failure: #{FailureReport.failure_type_summary(report)} (seed: #{report.seed})"

    opts = Keyword.put(opts, :title, title)

    # `steps/1` attributes events and the failure point by branch-aware position;
    # each Step carries its command, entries, and failed? flag.
    report |> FailureReport.steps() |> render(format, opts)
  end

  @doc """
  Generate a sequence diagram from a sequence and event log.

  ## Parameters

  - `sequence` - A PropertyDamage.Sequence struct
  - `event_log` - List of PropertyDamage.EventLog.Entry structs
  - `format` - Output format (`:mermaid`, `:plantuml`, `:websequence`)
  - `opts` - Options (see module docs)

  ## Returns

  A string containing the diagram in the specified format.
  """
  @spec generate(Sequence.t(), [Entry.t()], format(), options()) :: String.t()
  def generate(sequence, event_log, format, opts \\ []) do
    opts = Keyword.merge(@default_options, opts)
    opts = Keyword.update(opts, :title, @default_title, fn t -> t || @default_title end)

    # No report here, so labels are empty; the failure point (if any) is passed
    # through opts. RunTrace owns the grouping so both diagram entry points
    # share one branch-aware step timeline.
    sequence
    |> RunTrace.build_steps(event_log, %{}, Keyword.get(opts, :failed_at_index))
    |> render(format, opts)
  end

  defp render(steps, :mermaid, opts), do: generate_mermaid(steps, opts)
  defp render(steps, :plantuml, opts), do: generate_plantuml(steps, opts)
  defp render(steps, :websequence, opts), do: generate_websequence(steps, opts)

  @doc """
  Generate diagrams in all supported formats.

  Returns a map with format keys and diagram strings as values.
  """
  @spec generate_all(Sequence.t(), [Entry.t()], options()) :: %{format() => String.t()}
  def generate_all(sequence, event_log, opts \\ []) do
    %{
      mermaid: generate(sequence, event_log, :mermaid, opts),
      plantuml: generate(sequence, event_log, :plantuml, opts),
      websequence: generate(sequence, event_log, :websequence, opts)
    }
  end

  @doc """
  Save a diagram to a file.

  Automatically adds the appropriate file extension if not present.
  """
  @spec save(String.t(), Path.t(), format()) :: :ok | {:error, term()}
  def save(diagram, path, format) do
    extension = format_extension(format)

    path =
      if String.ends_with?(path, extension) do
        path
      else
        "#{path}#{extension}"
      end

    File.write(path, diagram)
  end

  # ============================================================================
  # Mermaid Format
  # ============================================================================

  defp generate_mermaid(steps, opts) do
    title = Keyword.get(opts, :title)
    show_state = Keyword.get(opts, :show_state)
    failure_message = Keyword.get(opts, :failure_message)

    participants =
      if show_state do
        """
            participant Test
            participant SUT
            participant State
        """
      else
        """
            participant Test
            participant SUT
        """
      end

    interactions =
      Enum.map_join(steps, "\n", &generate_mermaid_interaction(&1, failure_message, opts))

    """
    ```mermaid
    sequenceDiagram
        title #{title}
    #{participants}
    #{interactions}
    ```
    """
  end

  defp generate_mermaid_interaction(step, failure_message, opts) do
    cmd_name = command_name(step.command)
    cmd_params = command_params(step.command, opts)
    max_len = Keyword.get(opts, :max_value_length)

    cmd_str = truncate("#{cmd_name}(#{cmd_params})", max_len)

    # Command line
    cmd_line =
      if step.failed? do
        "    Note over Test,SUT: ❌ FAILURE at command #{step.flattened_index}\n    Test-xSUT: #{cmd_str}"
      else
        "    Test->>SUT: #{cmd_str}"
      end

    # Event lines
    event_lines =
      step.entries
      |> Enum.map_join("\n", fn entry ->
        event_name = event_name(entry.event)
        event_params = event_params(entry.event, opts)
        event_str = truncate("#{event_name}(#{event_params})", max_len)

        source_indicator =
          case entry.source do
            :command -> ""
            :nemesis -> " [nemesis]"
            :injector -> " [injected]"
            :mock -> " [mock]"
            _ -> ""
          end

        "    SUT-->>Test: #{event_str}#{source_indicator}"
      end)

    # Failure note
    failure_note =
      if step.failed? and failure_message do
        "\n    Note right of SUT: #{truncate(failure_message, 40)}"
      else
        ""
      end

    [cmd_line, event_lines, failure_note]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # ============================================================================
  # PlantUML Format
  # ============================================================================

  defp generate_plantuml(steps, opts) do
    title = Keyword.get(opts, :title)
    show_state = Keyword.get(opts, :show_state)
    failure_message = Keyword.get(opts, :failure_message)

    participants =
      if show_state do
        """
        participant Test
        participant SUT
        participant State
        """
      else
        """
        participant Test
        participant SUT
        """
      end

    interactions =
      Enum.map_join(steps, "\n", &generate_plantuml_interaction(&1, failure_message, opts))

    """
    @startuml
    title #{title}

    #{String.trim(participants)}

    #{interactions}
    @enduml
    """
  end

  defp generate_plantuml_interaction(step, failure_message, opts) do
    cmd_name = command_name(step.command)
    cmd_params = command_params(step.command, opts)
    max_len = Keyword.get(opts, :max_value_length)

    cmd_str = truncate("#{cmd_name}(#{cmd_params})", max_len)

    # Command line
    cmd_line =
      if step.failed? do
        """
        hnote over Test,SUT #ffcccc : FAILURE at command #{step.flattened_index}
        Test -x SUT : #{cmd_str}
        """
      else
        "Test -> SUT : #{cmd_str}"
      end

    # Event lines
    event_lines =
      step.entries
      |> Enum.map_join("\n", fn entry ->
        event_name = event_name(entry.event)
        event_params = event_params(entry.event, opts)
        event_str = truncate("#{event_name}(#{event_params})", max_len)

        source_indicator =
          case entry.source do
            :nemesis -> " **[nemesis]**"
            :injector -> " //[injected]//"
            :mock -> " ''[mock]''"
            _ -> ""
          end

        "SUT --> Test : #{event_str}#{source_indicator}"
      end)

    # Failure note
    failure_note =
      if step.failed? and failure_message do
        "\nnote right of SUT #ffcccc\n  #{truncate(failure_message, 60)}\nend note"
      else
        ""
      end

    [String.trim(cmd_line), event_lines, failure_note]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # ============================================================================
  # WebSequence (sequencediagram.org) Format
  # ============================================================================

  defp generate_websequence(steps, opts) do
    title = Keyword.get(opts, :title)
    failure_message = Keyword.get(opts, :failure_message)

    header = "title #{title}\n"

    interactions =
      Enum.map_join(steps, "\n", &generate_websequence_interaction(&1, failure_message, opts))

    header <> "\n" <> interactions
  end

  defp generate_websequence_interaction(step, failure_message, opts) do
    cmd_name = command_name(step.command)
    cmd_params = command_params(step.command, opts)
    max_len = Keyword.get(opts, :max_value_length)

    cmd_str = truncate("#{cmd_name}(#{cmd_params})", max_len)

    # Command line
    cmd_line =
      if step.failed? do
        "note over Test,SUT: FAILURE at command #{step.flattened_index}\nTest->SUT: #{cmd_str}"
      else
        "Test->SUT: #{cmd_str}"
      end

    # Event lines
    event_lines =
      step.entries
      |> Enum.map_join("\n", fn entry ->
        event_name = event_name(entry.event)
        event_params = event_params(entry.event, opts)
        event_str = truncate("#{event_name}(#{event_params})", max_len)
        "SUT-->Test: #{event_str}"
      end)

    # Failure note
    failure_note =
      if step.failed? and failure_message do
        "\nnote right of SUT: #{truncate(failure_message, 40)}"
      else
        ""
      end

    [cmd_line, event_lines, failure_note]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp command_name(cmd) do
    cmd.__struct__
    |> Module.split()
    |> List.last()
  end

  defp command_params(cmd, opts) do
    max_len = Keyword.get(opts, :max_value_length, 50)

    cmd
    |> Map.from_struct()
    |> Enum.reject(fn {k, _} -> k == :__struct__ end)
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{format_value(v)}" end)
    |> truncate(max_len)
  end

  defp event_name(event) do
    event.__struct__
    |> Module.split()
    |> List.last()
  end

  defp event_params(event, opts) do
    max_len = Keyword.get(opts, :max_value_length, 50)

    event
    |> Map.from_struct()
    |> Enum.reject(fn {k, _} -> k == :__struct__ end)
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{format_value(v)}" end)
    |> truncate(max_len)
  end

  defp format_value(value) when is_binary(value), do: "\"#{value}\""
  defp format_value(value) when is_atom(value), do: ":#{value}"
  defp format_value(value) when is_number(value), do: to_string(value)
  defp format_value(value) when is_list(value), do: "[#{length(value)} items]"
  defp format_value(value) when is_map(value), do: "%{#{map_size(value)} keys}"
  defp format_value(value), do: inspect(value, limit: 3)

  defp truncate(str, max_len) do
    if String.length(str) <= max_len do
      str
    else
      String.slice(str, 0, max_len - 3) <> "..."
    end
  end

  defp format_extension(:mermaid), do: ".md"
  defp format_extension(:plantuml), do: ".puml"
  defp format_extension(:websequence), do: ".txt"
end
