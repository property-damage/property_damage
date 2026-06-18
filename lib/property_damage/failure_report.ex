defmodule PropertyDamage.FailureReport do
  @moduledoc """
  Rich failure report with comprehensive diagnostic information.

  A FailureReport captures everything needed to understand, debug, and
  reproduce a test failure:

  - **Location**: Which run, command index, and seed
  - **Sequences**: Original and shrunk command sequences
  - **State**: Projection states before and at failure
  - **Events**: Complete event trail leading to failure
  - **Reason**: Structured failure reason with context

  ## Creating Reports

  Reports are created automatically by PropertyDamage when a test fails.
  You can also create them manually for testing:

      report = FailureReport.new(
        seed: 12345,
        run_number: 3,
        original_sequence: sequence,
        shrunk_sequence: shrunk,
        failed_at_index: 5,
        failure_reason: {:check_failed, :NonNegativeBalance, "..."}
      )

  ## Formatting Reports

  Use `FailureReport.Formatter` to render reports in different formats:

      # Terminal output (default)
      FailureReport.Formatter.format(report, :terminal)

      # Markdown for documentation
      FailureReport.Formatter.format(report, :markdown)

      # JSON for CI integration
      FailureReport.Formatter.format(report, :json)

  ## Failure Reasons

  The `failure_reason` field contains structured data about what failed:

  - `{:check_failed, check_name, message}` - Invariant violation
  - `{:idempotency_violation, %Stutter.Violation{}}` - Idempotency failure
  - `{:adapter_error, reason}` - Adapter execution failed
  - `{:linearization_failed, message}` - No valid linearization (parallel)
  - `{:branch_failure, branch_id, reason}` - Branch execution failed
  - `{:ref_resolution_error, reason}` - Symbolic ref couldn't be resolved
  """

  alias PropertyDamage.{ErrorOrigin, EventLog.Entry, Sequence}

  @type failure_type ::
          :check_failed
          | :idempotency_violation
          | :adapter_error
          | :linearization_failed
          | :branch_failure
          | :ref_resolution_error
          | :poll_timeout
          | :unknown

  @type t :: %__MODULE__{
          # Location
          seed: integer(),
          run_number: non_neg_integer(),
          failed_at_index: non_neg_integer(),
          failure_type: failure_type(),

          # Sequences
          original_sequence: Sequence.t(),
          shrunk_sequence: Sequence.t(),

          # Failure details
          failure_reason: term(),
          check_name: atom() | nil,
          failure_message: String.t() | nil,

          # State snapshots
          state_before_failure: %{atom() => any()} | nil,
          state_at_failure: %{atom() => any()} | nil,

          # Event trail
          event_log: [Entry.t()],
          command_at_failure: struct() | nil,
          events_at_failure: [struct()],

          # Idempotency-specific (for stutter failures)
          idempotency_violation: map() | nil,

          # Poll timeout-specific (for @poll_state failures)
          poll_timeout_info: map() | nil,

          # Parallel execution-specific
          branch_id: non_neg_integer() | nil,
          linearization: [struct()] | nil,
          branch_events: %{non_neg_integer() => [Entry.t()]} | nil,

          # Shrinking stats
          shrink_iterations: non_neg_integer(),
          shrink_time_ms: non_neg_integer(),

          # Metadata
          model: module() | nil,
          adapter: module() | nil,
          timestamp: DateTime.t(),

          # Error origin classification
          error_origin: ErrorOrigin.origin() | nil,
          error_origin_details: ErrorOrigin.details() | nil,
          stacktrace: list() | nil
        }

  defstruct seed: nil,
            run_number: nil,
            failed_at_index: nil,
            failure_type: nil,
            original_sequence: nil,
            shrunk_sequence: nil,
            failure_reason: nil,
            check_name: nil,
            failure_message: nil,
            state_before_failure: nil,
            state_at_failure: nil,
            event_log: [],
            command_at_failure: nil,
            events_at_failure: [],
            idempotency_violation: nil,
            poll_timeout_info: nil,
            branch_id: nil,
            linearization: nil,
            branch_events: nil,
            shrink_iterations: 0,
            shrink_time_ms: 0,
            model: nil,
            adapter: nil,
            timestamp: nil,
            error_origin: nil,
            error_origin_details: nil,
            stacktrace: nil

  @doc """
  Create a new failure report from execution results.

  ## Options

  Required:
  - `:seed` - Random seed for reproduction
  - `:run_number` - Which test run failed
  - `:original_sequence` - The sequence before shrinking
  - `:failed_at_index` - Command index where failure occurred
  - `:failure_reason` - Structured failure reason

  Optional:
  - `:shrunk_sequence` - Minimized sequence (defaults to original)
  - `:event_log` - Complete event log
  - `:projections` - Projection states at failure
  - `:projections_before` - Projection states before failing command
  - `:shrink_iterations` - Number of shrink attempts
  - `:shrink_time_ms` - Time spent shrinking
  - `:model` - Model module
  - `:adapter` - Adapter module
  - `:linearization` - Selected linearization (parallel)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    seed = Keyword.fetch!(opts, :seed)
    run_number = Keyword.fetch!(opts, :run_number)
    original_sequence = Keyword.fetch!(opts, :original_sequence)
    failed_at_index = Keyword.fetch!(opts, :failed_at_index)
    failure_reason = Keyword.fetch!(opts, :failure_reason)

    shrunk_sequence = Keyword.get(opts, :shrunk_sequence, original_sequence)
    event_log = Keyword.get(opts, :event_log, [])
    projections = Keyword.get(opts, :projections, %{})
    projections_before = Keyword.get(opts, :projections_before)
    stacktrace = Keyword.get(opts, :stacktrace)

    # Parse failure reason
    {failure_type, check_name, failure_message, idempotency_violation, poll_timeout_info,
     branch_id} =
      parse_failure_reason(failure_reason)

    # Extract command and events at failure point (branch-aware: branch
    # command indices are prefix-relative and overlap across branches)
    {command_at_failure, events_at_failure} =
      extract_failure_context(shrunk_sequence, event_log, failed_at_index, branch_id)

    # Extract branch events if parallel
    branch_events = extract_branch_events(event_log)

    # Classify error origin
    classification = ErrorOrigin.classify(failure_reason, stacktrace)

    %__MODULE__{
      seed: seed,
      run_number: run_number,
      failed_at_index: failed_at_index,
      failure_type: failure_type,
      original_sequence: original_sequence,
      shrunk_sequence: shrunk_sequence,
      failure_reason: failure_reason,
      check_name: check_name,
      failure_message: failure_message,
      state_before_failure: projections_before,
      state_at_failure: projections,
      event_log: event_log,
      command_at_failure: command_at_failure,
      events_at_failure: events_at_failure,
      idempotency_violation: idempotency_violation,
      poll_timeout_info: poll_timeout_info,
      branch_id: branch_id,
      linearization: Keyword.get(opts, :linearization),
      branch_events: branch_events,
      shrink_iterations: Keyword.get(opts, :shrink_iterations, 0),
      shrink_time_ms: Keyword.get(opts, :shrink_time_ms, 0),
      model: Keyword.get(opts, :model),
      adapter: Keyword.get(opts, :adapter),
      timestamp: DateTime.utc_now(),
      error_origin: classification.origin,
      error_origin_details: classification.details,
      stacktrace: stacktrace
    }
  end

  @doc """
  Convert from the legacy failure_report map format.

  This allows gradual migration from the old format.
  """
  @spec from_legacy(map(), keyword()) :: t()
  def from_legacy(legacy_report, opts \\ []) do
    new(
      seed: legacy_report.seed,
      run_number: legacy_report.run_number,
      original_sequence: legacy_report.original_sequence,
      shrunk_sequence: legacy_report.shrunk_sequence,
      failed_at_index: legacy_report.failed_at_index,
      failure_reason: legacy_report.failure_reason,
      shrink_iterations: legacy_report.shrink_iterations,
      shrink_time_ms: legacy_report.shrink_time_ms,
      event_log: Keyword.get(opts, :event_log, []),
      projections: Keyword.get(opts, :projections, %{}),
      model: Keyword.get(opts, :model),
      adapter: Keyword.get(opts, :adapter),
      # Forward the stacktrace so the converted report keeps it and the origin
      # classifier can attribute the failure (it was silently dropped before).
      stacktrace: Keyword.get(opts, :stacktrace)
    )
  end

  @doc """
  Convert to the legacy failure_report map format.

  For backwards compatibility with existing code.
  """
  @spec to_legacy(t()) :: map()
  def to_legacy(%__MODULE__{} = report) do
    %{
      seed: report.seed,
      run_number: report.run_number,
      original_sequence: report.original_sequence,
      shrunk_sequence: report.shrunk_sequence,
      failed_at_index: report.failed_at_index,
      failure_reason: report.failure_reason,
      shrink_iterations: report.shrink_iterations,
      shrink_time_ms: report.shrink_time_ms
    }
  end

  @doc """
  Get a summary string for the failure type.
  """
  @spec failure_type_summary(t()) :: String.t()
  def failure_type_summary(%__MODULE__{failure_type: type, check_name: check_name}) do
    case type do
      :check_failed -> "Invariant Violation: #{check_name}"
      :idempotency_violation -> "Idempotency Violation"
      :poll_timeout -> "Poll Timeout: #{check_name}"
      :poll_error -> "Poll Predicate Error"
      :adapter_error -> "Adapter Error"
      :settle_timeout -> "Settle Timeout"
      :nemesis_error -> "Fault Injection Error"
      :resource_poller_error -> "Resource Poller Error"
      :stutter_execution_failed -> "Stutter Execution Failed"
      :linearization_failed -> "Linearization Failed"
      :branch_failure -> "Branch Execution Failed"
      :ref_resolution_error -> "Ref Resolution Error"
      :unknown -> "Unknown Failure"
      # Total fallback (e.g. nil on a hand-built struct) so rendering/Inspect
      # never crashes with a CaseClauseError
      _ -> "Failure"
    end
  end

  @doc """
  Check if this is a poll timeout failure.
  """
  @spec poll_timeout_failure?(t()) :: boolean()
  def poll_timeout_failure?(%__MODULE__{failure_type: :poll_timeout}), do: true
  def poll_timeout_failure?(_), do: false

  @doc """
  Check if this is a parallel execution failure.
  """
  @spec parallel_failure?(t()) :: boolean()
  def parallel_failure?(%__MODULE__{failure_type: type}) do
    type in [:linearization_failed, :branch_failure]
  end

  @doc """
  Check if this is an idempotency failure.
  """
  @spec idempotency_failure?(t()) :: boolean()
  def idempotency_failure?(%__MODULE__{failure_type: :idempotency_violation}), do: true
  def idempotency_failure?(_), do: false

  @doc """
  Check if this failure is likely a test code error.

  Test code errors are bugs in the model, projections, commands, or adapters
  rather than bugs in the System Under Test.
  """
  @spec test_code_error?(t()) :: boolean()
  def test_code_error?(%__MODULE__{error_origin: :test_code_error}), do: true
  def test_code_error?(_), do: false

  @doc """
  Check if this failure is likely a SUT error (bug in System Under Test).
  """
  @spec sut_error?(t()) :: boolean()
  def sut_error?(%__MODULE__{error_origin: :sut_error}), do: true
  def sut_error?(_), do: false

  @doc """
  Get a human-readable summary of the error origin.
  """
  @spec error_origin_summary(t()) :: String.t()
  def error_origin_summary(%__MODULE__{error_origin: :sut_error, error_origin_details: details}) do
    "SUT Bug: #{details.reason}"
  end

  def error_origin_summary(%__MODULE__{
        error_origin: :test_code_error,
        error_origin_details: details
      }) do
    "Test Code Error: #{details.reason}"
  end

  def error_origin_summary(%__MODULE__{error_origin: :unknown, error_origin_details: details}) do
    "Unknown Origin: #{details.reason}"
  end

  def error_origin_summary(%__MODULE__{error_origin: nil}) do
    "Origin not classified"
  end

  @doc """
  Get the reproduction command as a string.
  """
  @spec reproduction_command(t()) :: String.t()
  def reproduction_command(%__MODULE__{seed: seed, model: model, adapter: adapter}) do
    model_str = if model, do: "model: #{inspect(model)}, ", else: ""
    adapter_str = if adapter, do: "adapter: #{inspect(adapter)}, ", else: ""

    "PropertyDamage.run(#{model_str}#{adapter_str}seed: #{seed}, max_runs: 1)"
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp parse_failure_reason({:check_failed, check_name, message}) do
    {:check_failed, check_name, extract_message(message), nil, nil, nil}
  end

  defp parse_failure_reason({:assertion_failed, check_name, reason}) do
    {:check_failed, check_name, extract_message(reason), nil, nil, nil}
  end

  defp parse_failure_reason({:projection_violation, projection, exception}) do
    message =
      "projection #{inspect(projection)} rejected the transition: " <> extract_message(exception)

    {:check_failed, projection, message, nil, nil, nil}
  end

  defp parse_failure_reason({:idempotency_violation, violation}) do
    message = format_idempotency_message(violation)
    {:idempotency_violation, nil, message, violation, nil, nil}
  end

  defp parse_failure_reason({:poll_timeout, info}) do
    message = format_poll_timeout_message(info)
    {:poll_timeout, info.triggered_by.assertion_name, message, nil, info, nil}
  end

  defp parse_failure_reason({:poll_error, reason}) do
    {:poll_error, nil, "Poll predicate error: #{inspect(reason)}", nil, nil, nil}
  end

  defp parse_failure_reason({:adapter_error, reason}) do
    {:adapter_error, nil, extract_message(reason), nil, nil, nil}
  end

  defp parse_failure_reason({:settle_timeout, reason}) do
    {:settle_timeout, nil, "Command did not settle: #{inspect(reason)}", nil, nil, nil}
  end

  defp parse_failure_reason({:nemesis_error, reason}) do
    {:nemesis_error, nil, "Fault injection failed: #{inspect(reason)}", nil, nil, nil}
  end

  defp parse_failure_reason({:resource_poller_error, reason}) do
    {:resource_poller_error, nil, "Resource poller error: #{inspect(reason)}", nil, nil, nil}
  end

  defp parse_failure_reason({:stutter_execution_failed, details}) do
    {:stutter_execution_failed, nil, "Stutter retry failed: #{inspect(details)}", nil, nil, nil}
  end

  defp parse_failure_reason({:linearization_failed, message}) do
    {:linearization_failed, nil, to_string(message), nil, nil, nil}
  end

  defp parse_failure_reason({:branch_failure, branch_id, reason}) do
    {inner_type, check_name, message, idempotency, poll_info, _} = parse_failure_reason(reason)
    {inner_type, check_name, message, idempotency, poll_info, branch_id}
  end

  defp parse_failure_reason({:ref_resolution_error, reason}) do
    {:ref_resolution_error, nil, inspect(reason), nil, nil, nil}
  end

  defp parse_failure_reason(other) do
    {:unknown, nil, inspect(other), nil, nil, nil}
  end

  # Extract a human message from an assertion/exception reason. The
  # is_exception clause MUST precede %{message: msg}: exceptions like
  # KeyError/FunctionClauseError carry message: nil and compute it lazily,
  # so matching the map first yielded empty strings.
  defp extract_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp extract_message(%{message: msg}) when is_binary(msg), do: msg
  defp extract_message(msg) when is_binary(msg), do: msg
  defp extract_message(other), do: inspect(other)

  defp format_poll_timeout_message(info) do
    """
    Temporal assertion #{info.triggered_by.assertion_name} timed out after #{info.elapsed_ms}ms.
    Trigger event: #{inspect(info.triggered_by.event)}
    Predicate: #{info.predicate_source || "unknown"}
    Final state: #{inspect(info.final_state, limit: 5)}
    Poll attempts: #{info.poll_count}
    """
  end

  defp format_idempotency_message(%{command: command, comparison_result: result}) do
    cmd_name = command.__struct__ |> Module.split() |> List.last()
    "Command #{cmd_name} produced different events on retry: #{inspect(result)}"
  end

  defp format_idempotency_message(violation) do
    inspect(violation)
  end

  defp extract_failure_context(_sequence, _event_log, nil, _branch_id), do: {nil, []}

  defp extract_failure_context(sequence, event_log, failed_at_index, branch_id) do
    command = command_at(sequence, failed_at_index, branch_id)

    events =
      event_log
      |> Enum.filter(fn entry ->
        entry.command_index == failed_at_index and entry.branch_id == branch_id
      end)
      |> Enum.map(& &1.event)

    {command, events}
  end

  # Resolve an executor command index against the sequence structure.
  # Executor indexing: prefix commands are 0..len(prefix)-1; EVERY branch's
  # commands continue from len(prefix) (overlapping across branches, hence
  # branch_id); suffix indices continue after the SUM of branch lengths.
  defp command_at(sequence, index, branch_id) do
    cond do
      Sequence.linear?(sequence) ->
        sequence |> Sequence.to_list() |> Enum.at(index)

      branch_id != nil ->
        branch = Enum.at(sequence.branches || [], branch_id) || []
        Enum.at(branch, index - length(sequence.prefix))

      index < length(sequence.prefix) ->
        Enum.at(sequence.prefix, index)

      true ->
        total_branch = sequence.branches |> Enum.map(&length/1) |> Enum.sum()
        Enum.at(sequence.suffix, index - length(sequence.prefix) - total_branch)
    end
  end

  defp extract_branch_events(event_log) do
    event_log
    |> Enum.filter(fn entry -> entry.branch_id != nil end)
    |> Enum.group_by(& &1.branch_id)
    |> case do
      empty when map_size(empty) == 0 -> nil
      grouped -> grouped
    end
  end
end

defimpl Inspect, for: PropertyDamage.FailureReport do
  def inspect(report, opts) do
    # For IEx/IO.inspect, show the formatted report instead of raw struct. The
    # formatters assume a report built by FailureReport.new (real sequence and
    # timestamp); a hand-built or partially-deserialized struct can crash them,
    # so guard with a minimal, always-safe fallback rather than letting inspect/1
    # blow up into an #Inspect.Error<...>.
    if opts.limit == :infinity or opts.pretty do
      # User wants detailed output - show formatted report
      formatted = PropertyDamage.FailureReport.Formatter.format(report, :terminal, color: false)
      Inspect.Algebra.concat(["#FailureReport<\n", formatted, ">"])
    else
      # Brief output - show compact format
      compact = PropertyDamage.FailureReport.Formatter.format(report, :compact)
      Inspect.Algebra.concat(["#FailureReport<", compact, ">"])
    end
  rescue
    _ -> fallback(report)
  catch
    _, _ -> fallback(report)
  end

  defp fallback(report) do
    type = report.failure_type || :unknown

    Inspect.Algebra.concat([
      "#FailureReport<",
      "seed: #{inspect(report.seed)}, ",
      "type: #{inspect(type)}, ",
      "failed_at: #{inspect(report.failed_at_index)}",
      ">"
    ])
  end
end
