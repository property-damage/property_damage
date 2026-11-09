defmodule PropertyDamage.Reproduction do
  @moduledoc """
  The failure path of a run: shrink the failing sequence, reproduce the shrunk
  sequence once, build the report, place its replay artifact and announce it.

  The campaign loop (`PropertyDamage.Campaign`) calls `handle_failure/2` for each
  failure a run finds, and `report_failure/2` for a failure that has nothing to
  shrink. The facade's `shrink_further/2` runs the same shrink and reproduction
  on an existing report through `shrink_further/3`. The shrinker hands every candidate
  to the oracle `PropertyDamage.Runner.shrink_oracle/2` builds, and the
  reproduction runs through `PropertyDamage.Runner.execute/2`.

  `handle_failure/2` and `report_failure/2` take the campaign context, the
  `PropertyDamage.Campaign.Context` the run holds. `PropertyDamage.ReportBuilder` builds the
  report each of them returns.
  """

  alias PropertyDamage.Campaign.Context

  alias PropertyDamage.{
    Expansion,
    Failure,
    FailureReport,
    Options,
    Progress.Reporter,
    Progress.RunResult,
    ReplayArtifact,
    ReportBuilder,
    Runner,
    Sequence,
    Shrinker,
    Stutter
  }

  alias PropertyDamage.Shrinker.Config, as: ShrinkerConfig

  @doc """
  Shrinks a failure the run found, reproduces the shrunk sequence and reports.

  `found` holds the failing run's sequence, effective seed, run number,
  expansion and scheduler-shaped failure. A target's setup failure implicates no
  command, so it is reported as found, unshrunk. Returns `{:error, report}`.
  """
  def handle_failure(ctx, %{failure: %{report_kind: :setup_failed}} = found) do
    report_failure(ctx, ReportBuilder.from_found(ctx, found, :found))
  end

  def handle_failure(ctx, found) do
    # One mint-epoch source for this whole logical run (DR-034): shrink attempts
    # and the reproduction re-execution below all draw from it, so no two SUT
    # executions in this run send the same client-minted values on a
    # non-resettable SUT. Epoch 0 was the exploration run.
    mint_epoch_counter = :atomics.new(1, signed: false)

    {shrunk_sequence, shrunk_expansion, shrink_iterations, shrink_time_ms, shrink_stop} =
      if ctx.shrink do
        shrink_result =
          Shrinker.shrink(found.sequence,
            failed_at_index: found.failure.root,
            failure_reason: found.failure.reason,
            variant_index: found.failure.variant.index,
            model: ctx.model,
            targets: ctx.targets,
            # Stutter failures are shrinkable (DR-029): the oracle runs every
            # candidate of one with stutter forced on (probability 1.0), so it
            # minimizes to the offending command rather than being skipped.
            oracle: shrink_oracle(ctx, found),
            config: ctx.shrinker_config,
            external_markers: ctx.external_markers,
            rng_seed: found.run_seed,
            mint_epoch_counter: mint_epoch_counter,
            # Every target runs each candidate root as it ran the failing run:
            # the entries are carried, with no new draw.
            expansion: found.expansion
          )

        {shrink_result.sequence, shrink_result.expansion, shrink_result.iterations,
         shrink_result.time_ms, shrink_result.stop}
      else
        {found.sequence, found.expansion, 0, 0, :done}
      end

    shrink = %{iterations: shrink_iterations, time_ms: shrink_time_ms, stop: shrink_stop}

    # Re-execute the shrunk sequence to get fresh state (the original result has
    # state from before shrinking). The reproduction is a fresh SUT execution:
    # it gets its own mint epoch from the shared counter (DR-034).
    fresh_epoch = :atomics.add_get(mint_epoch_counter, 1, 1)

    # Normally the re-execution reproduces the failure on the (possibly smaller)
    # shrunk sequence, giving the report fresh state and a minimal repro. But an
    # intermittent failure may not reproduce on this single re-run, or may fail
    # differently (another kind, another target). Then the report falls back to
    # the original failing run: its sequence, reason, index, target and state.
    expansion = reproduction_expansion(ctx, shrunk_sequence, shrunk_expansion, found)

    report =
      case reproduce(ctx, shrunk_sequence, found, fresh_epoch, expansion) do
        {:reproduced, failure, result, other_failures, counts} ->
          # The report describes the reproduction: its compare counts, and
          # its firings in place of the failing run's.
          reproduced =
            Map.merge(found, %{
              failure: failure,
              result: result,
              reference_result: counts.reference_result,
              other_failures: other_failures,
              expansion: expansion,
              original_root: found.failure.root,
              fires: ReportBuilder.merge_fires(Map.get(found, :fires_before, %{}), counts.fires),
              run_fires: counts.fires,
              compare_counts: counts.compare_counts
            })

          ReportBuilder.from_found(
            ctx,
            reproduced,
            {:shrunk, shrunk_sequence, fresh_epoch, shrink}
          )

        # A passing re-run, or a re-execution whose adapter setup failed: not
        # a reproduction.
        _not_reproduced ->
          ReportBuilder.from_found(ctx, found, {:fallback, shrink})
      end

    report_failure(ctx, report)
  end

  # The oracle every shrink candidate runs through: the run driver with the
  # run's options, every candidate as run 0 of the failing run's effective
  # seed, so the per-target RNG and the stutter base track the original run.
  defp shrink_oracle(ctx, found) do
    Runner.shrink_oracle(
      %Runner.Context{
        model: ctx.model,
        targets: ctx.targets,
        seed: found.run_seed,
        run_number: 0,
        run_nonce: ctx.run_nonce,
        concurrency: ctx.concurrency,
        compare: ctx.compare,
        stutter_config: Context.stutter_config(ctx),
        keep_attempts: ctx.keep_attempts,
        check_mode: ctx.check_mode
      },
      Failure.signature(found.failure.reason, found.failure.variant.index)
    )
  end

  # Runs the shrunk sequence once on every target through the run driver, each
  # target with its own services. For a stutter failure, stutter is forced on
  # with the run's seed so the fresh state carries the reproduced violation
  # (DR-029). Returns `{:reproduced, failure, result, other_failures, counts}`
  # when its primary failure has the found failure's signature (kind, name,
  # target), whatever its other failures, where `counts` holds the
  # reproduction's `compare_counts` and the check `fires` of its reference
  # target; `{:setup_failed, reason}` when a target's setup failed, else
  # `:not_reproduced`.
  defp reproduce(ctx, %Sequence{} = sequence, found, epoch, expansion) do
    plan = Sequence.plan(sequence, expansion && Expansion.schedule(ctx.targets, expansion))

    context = %Runner.Context{
      model: ctx.model,
      targets: ctx.targets,
      seed: found.run_seed,
      run_number: found.run_number,
      run_seed: found.run_seed,
      run_nonce: ctx.run_nonce,
      mint_epoch: epoch,
      concurrency: ctx.concurrency,
      compare: ctx.compare,
      stutter_config: repro_stutter_config(found.failure.reason, Context.stutter_config(ctx)),
      keep_attempts: ctx.keep_attempts,
      check_mode: ctx.check_mode
    }

    {:ok, outcome} = Runner.execute(plan, context)

    case outcome.failure do
      nil ->
        :not_reproduced

      %{report_kind: :setup_failed, reason: reason} ->
        {:setup_failed, reason}

      failure ->
        if same_failure?(failure, found.failure),
          do:
            {:reproduced, failure, Enum.at(outcome.results, failure.variant.index),
             outcome.other_failures, reproduction_counts(outcome)},
          else: :not_reproduced
    end
  end

  # The compare counts of a lockstep reproduction and the check firings of
  # its reference target (DR-026: firings count what the reference ran).
  defp reproduction_counts(outcome) do
    fires =
      case outcome.results do
        [%{} = reference | _] ->
          ReportBuilder.project_fires(Map.get(reference, :check_counters, %{}))

        _no_reference ->
          %{}
      end

    %{
      compare_counts: outcome.compare_counts,
      fires: fires,
      reference_result: Enum.at(outcome.results, 0)
    }
  end

  # What every target runs when the shrunk sequence is reproduced: the
  # failing run's choices, realized again for the shrunk sequence (the
  # shrinker carries them), or every root as itself for a model without
  # expansions.
  defp reproduction_expansion(_ctx, _sequence, %{} = shrunk, _found), do: shrunk

  defp reproduction_expansion(ctx, sequence, nil, _found),
    do: Expansion.identity(sequence, ctx.targets)

  defp same_failure?(failure, found_failure) do
    Failure.signature(failure.reason, failure.variant.index) ==
      Failure.signature(found_failure.reason, found_failure.variant.index)
  end

  @doc """
  Announces a failure report and returns it as the run's result.

  Places the report's replay artifact, writes its HTML page when the run names
  a directory, emits the terminal failure notification and calls the run's
  `on_failure` handler. A raising handler is logged and never costs the report.
  """
  @spec report_failure(Context.t(), FailureReport.t()) :: {:error, FailureReport.t()}
  def report_failure(ctx, failure_report) do
    failure_report = with_replay(ctx, failure_report)
    write_html(ctx, failure_report)

    # Terminal failure notification (DR-022): the verbose consumer renders this
    # as the failure summary. The authoritative result is the returned report.
    Reporter.emit(ctx.reporter, fn ->
      %RunResult{
        outcome: :error,
        failure: failure_report,
        report_kind: failure_report.report_kind,
        variant: failure_report.variant,
        metrics: failure_report.metrics
      }
    end)

    on_failure = ctx.on_failure

    # A raising on_failure handler must not destroy the failure we just found:
    # catch it, warn, and still return the report.
    if on_failure do
      try do
        on_failure.(failure_report)
      rescue
        e ->
          require Logger

          Logger.warning(
            "on_failure handler raised #{inspect(e.__struct__)}: #{Exception.message(e)} " <>
              "-- the failure report is preserved."
          )
      catch
        kind, reason ->
          require Logger

          Logger.warning(
            "on_failure handler #{kind} #{inspect(reason)} -- the failure report is preserved."
          )
      end
    end

    {:error, failure_report}
  end

  # The report's campaign run and its replay artifact: built from what the
  # report describes, refused when a command field holds a value no file can
  # hold, and written into `replay_dir:` unless the option is `false`. A run
  # that replayed an artifact writes none of its own unless shrinking found a
  # smaller failure; it records whether the artifact reproduced.
  defp with_replay(ctx, report) do
    report = %{
      report
      | run: FailureReport.run_number(report) && FailureReport.run_number(report) + 1
    }

    case ReplayArtifact.build(report) do
      nil ->
        %{report | replay_status: :unavailable}

      term ->
        case ReplayArtifact.check(term) do
          {:refused, _refusal} = refused -> %{report | replay: refused, replay_status: :refused}
          :ok -> place_replay(ctx, %{report | replay: term}, term)
        end
    end
  end

  defp place_replay(%{replay: %{} = replay} = ctx, report, term) do
    if smaller?(report, term, replay.term) do
      write_replay(ctx, report, term)
    else
      status =
        if ReplayArtifact.reproduced?(replay.term, report), do: :reproduced, else: :not_reproduced

      %{report | replay_path: replay.path, replay_status: status}
    end
  end

  defp place_replay(ctx, report, term), do: write_replay(ctx, report, term)

  defp write_replay(%{replay_dir: false}, report, _term), do: %{report | replay_status: :disabled}

  defp write_replay(ctx, report, term) do
    case ReplayArtifact.write(term, ctx.replay_dir) do
      {:ok, path} -> %{report | replay_path: path, replay_status: :written}
      {:error, reason} -> %{report | replay_status: {:write_failed, reason}}
    end
  end

  # The report's HTML page, when the run names a directory for it. An error
  # while rendering or writing the page costs one logged warning, never the
  # report.
  defp write_html(%{report_html: dir}, report) when is_binary(dir) do
    case FailureReport.HTML.write(report, dir) do
      {:ok, _path} -> :ok
      {:error, reason} -> warn_html(dir, inspect(reason))
    end
  rescue
    exception -> warn_html(dir, Exception.message(exception))
  end

  defp write_html(_ctx, _report), do: :ok

  defp warn_html(dir, reason) do
    require Logger

    Logger.warning("could not write the failure report's HTML page into #{dir}: #{reason}")
  end

  # A replay run's shrink found a failure with fewer roots than the artifact.
  defp smaller?(report, term, replayed),
    do: report.trace.plan_source == :shrunk and length(term.roots) < length(replayed.roots)

  # Check if a failure reason is stutter-related (idempotency violation or execution failure)
  defp stutter_failure?(%Failure{} = failure),
    do: Failure.kind(failure) in [:idempotency_violation, :stutter_execution_failed]

  defp stutter_failure?(_), do: false

  # The stutter configuration of the post-shrink re-execution (DR-029). For a
  # stutter failure, stutter is forced on (prob 1.0) so the report's fresh
  # state reproduces the violation; otherwise the re-execution runs without
  # stutter.
  defp repro_stutter_config(failure_reason, %Stutter.Config{} = config) do
    if stutter_failure?(failure_reason), do: %{config | probability: 1.0, enabled: true}
  end

  defp repro_stutter_config(_failure_reason, _config), do: nil

  @doc """
  Attempts further shrinking on an existing failure report.

  The facade's `shrink_further/2` documents the options and the result. `caller`
  names that public function in the error a report with no recorded choices
  raises.
  """
  @spec shrink_further(FailureReport.t(), keyword(), String.t()) ::
          {:ok, FailureReport.t()} | {:error, term()}
  def shrink_further(%FailureReport{} = report, opts, caller) do
    cond do
      is_nil(FailureReport.model(report)) or is_nil(FailureReport.reference_target(report)) ->
        {:error, :missing_model_or_target}

      report.report_kind in [:setup_failed, :latency_exceeded] ->
        {:ok, report}

      true ->
        targets = Options.override_targets!(opts, report.targets)

        # Each target re-runs the roots as the report's run ran them: the
        # sequence and every target's choices come from the report's replay
        # term (else from its trace), never from a new draw. A target whose
        # choices the report does not record raises here.
        reexecution =
          ReplayArtifact.reexecution(
            report,
            Enum.map(targets, & &1.name),
            caller,
            external_markers: further_markers(report, opts)
          )

        if names_failing_target?(targets, report.variant),
          do: do_shrink_further(report, targets, reexecution, opts),
          else: {:error, {:variant_not_in_targets, report.variant.name}}
    end
  end

  # The markers a re-shrink simulates with: the option, else the run's.
  defp further_markers(report, opts),
    do: Keyword.get(opts, :external_markers, report.external_markers)

  # Whether `targets` hold the target the report failed in at the index it
  # failed at. A candidate counts only when it fails in that target, so
  # targets that renamed, dropped or moved it could never reproduce it.
  defp names_failing_target?(_targets, nil), do: true

  defp names_failing_target?(targets, %{index: index, name: name}),
    do: match?(%{name: ^name}, Enum.at(targets, index))

  defp do_shrink_further(report, targets, {sequence, variants}, opts) do
    strategy = Keyword.get(opts, :strategy, :thorough)

    ctx = %Context{
      model: FailureReport.model(report),
      targets: targets,
      target: hd(targets),
      # Carry the original run's nonce (DR-034) so re-shrinking mints the same
      # class of run-scoped values.
      run_nonce: report.trace && report.trace.run_nonce,
      concurrency: Keyword.get(opts, :concurrency, report.concurrency),
      compare: shrink_further_compare(report, opts),
      stutter: report.stutter,
      keep_attempts: Options.keep_attempts!(opts),
      external_markers: further_markers(report, opts),
      # A `:record` failure re-shrinks under `:record`, as the run found it.
      check_mode: report.check_mode || :halt
    }

    traced = variants && Map.new(variants, fn {name, variant} -> {name, variant.choices} end)

    found = %{
      sequence: sequence,
      run_seed: FailureReport.seed(report),
      run_number: FailureReport.run_number(report),
      failure: %{
        report_kind: report.report_kind,
        variant: report.variant || ReportBuilder.variant_of(ctx.target),
        root: report.failed_at_index,
        reason: FailureReport.failure_reason(report),
        stacktrace: report.stacktrace
      }
    }

    # A shared epoch counter keeps every SUT execution in this re-shrink
    # distinct (DR-034).
    mint_epoch_counter = :atomics.new(1, signed: false)
    start_time = System.monotonic_time(:millisecond)

    shrink_result =
      Shrinker.shrink(found.sequence,
        failed_at_index: found.failure.root,
        failure_reason: found.failure.reason,
        variant_index: found.failure.variant.index,
        model: ctx.model,
        targets: targets,
        # A stutter failure re-shrinks with stutter forced on (DR-029), as in
        # the run's own failure path.
        oracle: shrink_oracle(ctx, found),
        external_markers: ctx.external_markers,
        config:
          ShrinkerConfig.new(
            max_iterations: strategy_iterations(strategy, opts),
            max_time_ms: strategy_time(strategy, opts),
            shrink_arguments: Keyword.get(opts, :shrink_arguments, true),
            granularity_threshold: strategy_threshold(strategy)
          ),
        # The report's seed is the run's effective seed.
        rng_seed: FailureReport.seed(report),
        mint_epoch_counter: mint_epoch_counter,
        expansion: traced,
        root_ids: Expansion.root_ids(traced)
      )

    fresh_epoch = :atomics.add_get(mint_epoch_counter, 1, 1)

    # As in the run's failure path: only adopt the further-shrunk sequence on a
    # genuine reproduction. A re-execution that passes or fails differently
    # confirms nothing, so the incoming report comes back unchanged.
    case reproduce(ctx, shrink_result.sequence, found, fresh_epoch, shrink_result.expansion) do
      {:reproduced, failure, result, other_failures, counts} ->
        elapsed = System.monotonic_time(:millisecond) - start_time

        further =
          ReportBuilder.further_shrink(
            ctx,
            report,
            %{
              targets: targets,
              failure: failure,
              result: result,
              other_failures: other_failures,
              counts: counts,
              epoch: fresh_epoch
            },
            shrink_result,
            elapsed
          )

        {:ok, further_replay(ctx, report, further)}

      # A re-execution whose adapter setup fails cannot confirm a further
      # shrink; surface the setup failure.
      {:setup_failed, reason} ->
        {:error, reason}

      :not_reproduced ->
        {:ok, report}
    end
  end

  # The further-shrunk report's replay term and artifact. The artifact goes
  # beside the one the report came with, replacing it (the same seed names
  # the same file); a report with no artifact file gets none, and keeps the
  # reason it had none.
  defp further_replay(ctx, %FailureReport{replay_path: path}, further) when is_binary(path),
    do: with_replay(%{ctx | replay_dir: Path.dirname(path), replay: nil}, further)

  defp further_replay(ctx, report, further) do
    case with_replay(%{ctx | replay_dir: false, replay: nil}, further) do
      %{replay_status: :disabled} = replayed ->
        %{replayed | replay_status: report.replay_status || :disabled}

      replayed ->
        replayed
    end
  end

  # The convergence bound of a re-shrink: the `compare:` option, validated as
  # on `run/1`, else the report's.
  defp shrink_further_compare(report, opts) do
    if Keyword.has_key?(opts, :equivalence) do
      raise ArgumentError,
            "`equivalence:` was removed; targets are compared only through `@compare` " <>
              "functions, each deciding agreement with its own `using:` relation"
    end

    case Keyword.fetch(opts, :compare) do
      {:ok, compare} ->
        case Options.validate_compare(compare) do
          {:ok, compare} -> compare
          {:error, message} -> raise ArgumentError, message
        end

      :error ->
        report.compare
    end
  end

  # Strategy configuration helpers
  defp strategy_iterations(:quick, opts), do: Keyword.get(opts, :max_iterations, 500)
  defp strategy_iterations(:thorough, opts), do: Keyword.get(opts, :max_iterations, 2000)
  defp strategy_iterations(:exhaustive, opts), do: Keyword.get(opts, :max_iterations, 10_000)

  defp strategy_time(:quick, opts), do: Keyword.get(opts, :max_time_ms, 10_000)
  defp strategy_time(:thorough, opts), do: Keyword.get(opts, :max_time_ms, 60_000)
  defp strategy_time(:exhaustive, opts), do: Keyword.get(opts, :max_time_ms, 300_000)

  defp strategy_threshold(:quick), do: 4
  defp strategy_threshold(:thorough), do: 8
  defp strategy_threshold(:exhaustive), do: 16
end
