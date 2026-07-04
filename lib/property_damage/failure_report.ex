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
        failure_reason: Failure.assertion_failed(:NonNegativeBalance, "...")
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

  The `failure_reason` field holds a `%PropertyDamage.Failure{}` describing what
  failed (see that module for the class/kind vocabulary). Convenience accessors
  derive the common views: `failure_type/1` (the kind), `check_name/1`,
  `failure_message/1`, `idempotency_violation/1`, and `poll_timeout_info/1`.
  """

  alias PropertyDamage.{ErrorOrigin, EventLog.Entry, Failure, RunTrace, Sequence}
  alias PropertyDamage.Failure.Assertion
  alias PropertyDamage.RunTrace.Step

  @typedoc "The failure's kind (`PropertyDamage.Failure.kind/1`)."
  @type failure_type :: Failure.kind()

  @type t :: %__MODULE__{
          # Location
          seed: integer(),
          run_number: non_neg_integer(),
          failed_at_index: non_neg_integer() | nil,

          # The execution record of the run this report describes (DR-033). The
          # deep structures (plan, event_log, executed) live here once;
          # `shrunk_sequence/1` and `event_log/1` are accessors over it.
          trace: RunTrace.t(),

          # The generated plan of the failing exploration run (before shrinking).
          # Distinct from `trace.plan`, which is the shrunk minimal reproduction
          # (or the original run when it didn't reproduce; see DR-033).
          original_sequence: Sequence.t(),

          # Failure details: the structured %Failure{}. The kind / check name /
          # message / idempotency violation / poll-timeout info are derived views
          # over this, exposed as accessor functions (failure_type/1, check_name/1,
          # failure_message/1, idempotency_violation/1, poll_timeout_info/1).
          failure_reason: Failure.t() | nil,

          # State snapshots
          state_before_failure: %{atom() => any()} | nil,
          state_at_failure: %{atom() => any()} | nil,

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

          # Invariant identity + coverage (DR-026). The name is derived from the
          # model's catalog and the failing check (invariant_name/1); the
          # description is resolved once at construction.
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
            trace: nil,
            original_sequence: nil,
            failure_reason: nil,
            state_before_failure: nil,
            state_at_failure: nil,
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

    # The failing check name (for invariant resolution) and the branch, derived
    # straight from the structured %Failure{}.
    check_name = failure_check_name(failure_reason)
    branch_id = failure_branch_id(failure_reason)

    # Extract branch events if parallel
    branch_events = extract_branch_events(event_log)

    # Classify error origin
    classification = ErrorOrigin.classify(failure_reason, stacktrace)

    # Resolve the invariant the failing assertion checks (DR-026), so the report
    # can headline the named property and the formatter stays pure.
    {_invariant_name, invariant_description} =
      resolve_invariant(Keyword.get(opts, :model), check_name)

    # Lazily reconstruct each command's human-readable label (P7). Only runs at
    # report construction (i.e. on a failure), so passing/generation runs pay
    # nothing.
    command_labels = build_command_labels(shrunk_sequence, Keyword.get(opts, :model))

    timestamp = DateTime.utc_now()

    # Compose the execution record of the run this report describes (DR-033). The
    # plan is the shrunk minimal reproduction when it reproduced, else the
    # original failing run; the caller signals which via `:plan_source`
    # (defaults to `:shrunk`, the common case).
    trace =
      RunTrace.new(
        seed: seed,
        run_number: run_number,
        run_nonce: Keyword.get(opts, :run_nonce),
        mint_epoch: Keyword.get(opts, :mint_epoch),
        model: Keyword.get(opts, :model),
        adapter: Keyword.get(opts, :adapter),
        timestamp: timestamp,
        source_revision: Keyword.get(opts, :source_revision),
        plan: shrunk_sequence,
        plan_source: Keyword.get(opts, :plan_source, :shrunk),
        executed: Keyword.get(opts, :executed, %{}),
        event_log: event_log,
        command_labels: command_labels,
        # P8 / DR-040: the fold-order record so the trace can derive the per-step
        # state timeline and the report can run the projection-purity check.
        command_fold_ordinals: Keyword.get(opts, :command_fold_ordinals, %{}),
        linearization: Keyword.get(opts, :linearization),
        outcome: {:fail, failure_reason}
      )

    %__MODULE__{
      seed: seed,
      run_number: run_number,
      failed_at_index: failed_at_index,
      trace: trace,
      original_sequence: original_sequence,
      failure_reason: failure_reason,
      state_before_failure: projections_before,
      state_at_failure: projections,
      branch_id: branch_id,
      linearization: Keyword.get(opts, :linearization),
      branch_events: branch_events,
      shrink_iterations: Keyword.get(opts, :shrink_iterations, 0),
      shrink_time_ms: Keyword.get(opts, :shrink_time_ms, 0),
      model: Keyword.get(opts, :model),
      adapter: Keyword.get(opts, :adapter),
      timestamp: timestamp,
      error_origin: classification.origin,
      error_origin_details: classification.details,
      stacktrace: stacktrace,
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
      shrunk_sequence: shrunk_sequence(report),
      failed_at_index: report.failed_at_index,
      failure_reason: report.failure_reason,
      shrink_iterations: report.shrink_iterations,
      shrink_time_ms: report.shrink_time_ms
    }
  end

  @doc """
  The plan the report describes: the shrunk minimal reproduction (or the
  original failing run when it did not reproduce; see DR-033).

  Accessor over the embedded `RunTrace` (DR-033: the deep structure lives once,
  on the trace). Returns `nil` for a report with no trace.
  """
  @spec shrunk_sequence(t()) :: Sequence.t() | nil
  def shrunk_sequence(%__MODULE__{trace: %RunTrace{plan: plan}}), do: plan
  def shrunk_sequence(%__MODULE__{trace: nil}), do: nil

  @doc """
  The complete event log of the run the report describes.

  Accessor over the embedded `RunTrace` (DR-033). Returns `[]` for a report with
  no trace.
  """
  @spec event_log(t()) :: [Entry.t()]
  def event_log(%__MODULE__{trace: %RunTrace{event_log: log}}), do: log
  def event_log(%__MODULE__{trace: nil}), do: []

  @doc """
  The event-log entries with no command attribution (`command_index: nil`).

  Delegates to `RunTrace.async_entries/1`. Injector / telemetry / async-source
  events that belong to no command; renderers show them separately.
  """
  @spec async_entries(t()) :: [Entry.t()]
  def async_entries(%__MODULE__{trace: %RunTrace{} = trace}), do: RunTrace.async_entries(trace)
  def async_entries(%__MODULE__{trace: nil}), do: []

  @doc """
  Classify a `%Failure{}` into its `{kind, name}`.

  For callers (e.g. the seed-library replay phase) that hold an executor
  `failure_reason` and only need the descriptive kind/name, without building a
  full report.
  """
  @spec classify_reason(term()) :: {failure_type() | nil, atom() | nil}
  def classify_reason(%Failure{} = failure), do: {Failure.kind(failure), Failure.name(failure)}
  def classify_reason(_failure_reason), do: {nil, nil}

  @doc """
  Get a summary string for the failure type.
  """
  @spec failure_type_summary(t()) :: String.t()
  def failure_type_summary(%__MODULE__{} = report) do
    check_name = check_name(report)

    case failure_type(report) do
      :assertion_failed -> "Invariant Violation: #{check_name}"
      :projection_violation -> "Invariant Violation: #{check_name}"
      :idempotency_violation -> "Idempotency Violation"
      :poll_timeout -> "Poll Timeout: #{check_name}"
      :poll_error -> "Poll Predicate Error"
      :adapter_error -> "Adapter Error"
      :settle_timeout -> "Settle Timeout"
      :nemesis_error -> "Fault Injection Error"
      :resource_poller_error -> "Resource Poller Error"
      :stutter_execution_failed -> "Stutter Execution Failed"
      :retry_from_sync_command -> "Sync Command Returned Retry"
      :malformed_adapter_return -> "Malformed Adapter Return"
      :linearization -> "Linearization Failed"
      :placeholder_resolution -> "Placeholder Resolution Error"
      :unknown -> "Unknown Failure"
      # Total fallback (e.g. nil on a hand-built struct) so rendering/Inspect
      # never crashes with a CaseClauseError
      _ -> "Failure"
    end
  end

  # ==========================================================================
  # Failure-reason accessors (derived views over the %Failure{})
  # ==========================================================================

  @doc "The failure's kind (`PropertyDamage.Failure.kind/1`), or `:unknown`."
  @spec failure_type(t()) :: failure_type()
  def failure_type(%__MODULE__{failure_reason: %Failure{} = f}), do: Failure.kind(f)
  def failure_type(%__MODULE__{}), do: :unknown

  @doc "The failing assertion/check/projection name, or `nil`."
  @spec check_name(t()) :: atom() | nil
  def check_name(%__MODULE__{failure_reason: fr}), do: failure_check_name(fr)

  @doc "A human-readable message describing the failure, or `nil`."
  @spec failure_message(t()) :: String.t() | nil
  def failure_message(%__MODULE__{failure_reason: %Failure{} = f}), do: message_for(f)
  def failure_message(%__MODULE__{}), do: nil

  @doc "The `%Stutter.Violation{}` for an idempotency failure, or `nil`."
  @spec idempotency_violation(t()) :: map() | nil
  def idempotency_violation(%__MODULE__{
        failure_reason: %Failure{type: %Assertion{kind: :idempotency_violation, detail: v}}
      }),
      do: v

  def idempotency_violation(%__MODULE__{}), do: nil

  @doc "The poll-timeout info map for a `@poll_state` timeout, or `nil`."
  @spec poll_timeout_info(t()) :: map() | nil
  def poll_timeout_info(%__MODULE__{
        failure_reason: %Failure{type: %Assertion{kind: :poll_timeout, detail: info}}
      }),
      do: info

  def poll_timeout_info(%__MODULE__{}), do: nil

  @doc "The named invariant the failing check validates (DR-026), or `nil`."
  @spec invariant_name(t()) :: atom() | nil
  def invariant_name(%__MODULE__{model: model} = report) do
    {name, _description} = resolve_invariant(model, check_name(report))
    name
  end

  @doc """
  Check if this is a poll timeout failure.
  """
  @spec poll_timeout_failure?(t()) :: boolean()
  def poll_timeout_failure?(%__MODULE__{} = report), do: failure_type(report) == :poll_timeout

  @doc """
  Check if this is a parallel execution failure.
  """
  @spec parallel_failure?(t()) :: boolean()
  def parallel_failure?(%__MODULE__{failure_reason: %Failure{} = f}) do
    Failure.kind(f) == :linearization or Failure.branch_id(f) != nil
  end

  def parallel_failure?(%__MODULE__{}), do: false

  @doc """
  Check if this is an idempotency failure.
  """
  @spec idempotency_failure?(t()) :: boolean()
  def idempotency_failure?(%__MODULE__{} = report),
    do: failure_type(report) == :idempotency_violation

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
  observed log entries, label, and a `failed?` flag. This is the structural
  accessor callers use instead of re-walking `shrunk_sequence` / `event_log` /
  `failed_at_index` themselves; `event_entries_at/2` and `failure_step/1` are
  sugar over it.

  Returns `[]` for a report with no sequence (e.g. a partially hand-built
  struct).
  """
  @spec steps(t()) :: [Step.t()]
  def steps(%__MODULE__{trace: nil}), do: []
  def steps(%__MODULE__{trace: %RunTrace{plan: nil}}), do: []

  def steps(%__MODULE__{trace: %RunTrace{plan: %Sequence{} = plan} = trace} = report) do
    # Delegate to the trace's data and the shared grouping core (DR-033), adding
    # the report's failure-localization overlay (`failed_at_index` / `branch_id`
    # stay report-level). Output is identical to the pre-move behavior.
    RunTrace.build_steps(plan, trace.event_log, trace.command_labels, report.failed_at_index,
      branch_id: report.branch_id,
      executed: trace.executed
    )
  end

  @doc """
  The `EventLog.Entry` structs observed for a single command, addressed by
  flattened index or `Sequence.Position`.

  Delegates to `RunTrace.event_entries_at/2` (entries are independent of failure
  localization). Each entry carries its per-event provenance (`source`,
  `branch_id`); the bare event struct is `entry.event`. Returns `[]` when
  nothing matches.
  """
  @spec event_entries_at(t(), non_neg_integer() | Sequence.Position.t()) :: [Entry.t()]
  def event_entries_at(%__MODULE__{trace: %RunTrace{} = trace}, index_or_position) do
    RunTrace.event_entries_at(trace, index_or_position)
  end

  def event_entries_at(%__MODULE__{trace: nil}, _index_or_position), do: []

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

  @doc """
  The flattened (reading-order) index of the failing command, for reader-facing
  display.

  This is the ordinal into `steps/1` / `Sequence.to_list/1`, i.e. the number a
  reader cross-references against the reproduction listing. It differs from the
  raw `failed_at_index` field, which is the *executor* command index and diverges
  from the flattened ordinal for parallel-branch failures. Falls back to
  `failed_at_index` when the failure can't be localized to a step (typically
  `nil`, e.g. a teardown / whole-run / linearization failure).
  """
  @spec failure_index(t()) :: non_neg_integer() | nil
  def failure_index(%__MODULE__{} = report) do
    case failure_step(report) do
      %Step{flattened_index: index} -> index
      nil -> report.failed_at_index
    end
  end

  @doc """
  Projection-purity check: does the faithful per-step state derived from the
  trace match the authoritative runtime snapshots? (P8 / DR-040.)

  Re-derives the projection state at the failing step from the recorded fold
  order (`RunTrace.state_before/2` / `state_at/2`) and compares it to the
  runtime `state_before_failure` / `state_at_failure` snapshots. Pure
  projections re-derive identically; a mismatch means a projection read
  something outside its `(state, event)` inputs in `apply/2` (a clock, a
  counter, the environment).

  Because the derivation replays the run's *real* fold order, a pure-but-async
  projection (late-settling events) re-derives correctly and does NOT
  false-positive — that is the load-bearing property of this check.

  This is a two-point sample (before + at the failing step), so it is partial
  coverage: it proves purity at the failure boundary, not across the whole run.

  Returns:

    * `:ok` — the derived state matched both snapshots (or there was nothing to
      check: no localized failure step, or empty snapshots).
    * `{:non_pure_projections, [module()]}` — the projection modules whose
      derived state diverged from a snapshot.
  """
  @spec verify_projections(t()) :: :ok | {:non_pure_projections, [module()]}
  def verify_projections(%__MODULE__{trace: %RunTrace{} = trace} = report) do
    case failure_step(report) do
      %Step{position: position} ->
        before_result =
          RunTrace.verify_projections(
            trace,
            position,
            report.state_before_failure || %{},
            :before
          )

        at_result =
          RunTrace.verify_projections(trace, position, report.state_at_failure || %{}, :at)

        merge_purity_results([before_result, at_result])

      nil ->
        :ok
    end
  end

  def verify_projections(%__MODULE__{trace: nil}), do: :ok

  defp merge_purity_results(results) do
    modules =
      results
      |> Enum.flat_map(fn
        :ok -> []
        {:non_pure_projections, mods} -> mods
      end)
      |> Enum.uniq()
      |> Enum.sort()

    if modules == [], do: :ok, else: {:non_pure_projections, modules}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp failure_check_name(%Failure{} = failure), do: Failure.name(failure)
  defp failure_check_name(_), do: nil

  defp failure_branch_id(%Failure{} = failure), do: Failure.branch_id(failure)
  defp failure_branch_id(_), do: nil

  # Human-readable message for each failure kind, mirroring the per-tag wording
  # the old parser produced.
  defp message_for(%Failure{type: %Assertion{kind: :assertion_failed, detail: detail}}),
    do: extract_message(detail)

  defp message_for(%Failure{type: %Assertion{kind: :idempotency_violation, detail: violation}}),
    do: format_idempotency_message(violation)

  defp message_for(%Failure{type: %Assertion{kind: :linearization, detail: message}}),
    do: to_string(message)

  defp message_for(%Failure{type: %Assertion{kind: :poll_timeout, detail: info}}),
    do: format_poll_timeout_message(info)

  defp message_for(%Failure{type: %Assertion{kind: :settle_timeout, detail: reason}}),
    do: "Command did not settle: #{inspect(reason)}"

  defp message_for(%Failure{type: %Assertion{kind: :projection_violation} = t}) do
    "projection #{inspect(t.name)} rejected the transition: " <> extract_message(t.detail)
  end

  defp message_for(%Failure{type: %Failure.Execution{kind: :adapter_error, detail: reason}}),
    do: extract_message(reason)

  defp message_for(%Failure{type: %Failure.Execution{kind: :nemesis_error, detail: reason}}),
    do: "Fault injection failed: #{inspect(reason)}"

  defp message_for(%Failure{type: %Failure.Execution{kind: :resource_poller_error, detail: reason}}),
    do: "Resource poller error: #{inspect(reason)}"

  defp message_for(%Failure{
         type: %Failure.Execution{kind: :stutter_execution_failed, detail: details}
       }),
       do: "Stutter retry failed: #{inspect(details)}"

  defp message_for(%Failure{type: %Failure.Execution{kind: :poll_error, detail: reason}}),
    do: "Poll predicate error: #{inspect(reason)}"

  defp message_for(%Failure{type: %Failure.Framework{kind: :placeholder_resolution, detail: reason}}),
    do: inspect(reason)

  defp message_for(%Failure{type: type}), do: inspect(type.detail)

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
    type = PropertyDamage.FailureReport.failure_type(report)

    Inspect.Algebra.concat([
      "#FailureReport<",
      "seed: #{inspect(report.seed)}, ",
      "type: #{inspect(type)}, ",
      "failed_at: #{inspect(report.failed_at_index)}",
      ">"
    ])
  end
end
