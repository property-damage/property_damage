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
  alias PropertyDamage.FailureReport.Step

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
          failed_at_index: non_neg_integer() | nil,
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
          stacktrace: list() | nil,

          # Invariant identity + coverage (DR-026)
          invariant_name: atom() | nil,
          invariant_description: String.t() | nil,
          assertion_fires: %{{module(), atom()} => non_neg_integer()},

          # Human-readable command labels (DR-028 amendment, P7): keyed by the
          # flattened command index (the 0..n-1 index of `Sequence.to_list/1`,
          # which every formatter/exporter iterates with). Only commands whose
          # `label/2` returns a non-nil string appear.
          command_labels: %{non_neg_integer() => String.t()}
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
            stacktrace: nil,
            invariant_name: nil,
            invariant_description: nil,
            assertion_fires: %{},
            command_labels: %{}

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

    # Extract branch events if parallel
    branch_events = extract_branch_events(event_log)

    # Classify error origin
    classification = ErrorOrigin.classify(failure_reason, stacktrace)

    # Resolve the invariant the failing assertion checks (DR-026), so the report
    # can headline the named property and the formatter stays pure.
    {invariant_name, invariant_description} =
      resolve_invariant(Keyword.get(opts, :model), check_name)

    # Lazily reconstruct each command's human-readable label (P7). Only runs at
    # report construction (i.e. on a failure), so passing/generation runs pay
    # nothing.
    command_labels = build_command_labels(shrunk_sequence, Keyword.get(opts, :model))

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
      stacktrace: stacktrace,
      invariant_name: invariant_name,
      invariant_description: invariant_description,
      assertion_fires: Keyword.get(opts, :assertion_fires, %{}),
      command_labels: command_labels
    }
  end

  # Reconstruct command labels by folding the shrunk sequence through the model's
  # command_sequence_projection, computing each command's `label/2` against the
  # pre-state generation saw. The fold mirrors the generator's `update_state`
  # (`Generator.update_state/4`): apply the command, then each simulated event.
  #
  # Commands are folded in flattened (`Sequence.to_list/1`) order, and labels are
  # keyed by that flat index, so the displayed order a reader sees IS the order
  # the pre-states were folded in. For a branching sequence this is a
  # linearization (branch N's pre-state reflects earlier branches), matching the
  # linear reproduction the report renders rather than any per-branch fork.
  #
  # Best-effort and never load-bearing: a model without the callback, or any
  # error in user `label/2`/projection/simulator code, degrades to "no labels"
  # rather than failing the report being built for an unrelated failure.
  @spec build_command_labels(Sequence.t() | nil, module() | nil) ::
          %{non_neg_integer() => String.t()}
  defp build_command_labels(nil, _model), do: %{}
  defp build_command_labels(_sequence, nil), do: %{}

  defp build_command_labels(%Sequence{} = sequence, model) when is_atom(model) do
    projection = model.command_sequence_projection()

    {labels, _state} =
      sequence
      |> Sequence.to_list()
      |> Enum.with_index()
      |> Enum.reduce({%{}, projection.init()}, fn {command, index}, {acc, state} ->
        acc =
          case command_label(command, state) do
            label when is_binary(label) -> Map.put(acc, index, label)
            _ -> acc
          end

        {acc, advance_command_state(state, command, model, projection)}
      end)

    labels
  rescue
    _ -> %{}
  end

  # Call a command's optional `label/2` against its pre-state, guarding both the
  # not-loaded-module case (see PropertyDamage.Linearization) and a raising user
  # implementation.
  defp command_label(command, state) when is_struct(command) do
    module = command.__struct__

    if Code.ensure_loaded?(module) and function_exported?(module, :label, 2) do
      module.label(state, command)
    end
  rescue
    _ -> nil
  end

  defp command_label(_command, _state), do: nil

  # Advance the projection exactly as generation does: apply the command, then
  # the events the simulator predicts for it.
  defp advance_command_state(state, command, model, projection) do
    events =
      if Code.ensure_loaded?(model) and function_exported?(model, :simulator, 0) do
        model.simulator().simulate(command, state)
      else
        []
      end

    Enum.reduce(events, projection.apply(state, command), fn event, acc ->
      projection.apply(acc, event)
    end)
  end

  # Resolve the invariant a failing assertion (by its logical check name) checks,
  # returning {name, description}. Best-effort: a non-assertion failure (nil
  # check_name), a model without a catalog, or an unmatched name yields
  # {nil, nil}, so the formatter falls back to the bare assertion name.
  defp resolve_invariant(nil, _check_name), do: {nil, nil}
  defp resolve_invariant(_model, nil), do: {nil, nil}

  defp resolve_invariant(model, check_name) when is_atom(model) do
    if function_exported?(PropertyDamage.Model, :assertion_catalog, 1) do
      entry =
        model
        |> PropertyDamage.Model.assertion_catalog()
        |> Enum.find(fn %{checks: checks} ->
          Enum.any?(checks, &(&1.name == check_name))
        end)

      case entry do
        %{invariant: invariant} -> {invariant.name, invariant.description}
        nil -> {nil, nil}
      end
    else
      {nil, nil}
    end
  rescue
    _ -> {nil, nil}
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
  Classify a raw `failure_reason` into its `{failure_type, check_name}`.

  Exposes the same parsing `new/1` uses, for callers (e.g. the seed-library
  replay phase) that hold a raw executor `failure_reason` and only need the
  descriptive type/check, without building a full report.
  """
  @spec classify_reason(term()) :: {failure_type() | nil, atom() | nil}
  def classify_reason(failure_reason) do
    {failure_type, check_name, _msg, _idem, _poll, _branch} =
      parse_failure_reason(failure_reason)

    {failure_type, check_name}
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

  @doc """
  The failed run as a timeline of `Step` structs, in flattened (reading) order.

  Each step pairs a command with its `Sequence.Position`, flattened index,
  observed events, label, and a `failed?` flag. This is the structural
  accessor callers use instead of re-walking `shrunk_sequence` / `event_log` /
  `failed_at_index` themselves; `events_at/2` and `failure_step/1` are sugar
  over it.

  Returns `[]` for a report with no sequence (e.g. a partially hand-built
  struct).
  """
  @spec steps(t()) :: [Step.t()]
  def steps(%__MODULE__{shrunk_sequence: nil}), do: []

  def steps(%__MODULE__{shrunk_sequence: %Sequence{} = sequence} = report) do
    # Group command-produced events by the position of the command that produced
    # them. Injector/telemetry events carry no command_index and so belong to no
    # step. `(command_index, branch_id)` resolves uniquely to a position, so this
    # is the branch-aware equivalent of grouping by command_index alone.
    events_by_position =
      report.event_log
      |> Enum.filter(&(&1.command_index != nil))
      |> Enum.group_by(
        fn entry -> Sequence.position_at(sequence, entry.command_index, entry.branch_id) end,
        & &1.event
      )

    # The failing command's position (nil for a non-localized failure). Resolved
    # via position_at, NOT by comparing flattened_index to failed_at_index: the
    # latter is an executor index and diverges from the flattened ordinal for
    # branch failures.
    failed_position =
      if report.failed_at_index != nil do
        Sequence.position_at(sequence, report.failed_at_index, report.branch_id)
      end

    sequence
    |> Sequence.indexed()
    |> Enum.map(fn {position, flattened_index, command} ->
      %Step{
        position: position,
        flattened_index: flattened_index,
        command: command,
        events: Map.get(events_by_position, position, []),
        label: Map.get(report.command_labels, flattened_index),
        failed?: failed_position != nil and position == failed_position
      }
    end)
  end

  @doc """
  The events observed for a single command, addressed by flattened index or
  `Sequence.Position`.

  Sugar over `steps/1`. Returns `[]` when nothing matches.
  """
  @spec events_at(t(), non_neg_integer() | Sequence.Position.t()) :: [struct()]
  def events_at(%__MODULE__{} = report, %Sequence.Position{} = position) do
    report
    |> steps()
    |> Enum.find(&(&1.position == position))
    |> step_events()
  end

  def events_at(%__MODULE__{} = report, flattened_index) when is_integer(flattened_index) do
    report
    |> steps()
    |> Enum.find(&(&1.flattened_index == flattened_index))
    |> step_events()
  end

  defp step_events(nil), do: []
  defp step_events(%Step{events: events}), do: events

  @doc """
  The `Step` where the failure was localized, or `nil`.

  Returns `nil` for non-localized failures (teardown / whole-run / linearization
  checks, where `failed_at_index` is `nil`). At most one step is ever the failure
  step.
  """
  @spec failure_step(t()) :: Step.t() | nil
  def failure_step(%__MODULE__{} = report) do
    report |> steps() |> Enum.find(& &1.failed?)
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
