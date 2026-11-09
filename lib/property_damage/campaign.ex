defmodule PropertyDamage.Campaign do
  @moduledoc """
  The run loop behind the public `run/1`: it validates the options, builds
  the `PropertyDamage.Campaign.Context`, replays the seed library, then runs
  one generated sequence after another until one fails or all have passed.

  `run/2` is the entry point. For each run the loop draws a sequence from the
  seed, hands it to the run driver `PropertyDamage.Runner`, folds the outcome
  into the accumulator (check firings, compare counts, coverage, latency
  samples) and, on a failure, passes it to `PropertyDamage.Reproduction`. After
  the last run it judges the latency budget and returns the success stats.
  `loop/2` is the loop alone, driven by the context's `run_once` step.

  The seed-library replay phase runs before exploration and prints its own
  banner and summary. The `run/1` of the `PropertyDamage` module documents
  the options and the result.
  """

  alias PropertyDamage.Campaign.Context
  alias PropertyDamage.Log.{Cap, Filter}

  alias PropertyDamage.{
    Comparison,
    Coverage,
    Expansion,
    FailureReport,
    Generator,
    LatencyMetrics,
    Options,
    Progress.Printer,
    Progress.ReplayUpdate,
    Progress.Reporter,
    Progress.RunResult,
    Progress.RunUpdate,
    ReplayArtifact,
    ReportBuilder,
    Reproduction,
    Runner,
    SeedLibrary,
    Sequence,
    Telemetry,
    Validation
  }

  alias PropertyDamage.Shrinker.Config, as: ShrinkerConfig

  @typedoc """
  The accumulator of a whole run. See `loop/2`.
  """
  @type acc :: %{
          fires: map(),
          compare_counts: map(),
          tracker: term() | nil,
          total_commands: non_neg_integer(),
          setup_commands: non_neg_integer(),
          teardown_commands: non_neg_integer(),
          expansion_counts: map(),
          samples: list(),
          last_run: map() | nil
        }

  @doc """
  Runs a campaign with no `on_failure` callback and no regression handler.

  This is `run/2` for internal reruns (verification, exploration) that pass
  neither option.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, FailureReport.t()}
  def run(opts), do: run(opts, fn _opts -> nil end)

  @doc """
  Runs a campaign: validates `opts`, builds the campaign context, replays the
  seed library when it is on, then runs every run and returns the result.

  The `run/1` of the `PropertyDamage` module documents the options and the
  result. `on_failure_for` builds the run's `on_failure` callback from the
  validated options (or returns `nil`), so the campaign stays free of the
  regression handler that the callback may reach.
  """
  @spec run(keyword(), (keyword() -> (FailureReport.t() -> term()) | nil)) ::
          {:ok, map()} | {:error, FailureReport.t()}
  def run(opts, on_failure_for) when is_function(on_failure_for, 1) do
    # The reproduction command prints `latency:` as the caller wrote it, which
    # validation normalizes away.
    latency_given = Keyword.get(opts, :latency, false)

    # Validate options with NimbleOptions - applies defaults and provides helpful errors
    raw_opts = opts
    opts = Options.validate_run!(opts)

    # `only:` picks one run, or the run a replay artifact records, and the
    # targets of `targets:` that run (see `running_targets/2`).
    {opts, replay} = only_options(opts, raw_opts)

    model = opts[:model]
    all_targets = opts[:targets]
    targets = running_targets(all_targets, opts[:only])

    # Two or more targets are compared only through @compare observations:
    # refuse a model without any before anything runs, `validate:` or not.
    Comparison.check_model!(model, length(targets))
    # A model that still defines a removed lifecycle hook fails here, before
    # any target is set up.
    PropertyDamage.Model.check_lifecycle!(model)
    # The rules for expansions/0 fail here too, before any target is set up.
    Expansion.check_model!(model)
    [reference | _] = targets
    max_commands = opts[:max_commands]
    max_runs = opts[:max_runs]
    # Resolution order (DR-034): explicit option, else environment variable
    # (mix test cannot forward custom flags), else a random default.
    seed = opts[:seed] || env_int("PD_SEED") || :rand.uniform(1_000_000_000)

    # The run nonce seeds ONLY client-minted run-scoped values (mint_per_run).
    # Its random default comes from crypto entropy, NEVER the process RNG:
    # ExUnit pins :rand under `--seed N`, which would re-mint colliding values.
    # Every target of a run shares it, so all of them receive byte-identical
    # client-minted requests.
    run_nonce =
      opts[:run_nonce] || env_int("PD_RUN_NONCE") ||
        :crypto.strong_rand_bytes(8) |> :binary.decode_unsigned()

    verbose = opts[:verbose]

    # Seed-library replay working set (DR-023). `nil` when disabled; otherwise a
    # small config map driving the pre-exploration replay phase.
    # An `only:` run runs the one run it names, never the library's seeds.
    seed_library = if opts[:only], do: nil, else: build_seed_library_config(opts, verbose)
    seed_library_path = seed_library && seed_library.path

    # Unified progress projection (DR-022): one reporter fans out to the verbose
    # printer (if any), the user `on_progress:` callback (if any), and telemetry
    # (only when a handler is attached). With no consumers it is inert and the
    # run loop builds no %Progress{}.
    reporter =
      Reporter.new([
        if(verbose, do: Printer.consumer(model, targets, opts)),
        opts[:on_progress],
        Telemetry.progress_consumer([:test_run])
      ])

    ctx = %Context{
      model: model,
      targets: executed_targets(targets),
      # Every target of `targets:`: each one's choices are computed on the
      # full list, so a target keeps them whichever targets `only:` runs.
      all_targets: all_targets,
      target_entries: Enum.map(targets, &PropertyDamage.Target.to_entry/1),
      target: reference,
      max_commands: max_commands,
      max_runs: max_runs,
      first_run: first_run(opts[:only]),
      replay: replay,
      replay_dir: opts[:replay_dir],
      report_html: FailureReport.HTML.dir(opts[:report_html]),
      seed: seed,
      run_nonce: run_nonce,
      shrink: opts[:shrink],
      shrinker_config: opts[:shrinker_config] || ShrinkerConfig.new(),
      on_failure: on_failure_for.(opts),
      reporter: reporter,
      stutter: opts[:stutter],
      keep_attempts: keep_attempts(opts),
      log_filter: Filter.from_option(opts[:log]),
      setup_log: opts[:setup_log],
      check_mode: opts[:check_mode],
      coverage: opts[:coverage],
      concurrency: opts[:concurrency],
      compare: opts[:compare],
      latency: latency_given,
      latency_budget: opts[:latency],
      external_markers: opts[:external_markers] || []
    }

    # Validate configuration against every target's adapter and injectors
    if opts[:validate] do
      for target <- targets do
        {:ok, warnings} = Validation.validate!(model, target.adapter, injectors: target.injectors)

        if verbose do
          Validation.print_summary(model, target.adapter, warnings)
        end
      end

      # Targets that share an adapter and a config share the system's state.
      for warning <- Validation.target_warnings(targets) do
        require Logger
        Logger.warning(warning)
      end
    end

    # Print runtime warnings when verbose
    if verbose do
      runtime_warnings = Validation.runtime_warnings(opts)

      unless Enum.empty?(runtime_warnings) do
        IO.puts("Runtime Warnings:")

        for warning <- runtime_warnings do
          IO.puts("  ⚠ #{warning}")
        end

        IO.puts("")
      end
    end

    # Emit telemetry for run start
    telemetry_metadata = %{
      model: model,
      targets: Enum.map(targets, &%{index: &1.index, name: &1.name, adapter: &1.adapter}),
      max_runs: max_runs,
      max_commands: max_commands,
      seed: seed
    }

    start_time = System.system_time()
    Telemetry.run_start(telemetry_metadata)

    try do
      result = do_run(ctx, seed_library)

      # Auto-append a new exploration failure's seed to the working set
      # (DR-023); deduplicated by seed, so a replayed halt is a no-op.
      maybe_append_failure_seed(result, seed_library_path)

      # Emit telemetry for run stop
      {result_type, result_data} =
        case result do
          {:ok, stats} -> {:ok, stats}
          {:error, _} -> {:error, %{}}
        end

      Telemetry.run_stop(
        start_time,
        Map.merge(telemetry_metadata, %{
          result: result_type,
          runs_completed: if(result_type == :ok, do: result_data[:runs], else: 0),
          total_commands: if(result_type == :ok, do: result_data[:total_commands], else: 0)
        })
      )

      result
    rescue
      e ->
        Telemetry.run_exception(start_time, :error, e, __STACKTRACE__, telemetry_metadata)
        reraise e, __STACKTRACE__
    end
  end

  defp do_run(ctx, seed_library) do
    # Seed the process RNG (consumed by execution-time randomness such as
    # stutter decisions; sequence generation is seeded explicitly per run
    # via Generator.generate_value/2, NOT through the process RNG)
    :rand.seed(:exsss, ctx.seed)

    # Campaign start (DR-022): the verbose consumer renders this as the header.
    Reporter.emit(ctx.reporter, fn ->
      %RunUpdate{phase: :start, run_number: 0, total_runs: ctx.max_runs}
    end)

    # Generate sequences and run
    generator_opts = [max_commands: ctx.max_commands, external_markers: ctx.external_markers]

    ctx = %{ctx | generator: Generator.generate_sequence(ctx.model, generator_opts)}

    # Seed-library replay phase (DR-023): replay previously-failing seeds before
    # random exploration, reusing the per-sequence machinery below. On a
    # still-failing replay the run halts here; otherwise exploration proceeds.
    case replay_phase(seed_library, ctx) do
      {:halt, failure} ->
        {:error, failure}

      :proceed ->
        # Whole-run coverage accumulator (DR-026). `fires` aggregates
        # per-check firings across every generated sequence (always-on);
        # `tracker` accumulates the heavier command/transition/state dimensions
        # only when `coverage: true` was requested.
        acc = %{
          fires: %{},
          compare_counts: Comparison.zero_counts(ctx.model),
          tracker: if(ctx.coverage, do: Coverage.new(ctx.model), else: nil),
          total_commands: 0,
          setup_commands: 0,
          teardown_commands: 0,
          expansion_counts: Map.new(ctx.targets, &{&1.name, %{}}),
          samples: [],
          last_run: nil
        }

        loop(ctx, acc)
    end
  end

  @doc """
  Runs the campaign's runs from `ctx.first_run` to the end and finishes the
  campaign.

  Each run is one `ctx.run_once` step, called as `run_once.(ctx, run_number,
  acc)`, which returns `{:pass, acc}` or `{:error, found}`. The loop stops at
  the first error and returns it. When every run passes, it judges the latency
  budget and returns `{:ok, stats}`, or the report of a breached budget.
  `ctx.run_once` defaults to the campaign's own step, which generates one
  sequence from the seed and runs it on every target.

  `acc` is the accumulator of the whole run, a map with these keys: `fires`
  (check firings), `compare_counts`, `tracker` (`nil` unless coverage is on),
  `total_commands`, `setup_commands`, `teardown_commands`, `expansion_counts`,
  `samples` (latency samples) and `last_run` (`nil` before the first run
  passes).
  """
  @spec loop(Context.t(), acc()) :: {:ok, map()} | {:error, FailureReport.t()}
  def loop(%Context{} = ctx, acc), do: run_loop(ctx, ctx.first_run, acc)

  # `only:` options: `only: [run: n]` runs run n alone; `only: [replay:
  # path]` runs the run the artifact at `path` records, on the targets it
  # records (in its order, with its modes), from its seed, shrinking only
  # when the caller asked. Returns the options and the replay (nil without
  # `replay:`): the artifact term, its path, and the sequence and choices it
  # records, computed here so a broken artifact fails before any setup.
  defp only_options(opts, raw_opts) do
    case opts[:only] do
      nil ->
        {opts, nil}

      only ->
        opts = Keyword.put(opts, :max_runs, 1)

        case Keyword.fetch(only, :replay) do
          {:ok, path} ->
            # An `external_markers:` the caller gave replaces the artifact's.
            given = if Keyword.has_key?(raw_opts, :external_markers), do: opts, else: []

            replay =
              load_replay!(
                path,
                opts[:model],
                opts[:targets],
                Keyword.take(given, [:external_markers])
              )

            {opts
             |> Keyword.put(:seed, replay.term.seed)
             |> Keyword.put(:targets, replay.targets)
             |> Keyword.put(:external_markers, replay.external_markers)
             |> Keyword.put(:shrink, Keyword.get(raw_opts, :shrink, false)), replay}

          :error ->
            {opts, nil}
        end
    end
  end

  # The replay reads the artifact's commands with the markers it records,
  # or with the `external_markers:` in `markers` when the caller gave one.
  defp load_replay!(path, model, targets, markers) do
    # The loader builds structs of loaded modules only. Before it resolves the
    # file's atoms it loads the framework's failure and expansion modules and,
    # when the model the file names is loaded, the commands and projections
    # that model lists, so the modules `model:` names are loaded first: the
    # model and the commands it lists. A name still unknown after that, such
    # as a leaf only an expansion produces or an atom of a constants module,
    # makes the loader load the modules of every loaded application and read
    # the file once more.
    load_model_modules(model)

    term =
      case ReplayArtifact.read(path) do
        {:ok, term} ->
          term

        {:error, {:unknown_struct_module, module}} ->
          raise ArgumentError,
                "`only: [replay: #{inspect(path)}]`: the replay artifact holds a struct of " <>
                  "#{inspect(module)}, which is not a loaded command module; an artifact " <>
                  "holds only the structs of command modules that are already loaded and " <>
                  "the framework's own placeholders"

        {:error, reason} ->
          raise ArgumentError, "`only: [replay: #{inspect(path)}]`: " <> reason
      end

    if term.model != model do
      raise ArgumentError,
            "`only: [replay: #{inspect(path)}]` records a run of #{inspect(term.model)}, " <>
              "not of `model:` #{inspect(model)}"
    end

    recorded = Enum.map(term.targets, & &1.name)
    given = Enum.map(targets, & &1.name)

    case {recorded -- given, given -- recorded} do
      {[], []} ->
        :ok

      {missing, extra} ->
        raise ArgumentError,
              "`only: [replay: #{inspect(path)}]` replays exactly the targets the artifact " <>
                "records (#{Enum.map_join(recorded, ", ", &inspect/1)}), so `targets:` must " <>
                "name them all and no other: " <>
                Enum.join(
                  Enum.reject(
                    [
                      missing != [] && "missing #{Enum.map_join(missing, ", ", &inspect/1)}",
                      extra != [] && "not recorded #{Enum.map_join(extra, ", ", &inspect/1)}"
                    ],
                    &(&1 == false)
                  ),
                  "; "
                )
    end

    # The artifact's order and modes win: its first target is the reference,
    # and every target runs what it recorded.
    replayed =
      term.targets
      |> Enum.with_index()
      |> Enum.map(fn {%{name: name, expansion: mode}, index} ->
        %{Enum.find(targets, &(&1.name == name)) | index: index, expansion: mode}
      end)

    sequence = ReplayArtifact.sequence(term, markers)

    %{
      term: term,
      path: path,
      targets: replayed,
      external_markers: Keyword.get(markers, :external_markers, term.external_markers),
      sequence: sequence,
      expansion: ReplayArtifact.expansion(term, sequence, nil, markers)
    }
  end

  defp load_model_modules(model) do
    for callback <- [:commands, :setup_each, :teardown_each],
        PropertyDamage.ModuleCheck.exports?(model, callback, 0),
        entry <- apply(model, callback, []),
        module = PropertyDamage.Model.entry_module(entry),
        not is_nil(module),
        do: Code.ensure_loaded(module)

    :ok
  end

  # The targets that run: every target, or under `only: [variants: names]`
  # the named ones and, unless `with_reference: false`, the reference, in
  # `targets:` order and indexed from 0.
  defp running_targets(targets, only) do
    case only && only[:variants] do
      nil ->
        targets

      names ->
        keep = if only[:with_reference], do: [hd(targets).name | names], else: names

        targets
        |> Enum.filter(&(&1.name in keep))
        |> Enum.with_index()
        |> Enum.map(fn {target, index} -> %{target | index: index} end)
    end
  end

  # A `:reference` target that runs without the reference (`only:` with
  # `with_reference: false`) has no first target to copy: it runs the
  # choices computed for it on the full `targets:`, which every later
  # realization carries, as a `:random` target carries its own.
  # How many of a step's last settle or stutter attempts keep their log lines
  # (`log: [keep_attempts: n]`).
  defp keep_attempts(opts) do
    opts
    |> Keyword.get(:log, [])
    |> Keyword.get(:keep_attempts, Cap.default_keep_attempts())
  end

  defp executed_targets([%{expansion: :reference} = alone | rest]),
    do: [%{alone | expansion: :random} | rest]

  defp executed_targets(targets), do: targets

  # The run number (0-based) `only:` starts at.
  defp first_run(nil), do: 0
  defp first_run(only), do: Keyword.get(only, :run, 1) - 1

  defp run_loop(ctx, run_number, acc) when run_number >= ctx.first_run + ctx.max_runs do
    metrics = campaign_metrics(ctx, acc.samples)

    case judge_latency(ctx, metrics) do
      [] ->
        finish_campaign(ctx, acc, metrics)

      breaches ->
        Reproduction.report_failure(
          ctx,
          ReportBuilder.latency_exceeded(ctx, acc, metrics, breaches)
        )
    end
  end

  defp run_loop(ctx, run_number, acc) do
    step = ctx.run_once || (&run_once/3)

    case step.(ctx, run_number, acc) do
      {:pass, acc} -> run_loop(ctx, run_number + 1, acc)
      {:error, _failure} = error -> error
    end
  end

  defp judge_latency(%{latency_budget: budget} = ctx, metrics) when is_list(budget),
    do: LatencyMetrics.judge(ctx.targets, metrics, budget)

  defp judge_latency(_ctx, _metrics), do: []

  defp finish_campaign(ctx, acc, metrics) do
    stats =
      %{
        runs: ctx.max_runs,
        total_commands: acc.total_commands,
        setup_commands: acc.setup_commands,
        teardown_commands: acc.teardown_commands,
        seed: ctx.seed,
        targets: Enum.map(ctx.targets, &%{index: &1.index, name: &1.name})
      }
      |> put_coverage_stats(acc)
      |> Map.put(:compare_counts, acc.compare_counts)
      |> Map.put(:expansion_counts, acc.expansion_counts)
      |> put_metrics(metrics)
      |> put_replay(ctx)

    Reporter.emit(ctx.reporter, fn ->
      %RunResult{
        outcome: :ok,
        runs_completed: ctx.max_runs,
        total_commands: acc.total_commands,
        seed: ctx.seed,
        invariants: invariant_summary(acc.fires, ctx.model),
        metrics: metrics
      }
    end)

    {:ok, stats}
  end

  # One run: generate its sequence (setup commands, roots and teardown
  # commands), then execute it. Returns `{:pass, acc}` or the run's
  # `{:error, failure}`.
  defp run_once(ctx, run_number, acc) do
    # Generate a command sequence, deterministically derived from the seed.
    # Run 0 uses the base seed itself so a reported seed reproduces exactly
    # with max_runs: 1.
    run_seed = Generator.run_seed(ctx.seed, run_number)
    {sequence, expansion} = planned(ctx, run_seed)
    command_count = Sequence.command_count(sequence)

    # Per-run heartbeat (DR-022). run_number is reported 1-based for consumers.
    Reporter.emit(ctx.reporter, fn ->
      %RunUpdate{
        phase: :run,
        run_number: run_number + 1,
        total_runs: ctx.max_runs,
        command_count: command_count
      }
    end)

    # Emit telemetry for sequence start
    seq_start_time = System.system_time()

    Telemetry.sequence_start(%{
      run_number: run_number,
      command_count: command_count
    })

    run = %{
      sequence: sequence,
      expansion: expansion,
      seed: ctx.seed,
      run_seed: run_seed,
      run_number: run_number,
      start: seq_start_time
    }

    run_lockstep(ctx, run, acc)
  end

  # A sequence runs on every target through the lockstep scheduler,
  # which owns each target's event queue, injectors, mocks, setup and teardown.
  defp run_lockstep(ctx, run, acc) do
    outcome = schedule(ctx, run)

    # One sequence stop per run; `variant` names the target the run failed in
    # (nil when it passed).
    Telemetry.sequence_stop(run.start, %{
      run_number: run.run_number,
      success: is_nil(outcome.failure),
      commands_executed: Sequence.command_count(run.sequence),
      variant: outcome.failure && outcome.failure.variant
    })

    # Coverage and check firings come from the reference target's run (DR-026):
    # what it executed per root, leaves included. A shrunk report replaces
    # this run's firings with its reproduction's, so the firings before it
    # are kept apart.
    fires_before = acc.fires

    acc =
      case outcome.results do
        [%{} = reference | _] ->
          accumulate_coverage(acc, reference, run.sequence, reference_choices(ctx, run))

        _ ->
          acc
      end

    acc = record_sample(acc, ctx, run, outcome)
    counts_before = acc.expansion_counts

    acc = %{
      acc
      | compare_counts: Comparison.merge_counts(acc.compare_counts, outcome.compare_counts),
        expansion_counts:
          Expansion.merge_counts(acc.expansion_counts, Expansion.counts(run.expansion))
    }

    case outcome.failure do
      nil ->
        {:pass,
         %{
           acc
           | total_commands: acc.total_commands + Sequence.command_count(run.sequence),
             setup_commands: acc.setup_commands + length(run.sequence.setup),
             teardown_commands: acc.teardown_commands + length(run.sequence.teardown),
             last_run:
               run
               |> Map.take([:sequence, :run_seed, :run_number])
               |> Map.put(
                 :results,
                 if(Context.measure_latency?(ctx), do: outcome.results, else: [])
               )
         }}

      _failure ->
        # The report carries the metrics measured up to this failed run, and
        # the entry counts of the runs before it (the report adds the counts
        # of the run it describes, up to that run's failing root).
        ctx = %{ctx | measured_metrics: campaign_metrics(ctx, acc.samples)}

        Reproduction.handle_failure(
          ctx,
          run
          |> lockstep_found(outcome, acc.fires, counts_before)
          |> Map.put(:fires_before, fires_before)
        )
    end
  end

  # Runs a generated linear sequence on every target through the run driver.
  # `run.seed` and `run.run_number` derive the run's effective seed.
  defp schedule(ctx, run) do
    plan = Sequence.plan(run.sequence, Expansion.schedule(ctx.targets, run.expansion))

    context = %Runner.Context{
      model: ctx.model,
      targets: ctx.targets,
      seed: run.seed,
      run_number: run.run_number,
      run_nonce: ctx.run_nonce,
      # The exploration run is epoch 0 (DR-034); shrink attempts and the
      # reproduction re-execution draw later epochs.
      mint_epoch: 0,
      concurrency: ctx.concurrency,
      compare: ctx.compare,
      measure_latency: Context.measure_latency?(ctx),
      stutter_config: Context.stutter_config(ctx),
      keep_attempts: ctx.keep_attempts,
      check_mode: ctx.check_mode
    }

    {:ok, outcome} = Runner.execute(plan, context)
    outcome
  end

  # A failure a run found: the run that found it (sequence, effective seed, run number), the whole-run
  # check firings so far, the scheduler-shaped failure (`kind`, `variant`,
  # `root`, `reason`), and the failing target's finished result (nil when its
  # setup failed).
  defp lockstep_found(run, outcome, fires, expansion_counts) do
    %{
      sequence: run.sequence,
      expansion: run.expansion,
      expansion_counts: expansion_counts,
      run_seed: run.run_seed,
      run_number: run.run_number,
      fires: fires,
      compare_counts: outcome.compare_counts,
      failure: outcome.failure,
      other_failures: outcome.other_failures,
      result: Enum.at(outcome.results, outcome.failure.variant.index),
      reference_result: Enum.at(outcome.results, 0)
    }
  end

  # Under `latency:`, each run at or after the warm-up contributes its
  # per-target timings to the metrics.
  defp record_sample(%{samples: samples} = acc, ctx, run, outcome) do
    if Context.measure_latency?(ctx) and
         run.run_number >= Keyword.fetch!(ctx.latency_budget, :warmup) do
      sample =
        LatencyMetrics.sample(
          ctx.targets,
          outcome.latencies,
          Expansion.schedule(ctx.targets, run.expansion)
        )

      %{acc | samples: [sample | samples]}
    else
      acc
    end
  end

  # The metrics of the samples recorded so far, or `nil` when `latency:` is off.
  defp campaign_metrics(ctx, samples) do
    if Context.measure_latency?(ctx), do: LatencyMetrics.calculate(ctx.targets, samples)
  end

  # A replay that passed did not reproduce its artifact.
  defp put_replay(stats, %{replay: nil}), do: stats
  defp put_replay(stats, _ctx), do: Map.put(stats, :replay, :not_reproduced)

  defp put_metrics(stats, nil), do: stats
  defp put_metrics(stats, metrics), do: Map.put(stats, :metrics, metrics)

  # The run's sequence and every running target's choices: generated from
  # the run seed, or under `only: [replay:]` the ones the artifact records.
  defp planned(%{replay: %{} = replay} = ctx, _run_seed),
    do: {replay.sequence, running(replay.expansion, ctx)}

  defp planned(ctx, run_seed) do
    sequence = generate_one(ctx, run_seed)
    {sequence, expand(ctx, sequence, run_seed)}
  end

  # The choices of the targets that run.
  defp running(expansion, ctx) do
    names = Enum.map(ctx.targets, & &1.name)
    %{expansion | variants: Map.take(expansion.variants, names)}
  end

  # The run's sequence: its setup commands and roots from the run seed, then
  # its teardown commands generated against the state the roots leave.
  defp generate_one(ctx, run_seed) do
    sequence = Generator.generate_value(ctx.generator, run_seed)
    Generator.teardown_commands(ctx.model, sequence, run_seed, markers(ctx))
  end

  # The `:external_markers` option of the generator and expansion calls.
  defp markers(ctx), do: [external_markers: ctx.external_markers]

  # Every target's concrete sequence for a generated sequence: the roots with
  # each target's expansions realized, before any target is set up.
  defp expand(ctx, sequence, run_seed) do
    if Expansion.defines?(ctx.model) do
      ctx.model
      |> Expansion.expand(sequence, ctx.all_targets, run_seed, markers(ctx))
      |> running(ctx)
    else
      Expansion.identity(sequence, ctx.targets)
    end
  end

  # ============================================================================
  # Whole-run coverage accumulation (DR-026)
  # ============================================================================

  # Fold one sequence's result into the running coverage accumulator. Per-check
  # firings (always-on) are projected out of the executor's colocated counters
  # and summed; the heavier command/transition/state tracker (coverage: true
  # only) records the sequence via the existing Coverage path.
  defp accumulate_coverage(acc, result, sequence, choices) do
    run_fires = ReportBuilder.project_fires(Map.get(result, :check_counters, %{}))
    fires = ReportBuilder.merge_fires(acc.fires, run_fires)

    tracker =
      if acc.tracker do
        # Feed the tracker a result carrying the sequence (for command/transition
        # coverage) and this sequence's firings (lifted into check_hits).
        record =
          result
          |> Map.put(:sequence, sequence)
          |> Map.put(:choices, choices)
          |> Map.put(:check_fires, run_fires)

        Coverage.record(acc.tracker, {:ok, record})
      else
        nil
      end

    %{acc | fires: fires, tracker: tracker}
  end

  # What the reference target ran at each root of a lockstep run.
  defp reference_choices(ctx, %{expansion: %{variants: variants}}),
    do: variants |> Map.fetch!(hd(ctx.targets).name) |> Map.fetch!(:choices)

  # Attach the whole-run coverage data to the success stats map: always the
  # per-check fire totals, plus the command/transition/state tracker when
  # coverage: true was requested.
  defp put_coverage_stats(stats, %{fires: fires, tracker: tracker}) do
    stats = Map.put(stats, :check_fires, fires)
    if tracker, do: Map.put(stats, :coverage, tracker), else: stats
  end

  # Anti-vacuity summary {covered, total} for the terse verbose footer (DR-026),
  # or nil when the model declares no invariants (nothing to report).
  defp invariant_summary(fires, model) do
    catalog = PropertyDamage.Model.check_catalog(model)

    case length(catalog) do
      0 ->
        nil

      total ->
        covered =
          Enum.count(catalog, fn %{projection: projection, checks: checks} ->
            Enum.any?(checks, fn check -> Map.get(fires, {projection, check.name}, 0) > 0 end)
          end)

        {covered, total}
    end
  rescue
    _ -> nil
  end

  # ============================================================================
  # Seed Library Replay Phase (DR-023)
  # ============================================================================

  # Resolve the `seed_library:` option into the replay config map (or nil when
  # disabled). Default-off: only an explicit `true`/path enables it.
  defp build_seed_library_config(opts, verbose) do
    case resolve_seed_library_path(opts[:seed_library]) do
      nil -> nil
      path -> %{path: path, prune_after: opts[:seed_library_prune_after], verbose: verbose}
    end
  end

  defp resolve_seed_library_path(false), do: nil
  defp resolve_seed_library_path(nil), do: nil
  defp resolve_seed_library_path(true), do: SeedLibrary.default_file()
  defp resolve_seed_library_path(path) when is_binary(path), do: path

  # Replay previously-failing seeds before random exploration. Returns
  # `:proceed` to run exploration, or `{:halt, failure}` to stop with that
  # failure (a shrunk `FailureReport` for a still-failing seed, or a
  # `:setup_failed` report).
  #
  # A replayed seed runs against every target, as an exploration run does.
  defp replay_phase(nil, _ctx), do: :proceed

  defp replay_phase(%{path: path, prune_after: k, verbose: verbose}, ctx) do
    library = load_for_replay(path)

    case library.entries do
      [] ->
        :proceed

      entries ->
        print_replay_banner(path, length(entries), k)

        Reporter.emit(ctx.reporter, fn ->
          %ReplayUpdate{phase: :start, file: path, seed_count: length(entries), prune_after: k}
        end)

        finish_replay(replay_entries(entries, library, ctx, k, verbose), path, k, ctx.reporter)
    end
  end

  defp finish_replay({:setup_failed, report}, _path, _k, _reporter) do
    {:halt, report}
  end

  defp finish_replay({:ok, library, results, rep_report}, path, k, reporter) do
    {pruned_library, pruned_count} = SeedLibrary.prune(library, k)
    save_replay_library(pruned_library, path)

    passed = Enum.count(results, fn {_seed, outcome} -> outcome in [:pass, :prune] end)
    still_failing = Enum.count(results, fn {_seed, outcome} -> outcome == :fail end)
    replayed = length(results)
    halted? = rep_report != nil

    Reporter.emit(reporter, fn ->
      %ReplayUpdate{
        phase: :summary,
        file: path,
        replayed: replayed,
        passed: passed,
        pruned: pruned_count,
        still_failing: still_failing,
        halted?: halted?
      }
    end)

    if halted? do
      print_replay_halt_summary(path, replayed, passed, pruned_count, still_failing)
      {:halt, rep_report}
    else
      :proceed
    end
  end

  # Replay every entry once (most-recently-discovered first). The first failing
  # seed is shrunk into a representative report (one shrink on a red run);
  # subsequent failing seeds get a verdict only. Streaks are updated as we go.
  defp replay_entries(entries, library, ctx, k, verbose) do
    init = {library, [], nil}

    outcome =
      Enum.reduce_while(entries, init, fn entry, {lib, results, rep} ->
        replay_entry(entry.seed, lib, results, rep, ctx, k, verbose)
      end)

    case outcome do
      {:setup_failed, _report} = err -> err
      {lib, results, rep} -> {:ok, lib, Enum.reverse(results), rep}
    end
  end

  defp replay_entry(seed, lib, results, rep, ctx, k, verbose) do
    case replay_seed(seed, ctx, is_nil(rep)) do
      {:setup_failed, _report} = err ->
        {:halt, err}

      {:pass} ->
        lib2 = SeedLibrary.record_run(lib, seed, failed: false)
        outcome = pass_outcome(lib2, seed, k)
        emit_and_print_seed(ctx.reporter, seed, outcome, verbose)
        {:cont, {lib2, [{seed, outcome} | results], rep}}

      {:fail, refresh, maybe_report} ->
        lib2 = SeedLibrary.record_run(lib, seed, [failed: true] ++ refresh)
        emit_and_print_seed(ctx.reporter, seed, :fail, verbose)
        {:cont, {lib2, [{seed, :fail} | results], rep || maybe_report}}
    end
  end

  # Replays one seed as run 0 of itself: the sequence, setup and teardown
  # commands included, on every target through the lockstep scheduler. A failure, when this seed is the
  # representative (`build_rep?`), goes through the run's failure path: shrunk,
  # reproduced and reported. A target's setup failure halts the replay with its
  # report.
  defp replay_seed(seed, ctx, build_rep?) do
    sequence = generate_one(ctx, seed)

    run = %{
      sequence: sequence,
      expansion: expand(ctx, sequence, seed),
      seed: seed,
      run_seed: seed,
      run_number: 0
    }

    case replay_run(ctx, run) do
      :passed ->
        {:pass}

      {:failed, %{failure: %{report_kind: :setup_failed}} = found} ->
        {:error, report} = Reproduction.handle_failure(ctx, found)
        {:setup_failed, report}

      {:failed, found} ->
        {:fail, replay_refresh(found.failure.reason), replay_report(ctx, found, build_rep?)}
    end
  end

  # Replay is a pre-exploration phase; whole-run anti-vacuity coverage is an
  # exploration concern, so no firings are accumulated here.
  defp replay_run(ctx, run) do
    outcome = schedule(ctx, run)

    if outcome.failure,
      do: {:failed, lockstep_found(run, outcome, %{}, %{})},
      else: :passed
  end

  defp replay_report(ctx, found, true) do
    {:error, report} = Reproduction.handle_failure(ctx, found)
    report
  end

  defp replay_report(_ctx, _found, false), do: nil

  # Refresh descriptive metadata from the new failure. Keep the prior kind
  # if the reason did not classify (nil); check_name is legitimately nil for
  # many failure kinds, so it is refreshed as-is.
  defp replay_refresh(reason) do
    {kind, check_name} = FailureReport.classify_reason(reason)
    [check_name: check_name] ++ if(kind, do: [kind: kind], else: [])
  end

  defp pass_outcome(library, seed, k) do
    entry = Enum.find(library.entries, &(&1.seed == seed))
    if entry && entry.consecutive_passes >= k, do: :prune, else: :pass
  end

  # Load tolerantly: the working set is non-authoritative, so a missing or
  # unreadable file simply means "replay nothing this time".
  defp load_for_replay(path) do
    case SeedLibrary.load(path) do
      {:ok, library} ->
        library

      {:error, :enoent} ->
        SeedLibrary.new()

      {:error, reason} ->
        require Logger

        Logger.warning(
          "PropertyDamage seed_library at #{path} could not be read " <>
            "(#{inspect(reason)}); starting from an empty working set."
        )

        SeedLibrary.new()
    end
  end

  defp save_replay_library(library, path) do
    case SeedLibrary.save(library, path) do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "PropertyDamage seed_library could not be saved to #{path}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Auto-append a new exploration failure's seed to the working set. The halt
  # path returns a seed already present, so its add is a deduplicated no-op.
  defp maybe_append_failure_seed(_result, nil), do: :ok

  defp maybe_append_failure_seed({:error, %FailureReport{} = report}, path)
       when is_binary(path) do
    library = load_for_replay(path)

    case SeedLibrary.add(library, report, tags: [:auto_detected]) do
      {:ok, updated} -> save_replay_library(updated, path)
      {:error, {:duplicate_seed, _}} -> :ok
    end
  end

  defp maybe_append_failure_seed(_result, _path), do: :ok

  # Read a non-negative integer from an environment variable (DR-034 ad-hoc CLI
  # channel for seed/nonce, since `mix test` cannot forward custom flags).
  # Returns nil when unset or not a valid non-negative integer.
  defp env_int(var) do
    case System.get_env(var) do
      nil ->
        nil

      str ->
        case Integer.parse(str) do
          {n, ""} when n >= 0 -> n
          _ -> nil
        end
    end
  end

  defp emit_and_print_seed(reporter, seed, outcome, verbose) do
    Reporter.emit(reporter, fn -> %ReplayUpdate{phase: :seed, seed: seed, outcome: outcome} end)
    if verbose, do: print_replay_seed_line(seed, outcome)
    :ok
  end

  # Console output. The banner and halt summary print unconditionally when the
  # library is enabled (DR-023); per-seed lines print only under `verbose:`.
  defp print_replay_banner(path, count, k) do
    IO.puts("")
    IO.puts(String.duplicate("=", 60))
    IO.puts("  Seed Library Replay (DR-023)")
    IO.puts(String.duplicate("=", 60))
    IO.puts("")
    IO.puts("  Replaying #{count} previously-failing seed(s) from #{path}")
    IO.puts("  before random exploration, because they failed before.")
    IO.puts("  A seed is dropped after #{k} consecutive passing replays.")
    IO.puts("  Disable with: seed_library: false")
    IO.puts("")
    IO.puts(String.duplicate("-", 60))
    :ok
  end

  defp print_replay_seed_line(seed, outcome) do
    label =
      case outcome do
        :pass -> "pass"
        :prune -> "pass (pruned after reaching the prune threshold)"
        :fail -> "FAIL"
      end

    IO.puts("  [replay] seed #{seed}: #{label}")
    :ok
  end

  defp print_replay_halt_summary(path, replayed, passed, pruned, still_failing) do
    IO.puts("")
    IO.puts(String.duplicate("-", 60))
    IO.puts("  Seed Library Replay halted exploration")
    IO.puts("")
    IO.puts("  Replayed:      #{replayed}")
    IO.puts("  Passed:        #{passed}")
    IO.puts("  Pruned:        #{pruned}")
    IO.puts("  Still failing: #{still_failing}")
    IO.puts("")
    IO.puts("  Random exploration was skipped because seeds still fail.")
    IO.puts("  Fix them (or remove them from #{path}) and re-run.")
    IO.puts(String.duplicate("-", 60))
    :ok
  end
end
