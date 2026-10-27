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
        failure_reason: Failure.check_failed(:NonNegativeBalance, "...")
      )

  ## Printing Reports

  Inspecting a report prints it in full, as the guides show:

      IO.inspect(report, pretty: true)

  A plain `inspect/1` prints a one-line summary. To turn a report into a test,
  a script or a notebook, see `PropertyDamage.Export`; to save it, see
  `PropertyDamage.save_failure/3`.

  ## Failure Reasons

  The `failure_reason` field holds a `%PropertyDamage.Failure{}` describing what
  failed (see that module for the class/kind vocabulary).

  ## Report kind and the failing target

  `kind` sorts every failure into one of a few outcomes, whatever its
  fine-grained `Failure.kind/1` (which stays inside `failure_reason`):

  - `:check_failed` - a check did not hold: a check at a command, an
    `@eventually` timeout, a `:startup` or finalization check, an idempotency
    or linearization violation.
  - `:diverged` - a target's boundary observation (a `@compare` function)
    still differed from the reference's when the convergence bound expired.
  - `:setup_failed` - a target's adapter `setup/1` returned an error or raised.
  - `:execution_failed` - a command could not be executed: an adapter raise,
    a command the framework could not run, and, in a one-target run, an
    adapter `{:error, _}` answer.
  - `:did_not_converge` - a target's boundary observation was still pending
    when the convergence bound expired.
  - `:latency_exceeded` - a target's latency statistic exceeded a `latency:`
    bound over the whole campaign. The campaign judges the budget once after
    its last run, so the report is not localized to a command
    (`failed_at_index: nil`) and is never shrunk (`shrink_iterations: 0`);
    `original_sequence` and `shrunk_sequence` hold the last run's sequence for
    the record, and `seed` and `run_number` that run's.

  ## Reproduction inputs

  Besides `seed`, `targets` and `concurrency`, a report records the run
  options that decide whether the failure reproduces: `compare` (the run's
  `compare:`, `[converge_within: ms]`), `stutter` (the run's
  normalized `stutter:` option, or `nil` when stutter was off) and
  `max_commands` (the run's `max_commands:`, which decides the sequence the
  seed generates) and `check_mode` (the run's `check_mode:`).
  `reproduction_command/1` prints each one that differs from its default, and
  `PropertyDamage.shrink_further/2` re-shrinks under them; `PropertyDamage.Replay`
  replays under the report's `check_mode` too.

  `campaign` records the campaign a `:latency_exceeded` report judged its
  budget over, `%{seed: seed, max_runs: n}` (the run's `seed:` and
  `max_runs:`), and is `nil` for every other kind: a latency budget is
  reproduced by running the whole campaign again, so its
  `reproduction_command/1` names that seed and `max_runs:`, while every other
  failure reproduces one run of its own `seed` with `max_runs: 1`.

  `setup_commands` and `teardown_commands` list the setup and teardown
  commands of the reported sequence (the shrunk one when it reproduced, else
  the original), which every reproduction runs before and after the roots.

  `variant` names the target the failure happened in (`%{index:, name:}`, its
  position in `targets:` and its name; index 0 in a one-target run), and
  `targets` holds the run's `targets:` entries in order, the first being the
  reference. `failed_at_index` is the index of the command the failure belongs
  to in the sequence the report describes (`shrunk_sequence/1`), and `nil`
  for a setup failure or a failed `:startup` check. `original_failed_at_index`
  is the index the failure had in the run that found it, in
  `original_sequence`: the two differ when the report describes a
  reproduction that failed at another command, a shrunk one or an unshrunk
  one alike.

  `other_failures` lists the run's other failures when several targets failed
  in one run (see `PropertyDamage.Scheduler`): the reported failure is the
  first in root order, then target order, and each other one is
  `%{variant: %{index:, name:}, root: root, failure: %PropertyDamage.Failure{}}`,
  in the same order. It is `[]` when the run failed once. Shrinking keeps the
  reported failure only; the other failures of the shrunk run may differ.

  `latency` holds the run's `latency:` option as given (`false` when off) and
  `metrics` the latency metrics measured per target name, `%{target_name =>
  metrics}` (see `PropertyDamage.run/1`): all of the campaign's measured runs
  in a `:latency_exceeded` report, the runs measured up to the failure in a
  report of another kind, and `nil` when `latency:` is off.

  ## Replay artifact

  `run` is the campaign run the failure happened in, counting from 1 (run 3
  of a `max_runs: 10` campaign); `seed` is the seed that run generated from,
  so the failing run is run 1 of `seed`.

  A failing run writes a replay artifact after shrinking (see the
  `replay_dir:` run option): one Elixir file holding, as literal data, the
  setup commands, the roots and the commands every target ran at each root.
  `replay` holds its term (or `{:refused, where}` when a command field holds
  a function, pid, reference or port, which no file can hold), `replay_path`
  the file, and `replay_status` what became of it (see `t:replay_status/0`).
  The printed report ends with three calls: `reproduction_command/1` (the
  seed, before shrinking), `expansion_command/1` (the failing target's
  sequence, regenerated) and, last, `replay_command/1`, which runs the
  artifact with `only: [replay: path]`.

  Every path that executes the failure again reads what each target ran
  from `replay` (or, when the report has no term, from the choices its trace
  records): `PropertyDamage.shrink_further/2`, `PropertyDamage.Replay`,
  `PropertyDamage.Analysis.isolate_trigger/2` and the exports. They work for
  every target the report records, leaves included.

  ## The reference side of a comparison failure

  For `:diverged` and `:did_not_converge`, the report also keeps what the
  reference target did in the reported run, so a reader can set both sides
  side by side:

    * `reference_trace` - the reference target's `PropertyDamage.RunTrace` of
      the reported run. `trace` and `reference_trace` always come from the
      same run: the shrunk reproduction when the shrinker reproduced the
      failure, else the original run.
    * `reference_state_at_failure` - the reference's projection state at the
      failing boundary, `%{projection_module => state}` like
      `state_at_failure`. It holds every fold up to the last one attributed to
      the failing root, the folds of the leaf commands that root ran included,
      and nothing applied after the boundary: not the events of the teardown
      commands, and not what the run folded while it finalized.

  Every other kind leaves both fields `nil`. `reference_steps/1` and
  `reference_event_log/1` read the reference's trace the way `steps/1` and
  `event_log/1` read the failing target's, which they keep meaning.

  `shrink_stop` records why the shrinker stopped: `:done` when it finished
  inside its budget or never ran (`shrink: false`, a setup failure, a latency
  report), `:max_iterations` or `:max_time` when a budget ran out first (the
  iteration cap wins when both did), so the minimal reproduction may not be
  minimal. It is `nil` on a report saved before the field existed.

  `compare_counts` holds, per boundary observation `{projection, function}`,
  how many boundaries the failing run compared it at, how many it waited at,
  and the total time it waited (`%{compared_at:, waited_at:, waited_ms:}`),
  beside `check_fires`. `check_fires` counts each check's firings over the
  campaign's runs before the failing one plus the run the report describes;
  `run_check_fires` holds that run's own share, so a further shrink can
  replace it with its reproduction's. Convenience accessors
  derive the common views: `failure_type/1` (the kind), `check_name/1`,
  `failure_message/1`, `idempotency_violation/1`, and `poll_timeout_info/1`.
  """

  alias PropertyDamage.{ErrorOrigin, EventLog.Entry, Failure, LatencyMetrics, RunTrace, Sequence}
  alias PropertyDamage.Failure.Check

  # The `max_commands:` default of `PropertyDamage.run/1`; a reproduction
  # command prints the option only when the run used another value.
  @default_max_commands 50
  # The `compare: [converge_within:]` default; printed only when another.
  @default_converge_within 5_000
  alias PropertyDamage.RunTrace.Step

  @typedoc "The failure's kind (`PropertyDamage.Failure.kind/1`)."
  @type failure_type :: Failure.kind()

  @typedoc "The outcome a report describes; see \"Report kind and the failing target\"."
  @type kind ::
          :check_failed
          | :diverged
          | :setup_failed
          | :execution_failed
          | :did_not_converge
          | :latency_exceeded

  @typedoc "A target's position in `targets:` and its name."
  @type variant :: %{index: non_neg_integer(), name: String.t()}

  @typedoc "Another failure of the same run: the target, the root and the failure."
  @type other_failure :: %{
          variant: variant(),
          root: non_neg_integer() | nil,
          failure: Failure.t()
        }

  @typedoc """
  What became of a report's replay artifact:

    * `:written` - written to `replay_path`
    * `:disabled` - not written: the run was given `replay_dir: false`
    * `{:write_failed, reason}` - not written: the directory or the file
      could not be written
    * `:refused` - not built: a command field holds a value no file can hold
      (`replay` names where)
    * `:unavailable` - no artifact can describe the run: a latency budget
      judged over the whole campaign, or a branching sequence
    * `:reproduced` - the run replayed the artifact at `replay_path` and
      failed as it records
    * `:not_reproduced` - the run replayed the artifact at `replay_path` and
      failed another way
  """
  @type replay_status ::
          :written
          | :disabled
          | {:write_failed, term()}
          | :refused
          | :unavailable
          | :reproduced
          | :not_reproduced
          | nil

  @typedoc "A `targets:` entry in its normalized form: the adapter module and its options."
  @type target_entry :: {module(), keyword()}

  @type t :: %__MODULE__{
          # Location
          seed: integer(),
          run_number: non_neg_integer(),
          failed_at_index: non_neg_integer() | nil,
          original_failed_at_index: non_neg_integer() | nil,

          # What failed and where
          kind: kind() | nil,
          variant: variant() | nil,
          targets: [target_entry()],
          concurrency: :serial | :parallel,

          # The run options a reproduction needs (see "Reproduction inputs").
          compare: [converge_within: pos_integer()],
          stutter: keyword() | nil,
          max_commands: pos_integer() | nil,
          check_mode: :halt | :record | :log | :disabled,
          campaign: %{seed: integer(), max_runs: pos_integer()} | nil,
          latency: false | true | keyword(),
          metrics: %{String.t() => map()} | nil,

          # The execution record of the run this report describes (DR-033). The
          # deep structures (plan, event_log, executed) live here once;
          # `shrunk_sequence/1` and `event_log/1` are accessors over it.
          trace: RunTrace.t(),

          # The reference target's trace of the same run, and its projection
          # state at the failing boundary, for `:diverged` and
          # `:did_not_converge`; nil for every other kind (see "The reference
          # side of a comparison failure").
          reference_trace: RunTrace.t() | nil,
          reference_state_at_failure: %{atom() => any()} | nil,

          # The setup and teardown commands of the reported sequence (the
          # shrunk one when it reproduced, else the original), with concrete
          # arguments and placeholders symbolic.
          setup_commands: [struct()],
          teardown_commands: [struct()],

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
          shrink_stop: PropertyDamage.Shrinker.stop_reason() | nil,

          # Metadata
          model: module() | nil,
          timestamp: DateTime.t(),

          # Error origin classification
          error_origin: ErrorOrigin.origin() | nil,
          error_origin_details: ErrorOrigin.details() | nil,
          stacktrace: list() | nil,

          # Invariant identity + coverage (DR-026). The name is derived from the
          # model's catalog and the failing check (invariant_name/1); the
          # description is resolved once at construction.
          invariant_description: String.t() | nil,
          check_fires: %{{module(), atom()} => non_neg_integer()},
          # The share of `check_fires` the run the report describes fired.
          run_check_fires: %{{module(), atom()} => non_neg_integer()},
          other_failures: [other_failure()],
          compare_counts: %{
            {module(), atom()} => %{
              compared_at: non_neg_integer(),
              waited_at: non_neg_integer(),
              waited_ms: non_neg_integer()
            }
          },

          # What each target ran at each root it executed, by target name: the
          # entry key (`"Root[i]"`), nil when no expansion applied, `:forced`,
          # or `:identity` for a root that ran as itself in place of an entry
          # (shrinking collapsed it, or the entry realized was one leaf equal
          # to the root), and the modules of the commands it executed for the
          # root.
          # `root` is the root's index in the reported sequence.
          expansions: %{
            String.t() => [
              %{
                root: non_neg_integer(),
                entry: String.t() | nil | :forced | :identity,
                leaves: [module()]
              }
            ]
          },

          # Per target name and root module: how many times each entry was
          # realized, `:forced` and `:identity` roots, over the runs that
          # passed before the failure and the reported (shrunk) failing run.
          expansion_counts: %{
            String.t() => %{module() => %{(String.t() | :forced | :identity) => pos_integer()}}
          },

          # The campaign run the failure happened in, counting from 1
          # (`run_number + 1`).
          run: pos_integer() | nil,

          # The replay artifact (see "Replay artifact"): its term, or
          # `{:refused, refusal}` when a command field holds a value no file
          # can hold, or nil when the report has none; the path it was written
          # to, or nil; and what became of it.
          replay: map() | {:refused, map()} | nil,
          replay_path: String.t() | nil,
          replay_status: replay_status(),

          # Human-readable command labels (DR-028 amendment): keyed by the
          # flattened command index (the 0..n-1 index of `Sequence.to_list/1`,
          # which every formatter/exporter iterates with). Only commands whose
          # `label/2` returns a non-nil string appear.
          command_labels: %{non_neg_integer() => String.t()}
        }

  # The report is the complete record of a run, so it holds more fields than
  # the struct-size check allows.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct seed: nil,
            run_number: nil,
            failed_at_index: nil,
            original_failed_at_index: nil,
            kind: nil,
            variant: nil,
            targets: [],
            concurrency: :serial,
            compare: [converge_within: 5_000],
            stutter: nil,
            max_commands: nil,
            check_mode: :halt,
            campaign: nil,
            latency: false,
            metrics: nil,
            trace: nil,
            reference_trace: nil,
            reference_state_at_failure: nil,
            setup_commands: [],
            teardown_commands: [],
            original_sequence: nil,
            failure_reason: nil,
            state_before_failure: nil,
            state_at_failure: nil,
            branch_id: nil,
            linearization: nil,
            branch_events: nil,
            shrink_iterations: 0,
            shrink_time_ms: 0,
            shrink_stop: :done,
            model: nil,
            timestamp: nil,
            error_origin: nil,
            error_origin_details: nil,
            stacktrace: nil,
            invariant_description: nil,
            check_fires: %{},
            run_check_fires: %{},
            other_failures: [],
            compare_counts: %{},
            expansions: %{},
            expansion_counts: %{},
            command_labels: %{},
            run: nil,
            replay: nil,
            replay_path: nil,
            replay_status: nil

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
  - `:shrink_stop` - Why the shrinker stopped (default `:done`)
  - `:reference_result` - The reference target's finished result of the
    reported run (`event_log`, `executed`, `command_fold_ordinals`); for
    `:diverged` and `:did_not_converge` it becomes `reference_trace` and
    `reference_state_at_failure` (default `nil`)
  - `:model` - Model module
  - `:targets` - The run's `targets:` entries (normalized to `{adapter, options}`
    form), the reference first (default `[]`)
  - `:variant` - The target the failure happened in, `%{index:, name:}`
    (default: the reference target, or `nil` without targets)
  - `:kind` - The report kind (default: derived from `:failure_reason` by
    `kind_of/1`)
  - `:concurrency` - The run's `concurrency:` (default `:serial`)
  - `:compare` - The run's `compare:` (default `[converge_within: 5_000]`)
  - `:compare_counts` - The failing run's per-observation compare counts
    (default `%{}`)
  - `:run_check_fires` - The check firings of the run the report describes,
    the share of `:check_fires` that run fired (default `%{}`)
  - `:other_failures` - The run's other failures, `[%{variant:, root:,
    failure:}]` (default `[]`)
  - `:stutter` - The run's normalized `stutter:` option (default `nil`, stutter
    off)
  - `:max_commands` - The run's `max_commands:` (default `nil`, not recorded)
  - `:check_mode` - The run's `check_mode:` (default `:halt`)
  - `:campaign` - The campaign of a latency budget, `%{seed:, max_runs:}`
    (default `nil`)
  - `:original_failed_at_index` - The failing index in the run that found the
    failure (default: `:failed_at_index`)
  - `:latency` - The run's `latency:` option as given (default `false`)
  - `:metrics` - The latency metrics per target name measured so far (default
    `nil`, `latency:` off)
  - `:linearization` - Selected linearization (parallel)
  - `:expansion` - What every target ran for the reported sequence
    (`PropertyDamage.Expansion.t()`); the report's `expansions` lists it up to
    the failing root, and its trace keeps the concrete commands
  - `:expansion_counts` - The entry counts per target and root module
    (default `%{}`)
  - `:last_root` - The last root the failing run executed, which bounds
    `expansions`: `-1` for none, `nil` for every root (default: none for a
    setup failure, else `:failed_at_index`)
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
    targets = Keyword.get(opts, :targets, [])

    # The failing check name (for invariant resolution) and the branch, derived
    # straight from the structured %Failure{}.
    check_name = failure_check_name(failure_reason)
    branch_id = failure_branch_id(failure_reason)

    # Extract branch events if parallel
    branch_events = extract_branch_events(event_log)

    # Classify error origin
    classification = ErrorOrigin.classify(failure_reason, stacktrace)

    # Resolve the invariant the failing check validates (DR-026), so the report
    # can headline the named property and the formatter stays pure.
    {_invariant_name, invariant_description} =
      resolve_invariant(Keyword.get(opts, :model), check_name)

    # Lazily reconstruct each command's human-readable label. Only runs at
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
        adapter: reference_adapter(targets),
        timestamp: timestamp,
        source_revision: Keyword.get(opts, :source_revision),
        plan: shrunk_sequence,
        plan_source: Keyword.get(opts, :plan_source, :shrunk),
        executed: Keyword.get(opts, :executed, %{}),
        event_log: event_log,
        command_labels: command_labels,
        # DR-040: the fold-order record so the trace can derive the per-step
        # state timeline and the report can run the projection-purity check.
        command_fold_ordinals: Keyword.get(opts, :command_fold_ordinals, %{}),
        linearization: Keyword.get(opts, :linearization),
        expansion: expansion_choices(Keyword.get(opts, :expansion)),
        outcome: {:fail, failure_reason}
      )

    kind = Keyword.get_lazy(opts, :kind, fn -> kind_of(failure_reason) end)

    reference_trace =
      reference_trace(kind, Keyword.get(opts, :reference_result), trace)

    %__MODULE__{
      seed: seed,
      run_number: run_number,
      failed_at_index: failed_at_index,
      original_failed_at_index: Keyword.get(opts, :original_failed_at_index, failed_at_index),
      kind: kind,
      variant: Keyword.get_lazy(opts, :variant, fn -> reference_variant(targets) end),
      targets: targets,
      concurrency: Keyword.get(opts, :concurrency, :serial),
      compare: Keyword.get(opts, :compare, converge_within: @default_converge_within),
      stutter: Keyword.get(opts, :stutter),
      max_commands: Keyword.get(opts, :max_commands),
      check_mode: Keyword.get(opts, :check_mode, :halt),
      campaign: Keyword.get(opts, :campaign),
      latency: Keyword.get(opts, :latency, false),
      metrics: Keyword.get(opts, :metrics),
      trace: trace,
      reference_trace: reference_trace,
      reference_state_at_failure: reference_state(reference_trace, failed_at_index),
      setup_commands: Sequence.setup_commands(shrunk_sequence),
      teardown_commands: Sequence.teardown_commands(shrunk_sequence),
      original_sequence: original_sequence,
      failure_reason: failure_reason,
      state_before_failure: projections_before,
      state_at_failure: projections,
      branch_id: branch_id,
      linearization: Keyword.get(opts, :linearization),
      branch_events: branch_events,
      shrink_iterations: Keyword.get(opts, :shrink_iterations, 0),
      shrink_time_ms: Keyword.get(opts, :shrink_time_ms, 0),
      shrink_stop: Keyword.get(opts, :shrink_stop, :done),
      model: Keyword.get(opts, :model),
      timestamp: timestamp,
      error_origin: classification.origin,
      error_origin_details: classification.details,
      stacktrace: stacktrace,
      invariant_description: invariant_description,
      check_fires: Keyword.get(opts, :check_fires, %{}),
      run_check_fires: Keyword.get(opts, :run_check_fires, %{}),
      other_failures: Keyword.get(opts, :other_failures, []),
      compare_counts: Keyword.get(opts, :compare_counts, %{}),
      expansions:
        PropertyDamage.Expansion.report(
          Keyword.get(opts, :expansion),
          Keyword.get_lazy(opts, :last_root, fn -> executed_root(kind, failed_at_index) end)
        ),
      expansion_counts: Keyword.get(opts, :expansion_counts, %{}),
      command_labels: command_labels
    }
  end

  # The reference target's trace of the run `trace` describes: the same plan,
  # seed, nonce, epoch and expansion choices, with the reference's own events,
  # executed commands and fold ordinals. Only a comparison failure has one.
  defp reference_trace(kind, %{} = result, %RunTrace{} = trace)
       when kind in [:diverged, :did_not_converge] do
    %RunTrace{
      trace
      | executed: Map.get(result, :executed, %{}),
        event_log: Map.get(result, :event_log, []),
        command_fold_ordinals: Map.get(result, :command_fold_ordinals, %{}),
        linearization: nil,
        outcome: :pass
    }
  end

  defp reference_trace(_kind, _result, _trace), do: nil

  # The reference's state at the failing boundary, derived from its trace
  # (DR-040) so that nothing folded after the boundary is in it.
  defp reference_state(%RunTrace{} = trace, failed_at_index) when is_integer(failed_at_index),
    do: RunTrace.state_at(trace, Sequence.Position.prefix(failed_at_index))

  defp reference_state(_trace, _failed_at_index), do: nil

  # The last root the failing run executed: none before a setup failure, the
  # failing root, or every root for a failure at the end of the run.
  defp executed_root(:setup_failed, _failed_at_index), do: -1
  defp executed_root(_kind, failed_at_index), do: failed_at_index

  # The trace keeps each target's choices with their concrete commands, not
  # the registries they were realized with.
  defp expansion_choices(nil), do: nil

  defp expansion_choices(%{variants: variants}),
    do: Map.new(variants, fn {name, %{choices: choices}} -> {name, choices} end)

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

  # Resolve the invariant a failing check (by its logical check name) checks,
  # returning {name, description}. Best-effort: a non-check failure (nil
  # check_name), a model without a catalog, or an unmatched name yields
  # {nil, nil}, so the formatter falls back to the bare check name.
  defp resolve_invariant(nil, _check_name), do: {nil, nil}
  defp resolve_invariant(_model, nil), do: {nil, nil}

  defp resolve_invariant(model, check_name) when is_atom(model) do
    if function_exported?(PropertyDamage.Model, :check_catalog, 1) do
      entry =
        model
        |> PropertyDamage.Model.check_catalog()
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
      targets: Keyword.get(opts, :targets, []),
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
  The report kind for a failure reason: `:check_failed` for every check kind,
  `:diverged`, `:did_not_converge`, `:setup_failed`, `:latency_exceeded`, and
  `:execution_failed` for every execution and framework kind. `nil` for anything that is not a
  `%Failure{}`.
  """
  @spec kind_of(term()) :: kind() | nil
  def kind_of(%Failure{} = failure) do
    case Failure.class(failure) do
      :check -> :check_failed
      :divergence -> :diverged
      :convergence -> :did_not_converge
      :setup -> :setup_failed
      :latency -> :latency_exceeded
      class when class in [:execution, :framework] -> :execution_failed
    end
  end

  def kind_of(_failure_reason), do: nil

  @doc """
  The reference target (the first of `targets`) rebuilt as a
  `%PropertyDamage.Target{}` with its adapter, name and config, or `nil` when
  the report records no target.

  Entry points that re-execute a report against one system default to it. The
  injectors and mocks of the recorded entry are not carried over: those entry
  points do not set them up.
  """
  @spec reference_target(t()) :: PropertyDamage.Target.t() | nil
  def reference_target(%__MODULE__{targets: [{adapter, entry} | _]}) when is_atom(adapter) do
    %PropertyDamage.Target{
      adapter: adapter,
      name: Keyword.get(entry, :name) || PropertyDamage.Target.default_name(adapter),
      index: 0,
      config: Keyword.get(entry, :config, %{})
    }
  end

  def reference_target(%__MODULE__{}), do: nil

  @doc """
  The report's `targets:` list as Elixir source, each entry with only the keys
  that differ from their defaults (an `expansion:` other than `:random`
  included), so a reproduction runs against the same configuration.
  """
  @spec targets_source(t()) :: String.t()
  def targets_source(%__MODULE__{targets: targets}) do
    "[" <> Enum.map_join(targets, ", ", &entry_source/1) <> "]"
  end

  defp entry_source({adapter, entry}) do
    defaults = [
      name: PropertyDamage.Target.default_name(adapter),
      config: %{},
      injectors: [],
      mocks: [],
      expansion: :random
    ]

    keys =
      for {key, default} <- defaults,
          value = Keyword.get(entry, key, default),
          value != default,
          do: "#{key}: #{inspect(value)}"

    case keys do
      [] -> inspect(adapter)
      keys -> "{#{inspect(adapter)}, #{Enum.join(keys, ", ")}}"
    end
  end

  defp reference_adapter([{adapter, _entry} | _]), do: adapter
  defp reference_adapter(_targets), do: nil

  defp reference_variant([{adapter, entry} | _]) do
    %{index: 0, name: Keyword.get(entry, :name) || PropertyDamage.Target.default_name(adapter)}
  end

  defp reference_variant(_targets), do: nil

  @doc """
  Classify a `%Failure{}` into its `{kind, name}`.

  For callers (e.g. the seed-library replay phase) that hold an executor
  `failure_reason` and only need the descriptive kind/name, without building a
  full report.
  """
  @spec classify_reason(term()) :: {failure_type() | nil, Failure.name()}
  def classify_reason(%Failure{} = failure), do: {Failure.kind(failure), Failure.name(failure)}
  def classify_reason(_failure_reason), do: {nil, nil}

  @doc """
  Get a summary string for the failure type.
  """
  @spec failure_type_summary(t()) :: String.t()
  def failure_type_summary(%__MODULE__{} = report) do
    check_name = check_name(report)

    case failure_type(report) do
      :check_failed -> "Invariant Violation: #{format_name(check_name)}"
      :projection_violation -> "Invariant Violation: #{format_name(check_name)}"
      :idempotency_violation -> "Idempotency Violation"
      :poll_timeout -> "Poll Timeout: #{format_name(check_name)}"
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
      :diverged -> "Divergence: #{format_name(check_name)}"
      :did_not_converge -> "Did Not Converge: #{format_name(check_name)}"
      :setup_failed -> "Setup Failed"
      :latency_exceeded -> "Latency Exceeded: #{format_name(check_name)}"
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

  @doc "The failing check/projection name, or `nil`."
  @spec check_name(t()) :: Failure.name()
  def check_name(%__MODULE__{failure_reason: fr}), do: failure_check_name(fr)

  @doc """
  A human-readable message describing the report's failure, or `nil`. Also
  takes a bare `%PropertyDamage.Failure{}`, such as one of `other_failures`.
  """
  @spec failure_message(t() | Failure.t()) :: String.t() | nil
  def failure_message(%__MODULE__{failure_reason: %Failure{} = f}), do: message_for(f)
  def failure_message(%__MODULE__{}), do: nil
  def failure_message(%Failure{} = failure), do: message_for(failure)

  @doc "The `%Stutter.Violation{}` for an idempotency failure, or `nil`."
  @spec idempotency_violation(t()) :: map() | nil
  def idempotency_violation(%__MODULE__{
        failure_reason: %Failure{type: %Check{kind: :idempotency_violation, detail: v}}
      }),
      do: v

  def idempotency_violation(%__MODULE__{}), do: nil

  @doc "The poll-timeout info map for a `@eventually` timeout, or `nil`."
  @spec poll_timeout_info(t()) :: map() | nil
  def poll_timeout_info(%__MODULE__{
        failure_reason: %Failure{type: %Check{kind: :poll_timeout, detail: info}}
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

  It names the run's exact `targets:` list (see `targets_source/1`) and, for
  several targets, a `concurrency:` other than the default `:serial`. It also
  prints `max_commands:` when it differs from the default, `stutter:` when the
  run used stutter, `compare: [converge_within: ms]` when the run's
  convergence bound is not the default, and `latency:` exactly as the run was
  given it when it was not `false`, and `check_mode:` when it was not
  `:halt`. A `:latency_exceeded` report names the campaign's seed and
  `max_runs:` (see `campaign`), since a latency budget is judged over every
  run of the campaign; every other report names its own seed and
  `max_runs: 1`.
  """
  @spec reproduction_command(t()) :: String.t()
  def reproduction_command(%__MODULE__{model: model, targets: targets} = report) do
    {seed, max_runs} = reproduced_runs(report)

    options =
      [
        model && "model: #{inspect(model)}",
        targets != [] && "targets: #{targets_source(report)}",
        (length(targets) > 1 and report.concurrency != :serial) &&
          "concurrency: #{inspect(report.concurrency)}",
        converge_within(report) != @default_converge_within &&
          "compare: [converge_within: #{converge_within(report)}]",
        report.latency != false && "latency: #{inspect(report.latency)}",
        report.stutter && "stutter: #{inspect(report.stutter)}",
        report.max_commands not in [nil, @default_max_commands] &&
          "max_commands: #{report.max_commands}",
        report.check_mode not in [nil, :halt] && "check_mode: #{inspect(report.check_mode)}",
        "seed: #{seed}",
        "max_runs: #{max_runs}"
      ]
      |> Enum.filter(&is_binary/1)

    "PropertyDamage.run(#{Enum.join(options, ", ")})"
  end

  defp reproduced_runs(%__MODULE__{kind: :latency_exceeded, campaign: %{} = campaign}),
    do: {campaign.seed, campaign.max_runs}

  defp reproduced_runs(%__MODULE__{seed: seed}), do: {seed, 1}

  @doc """
  The call that replays the report's artifact: `PropertyDamage.run/1` with the
  report's model and `targets:` and `only: [replay: path]`. It runs the
  setup commands, the roots and every target's recorded commands, so it
  reproduces the shrunk failure without generating anything. It names
  `compare: [converge_within: ms]` and `check_mode:` when the run's differ from
  their defaults, as `reproduction_command/1` does. Returns nil when the
  report has no artifact file (`replay_status` says why).
  """
  @spec replay_command(t()) :: String.t() | nil
  def replay_command(%__MODULE__{replay_path: nil}), do: nil

  def replay_command(%__MODULE__{model: model, replay_path: path} = report) do
    options =
      [
        "model: #{inspect(model)}",
        "targets: #{targets_source(report)}",
        converge_within(report) != @default_converge_within &&
          "compare: [converge_within: #{converge_within(report)}]",
        report.check_mode not in [nil, :halt] && "check_mode: #{inspect(report.check_mode)}",
        "only: [replay: #{inspect(path)}]"
      ]
      |> Enum.filter(&is_binary/1)

    "PropertyDamage.run(#{Enum.join(options, ", ")})"
  end

  @doc """
  The call that regenerates the sequence the failing target ran before
  shrinking: `PropertyDamage.Expansion.for/5` at the report's `seed`, run 1.
  It names `targets:` when the failing target does not run `:random` or the
  reference does not (the sequence then depends on another target's mode),
  and `max_commands:` when the run did not use the default.
  """
  @spec expansion_command(t()) :: String.t()
  def expansion_command(%__MODULE__{model: model, seed: seed} = report) do
    name = (report.variant || reference_variant(report.targets) || %{})[:name]

    options =
      [
        names_targets?(report, name) && "targets: #{targets_source(report)}",
        report.max_commands not in [nil, @default_max_commands] &&
          "max_commands: #{report.max_commands}"
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.map_join(&(", " <> &1))

    "PropertyDamage.Expansion.for(#{inspect(model)}, #{seed}, 1, #{inspect(name)}#{options})"
  end

  defp names_targets?(%__MODULE__{targets: targets}, name) do
    modes =
      Map.new(targets, fn {adapter, entry} ->
        {Keyword.get(entry, :name) || PropertyDamage.Target.default_name(adapter),
         Keyword.get(entry, :expansion, :random)}
      end)

    reference_mode =
      case targets do
        [{_adapter, entry} | _] -> Keyword.get(entry, :expansion, :random)
        [] -> :random
      end

    Map.get(modes, name, :random) != :random or reference_mode != :random
  end

  defp converge_within(%__MODULE__{compare: compare}) when is_list(compare),
    do: Keyword.get(compare, :converge_within, @default_converge_within)

  defp converge_within(%__MODULE__{}), do: @default_converge_within

  @doc """
  A failure name as text: a `{projection, function}` key as
  `Projection.function`, a module by its name, a check name as is, `nil` as
  an empty string.
  """
  @spec format_name(Failure.name()) :: String.t()
  def format_name({projection, function}) when is_atom(projection) and is_atom(function),
    do: "#{inspect(projection)}.#{function}"

  def format_name(nil), do: ""

  def format_name(name) when is_atom(name) do
    case Atom.to_string(name) do
      "Elixir." <> _module -> inspect(name)
      string -> string
    end
  end

  def format_name(name), do: inspect(name)

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
      executed: trace.executed,
      choices: traced_choices(report)
    )
  end

  # The trace records the failing target's execution: its steps are what that
  # target ran at each root.
  defp traced_choices(%__MODULE__{} = report),
    do:
      choices_of(
        report.trace,
        (report.variant || reference_variant(report.targets) || %{})[:name]
      )

  defp choices_of(%RunTrace{expansion: expansion}, name) when is_map(expansion),
    do: Map.get(expansion, name)

  defp choices_of(_trace, _name), do: nil

  @doc """
  The steps of the reference target's run, for a comparison failure.

  The same `PropertyDamage.RunTrace.Step` shape as `steps/1`, over
  `reference_trace` with the reference's own expansion choices. `[]` when the
  report has no reference trace.
  """
  @spec reference_steps(t()) :: [Step.t()]
  def reference_steps(
        %__MODULE__{reference_trace: %RunTrace{plan: %Sequence{} = plan} = trace} = report
      ) do
    RunTrace.build_steps(plan, trace.event_log, trace.command_labels, nil,
      executed: trace.executed,
      choices: choices_of(trace, (reference_variant(report.targets) || %{})[:name])
    )
  end

  def reference_steps(%__MODULE__{}), do: []

  @doc """
  The reference target's event log of the reported run, as `event_log/1` gives
  the failing target's. `[]` when the report has no reference trace.
  """
  @spec reference_event_log(t()) :: [Entry.t()]
  def reference_event_log(%__MODULE__{reference_trace: %RunTrace{event_log: log}}), do: log
  def reference_event_log(%__MODULE__{}), do: []

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
  Where a setup failure happened, for a reader: the setup command, its setup
  index and the cause, and for an unresolved placeholder the field.

  A setup failure implicates no root, so `failure_index/1` is `nil` for it;
  this names the place instead, for example
  `"setup command 1 (MyApp.Login), cause: command"` or
  `"adapter setup/1, cause: adapter_setup"`. Takes a report or its
  `%PropertyDamage.Failure{}`; returns `nil` for any other failure.
  """
  @spec setup_location(t() | Failure.t() | term()) :: String.t() | nil
  def setup_location(%__MODULE__{failure_reason: reason}), do: setup_location(reason)

  def setup_location(%Failure{type: %Failure.Setup{cause: :adapter_setup}}),
    do: "adapter setup/1, cause: adapter_setup"

  def setup_location(%Failure{type: %Failure.Setup{setup_index: nil} = setup}),
    do: "setup phase, cause: #{setup.cause}"

  def setup_location(%Failure{type: %Failure.Setup{cause: :unresolved_placeholder} = setup}) do
    "setup command #{setup.setup_index} (#{command_name(setup.command)}), " <>
      "cause: unresolved_placeholder, field #{inspect(setup.field)}"
  end

  def setup_location(%Failure{type: %Failure.Setup{} = setup}),
    do:
      "setup command #{setup.setup_index} (#{command_name(setup.command)}), cause: #{setup.cause}"

  def setup_location(_reason), do: nil

  @doc """
  Projection-purity check: does the faithful per-step state derived from the
  trace match the authoritative runtime snapshots? (DR-040.)

  Re-derives the projection state at the failing step from the recorded fold
  order (`RunTrace.state_before/2` / `state_at/2`) and compares it to the
  runtime `state_before_failure` / `state_at_failure` snapshots. Pure
  projections re-derive identically; a mismatch means a projection read
  something outside its `(state, event)` inputs in `apply/2` (a clock, a
  counter, the environment).

  Because the faithful fold replays the run's *real* fold order, a pure-but-async
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
  defp message_for(%Failure{type: %Check{kind: :check_failed, detail: detail} = check}) do
    case Map.get(check, :context) do
      %{poll_count: poll} ->
        "@eventually #{format_name(check.name)} failed on poll #{poll}: " <>
          extract_message(detail)

      _ ->
        extract_message(detail)
    end
  end

  defp message_for(%Failure{type: %Check{kind: :idempotency_violation, detail: violation}}),
    do: format_idempotency_message(violation)

  defp message_for(%Failure{type: %Check{kind: :linearization, detail: message}}),
    do: to_string(message)

  defp message_for(%Failure{type: %Check{kind: :poll_timeout, detail: info}}),
    do: format_poll_timeout_message(info)

  defp message_for(%Failure{type: %Check{kind: :settle_timeout, detail: reason}}),
    do: "Command did not settle: #{inspect(reason)}"

  defp message_for(%Failure{type: %Check{kind: :projection_violation} = t}) do
    "projection #{inspect(t.name)} rejected the transition: " <> extract_message(t.detail)
  end

  defp message_for(%Failure{type: %Failure.Execution{kind: :adapter_error, detail: reason}}),
    do: extract_message(reason)

  defp message_for(%Failure{type: %Failure.Execution{kind: :nemesis_error, detail: reason}}),
    do: "Fault injection failed: #{inspect(reason)}"

  defp message_for(%Failure{
         type: %Failure.Execution{kind: :resource_poller_error, detail: reason}
       }),
       do: "Resource poller error: #{inspect(reason)}"

  defp message_for(%Failure{
         type: %Failure.Execution{kind: :stutter_execution_failed, detail: details}
       }),
       do: "Stutter retry failed: #{inspect(details)}"

  defp message_for(%Failure{type: %Failure.Execution{kind: :poll_error, detail: reason}}),
    do: "Poll predicate error: #{inspect(reason)}"

  defp message_for(%Failure{
         type: %Failure.Framework{kind: :placeholder_resolution, detail: reason}
       }),
       do: inspect(reason)

  defp message_for(%Failure{type: %Failure.Divergence{} = d}) do
    "#{format_name(d.key)} diverged at root #{d.root}: " <> extract_message(d.mismatch)
  end

  defp message_for(%Failure{type: %Failure.Convergence{} = c}) do
    "#{format_name(c.key)} did not converge within #{c.within_ms} ms at root #{c.root} " <>
      "(waited #{c.waited_ms} ms); still pending: #{inspect(c.reason)}"
  end

  defp message_for(%Failure{type: %Failure.Latency{} = latency}),
    do: LatencyMetrics.describe(latency)

  defp message_for(%Failure{type: %Failure.Setup{cause: :adapter_setup, detail: detail}}),
    do: "Adapter setup failed (cause: adapter_setup): " <> extract_message(detail)

  defp message_for(%Failure{type: %Failure.Setup{cause: :unresolved_placeholder} = setup}) do
    "Setup failed (cause: unresolved_placeholder) at setup command #{setup.setup_index} " <>
      "(#{command_name(setup.command)}): its external() at field #{inspect(setup.field)} " <>
      "never arrived"
  end

  defp message_for(%Failure{type: %Failure.Setup{cause: :check, detail: %Failure{} = check}} = f) do
    "Setup failed (cause: check) at setup command #{f.type.setup_index} " <>
      "(#{command_name(f.type.command)}): " <> failure_message(check)
  end

  defp message_for(%Failure{type: %Failure.Setup{} = setup}) do
    "Setup failed (cause: #{setup.cause}) at setup command #{setup.setup_index} " <>
      "(#{command_name(setup.command)}): " <> setup_detail_message(setup.detail)
  end

  defp message_for(%Failure{type: type}), do: inspect(type.detail)

  defp command_name(%{__struct__: module}), do: inspect(module)
  defp command_name(nil), do: "no command"

  defp setup_detail_message(%Failure{} = failure), do: failure_message(failure)
  defp setup_detail_message(detail), do: extract_message(detail)

  # Extract a human message from a check/exception reason. The
  # is_exception clause MUST precede %{message: msg}: exceptions like
  # KeyError/FunctionClauseError carry message: nil and compute it lazily,
  # so matching the map first yielded empty strings.
  defp extract_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp extract_message(%{message: msg}) when is_binary(msg), do: msg
  defp extract_message(msg) when is_binary(msg), do: msg
  defp extract_message(other), do: inspect(other)

  defp format_poll_timeout_message(info) do
    """
    Eventually check #{info.triggered_by.check_name} timed out after #{info.elapsed_ms}ms.
    Trigger event: #{inspect(info.triggered_by.event)}
    Predicate: #{info.predicate_source || "unknown"}
    Final state: #{inspect(info.final_state, limit: 5)}
    Poll attempts: #{info.poll_count}
    """
  end

  defp format_idempotency_message(%{command: command, mismatch: mismatch}) do
    cmd_name = command.__struct__ |> Module.split() |> List.last()

    "Command #{cmd_name} produced different events on retry (original, then retry):\n" <>
      extract_message(mismatch)
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
