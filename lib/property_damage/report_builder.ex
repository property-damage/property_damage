defmodule PropertyDamage.ReportBuilder do
  @moduledoc """
  Builds the `PropertyDamage.FailureReport` of each failure path.

  This is the only module in `lib/` that calls `PropertyDamage.FailureReport.new/1`
  to assemble a report. Each public function serves one path. It takes the
  campaign context (`PropertyDamage.Campaign.Context`), plus what that path knows:

  - `latency_exceeded/4`: the latency budget was breached after every run passed
  - `from_found/3`: a run found a failure
  - `further_shrink/5`: a report was shrunk again and the new sequence reproduced

  A path leaves a field unset when it has nothing to record there, and the field
  takes the default `FailureReport.new/1` gives it. Each function's doc names
  the fields its path leaves unset.
  """

  alias PropertyDamage.Campaign.Context
  alias PropertyDamage.{Expansion, FailureReport, RunTrace, Sequence}

  @doc """
  Reports a breached latency budget.

  The budget is judged once, after every run passed, so the report is not
  localized to a command and nothing is shrunk or re-executed. `acc.last_run`
  holds the last run; the report records its sequence, seed and number, and the
  failing target's result of that run (each run replaces the previous one, so
  one run stays in memory). `breaches` pairs each breaching target with its
  failure: the first is the report's failure and the rest become
  `:other_failures`.

  Leaves unset: `:projections`, `:projections_before`, `:stacktrace`,
  `:original_failed_at_index`, `:last_root`, `:shrink_stop`, `:reference_result`,
  `:run_check_fires`, `:expansion` and `:expansion_counts`.
  """
  @spec latency_exceeded(Context.t(), map(), map() | nil, [
          {PropertyDamage.Target.t(), term()},
          ...
        ]) ::
          FailureReport.t()
  def latency_exceeded(ctx, acc, metrics, [{target, failure} | rest]) do
    last = acc.last_run
    result = Enum.at(last.results, target.index) || %{}

    FailureReport.new(
      seed: last.run_seed,
      run_number: last.run_number,
      original_sequence: last.sequence,
      shrunk_sequence: last.sequence,
      plan_source: :generated,
      source_revision: RunTrace.source_revision(),
      run_nonce: ctx.run_nonce,
      mint_epoch: 0,
      failed_at_index: nil,
      executed: Map.get(result, :executed, %{}),
      event_log: Map.get(result, :event_log, []),
      command_fold_ordinals: Map.get(result, :command_fold_ordinals, %{}),
      logs: Map.get(result, :logs, %{}),
      failure_reason: failure,
      report_kind: :latency_exceeded,
      variant: variant_of(target),
      shrink_iterations: 0,
      shrink_time_ms: 0,
      model: ctx.model,
      targets: ctx.target_entries,
      concurrency: ctx.concurrency,
      compare: ctx.compare,
      setup_log: ctx.setup_log,
      log_filter: ctx.log_filter,
      stutter: ctx.stutter,
      max_commands: ctx.max_commands,
      check_fires: acc.fires,
      compare_counts: acc.compare_counts,
      other_failures:
        for({other, other_failure} <- rest) do
          %{variant: variant_of(other), root: nil, failure: other_failure}
        end,
      check_mode: ctx.check_mode,
      external_markers: ctx.external_markers,
      campaign: %{seed: ctx.seed, max_runs: ctx.max_runs},
      latency: ctx.latency,
      metrics: metrics
    )
  end

  @doc """
  Reports a found failure.

  `how` says what the report describes. `:found` reports it as the run found it
  (no shrinking); `{:fallback, shrink}` likewise, after a shrink whose result
  did not reproduce; `{:shrunk, sequence, epoch, shrink}` reports the
  reproduction of the shrunk sequence (`found` then holds the reproduction's
  failure and result).

  Leaves unset: `:campaign`.
  """
  @spec from_found(
          Context.t(),
          map(),
          :found | {:fallback, map()} | {:shrunk, term(), term(), map()}
        ) ::
          FailureReport.t()
  def from_found(ctx, found, how) do
    {shrunk_sequence, plan_source, mint_epoch, shrink} =
      case how do
        :found -> {found.sequence, :generated, 0, %{iterations: 0, time_ms: 0, stop: :done}}
        {:fallback, shrink} -> {found.sequence, :generated, 0, shrink}
        # Without shrinking the reproduced sequence is the generated one.
        {:shrunk, sequence, epoch, shrink} -> {sequence, plan_source(ctx), epoch, shrink}
      end

    result = found.result || %{}
    failure = found.failure
    last_root = last_root(failure, result)

    FailureReport.new(
      seed: found.run_seed,
      run_number: found.run_number,
      original_sequence: found.sequence,
      shrunk_sequence: shrunk_sequence,
      # The embedded trace describes whichever run carries the observed
      # failure (DR-033): the shrunk minimal reproduction when it reproduced,
      # else the original generated run.
      plan_source: plan_source,
      source_revision: RunTrace.source_revision(),
      # Record the run inputs of the execution the report describes (DR-034):
      # the reproduction re-execution's epoch when it reproduced, else the
      # exploration run's epoch 0.
      run_nonce: ctx.run_nonce,
      mint_epoch: mint_epoch,
      executed: Map.get(result, :executed, %{}),
      failed_at_index: failure.root,
      original_failed_at_index: Map.get(found, :original_root, failure.root),
      last_root: last_root,
      failure_reason: failure.reason,
      report_kind: failure.report_kind,
      variant: failure.variant,
      shrink_iterations: shrink.iterations,
      shrink_time_ms: shrink.time_ms,
      shrink_stop: shrink.stop,
      reference_result: Map.get(found, :reference_result),
      event_log: Map.get(result, :event_log, []),
      projections: Map.get(result, :projections, %{}),
      projections_before: Map.get(result, :projections_before),
      command_fold_ordinals: Map.get(result, :command_fold_ordinals, %{}),
      # The reported run's log lines (DR-054); a target whose setup/1 failed
      # has no result, and its failure carries that setup's lines.
      logs: Map.get(result, :logs) || Map.get(failure, :logs, %{}),
      stacktrace: failure.stacktrace,
      model: ctx.model,
      targets: ctx.target_entries,
      concurrency: ctx.concurrency,
      compare: ctx.compare,
      setup_log: ctx.setup_log,
      log_filter: ctx.log_filter,
      stutter: ctx.stutter,
      max_commands: ctx.max_commands,
      check_mode: ctx.check_mode,
      external_markers: ctx.external_markers,
      check_fires: found.fires,
      run_check_fires: run_fires(found),
      other_failures: Enum.map(found.other_failures, &other_failure/1),
      compare_counts: found.compare_counts,
      expansion: report_expansion(ctx, found, shrunk_sequence),
      expansion_counts:
        Expansion.merge_counts(
          found.expansion_counts,
          Expansion.counts(found.expansion, last_root)
        ),
      latency: ctx.latency,
      metrics: ctx.measured_metrics
    )
  end

  @doc """
  Reports a further shrink that reproduced.

  `report` is the report that was shrunk again. `reproduction` holds the
  reproduction of the further-shrunk sequence: `:targets`, `:failure`,
  `:result`, `:other_failures`, `:counts` and `:epoch`. `shrink_result` is what
  the shrinker returned and `elapsed` the milliseconds it took; both add to the
  incoming report's iterations and time. The report keeps its own setup lines,
  log filter and command bound.

  Leaves unset: `:campaign`, `:last_root`, `:latency` and `:metrics`.
  """
  @spec further_shrink(Context.t(), FailureReport.t(), map(), map(), non_neg_integer()) ::
          FailureReport.t()
  def further_shrink(ctx, report, reproduction, shrink_result, elapsed) do
    %{
      targets: targets,
      failure: failure,
      result: result,
      other_failures: other_failures,
      counts: counts,
      epoch: fresh_epoch
    } = reproduction

    FailureReport.new(
      seed: report.seed,
      run_number: report.run_number,
      original_sequence: report.original_sequence,
      shrunk_sequence: shrink_result.sequence,
      failed_at_index: failure.root,
      original_failed_at_index: report.original_failed_at_index,
      failure_reason: failure.reason,
      report_kind: failure.report_kind,
      variant: failure.variant,
      shrink_iterations: report.shrink_iterations + shrink_result.iterations,
      shrink_time_ms: report.shrink_time_ms + elapsed,
      shrink_stop: shrink_result.stop,
      reference_result: counts.reference_result,
      event_log: Map.get(result, :event_log, []),
      executed: Map.get(result, :executed, %{}),
      # A further-shrunk report only reaches here on a genuine
      # reproduction, so its plan is a shrinker product (DR-033).
      plan_source: :shrunk,
      source_revision: RunTrace.source_revision(),
      run_nonce: ctx.run_nonce,
      mint_epoch: fresh_epoch,
      projections: Map.get(result, :projections, %{}),
      projections_before: Map.get(result, :projections_before),
      command_fold_ordinals: Map.get(result, :command_fold_ordinals, %{}),
      model: report.model,
      targets: Enum.map(targets, &PropertyDamage.Target.to_entry/1),
      concurrency: ctx.concurrency,
      compare: ctx.compare,
      # The compare counts are the reproduction's, and its firings
      # replace the share the report's own run fired.
      compare_counts: counts.compare_counts,
      check_fires:
        (report.check_fires || %{})
        |> subtract_fires(Map.get(report, :run_check_fires) || %{})
        |> merge_fires(counts.fires),
      run_check_fires: counts.fires,
      other_failures: Enum.map(other_failures, &other_failure/1),
      # The report's own setup lines stay, as the caller gave them.
      setup_log: report.setup_log,
      log_filter: report.log_filter,
      stutter: ctx.stutter,
      max_commands: report.max_commands,
      check_mode: ctx.check_mode,
      external_markers: ctx.external_markers,
      logs: Map.get(result, :logs, %{}),
      stacktrace: failure.stacktrace,
      expansion: shrink_result.expansion,
      expansion_counts: recount(report, shrink_result.expansion, failure.root)
    )
  end

  @doc """
  The variant a target stands for in a report: its index and name.
  """
  @spec variant_of(PropertyDamage.Target.t()) :: %{index: non_neg_integer(), name: String.t()}
  def variant_of(target), do: %{index: target.index, name: target.name}

  @doc """
  Projects the colocated `{:fired, projection, name}` keys out of the check
  counters into the public `%{{projection, name} => count}` fire map, dropping
  the sampling counters (`:step`, `:command`, `:event`, per-module) that share
  the map.
  """
  @spec project_fires(map()) :: map()
  def project_fires(counters) do
    for {{:fired, projection, name}, count} <- counters, into: %{} do
      {{projection, name}, count}
    end
  end

  @doc """
  Adds the counts of two check-fire maps key by key.
  """
  @spec merge_fires(map(), map()) :: map()
  def merge_fires(acc, new) do
    Map.merge(acc, new, fn _key, a, b -> a + b end)
  end

  defp plan_source(%{shrink: false}), do: :generated
  defp plan_source(_ctx), do: :shrunk

  # The last root the failing run executed: none when a setup command failed,
  # the failing root, or for a failure at no root (a `:startup` check, the end
  # of the run) every root when any root executed, else none.
  defp last_root(%{report_kind: :setup_failed}, _result), do: -1
  defp last_root(%{root: nil}, result), do: if(ran_a_root?(result), do: nil, else: -1)
  defp last_root(failure, _result), do: failure.root

  defp ran_a_root?(result),
    do: result |> Map.get(:executed, %{}) |> Map.keys() |> Enum.any?(&Sequence.Position.root?/1)

  # The concrete sequences of the run the report describes; a found failure
  # that carries none ran the reference target's roots as generated.
  defp report_expansion(_ctx, %{expansion: %{} = expansion}, _sequence), do: expansion
  defp report_expansion(ctx, _found, sequence), do: Expansion.identity(sequence, [ctx.target])

  defp other_failure(failure),
    do: %{variant: failure.variant, root: failure.root, failure: failure.reason}

  # The firings the run a found failure describes fired: its reproduction's,
  # else the whole-run firings less those of the runs before it.
  defp run_fires(%{run_fires: fires}), do: fires
  defp run_fires(found), do: subtract_fires(found.fires, Map.get(found, :fires_before, %{}))

  defp subtract_fires(fires, taken) do
    for {key, count} <- fires,
        left = count - Map.get(taken, key, 0),
        left > 0,
        into: %{},
        do: {key, left}
  end

  # The report's expansion counts with the failing run's share replaced by
  # the further-shrunk run's; the counts of the runs that passed before it
  # stay.
  defp recount(report, expansion, failed_at) do
    recorded = %{
      variants: Map.new(recorded_choices(report), &{elem(&1, 0), %{choices: elem(&1, 1)}})
    }

    (report.expansion_counts || %{})
    |> Expansion.subtract_counts(Expansion.counts(recorded, report.failed_at_index))
    |> Expansion.merge_counts(Expansion.counts(expansion, failed_at))
  end

  # What every target of the report's run ran, by name: the replay term's
  # choices (each given its root's module), else the trace's.
  defp recorded_choices(%FailureReport{replay: %{roots: roots, choices: choices}}) do
    modules = Map.new(roots, &{&1.root_id, &1.command.__struct__})

    Map.new(choices, fn {name, ran} ->
      {name, Enum.map(ran, &Map.put(&1, :module, Map.fetch!(modules, &1.root_id)))}
    end)
  end

  defp recorded_choices(%FailureReport{trace: %RunTrace{expansion: %{} = traced}}), do: traced
  defp recorded_choices(_report), do: %{}
end
