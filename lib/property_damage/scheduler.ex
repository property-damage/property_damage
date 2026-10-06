defmodule PropertyDamage.Scheduler do
  @moduledoc """
  Runs one command sequence against several targets in lockstep and compares
  their boundary observations root by root.

  Each target runs as a `PropertyDamage.Variant`: its own process with its own
  executor state, event queue, injectors, mocks and pollers. The scheduler only
  tells the variants how far to go and looks at what they observed.
  `PropertyDamage.run/1` calls `run/1` once per generated linear sequence, for
  one target or several.

  ## Lockstep

  Every command of the sequence is a root. For each root `r`, in order, every
  variant executes command `r` and stops at boundary `r`; only then does the
  comparison run, and only after the variants agree does any variant start
  command `r + 1`.
  Two settings decide how the variants reach a boundary:

    * `concurrency: :serial` - one variant at a time, in target order. Commands
      never overlap, so targets that share one system do not disturb each
      other, and per-command latency is measured without other load.
    * `concurrency: :parallel` - every variant executes command `r` at the same
      time. The run takes about as long as its slowest target, but the targets'
      commands overlap: targets that share a system need isolated slices of it
      (a tenant or a key prefix per target, through each target's `config:`),
      or one target's command changes what another observes.

  ## Per-run setup and the barrier

  The variants are set up one after another in target order: each variant
  calls its adapter's `setup/1` in its own process, and the next setup starts
  after the previous one returned. No variant executes command 0 before every
  setup returned and every `@check at: :startup` check passed. At the end of
  the run, pass or fail, every variant that was set up finalizes its run and
  tears its adapter down, again in its own process.

  So `c:PropertyDamage.Adapter.setup/1` runs once per run per target, and may
  find state a previous run (or a crashed one) left behind: it must be
  idempotent.

  ## Comparison

  Variants are compared only through boundary observations: the functions
  the model's projections mark with `@compare`. The first target is the
  reference. At each root boundary an observation's `every:` schedule names,
  every variant evaluates it on its own projection state, and the comparison
  judges each other variant's value against the reference's with the
  observation's `using:` predicate. When a side is
  pending or the values differ, the convergence loop lets the variants catch
  up until they agree or the convergence bound (`compare: [converge_within:
  ms]`) expires; then a pending side did not converge and differing sides
  diverged, and the run stops at that boundary. The final boundary is
  compared after every variant finalized its run (pollers awaited, queue
  drained); when the last root is a `:probe` command, the convergence loop
  still re-reads it there, because finalizing stops a variant's pollers, not
  the system it reads. With one target there is no comparison.

  ## Failures

  A failure names the target it happened in. Its `reason` is always a
  `%PropertyDamage.Failure{}`:

    * `:diverged` - a target's boundary observation still differed from the
      reference's at the convergence bound (`PropertyDamage.Failure.diverged/1`).
      Its name is the observation's `{projection, function}` key.
    * `:did_not_converge` - a target's boundary observation was still pending
      at the convergence bound (`PropertyDamage.Failure.did_not_converge/1`),
      named by its key.
    * `:setup_failed` - a target's `setup/1` returned an error or raised
      (`PropertyDamage.Failure.setup_failed/1`, holding the error term or the
      exception). Targets already set up are torn down; the failing one is not.
    * `:check_failed` - a check failed in a target: at a command, at the
      `:startup` phase, or while the run finalized (an `@eventually` timeout,
      a `:teardown` check).
    * `:execution_failed` - a target's adapter raised, a command could not be
      executed (the failure the target's engine reported for it), the
      machinery failed while the run finalized (a resource poller error, a
      poll predicate that raised), or the target's process crashed
      (`PropertyDamage.Failure.unknown/1` holding the exit reason).

  A `@compare` function or `using:` predicate that raises is a `:check_failed`
  in the target whose value it was producing or judging.

  An adapter `{:error, _}` or raise at a root is an `:execution_failed` in
  that target, never an observation: `{:error, reason}` means the command
  could not be executed (a rejection the system answers belongs in an event).

  ## Which targets go on after a failure

  Every failure ends the run, with one exception: an `:execution_failed` at a
  root in a target other than the reference. That target leaves the run (it
  is retired) and the others go on:

    * Before the next root starts in any target, the retired target finalizes
      its run (which stops its pollers), runs its `@check at: :teardown`
      checks and tears its adapter down; its process, and with it its copy of
      the placeholder registry, is gone.
    * The comparison at that root and at every later one compares the targets
      still running with the reference.
    * When no target other than the reference is left, the run ends.

  A failure in the reference ends the run at that root: no target starts the
  next root, every target is torn down, and that root is not compared.

  A run can therefore collect several failures. The first in root order, then
  in target order, is the run's `failure` (the primary failure; it is the one
  a shrinker keeps). The others are in `other_failures` in the same order,
  each still naming its target and root. A `:teardown` check that fails while
  a retired target is torn down is one of the others, never the primary
  failure: its target had already failed.

  When the run went on after a retirement, a failure a remaining target
  reports while it finalizes its run (an `@eventually` timeout, a
  `:teardown` check, the reference's included) is one of the run's failures
  in the same order. One that belongs to a root (an `@eventually` window
  opened at that root) sorts at that root; one that belongs to no root (a
  `:teardown` check) happened at the end of the run and sorts after every
  failure at a root, in target order.

  A failure's kind is derived from its `reason` by
  `PropertyDamage.FailureReport.kind_of/1`, so a report's `kind` always agrees
  with its `failure_reason`.

  When a failure ends the run, under `:serial` no other target executes the
  failing root after it; under `:parallel` the commands already running
  finish. In both, no target starts the next root. A retired target does not
  stop the others: under `:serial` the targets after it still execute that
  root.
  """

  alias PropertyDamage.{
    Comparison,
    Failure,
    FailureReport,
    Model,
    PlaceholderRegistry,
    Target,
    Variant
  }

  alias PropertyDamage.Executor.Finalization

  @typedoc "A target's position in `targets:` and its name."
  @type variant :: %{index: non_neg_integer(), name: String.t()}

  @typedoc """
  What ended a run, naming the target it happened in. `root` is the command the
  failure belongs to, `nil` for a setup failure or a failed `:startup` check.
  A check that raised and an adapter that raised hold the exception alone in
  `reason`'s detail; its stacktrace is in `stacktrace` (`nil` for every other
  failure).
  """
  @type failure :: %{
          kind: :check_failed | :setup_failed | :execution_failed | :diverged | :did_not_converge,
          variant: variant(),
          run: non_neg_integer(),
          root: non_neg_integer() | nil,
          reason: Failure.t(),
          stacktrace: Exception.stacktrace() | nil
        }

  @typedoc """
  The outcome of one run. `results`, `observations` and `latencies` hold one
  entry per target in target order, for every target that was set up (all of
  them unless setup failed, then none). Each result is what
  `PropertyDamage.Executor.run/4` reports for that target's run; a retired
  target's is the result it had when it left the run. `failure` is the
  primary failure and `other_failures` the run's other failures, in root
  order, then target order (see "Which targets go on after a failure").
  `compare_counts` holds, per boundary observation the model declares, the
  boundaries it was compared at, the boundaries it waited at, and the time it
  waited (every count 0 with one target).
  """
  @type run :: %{
          failure: failure() | nil,
          other_failures: [failure()],
          results: [map()],
          observations: [[{non_neg_integer(), Variant.observation()}]],
          latencies: [[{non_neg_integer(), non_neg_integer()}]],
          compare_counts: compare_counts()
        }

  @typedoc """
  Per boundary observation `{projection, function}`: the boundaries it was
  compared at, the boundaries it waited at (a side was pending or differed
  first), and the time it waited, in milliseconds.
  """
  @type compare_counts :: %{
          {module(), atom()} => %{
            compared_at: non_neg_integer(),
            waited_at: non_neg_integer(),
            waited_ms: non_neg_integer()
          }
        }

  # The boundary before command 0: asking a variant to advance to it steps
  # nothing and reports a failed `:startup` check.
  @before_first_root -1

  @doc """
  Run `commands` against every target in lockstep.

  Options (all required unless noted):

    * `:model` - the model module
    * `:targets` - `[%PropertyDamage.Target{}]`; the first is the reference
    * `:commands` - the concrete command list
    * `:seed`, `:run_number` - the campaign seed and the 0-based run
    * `:run_nonce` - the run nonce shared by every target
    * `:concurrency` - `:serial` or `:parallel` (see the module doc)
    * `:compare` - `[converge_within: ms]`, the convergence bound of each
      boundary comparison (optional, default `[converge_within: 5_000]`)
    * `:measure_latency` - record the wall-clock time of each target's `execute/3` per command
      into `latencies` (optional, default `false`)
    * `:mint_epoch` - the mint epoch every target's run uses for client-minted
      values (DR-034); optional, default `0`, the exploration run's epoch
    * `:stutter_config`, `:check_mode` - passed to every variant (optional)
    * `:placeholder_registry` - the registry the commands' placeholders resolve
      against (DR-021); optional, default the registry built from `:commands`.
      A shrunk sequence passes its own registry, whose producer positions were
      remapped onto the shrunk command list.

  Returns `{:ok, run}`; see `t:run/0`.
  """
  @spec run(keyword()) :: {:ok, run()}
  def run(opts) do
    config = build_config(opts)

    case set_up(config) do
      {:ok, variants} ->
        {:ok, finish_run(config, lockstep(config, variants))}

      {:error, failure} ->
        {:ok, empty_run(config, failure)}
    end
  end

  defp build_config(opts) do
    model = Keyword.fetch!(opts, :model)
    targets = Keyword.fetch!(opts, :targets)
    commands = Keyword.fetch!(opts, :commands)

    %{
      model: model,
      targets: targets,
      commands: commands,
      seed: Keyword.fetch!(opts, :seed),
      run_number: Keyword.fetch!(opts, :run_number),
      run_nonce: Keyword.get(opts, :run_nonce),
      concurrency: Keyword.fetch!(opts, :concurrency),
      compare?: length(targets) > 1,
      converge_within: opts |> Keyword.get(:compare, []) |> Keyword.get(:converge_within, 5_000),
      plan: Comparison.plan(Comparison.observations(model), commands),
      zero_counts: Comparison.zero_counts(model),
      probes: probe_modules(model),
      measure_latency: Keyword.get(opts, :measure_latency, false),
      mint_epoch: Keyword.get(opts, :mint_epoch, 0),
      stutter_config: Keyword.get(opts, :stutter_config),
      check_mode: Keyword.get(opts, :check_mode, :halt),
      registry: Keyword.get(opts, :placeholder_registry) || PlaceholderRegistry.build(commands)
    }
  end

  defp empty_run(config, failure) do
    %{
      failure: failure,
      other_failures: [],
      results: [],
      observations: [],
      latencies: [],
      compare_counts: config.zero_counts
    }
  end

  # The command modules the model runs as `:probe`: a boundary after one of
  # them is re-read while the comparison waits.
  defp probe_modules(model) do
    for {_weight, module, spec} <- Model.normalize_commands(model.commands()),
        Map.get(spec, :execution) == :probe,
        into: MapSet.new(),
        do: module
  end

  # ==========================================================================
  # Setup
  # ==========================================================================

  # Starts and sets up one variant after another. On a failure, the variants
  # already set up are stopped (their adapters torn down) and the failing one is
  # stopped without an adapter teardown.
  defp set_up(config) do
    config.targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, ready} ->
      case set_up_variant(config, target) do
        {:ok, variant} ->
          {:cont, {:ok, [variant | ready]}}

        {:error, reason} ->
          Enum.each(ready, &stop_variant/1)
          reason = Failure.setup_failed(reason)
          {:halt, {:error, failure(config, target, nil, reason)}}
      end
    end)
    |> case do
      {:ok, ready} -> {:ok, Enum.reverse(ready)}
      error -> error
    end
  end

  defp set_up_variant(config, target) do
    {:ok, pid} =
      Variant.start(
        target: target,
        model: config.model,
        commands: config.commands,
        placeholder_registry: config.registry,
        seed: config.seed,
        run_number: config.run_number,
        run_nonce: config.run_nonce,
        stutter_config: config.stutter_config,
        check_mode: config.check_mode,
        measure_latency: config.measure_latency,
        mint_epoch: config.mint_epoch
      )

    variant = %{pid: pid, target: target, observations: []}

    case call(pid, &Variant.setup/1) do
      {:ok, :ok} ->
        {:ok, variant}

      {:ok, {:error, reason}} ->
        stop_variant(variant)
        {:error, setup_reason(reason)}

      {:crashed, reason} ->
        {:error, reason}
    end
  end

  # A setup that raised is reported by the exception itself.
  defp setup_reason({:raised, exception}), do: exception
  defp setup_reason(reason), do: reason

  # ==========================================================================
  # Lockstep
  # ==========================================================================

  # Returns the run so far: `active`, the variants still running (each carrying
  # what it observed so far), `retired`, the variants that left the run after
  # an execution failure, `failures`, every failure found (`{failure,
  # primary?}`; a retired variant's `:teardown` check failure cannot be the
  # primary one), and `counts`, the compare counts of the boundaries compared.
  defp lockstep(config, variants) do
    run = %{active: variants, retired: [], failures: [], counts: config.zero_counts}

    # The barrier: every setup returned and every :startup check passed before
    # any variant executes command 0. Any failure here ends the run.
    case advance_all(config, variants, @before_first_root) do
      {variants, []} -> step_roots(config, %{run | active: variants})
      {variants, failures} -> %{run | active: variants, failures: primary_candidates(failures)}
    end
  end

  defp step_roots(config, run) do
    last = length(config.commands) - 1

    config.commands
    |> Enum.with_index()
    |> Enum.reduce_while(run, fn {command, root}, run ->
      step_root(config, run, command, root, root == last)
    end)
  end

  # Advances every active variant to `root`, retires the variants whose
  # execution failed there when the run can go on without them, then compares
  # the variants still running.
  defp step_root(config, run, command, root, last?) do
    {active, failures} = advance_all(config, run.active, root)
    run = %{run | active: active}

    cond do
      failures == [] ->
        compare_root(config, run, command, root, last?)

      Enum.all?(failures, &retires?(&1, root)) ->
        run = Enum.reduce(failures, run, &retire(config, &2, &1))

        if Enum.any?(run.active, &(&1.target.index != 0)),
          do: compare_root(config, run, command, root, last?),
          else: {:halt, run}

      true ->
        {:halt, %{run | failures: run.failures ++ primary_candidates(failures)}}
    end
  end

  defp compare_root(config, run, command, root, last?) do
    case compare_boundary(config, run.active, root, command, last?) do
      {:agree, boundary} ->
        {:cont, %{run | counts: Comparison.merge_counts(run.counts, boundary)}}

      {:failed, failure, boundary} ->
        {:halt,
         %{
           run
           | failures: run.failures ++ primary_candidates([failure]),
             counts: Comparison.merge_counts(run.counts, boundary)
         }}
    end
  end

  defp primary_candidates(failures), do: Enum.map(failures, &{&1, true})

  # Only an execution failure at a root, in a variant other than the
  # reference, lets the run go on without that variant. The reference is what
  # every other variant is compared with, so its failure ends the run.
  defp retires?(%{kind: :execution_failed, variant: %{index: index}}, root),
    do: root >= 0 and index != 0

  defp retires?(_failure, _root), do: false

  # Takes the failed variant out of the run before any variant starts the next
  # root: its run is finalized (its pollers stop), its `:teardown` checks run,
  # and its adapter is torn down, which ends its process and drops its copy of
  # the placeholder registry. The variant keeps its result for the report.
  defp retire(config, run, failure) do
    {[variant], active} = Enum.split_with(run.active, &(&1.target.index == failure.variant.index))
    latency = latencies(config, variant)

    {result, failure, teardown_failures} =
      case variant.pid && call(variant.pid, &Variant.retire/1) do
        {:ok, {:ok, result, teardown_failures}} ->
          stop_variant(variant)
          {result, with_result_reason(failure, result), teardown_failures}

        _crashed_or_gone ->
          {nil, failure, []}
      end

    teardown =
      Enum.map(teardown_failures, &{failure(config, variant.target, failure.root, &1), false})

    %{
      run
      | active: active,
        retired: run.retired ++ [%{variant | pid: nil} |> Map.put(:retired, {result, latency})],
        failures: run.failures ++ [{failure, true} | teardown]
    }
  end

  # Every variant steps the root, one after another in target order. A failure
  # that ends the run stops the root there; a variant that will be retired
  # does not stop the variants after it. Returns `{variants, failures}`, the
  # failures in target order.
  defp advance_all(%{concurrency: :serial} = config, variants, root) do
    {advanced, failures} =
      Enum.reduce_while(variants, {[], []}, fn variant, {advanced, failures} ->
        case advance(config, variant, root) do
          {:ok, variant} ->
            {:cont, {[variant | advanced], failures}}

          {:failed, variant, failure} ->
            next = {[variant | advanced], [failure | failures]}
            if retires?(failure, root), do: {:cont, next}, else: {:halt, next}
        end
      end)

    rest = Enum.drop(variants, length(advanced))
    {Enum.reverse(advanced, rest), Enum.reverse(failures)}
  end

  # Every variant steps the root at once; the boundary is reached when every
  # one of them returned.
  defp advance_all(%{concurrency: :parallel} = config, variants, root) do
    advanced =
      variants
      |> Enum.map(fn variant -> Task.async(fn -> advance(config, variant, root) end) end)
      |> Task.await_many(:infinity)

    {Enum.map(advanced, &elem(&1, 1)), for({:failed, _variant, failure} <- advanced, do: failure)}
  end

  defp advance(config, variant, root) do
    case call(variant.pid, &Variant.advance_to(&1, root)) do
      {:ok, {:ok, observed}} ->
        {:ok, %{variant | observations: Enum.reverse(observed, variant.observations)}}

      {:ok, {:failed, %{root: failed_root, reason: reason}}} ->
        {:failed, variant, failure(config, variant.target, failed_root, reason)}

      {:ok, {:error, reason}} ->
        {:failed, variant, failure(config, variant.target, root, reason)}

      {:crashed, reason} ->
        variant = %{variant | pid: nil}
        reason = Failure.unknown(reason)
        {:failed, variant, failure(config, variant.target, root(root), reason)}
    end
  end

  defp root(@before_first_root), do: nil
  defp root(root), do: root

  # ==========================================================================
  # Comparison
  # ==========================================================================

  # Compares the boundary observations scheduled at `root`. The final
  # boundary is compared after every variant finalized its run; a variant
  # whose finalization failed ends the run with that failure instead (found
  # when the run finishes). Returns `{:agree, counts}` or
  # `{:failed, failure, counts}`.
  defp compare_boundary(%{compare?: false}, _variants, _root, _command, _last?),
    do: {:agree, %{}}

  defp compare_boundary(config, variants, root, command, last?) do
    case elem(config.plan, root) do
      [] ->
        {:agree, %{}}

      keys ->
        if last? and not finalized?(config, variants),
          do: {:agree, %{}},
          else: compare_keys(config, variants, root, command, keys, last?)
    end
  end

  defp compare_keys(config, variants, root, command, keys, last?) do
    opts = [
      within: config.converge_within,
      concurrency: config.concurrency,
      final: last?,
      probe: MapSet.member?(config.probes, command.__struct__),
      arrived_at: System.monotonic_time(:millisecond)
    ]

    case Comparison.compare(root, command, keys, variants, opts) do
      {:agree, counts} ->
        {:agree, counts}

      {:failed, target, failed_root, reason, counts} ->
        {:failed, failure(config, target, failed_root, reason), counts}
    end
  end

  # Finalizes every variant (its result is kept for the end of the run) and
  # tells whether all of them finished without a failure.
  defp finalized?(config, variants) do
    finish = fn variant -> call(variant.pid, &Variant.finish/1) end

    results =
      case config.concurrency do
        :serial ->
          Enum.map(variants, finish)

        :parallel ->
          variants
          |> Enum.map(fn variant -> Task.async(fn -> finish.(variant) end) end)
          |> Task.await_many(:infinity)
      end

    Enum.all?(results, &match?({:ok, %{success: true}}, &1))
  end

  # ==========================================================================
  # End of run
  # ==========================================================================

  defp finish_run(config, run) do
    variants = Enum.sort_by(run.active ++ run.retired, & &1.target.index)
    finished = Enum.map(variants, &finish_variant(config, &1))
    results = Enum.map(finished, fn {result, _latency, _outcome} -> result end)
    {failure, others} = run_failures(config, run, Enum.zip(variants, finished))

    %{
      failure: with_failure_reason(failure, results),
      other_failures: Enum.map(others, &with_failure_reason(&1, results)),
      results: results,
      observations: Enum.map(variants, &Enum.reverse(&1.observations)),
      latencies: Enum.map(finished, fn {_result, latency, _outcome} -> latency end),
      compare_counts: run.counts
    }
  end

  # The run's primary failure and its other failures, once every variant
  # finished.
  #
  # A run in which no variant was retired ended at its first failure, if it
  # had one. A failure a variant reports while it finalizes (an @eventually
  # timeout, a :teardown check, a check `check_mode: :record` recorded)
  # becomes the run's failure when the run has none; next to a divergence,
  # see `run_failure/4`.
  #
  # A run that went on after a retirement may have run on for many roots, so
  # every remaining variant's finalize-time failure is one of the run's
  # failures and competes for primary by the same order as the others (see
  # `primary_and_others/2`). One attributed to a root sorts at that root; one
  # with no root happened at the end of the run, after every failure at a
  # root.
  defp run_failures(config, %{retired: []} = run, finished) do
    {primary, others} = primary_and_others(run.failures)

    primary =
      Enum.reduce(finished, primary, fn
        {variant, {_result, _latency, {:finished, result}}}, failure ->
          run_failure(config, variant.target, result, failure)

        {_variant, {_result, _latency, {:crashed, crash}}}, failure ->
          failure || crash

        _gone, failure ->
          failure
      end)

    {primary, others}
  end

  defp run_failures(config, run, finished) do
    end_failures =
      for {variant, {_result, _latency, outcome}} <- finished,
          failure <- [end_failure(config, variant.target, outcome)],
          failure != nil,
          do: {failure, true}

    {at_root, at_end} = Enum.split_with(end_failures, fn {failure, _} -> failure.root != nil end)
    primary_and_others(run.failures ++ at_root, at_end)
  end

  defp end_failure(config, target, {:finished, result}),
    do: finalize_failure(config, target, result)

  defp end_failure(_config, _target, {:crashed, crash}), do: crash
  defp end_failure(_config, _target, _retired_or_gone), do: nil

  # The primary failure is the first in root order, then in target order (a
  # failure before command 0 first); the others follow in that order, and
  # the failures of `at_end` (failures of the end of the run, belonging to
  # no root) after all of them, in target order. The choice depends on the
  # order of `targets:`: the first target is the reference and the others
  # are compared with it in target order, so of two failures at one root the
  # earlier target's is primary. A retired variant's `:teardown` check
  # failure is never primary.
  defp primary_and_others(failures, at_end \\ [])

  defp primary_and_others([], []), do: {nil, []}

  defp primary_and_others(failures, at_end) do
    sorted =
      Enum.sort_by(failures, fn {failure, _primary?} -> sort_key(failure) end) ++
        Enum.sort_by(at_end, fn {failure, _primary?} -> failure.variant.index end)

    case Enum.find_index(sorted, fn {_failure, primary?} -> primary? end) do
      nil ->
        {nil, Enum.map(sorted, &elem(&1, 0))}

      index ->
        {{primary, true}, others} = List.pop_at(sorted, index)
        {primary, Enum.map(others, &elem(&1, 0))}
    end
  end

  defp sort_key(%{root: root, variant: %{index: index}}), do: {root || -1, index}

  # Finalizes and stops one variant. Returns its result, its latencies, and
  # how it ended: `{:finished, result}`, `{:crashed, failure}`, or
  # `:retired` / `:gone` for a variant that left the run earlier.
  defp finish_variant(_config, %{retired: {result, latency}}), do: {result, latency, :retired}

  defp finish_variant(_config, %{pid: nil}), do: {nil, [], :gone}

  defp finish_variant(config, variant) do
    latency = latencies(config, variant)

    case call(variant.pid, &Variant.finish/1) do
      {:ok, result} ->
        stop_variant(variant)
        {result, latency, {:finished, result}}

      {:crashed, reason} ->
        {nil, latency, {:crashed, failure(config, variant.target, nil, Failure.unknown(reason))}}
    end
  end

  # Under `check_mode: :record` a failing check does not end the run: the
  # result carries no failure_reason, only the recorded check failures
  # (chronological). The first of them is the run's failure.
  defp finalize_failure(
         config,
         target,
         %{success: false, failure_reason: nil, check_failures: [first | _]}
       ) do
    reason = Failure.check_failed(first.check_name, first.reason)
    failure(config, target, first.command_index, reason)
  end

  defp finalize_failure(config, target, %{success: false} = result) do
    failure(config, target, result.failed_at_index, result.failure_reason)
  end

  defp finalize_failure(_config, _target, _result), do: nil

  # The run's failure after one more variant finished. A finalize-time failure
  # counts when the run has none. Under `check_mode: :record` a check failure
  # the variant recorded at or before the root a divergence was found at
  # happened first: the check failed while that root was stepped, before the
  # boundary was compared.
  defp run_failure(config, target, result, nil), do: finalize_failure(config, target, result)

  defp run_failure(config, target, result, %{kind: kind, root: root} = divergence)
       when kind in [:diverged, :did_not_converge] do
    case result do
      %{success: false, failure_reason: nil, check_failures: [_ | _]} ->
        case finalize_failure(config, target, result) do
          %{root: failed_root} = recorded when is_integer(failed_root) and failed_root <= root ->
            recorded

          _ ->
            divergence
        end

      _ ->
        divergence
    end
  end

  defp run_failure(_config, _target, _result, failure), do: failure

  # A variant reports an adapter raise by the exception alone; the failing
  # variant's finished result holds the `%Failure{}` the engine built for it,
  # already split from its stacktrace, and the run reports that one.
  defp with_failure_reason(nil, _results), do: nil

  defp with_failure_reason(failure, results),
    do: with_result_reason(failure, Enum.at(results, failure.variant.index))

  defp with_result_reason(%{reason: %Failure{}} = failure, _result), do: failure

  defp with_result_reason(failure, result) do
    {reason, stacktrace} =
      case result do
        %{failure_reason: %Failure{} = reason} -> {reason, result.stacktrace}
        _ -> {Failure.adapter_error(failure.reason), nil}
      end

    %{failure | kind: FailureReport.kind_of(reason), reason: reason, stacktrace: stacktrace}
  end

  defp latencies(%{measure_latency: false}, _variant), do: []

  defp latencies(_config, variant) do
    case call(variant.pid, &Variant.latencies/1) do
      {:ok, latencies} -> latencies
      {:crashed, _reason} -> []
    end
  end

  defp stop_variant(%{pid: nil}), do: :ok

  defp stop_variant(variant) do
    call(variant.pid, &Variant.stop/1)
    :ok
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  # Calls into a variant. The variant is not linked to the scheduler, so its
  # crash surfaces here as an exit from the call, never as an exit signal.
  defp call(pid, fun) do
    {:ok, fun.(pid)}
  catch
    :exit, reason -> {:crashed, exit_reason(reason)}
  end

  defp exit_reason({{%{__exception__: true} = exception, _stacktrace}, _call}), do: exception
  defp exit_reason({reason, {GenServer, :call, _args}}), do: {:exit, reason}
  defp exit_reason(reason), do: {:exit, reason}

  # Every failure's kind comes from its reason by the one mapping a report
  # uses (`FailureReport.kind_of/1`), so the two always agree. A variant
  # reports an adapter raise by the bare exception; `with_failure_reason/2`
  # swaps in the engine's `%Failure{}` for it and derives the kind again.
  # A reason that embeds `{exception, stacktrace}` (a check that raised, on
  # any path) is split here as the engine splits its own result, so the
  # reason holds the exception alone.
  defp failure(config, %Target{} = target, root, reason) do
    {reason, stacktrace} = Finalization.extract_stacktrace(reason)

    %{
      kind: FailureReport.kind_of(reason) || :execution_failed,
      variant: variant_of(target),
      run: config.run_number,
      root: root,
      reason: reason,
      stacktrace: stacktrace
    }
  end

  defp variant_of(%Target{index: index, name: name}), do: %{index: index, name: name}
end
