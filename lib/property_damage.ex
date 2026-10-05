defmodule PropertyDamage do
  @moduledoc """
  PropertyDamage: A stateful property-based testing framework for Elixir.

  PropertyDamage combines the power of property-based testing with stateful system
  testing, allowing you to verify that your system behaves correctly under any
  sequence of operations.

  ## Overview

  Traditional property-based testing generates random inputs and verifies properties
  hold for all inputs. Stateful property-based testing extends this by generating
  random *sequences of operations* (commands) and verifying that the system under
  test (SUT) behaves correctly throughout the entire sequence.

  ## Key Concepts

  - **Commands**: Operations that can be executed against the SUT (create, update, delete, etc.)
  - **Model**: Defines what commands are available and how state is tracked
  - **Projections**: Pure state reducers that process commands and events to maintain state
  - **Adapters**: Bridge between the test framework and the actual SUT
  - **Refs**: Symbolic placeholders for entity IDs, resolved during execution

  ## Two-Phase Execution

  PropertyDamage uses a two-phase execution model:

  1. **Symbolic Phase**: Generate a sequence of commands with symbolic refs
  2. **Concrete Phase**: Execute commands against the SUT, resolving refs to real values

  This separation enables powerful shrinking of failing test cases while maintaining
  the dependency relationships between commands.

  ## Basic Usage

      defmodule MyModelTest do
        use ExUnit.Case
        use PropertyDamage.ExUnit

        property_damage "system maintains invariants",
          model: MyApp.TestModel,
          targets: [MyApp.TestAdapter],
          max_commands: 50,
          max_runs: 100
      end

  ## Running Directly

      PropertyDamage.run(
        model: MyApp.TestModel,
        targets: [MyApp.TestAdapter],
        max_commands: 50,
        max_runs: 100
      )

  ## Debugging Failures

  When a test fails, PropertyDamage provides rich tools for understanding what went wrong:

      {:error, failure} = PropertyDamage.run(model: M, targets: [A])

      # Understand why each command in the shrunk sequence is needed
      explanation = PropertyDamage.explain(failure)

      # Find the specific field/value that caused the failure
      {:ok, trigger} = PropertyDamage.isolate_trigger(failure)

      # Generate a reproducible test case
      test_code = PropertyDamage.generate_test(failure, format: :exunit)

      # Try harder to shrink if needed
      {:ok, smaller} = PropertyDamage.shrink_further(failure, strategy: :exhaustive)

      # Replay step-by-step
      {:ok, steps} = PropertyDamage.replay(failure)

  ## Failure Persistence

  Save failures for later analysis or regression testing:

      {:ok, path} = PropertyDamage.save_failure(failure, "failures/")
      {:ok, loaded} = PropertyDamage.load_failure(path)
      failures = PropertyDamage.list_failures("failures/")

  See `PropertyDamage.Persistence` for details.

  ## Seed Library

  Replay recently-failing seeds before random exploration (DR-023). This is an
  ephemeral, self-pruning working set for the fix cycle, not a durable corpus
  (for durable regressions, export to an ExUnit test):

      # Replay failing seeds first; append any new failure's seed automatically
      PropertyDamage.run(model: M, targets: [A], seed_library: true)

  See `PropertyDamage.SeedLibrary` for details.

  ## Coverage Metrics

  Track how thoroughly your model is being exercised:

      coverage = PropertyDamage.coverage(result, MyModel)
      IO.puts(PropertyDamage.Coverage.format(coverage))

  See `PropertyDamage.Coverage` for details.

  ## Flakiness Detection

  Detect non-deterministic behavior in your SUT by running one plan many times
  and localizing where the passing and failing runs diverge:

      {_traces, comparison} =
        PropertyDamage.RunComparison.investigate(
          runs: 10,
          capture: [model: Model, targets: [Adapter], seed: seed]
        )

  Scan a whole corpus of seeds with `PropertyDamage.RunComparison.scan/1`. See
  `PropertyDamage.RunComparison` for details.

  ## Architecture

  The framework consists of several layers:

  - **Tier 0 (Core Types)**: Ref, Command, Projection, Model behaviours
  - **Tier 1 (Execution)**: Adapter, EventQueue, InjectorAdapter, Executor
  - **Tier 2 (Shrinking)**: Sequence.Validator, Shrinker, dependency graph
  - **Tier 3 (Analysis)**: Analysis, Replay, Coverage, RunComparison
  - **Utilities**: Persistence, SeedLibrary, mix tasks

  See the individual module documentation for detailed information on each component.
  """

  alias PropertyDamage.{
    Coverage,
    EventQueue,
    Executor,
    Failure,
    FailureReport,
    Generator,
    LatencyMetrics,
    Options,
    Progress.Printer,
    Progress.ReplayUpdate,
    Progress.Reporter,
    Progress.RunResult,
    Progress.RunUpdate,
    RunTrace,
    Scheduler,
    SeedLibrary,
    Sequence,
    Shrinker,
    Stutter,
    Telemetry,
    Validation
  }

  alias PropertyDamage.Runtime.RunServices
  alias PropertyDamage.Shrinker.Config, as: ShrinkerConfig

  @typedoc """
  Result statistics from a successful run.
  """
  @type stats :: %{
          required(:runs) => non_neg_integer(),
          required(:total_commands) => non_neg_integer(),
          required(:seed) => integer(),
          required(:targets) => [%{index: non_neg_integer(), name: String.t()}],
          optional(:check_fires) => %{{module(), atom()} => non_neg_integer()},
          optional(:coverage) => term(),
          optional(:metrics) => %{String.t() => map()}
        }

  @typedoc """
  Failure report from a failed run.
  """
  @type failure_report :: %{
          seed: integer(),
          run_number: non_neg_integer(),
          original_sequence: Sequence.t(),
          shrunk_sequence: Sequence.t(),
          failed_at_index: non_neg_integer(),
          failure_reason: term(),
          shrink_iterations: non_neg_integer(),
          shrink_time_ms: non_neg_integer()
        }

  @typedoc """
  Result from `run/1` - either success stats or a failure report.
  """
  @type result :: {:ok, stats()} | {:error, failure_report()}

  @doc """
  Run a property-based test.

  This is the main entry point for PropertyDamage. It generates command sequences,
  executes them against the SUT, and shrinks failures to minimal reproductions.

  ## Required Options

  - `:model` - Model module implementing PropertyDamage.Model
  - `:targets` - The systems under test, as a list of adapter modules
    implementing PropertyDamage.Adapter or
    `{AdapterModule, name:, config:, injectors:, mocks:}` entries. See
    `PropertyDamage.Target`. With one entry the run tests that system; with
    several, the first is the reference and every other target is compared
    with it command by command (see "Several Targets" below).

  ## Optional Options

  - `:max_commands` - Maximum commands per sequence (default: 50)
  - `:max_runs` - Number of test sequences to run (default: 100)
  - `:seed` - Random seed for reproducibility (default: random)
  - `:shrink` - Whether to shrink failing sequences (default: true)
  - `:seed_library` - Ephemeral replay working set (DR-023): `false` (default,
    disabled), `true` (default file), or a path. Previously-failing seeds are
    replayed before exploration; a still-failing replay halts the run.
  - `:seed_library_prune_after` - Consecutive passing replays after which a seed
    is dropped from the library (default: 3)
  - `:shrinker_config` - ShrinkerConfig struct for tuning shrinking
  - `:on_failure` - Callback function receiving failure_report (default: nil)
  - `:regression` - Keyword list for automatic regression test management (see below)
  - `:verbose` - Print progress and configuration (default: false)
  - `:validate` - Run configuration validation first (default: true)
  - `:branching` - Keyword list for parallel branching (see below); one
    target only
  - `:stutter` - Keyword list for idempotency testing (see below)
  - `:check_mode` - How a failing check is handled: `:halt` (default),
    `:record`, `:log` or `:disabled`
  - `:concurrency` - How the targets reach each command boundary: `:serial`
    (default) steps one target at a time in target order; `:parallel` steps
    every target at once
  - `:compare` - `:correctness` (default) compares every target's answers with
    the reference's; `:performance` measures each target's latency instead;
    `:both` does both
  - `:equivalence` - How two answers are compared: `:exact` (default),
    `:structural` (ignores identifier and timestamp fields), or a function
    `fn reference_answer, target_answer -> boolean end`
  - `:metrics`, `:percentiles`, `:warmup_runs` - Parameters of
    `compare: :performance | :both`; `warmup_runs` (default 0) runs are left
    out of the metrics

  ## Several Targets

  Each linear run executes its command sequence against every target in
  lockstep (`PropertyDamage.Scheduler`): every target executes command `r`,
  their answers are compared, and only then does any target start command
  `r + 1`. Each target runs in its own process with its own event queue,
  injectors, mocks and pollers, and is set up and torn down once per run.
  `compare: :performance | :both` requires `concurrency: :serial`, because
  overlapping targets would mix their load into each other's latency.

  The first failure ends the campaign: a target answering differently from the
  reference (`kind: :diverged`), a failing check in any target, a setup failure
  or an execution failure. The report names the target in `variant`. With two
  or more targets an adapter `{:error, _}` answer is compared like any other
  answer. A failure in a run with two or more targets is reported as found,
  without shrinking.

  The model's `setup_once/1`, `setup_each/1` and their teardowns receive the
  reference target's config.

  ## Branching Options

  Pass `branching: [...]` to generate branching (parallel) sequences:

  - `:branch_probability` - Probability of creating a branch point (default: 0.2)
  - `:max_branches` - Maximum number of parallel branches (default: 3)
  - `:max_branch_length` - Maximum commands per branch (default: 5)
  - `:min_prefix_length` - Minimum commands before branching (default: 3)

  Branching sequences enable detection of race conditions by executing
  commands in parallel branches and checking linearizability.

  ## Stutter Options (Idempotency Testing)

  Pass `stutter: [...]` to enable idempotency testing:

  - `:probability` - Probability of stuttering each command (default: 0.1)
  - `:max_repeats` - Maximum retry attempts per stuttered command (default: 2)
  - `:delay_ms` - Delay between retries, `{min, max}` tuple or integer (default: {0, 100})
  - `:commands` - `:all` or list of command modules to stutter (default: :all)
  - `:comparison` - Event comparison mode (default: :strict)
    - `:strict` - Events must be exactly equal
    - `{:structural, fields}` - Ignore specified fields when comparing
    - `{:custom, fun}` - Custom comparison function `fn(events1, events2) -> :match | {:mismatch, map()}`

  Stutter testing verifies that retrying commands produces consistent results
  (idempotency). Retry events are captured but not applied to projections.

  ## Regression Options

  Pass `regression: [...]` to automatically save failures for regression testing:

  - `:save_failures` - Directory to save failure files
  - `:seed_library` - Path to seed library JSON file
  - `:generate_tests` - Directory to generate ExUnit test files
  - `:tags` - Tags to add to seed library entries (default: `[:auto_detected]`)
  - `:dedup` - Skip if similar failure exists (default: false)
  - `:dedup_threshold` - Similarity threshold for dedup (default: 0.90)
  - `:verbose` - Print regression actions (default: false)
  - `:targets` - Single-entry target for generated regression tests (default:
    the run's target)

  This option integrates with `:on_failure` - both can be used together.

  ## Returns

  - `{:ok, stats}` - All runs passed. `stats` holds `runs`, `total_commands`,
    `seed`, `targets` (`[%{index:, name:}]`), the coverage keys, and under
    `compare: :performance | :both` the latency `metrics` of each target,
    keyed by target name
  - `{:error, failure_report}` - A run failed; see `PropertyDamage.FailureReport`
    for its `kind` and the failing `variant`. A target whose adapter `setup/1`
    fails is a report of kind `:setup_failed`

  ## Target Entry Keys

  - `:name` - Label used in reports (default: last segment of the module name)
  - `:config` - Map passed to `adapter.setup/1` (default: `%{}`)
  - `:injectors` - List of InjectorAdapter modules for event injection
    (default: `[]`)
  - `:mocks` - Mock third-party services the SUT calls (default: `[]`).
    A list of `PropertyDamage.MockServiceAdapter` modules or `{module, config}`
    tuples. Per run the framework starts a `PropertyDamage.MockServiceRegistry`,
    registers and sets up each mock, drives `on_command/2` before each command,
    folds mock-injected events after, and tears each mock down. The registry pid
    is handed to the adapter on the `PropertyDamage.Runtime` handle
    (`runtime.mock_registry`) so `execute/3` can drive `handle_request/2`. See
    the "Mocking Third-Party Services" guide.

  ## Examples

      # Basic usage
      PropertyDamage.run(model: MyModel, targets: [MyAdapter])

      # With options
      PropertyDamage.run(
        model: MyModel,
        targets: [MyAdapter],
        max_commands: 100,
        max_runs: 1000,
        seed: 12345
      )

      # With failure callback
      PropertyDamage.run(
        model: MyModel,
        targets: [MyAdapter],
        on_failure: fn failure_report ->
          IO.puts("Failed at command \#{PropertyDamage.FailureReport.failure_index(failure_report)}")
        end
      )

      # With automatic regression management
      PropertyDamage.run(
        model: MyModel,
        targets: [MyAdapter],
        regression: [
          save_failures: "failures/",
          seed_library: "seeds.json",
          generate_tests: "test/regressions/",
          dedup: true
        ]
      )
  """
  @spec run(keyword()) :: {:ok, stats()} | {:error, failure_report()}
  def run(opts) do
    # Validate options with NimbleOptions - applies defaults and provides helpful errors
    opts = Options.validate_run!(opts)

    model = opts[:model]
    targets = opts[:targets]
    [reference | _] = targets
    max_commands = opts[:max_commands]
    max_runs = opts[:max_runs]
    # Resolution order (DR-034): explicit option, else environment variable
    # (mix test cannot forward custom flags), else a random default.
    seed = opts[:seed] || env_int("PD_SEED") || :rand.uniform(1_000_000_000)

    # The run nonce seeds ONLY client-minted run-scoped values (mint_per_run).
    # Its random default is drawn from crypto entropy, NEVER the process RNG:
    # ExUnit pins :rand under `--seed N`, which would re-mint colliding values.
    # Every target of a run shares it, so all of them receive byte-identical
    # client-minted requests.
    run_nonce =
      opts[:run_nonce] || env_int("PD_RUN_NONCE") ||
        :crypto.strong_rand_bytes(8) |> :binary.decode_unsigned()

    verbose = opts[:verbose]

    # Seed-library replay working set (DR-023). `nil` when disabled; otherwise a
    # small config map driving the pre-exploration replay phase.
    seed_library = build_seed_library_config(opts, verbose)
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

    ctx = %{
      model: model,
      targets: targets,
      target_entries: Enum.map(targets, &PropertyDamage.Target.to_entry/1),
      target: reference,
      max_commands: max_commands,
      max_runs: max_runs,
      seed: seed,
      run_nonce: run_nonce,
      shrink: opts[:shrink],
      shrinker_config: opts[:shrinker_config] || ShrinkerConfig.new(),
      on_failure: build_on_failure_callback(opts),
      reporter: reporter,
      branching: opts[:branching],
      stutter_config: Stutter.parse_config(opts[:stutter]),
      check_mode: opts[:check_mode],
      seed_library: seed_library,
      coverage: opts[:coverage],
      concurrency: opts[:concurrency],
      compare: opts[:compare],
      equivalence: opts[:equivalence],
      warmup_runs: opts[:warmup_runs],
      measure_latency: opts[:compare] in [:performance, :both]
    }

    # Validate configuration against every target's adapter and injectors
    if opts[:validate] do
      for target <- targets do
        {:ok, warnings} = Validation.validate!(model, target.adapter, injectors: target.injectors)

        if verbose do
          Validation.print_summary(model, target.adapter, warnings)
        end
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

    # Setup once (if model implements it). The model hooks receive the
    # reference target's config.
    setup_once_result =
      if function_exported?(model, :setup_once, 1) do
        model.setup_once(%{adapter_config: reference.config})
      else
        :ok
      end

    case setup_once_result do
      :ok ->
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
          result = do_run(ctx)

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
        after
          # Teardown once
          if function_exported?(model, :teardown_once, 1) do
            model.teardown_once(%{adapter_config: reference.config})
          end
        end

      {:error, reason} ->
        {:error, %{setup_once_failed: reason}}
    end
  end

  defp do_run(ctx) do
    # Seed the process RNG (consumed by execution-time randomness such as
    # stutter decisions; sequence generation is seeded explicitly per run
    # via Generator.generate_value/2, NOT through the process RNG)
    :rand.seed(:exsss, ctx.seed)

    # Campaign start (DR-022): the verbose consumer renders this as the header.
    Reporter.emit(ctx.reporter, fn ->
      %RunUpdate{phase: :start, run_number: 0, total_runs: ctx.max_runs}
    end)

    # Generate sequences and run
    generator_opts = [max_commands: ctx.max_commands]

    generator_opts =
      if ctx.branching,
        do: Keyword.put(generator_opts, :branching, ctx.branching),
        else: generator_opts

    ctx = Map.put(ctx, :generator, Generator.generate_sequence(ctx.model, generator_opts))

    # Seed-library replay phase (DR-023): replay previously-failing seeds before
    # random exploration, reusing the per-sequence machinery below. On a
    # still-failing replay the run halts here; otherwise exploration proceeds.
    case replay_phase(ctx.seed_library, ctx) do
      {:halt, failure} ->
        {:error, failure}

      :proceed ->
        # Whole-run coverage accumulator (DR-026). `fires` aggregates
        # per-check firings across every generated sequence (always-on);
        # `tracker` accumulates the heavier command/transition/state dimensions
        # only when `coverage: true` was requested.
        acc = %{
          fires: %{},
          tracker: if(ctx.coverage, do: Coverage.new(ctx.model), else: nil),
          total_commands: 0,
          samples: []
        }

        run_loop(ctx, 0, acc)
    end
  end

  defp run_loop(ctx, run_number, acc) when run_number >= ctx.max_runs do
    stats =
      %{
        runs: ctx.max_runs,
        total_commands: acc.total_commands,
        seed: ctx.seed,
        targets: Enum.map(ctx.targets, &%{index: &1.index, name: &1.name})
      }
      |> put_coverage_stats(acc)
      |> put_metrics(ctx, acc.samples)

    Reporter.emit(ctx.reporter, fn ->
      %RunResult{
        outcome: :ok,
        runs_completed: ctx.max_runs,
        total_commands: acc.total_commands,
        seed: ctx.seed,
        invariants: invariant_summary(acc.fires, ctx.model)
      }
    end)

    {:ok, stats}
  end

  defp run_loop(ctx, run_number, acc) do
    case run_once(ctx, run_number, acc) do
      {:pass, acc} -> run_loop(ctx, run_number + 1, acc)
      {:error, _failure} = error -> error
    end
  end

  # One run: generate its sequence, then setup_each, execute, teardown_each.
  # Returns `{:pass, acc}` or the run's `{:error, failure}`.
  defp run_once(ctx, run_number, acc) do
    # Generate a command sequence, deterministically derived from the seed.
    # Run 0 uses the base seed itself so a reported seed reproduces exactly
    # with max_runs: 1.
    run_seed = Generator.run_seed(ctx.seed, run_number)
    sequence = generate_one(ctx.generator, run_seed)
    command_count = Sequence.command_count(sequence)

    # Per-run heartbeat (DR-022). run_number is reported 1-based for consumers.
    Reporter.emit(ctx.reporter, fn ->
      %RunUpdate{
        phase: :run,
        run_number: run_number + 1,
        total_runs: ctx.max_runs,
        command_count: command_count,
        branch_count: Sequence.branch_count(sequence)
      }
    end)

    # Emit telemetry for sequence start
    seq_start_time = System.system_time()

    Telemetry.sequence_start(%{
      run_number: run_number,
      command_count: command_count,
      branching: Sequence.branching?(sequence)
    })

    run = %{sequence: sequence, run_seed: run_seed, run_number: run_number, start: seq_start_time}

    case call_setup_each(ctx, run_number) do
      :ok ->
        try do
          if ctx.branching,
            do: run_branching(ctx, run, acc),
            else: run_lockstep(ctx, run, acc)
        after
          call_teardown_each(ctx, run_number)
        end

      {:error, reason} ->
        {:error, %{setup_each_failed: reason, run_number: run_number}}
    end
  end

  # Setup each and teardown each (if the model implements them) receive the
  # reference target's config.
  defp call_setup_each(ctx, run_number) do
    if function_exported?(ctx.model, :setup_each, 1) do
      ctx.model.setup_each(%{adapter_config: ctx.target.config, run_number: run_number})
    else
      :ok
    end
  end

  defp call_teardown_each(ctx, run_number) do
    if function_exported?(ctx.model, :teardown_each, 1) do
      ctx.model.teardown_each(%{adapter_config: ctx.target.config, run_number: run_number})
    end
  end

  # A linear sequence runs on every target through the lockstep scheduler,
  # which owns each target's event queue, injectors, mocks, setup and teardown.
  defp run_lockstep(ctx, run, acc) do
    {:ok, outcome} =
      Scheduler.run(
        model: ctx.model,
        targets: ctx.targets,
        commands: Sequence.to_list(run.sequence),
        seed: ctx.seed,
        run_number: run.run_number,
        run_nonce: ctx.run_nonce,
        # The exploration run is epoch 0 (DR-034); shrink attempts and the
        # reproduction re-execution draw later epochs.
        mint_epoch: 0,
        concurrency: ctx.concurrency,
        compare: ctx.compare,
        equivalence: ctx.equivalence,
        measure_latency: ctx.measure_latency,
        stutter_config: ctx.stutter_config,
        check_mode: ctx.check_mode
      )

    Telemetry.sequence_stop(run.start, %{
      run_number: run.run_number,
      success: is_nil(outcome.failure),
      commands_executed: Sequence.command_count(run.sequence)
    })

    # Coverage and check firings come from the reference target's run (DR-026).
    acc =
      case outcome.results do
        [%{} = reference | _] -> accumulate_coverage(acc, reference, run.sequence)
        _ -> acc
      end

    acc = record_sample(acc, ctx, run.run_number, outcome)

    case outcome.failure do
      nil ->
        {:pass,
         %{acc | total_commands: acc.total_commands + Sequence.command_count(run.sequence)}}

      failure ->
        lockstep_failure(ctx, run, outcome, failure, acc.fires)
    end
  end

  # A one-target failure (other than a setup failure) is shrunk and reproduced
  # through the linear engine. A failure in a run with two or more targets is
  # reported as found, without shrinking.
  defp lockstep_failure(%{targets: [_one]} = ctx, run, outcome, %{kind: kind} = failure, fires)
       when kind != :setup_failed do
    case outcome.results do
      [%{failure_reason: %Failure{}} = result] ->
        with_run_services(ctx.target, fn event_queue, mock_registry ->
          handle_failure(
            ctx,
            run.sequence,
            result,
            event_queue,
            mock_registry,
            run.run_seed,
            run.run_number,
            fires
          )
        end)

      _ ->
        report_failure(ctx, lockstep_report(ctx, run, outcome, failure, fires))
    end
  end

  defp lockstep_failure(ctx, run, outcome, failure, fires) do
    report_failure(ctx, lockstep_report(ctx, run, outcome, failure, fires))
  end

  # The report of a lockstep failure as the run found it: the failing target's
  # state and event log, the original sequence, no shrinking.
  defp lockstep_report(ctx, run, outcome, failure, fires) do
    result = Enum.at(outcome.results, failure.variant.index) || %{}

    FailureReport.new(
      seed: run.run_seed,
      run_number: run.run_number,
      original_sequence: run.sequence,
      shrunk_sequence: run.sequence,
      plan_source: :generated,
      source_revision: RunTrace.source_revision(),
      run_nonce: ctx.run_nonce,
      mint_epoch: 0,
      executed: Map.get(result, :executed, %{}),
      failed_at_index: failure.root,
      failure_reason: failure.reason,
      event_log: Map.get(result, :event_log, []),
      projections: Map.get(result, :projections, %{}),
      projections_before: Map.get(result, :projections_before),
      command_fold_ordinals: Map.get(result, :command_fold_ordinals, %{}),
      linearization: Map.get(result, :linearization),
      stacktrace: Map.get(result, :stacktrace),
      model: ctx.model,
      targets: ctx.target_entries,
      variant: failure.variant,
      concurrency: ctx.concurrency,
      check_fires: fires
    )
  end

  # A branching sequence runs on the one target through the linear engine.
  defp run_branching(ctx, run, acc) do
    with_run_services(ctx.target, fn event_queue, mock_registry ->
      run_result =
        Executor.run(run.sequence, ctx.model, ctx.target.adapter,
          config: ctx.target.config,
          event_queue: event_queue,
          mock_registry: mock_registry,
          stutter_config: ctx.stutter_config,
          # Explicit stutter RNG base (DR-029): per-run seed so stutter
          # decisions are decoupled from run count and seed-library replay
          # drift, yet reproduce on the same campaign seed.
          rng_seed: run.run_seed,
          # Client-minted run-scoped values (DR-034): the exploration run is
          # epoch 0; the nonce is constant across the campaign's runs.
          run_nonce: ctx.run_nonce,
          mint_epoch: 0
        )

      case run_result do
        {:ok, result} ->
          Telemetry.sequence_stop(run.start, %{
            run_number: run.run_number,
            success: result.success,
            commands_executed: Sequence.command_count(run.sequence)
          })

          acc = accumulate_coverage(acc, result, run.sequence)

          if result.success do
            command_count = Sequence.command_count(run.sequence)
            {:pass, %{acc | total_commands: acc.total_commands + command_count}}
          else
            # Shrink and report. Pass the run's EFFECTIVE seed so the report's
            # "reproduce with this seed" is exact (run 0 of a reproduction
            # derives the identical sequence from it).
            handle_failure(
              ctx,
              run.sequence,
              result,
              event_queue,
              mock_registry,
              run.run_seed,
              run.run_number,
              acc.fires
            )
          end

        # Executor.run returns {:error, reason} when the adapter's setup/1
        # fails: a setup failure of the one target, never shrunk.
        {:error, reason} ->
          report_failure(
            ctx,
            setup_report(ctx, run.sequence, run.run_seed, run.run_number, reason, acc.fires)
          )
      end
    end)
  end

  # The report of a target's adapter setup failure: nothing ran, so it holds
  # the generated sequence, no state, and no command index.
  defp setup_report(ctx, sequence, seed, run_number, reason, fires) do
    FailureReport.new(
      seed: seed,
      run_number: run_number,
      original_sequence: sequence,
      shrunk_sequence: sequence,
      plan_source: :generated,
      source_revision: RunTrace.source_revision(),
      run_nonce: ctx.run_nonce,
      mint_epoch: 0,
      failed_at_index: nil,
      failure_reason: Failure.setup_failed(reason),
      model: ctx.model,
      targets: ctx.target_entries,
      variant: %{index: ctx.target.index, name: ctx.target.name},
      concurrency: ctx.concurrency,
      check_fires: fires
    )
  end

  # Starts an event queue with the target's injectors and mocks for the linear
  # engine, runs `fun` with the queue and the mock registry, and releases all
  # of them again. The queue's stop is guaranteed by the outer `after`, so a
  # raise in injector or mock setup cannot leak it (A6).
  defp with_run_services(target, fun) do
    {:ok, event_queue} = EventQueue.start_link()

    try do
      setup_injectors(target.injectors, event_queue)
      {mock_registry, mock_contexts} = setup_mocks(target.mocks, event_queue)

      try do
        fun.(event_queue, mock_registry)
      after
        teardown_mocks(mock_registry, mock_contexts)
        teardown_injectors(target.injectors)
      end
    after
      EventQueue.stop(event_queue)
    end
  end

  # Under `compare: :performance | :both`, each run at or after `warmup_runs`
  # contributes its per-target latencies and observations to the metrics.
  defp record_sample(%{samples: samples} = acc, ctx, run_number, outcome) do
    if ctx.measure_latency and run_number >= ctx.warmup_runs do
      sample = LatencyMetrics.sample(ctx.targets, outcome.latencies, outcome.observations)
      %{acc | samples: [sample | samples]}
    else
      acc
    end
  end

  defp put_metrics(stats, %{measure_latency: false}, _samples), do: stats

  defp put_metrics(stats, ctx, samples),
    do: Map.put(stats, :metrics, LatencyMetrics.calculate(ctx.targets, samples))

  defp generate_one(generator, run_seed) do
    Generator.generate_value(generator, run_seed)
  end

  # ============================================================================
  # Whole-run coverage accumulation (DR-026)
  # ============================================================================

  # Fold one sequence's result into the running coverage accumulator. Per-check
  # firings (always-on) are projected out of the executor's colocated counters
  # and summed; the heavier command/transition/state tracker (coverage: true
  # only) records the sequence via the existing Coverage path.
  defp accumulate_coverage(acc, result, sequence) do
    run_fires = project_fires(Map.get(result, :check_counters, %{}))
    fires = merge_fires(acc.fires, run_fires)

    tracker =
      if acc.tracker do
        # Feed the tracker a result carrying the sequence (for command/transition
        # coverage) and this sequence's firings (lifted into check_hits).
        record = result |> Map.put(:sequence, sequence) |> Map.put(:check_fires, run_fires)
        Coverage.record(acc.tracker, {:ok, record})
      else
        nil
      end

    %{acc | fires: fires, tracker: tracker}
  end

  # Project the colocated {:fired, projection, name} keys out of the check
  # counters into the public %{{projection, name} => count} fire map, dropping
  # the sampling counters (:step/:command/:event/per-module) that share the map.
  defp project_fires(counters) do
    for {{:fired, projection, name}, count} <- counters, into: %{} do
      {{projection, name}, count}
    end
  end

  defp merge_fires(acc, new) do
    Map.merge(acc, new, fn _key, a, b -> a + b end)
  end

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

  # Per-run injector and mock wiring, shared with PropertyDamage.Variant.
  defp setup_injectors(injectors, event_queue),
    do: RunServices.setup_injectors(injectors, event_queue)

  defp teardown_injectors(injectors), do: RunServices.teardown_injectors(injectors)

  defp setup_mocks(mocks, event_queue), do: RunServices.setup_mocks(mocks, event_queue)

  defp teardown_mocks(registry, contexts), do: RunServices.teardown_mocks(registry, contexts)

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
  # failure (a shrunk `FailureReport` for a still-failing seed, a `:setup_failed`
  # report, or a `setup_each_failed` map mirroring `run_loop`'s contract).
  #
  # A replayed seed runs against the reference target only.
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

  defp finish_replay({:setup_each_failed, reason}, _path, _k, _reporter) do
    {:halt, %{setup_each_failed: reason, phase: :seed_library_replay}}
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
      {:setup_each_failed, _reason} = err -> err
      {:setup_failed, _report} = err -> err
      {lib, results, rep} -> {:ok, lib, Enum.reverse(results), rep}
    end
  end

  defp replay_entry(seed, lib, results, rep, ctx, k, verbose) do
    build_rep? = is_nil(rep)

    execution =
      with_sequence_execution(seed, ctx, fn sequence, exec_result, event_queue, mock_registry ->
        replay_outcome(sequence, exec_result, event_queue, mock_registry, seed, ctx, build_rep?)
      end)

    case execution do
      {:setup_each_failed, _reason} = err ->
        {:halt, err}

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

  # Classify one replay execution. On failure (and when this is the
  # representative), shrink into a full report via the shared `handle_failure`
  # while the event queue is still alive.
  defp replay_outcome(
         _sequence,
         %{success: true},
         _event_queue,
         _mock_registry,
         _seed,
         _ctx,
         _build_rep?
       ) do
    {:pass}
  end

  defp replay_outcome(sequence, exec_result, event_queue, mock_registry, seed, ctx, build_rep?) do
    {failure_type, check_name} = FailureReport.classify_reason(exec_result.failure_reason)

    # Refresh descriptive metadata from the new failure. Keep the prior
    # failure_type if the reason did not classify (nil); check_name is
    # legitimately nil for many failure types, so it is refreshed as-is.
    refresh =
      [check_name: check_name] ++
        if(failure_type, do: [failure_type: failure_type], else: [])

    report =
      if build_rep? do
        {:error, report} =
          handle_failure(
            ctx,
            sequence,
            exec_result,
            event_queue,
            mock_registry,
            seed,
            0,
            # Replay is a pre-exploration phase; whole-run anti-vacuity coverage
            # is an exploration concern, so no firings are accumulated here.
            %{}
          )

        report
      end

    {:fail, refresh, report}
  end

  defp pass_outcome(library, seed, k) do
    entry = Enum.find(library.entries, &(&1.seed == seed))
    if entry && entry.consecutive_passes >= k, do: :prune, else: :pass
  end

  # Drive one sequence through the per-sequence lifecycle (setup_each → event
  # queue + injectors → Executor.run → teardown) against the reference target,
  # invoking `fun` with the live event queue. Mirrors a branching run of
  # `run_loop` for a single run-0 derivation.
  defp with_sequence_execution(seed, ctx, fun) do
    sequence = generate_one(ctx.generator, seed)

    case call_setup_each(ctx, 0) do
      :ok ->
        try do
          with_run_services(ctx.target, fn event_queue, mock_registry ->
            run_result =
              Executor.run(sequence, ctx.model, ctx.target.adapter,
                config: ctx.target.config,
                event_queue: event_queue,
                mock_registry: mock_registry,
                stutter_config: ctx.stutter_config,
                # Replay derives run 0, whose effective seed is the replayed seed.
                rng_seed: seed,
                # Mint run-scoped values against the campaign nonce (DR-034);
                # epoch 0 for this replay's exploration-equivalent execution.
                run_nonce: ctx.run_nonce,
                mint_epoch: 0
              )

            case run_result do
              {:ok, result} ->
                fun.(sequence, result, event_queue, mock_registry)

              # Executor.run returns {:error, reason} when the adapter's setup/1
              # fails: the replay halts with a setup failure report.
              {:error, reason} ->
                {:setup_failed, setup_report(ctx, sequence, seed, 0, reason, %{})}
            end
          end)
        after
          call_teardown_each(ctx, 0)
        end

      {:error, reason} ->
        {:setup_each_failed, reason}
    end
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

  # Shrinks a one-target failure and reproduces it through the linear engine,
  # using the event queue and mock registry the caller set up for the target.
  defp handle_failure(
         ctx,
         sequence,
         result,
         event_queue,
         mock_registry,
         seed,
         run_number,
         check_fires
       ) do
    %{
      model: model,
      target: target,
      shrink: shrink,
      shrinker_config: shrinker_config,
      run_nonce: run_nonce,
      stutter_config: stutter_config
    } = ctx

    # Stutter failures are now shrinkable (DR-029): the shrinker reproduces them
    # with stutter forced on (probability 1.0), so they minimize to the offending
    # command rather than being skipped. `seed` is the run's effective seed,
    # reused as the stutter RNG base so reproduction tracks the original run.
    # One mint-epoch source for this whole logical run (DR-034): shrink attempts
    # and the reproduction re-execution below all draw from it, so no two SUT
    # executions in this run send the same client-minted values on a
    # non-resettable SUT. Epoch 0 was the exploration run.
    mint_epoch_counter = :atomics.new(1, signed: false)

    {shrunk_sequence, shrink_iterations, shrink_time_ms} =
      if shrink do
        shrink_result =
          Shrinker.shrink(sequence,
            failed_at_index: result.failed_at_index,
            failure_reason: result.failure_reason,
            model: model,
            target: target,
            config: shrinker_config,
            event_queue: event_queue,
            mock_registry: mock_registry,
            stutter_config: stutter_config,
            rng_seed: seed,
            run_nonce: run_nonce,
            mint_epoch_counter: mint_epoch_counter
          )

        {shrink_result.sequence, shrink_result.iterations, shrink_result.time_ms}
      else
        {sequence, 0, 0}
      end

    # Re-execute shrunk sequence to get fresh event log and state
    # (the original result has state from before shrinking). For a stutter
    # failure, force stutter on (prob 1.0) with the run's seed so the report's
    # fresh state actually carries the reproduced violation (DR-029).
    # The reproduction re-execution is a fresh SUT execution: give it its own
    # mint epoch from the shared counter (DR-034), distinct from every shrink
    # attempt and from the exploration run.
    fresh_epoch = :atomics.add_get(mint_epoch_counter, 1, 1)

    fresh_opts =
      [
        config: target.config,
        event_queue: event_queue,
        mock_registry: mock_registry,
        run_nonce: run_nonce,
        mint_epoch: fresh_epoch
      ] ++
        stutter_repro_run_opts(result.failure_reason, stutter_config, seed)

    fresh_result =
      case Executor.run(shrunk_sequence, model, target.adapter, fresh_opts) do
        {:ok, fresh} ->
          fresh

        # The reproduction re-execution's adapter setup can fail. Treat that as a
        # non-reproduction and fall back to the original observed failure below,
        # instead of crashing on a hard {:ok, _} match (A4).
        {:error, _reason} ->
          nil
      end

    # Normally the re-execution reproduces the failure on the (possibly smaller)
    # shrunk sequence, giving the report fresh state and a minimal repro. But an
    # intermittent failure may not reproduce on this single re-run: the fresh
    # result then carries `success: true / failure_reason: nil / failed_at_index:
    # nil`, which would render as a contentless "Unknown Failure" and discard the
    # reason we actually observed. When the re-run fails to reproduce, fall back
    # to the original failing run -- report its sequence, reason, index, and
    # state. A genuine reproduction keeps the shrunk sequence and fresh state.
    reproduced? =
      not is_nil(fresh_result) and not fresh_result.success and
        not is_nil(fresh_result.failure_reason)

    {report_shrunk_sequence, report_result} =
      if reproduced? do
        {shrunk_sequence, fresh_result}
      else
        {sequence, result}
      end

    # Create rich failure report from whichever run carries the observed failure.
    failure_report =
      FailureReport.new(
        seed: seed,
        run_number: run_number,
        original_sequence: sequence,
        shrunk_sequence: report_shrunk_sequence,
        # The embedded trace describes whichever run carries the observed
        # failure (DR-033): the shrunk minimal reproduction when it reproduced,
        # else the original generated run.
        plan_source: if(reproduced?, do: :shrunk, else: :generated),
        source_revision: RunTrace.source_revision(),
        # Record the run inputs of the execution the report describes (DR-034):
        # the reproduction re-execution's epoch when it reproduced, else the
        # exploration run's epoch 0.
        run_nonce: run_nonce,
        mint_epoch: if(reproduced?, do: fresh_epoch, else: 0),
        executed: Map.get(report_result, :executed, %{}),
        failed_at_index: report_result.failed_at_index,
        failure_reason: report_result.failure_reason,
        shrink_iterations: shrink_iterations,
        shrink_time_ms: shrink_time_ms,
        event_log: report_result.event_log,
        projections: report_result.projections,
        projections_before: report_result.projections_before,
        command_fold_ordinals: Map.get(report_result, :command_fold_ordinals, %{}),
        model: model,
        targets: ctx.target_entries,
        variant: %{index: target.index, name: target.name},
        concurrency: ctx.concurrency,
        linearization: report_result.linearization,
        stacktrace: Map.get(report_result, :stacktrace),
        check_fires: check_fires
      )

    report_failure(ctx, failure_report)
  end

  # Announces a failure report and returns it as the run's result.
  defp report_failure(ctx, failure_report) do
    # Terminal failure notification (DR-022): the verbose consumer renders this
    # as the failure summary. The authoritative result is the returned report.
    Reporter.emit(ctx.reporter, fn ->
      %RunResult{
        outcome: :error,
        failure: failure_report,
        kind: failure_report.kind,
        variant: failure_report.variant
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

  # Check if a failure reason is stutter-related (idempotency violation or execution failure)
  defp stutter_failure?(%Failure{} = failure),
    do: Failure.kind(failure) in [:idempotency_violation, :stutter_execution_failed]

  defp stutter_failure?(_), do: false

  # Extra Executor.run opts for the post-shrink re-execution (DR-029). For a
  # stutter failure, force stutter on (prob 1.0) with the run seed so the
  # report's fresh state reproduces the violation; otherwise no stutter opts.
  defp stutter_repro_run_opts(failure_reason, %Stutter.Config{} = config, seed) do
    if stutter_failure?(failure_reason) do
      [stutter_config: %{config | probability: 1.0, enabled: true}, rng_seed: seed]
    else
      []
    end
  end

  defp stutter_repro_run_opts(_failure_reason, _config, _seed), do: []

  # Build the on_failure callback from :on_failure and :regression options
  defp build_on_failure_callback(opts) do
    on_failure = Keyword.get(opts, :on_failure)
    regression = Keyword.get(opts, :regression)

    cond do
      # Both options specified - compose them
      on_failure != nil and regression != nil ->
        regression_handler =
          PropertyDamage.Regression.handler(Options.with_target_entries(regression))

        fn failure_report ->
          on_failure.(failure_report)
          regression_handler.(failure_report)
        end

      # Only on_failure specified
      on_failure != nil ->
        on_failure

      # Only regression specified
      regression != nil ->
        PropertyDamage.Regression.handler(Options.with_target_entries(regression))

      # Neither specified
      true ->
        nil
    end
  end

  @doc """
  Attempt further shrinking on an existing failure report.

  Use this when the initial shrinking didn't produce a minimal enough sequence.
  You can specify more aggressive time/iteration limits or different strategies.

  ## Options

  - `:strategy` - Shrinking strategy (default: `:thorough`). Each strategy sets a
    default budget that the explicit options below override:

    | strategy       | max_iterations | max_time_ms |
    |----------------|----------------|-------------|
    | `:quick`       | 500            | 10_000      |
    | `:thorough`    | 2000           | 60_000      |
    | `:exhaustive`  | 10_000         | 300_000     |

  - `:max_iterations` - Maximum shrink attempts (default: from `:strategy`)
  - `:max_time_ms` - Maximum time for shrinking in ms (default: from `:strategy`)
  - `:shrink_arguments` - Whether to shrink argument values (default: true)
  - `:targets` - Single-entry target list overriding the system to re-execute
    against (default: the report's reference target: its adapter, name and
    `config:`); see `PropertyDamage.Target`

  ## Returns

  - `{:ok, new_failure_report}` - Shrinking succeeded, possibly smaller sequence
  - `{:error, reason}` - Shrinking failed: `:missing_model_or_adapter` when the
    report records no model or no target, or the setup `%PropertyDamage.Failure{}`
    when the target's adapter `setup/1` fails on the re-execution

  ## Example

      {:error, failure} = PropertyDamage.run(model: M, targets: [A])

      # Try harder to shrink
      {:ok, smaller} = PropertyDamage.shrink_further(failure,
        max_time_ms: 120_000,
        strategy: :exhaustive
      )

      IO.puts("Reduced from \#{length(original)} to \#{length(smaller)} commands")
  """
  @spec shrink_further(FailureReport.t(), keyword()) ::
          {:ok, FailureReport.t()} | {:error, term()}
  def shrink_further(%FailureReport{} = report, opts \\ []) do
    model = report.model
    reference = FailureReport.reference_target(report)

    if is_nil(model) or is_nil(reference) do
      {:error, :missing_model_or_adapter}
    else
      target = Options.override_target!(opts, reference, "PropertyDamage.shrink_further/2")

      # Build shrinker config from options
      strategy = Keyword.get(opts, :strategy, :thorough)

      shrinker_config =
        ShrinkerConfig.new(
          max_iterations: strategy_iterations(strategy, opts),
          max_time_ms: strategy_time(strategy, opts),
          shrink_arguments: Keyword.get(opts, :shrink_arguments, true),
          granularity_threshold: strategy_threshold(strategy)
        )

      # Start event queue for shrinking
      {:ok, event_queue} = EventQueue.start_link()

      try do
        start_time = System.monotonic_time(:millisecond)

        # Carry the original run's nonce (DR-034) so re-shrinking mints the same
        # class of run-scoped values; a shared epoch counter keeps every SUT
        # execution in this re-shrink distinct.
        run_nonce = report.trace && report.trace.run_nonce
        mint_epoch_counter = :atomics.new(1, signed: false)

        # Perform shrinking on the already-shrunk sequence
        shrink_result =
          Shrinker.shrink(FailureReport.shrunk_sequence(report),
            failed_at_index: report.failed_at_index,
            failure_reason: report.failure_reason,
            model: model,
            target: target,
            config: shrinker_config,
            event_queue: event_queue,
            run_nonce: run_nonce,
            mint_epoch_counter: mint_epoch_counter
          )

        fresh_epoch = :atomics.add_get(mint_epoch_counter, 1, 1)

        # Re-execute to get fresh state
        case Executor.run(shrink_result.sequence, model, target.adapter,
               config: target.config,
               event_queue: event_queue,
               run_nonce: run_nonce,
               mint_epoch: fresh_epoch
             ) do
          # A re-execution whose adapter setup fails cannot confirm a further
          # shrink; surface the setup failure instead of crashing on a hard
          # {:ok, _} match (A4).
          {:error, reason} ->
            {:error, Failure.setup_failed(reason)}

          {:ok, fresh_result} ->
            end_time = System.monotonic_time(:millisecond)

            # As in handle_failure/N: only adopt the further-shrunk sequence on a
            # genuine reproduction. If the re-execution did not reproduce the
            # failure (a flaky repro), the fresh result carries `success: true /
            # reason: nil`, which would emit a nil-reason "Unknown Failure" for an
            # unverified smaller sequence. In that case return the incoming report
            # unchanged -- the further-shrink found nothing it could confirm.
            if fresh_result.success or is_nil(fresh_result.failure_reason) do
              {:ok, report}
            else
              new_report =
                FailureReport.new(
                  seed: report.seed,
                  run_number: report.run_number,
                  original_sequence: report.original_sequence,
                  shrunk_sequence: shrink_result.sequence,
                  failed_at_index: fresh_result.failed_at_index,
                  failure_reason: fresh_result.failure_reason,
                  shrink_iterations: report.shrink_iterations + shrink_result.iterations,
                  shrink_time_ms: report.shrink_time_ms + (end_time - start_time),
                  event_log: fresh_result.event_log,
                  executed: Map.get(fresh_result, :executed, %{}),
                  # A further-shrunk report only reaches here on a genuine
                  # reproduction, so its plan is a shrinker product (DR-033).
                  plan_source: :shrunk,
                  source_revision: RunTrace.source_revision(),
                  run_nonce: run_nonce,
                  mint_epoch: fresh_epoch,
                  projections: fresh_result.projections,
                  projections_before: fresh_result.projections_before,
                  command_fold_ordinals: Map.get(fresh_result, :command_fold_ordinals, %{}),
                  model: model,
                  # The re-shrink re-executed against this one target.
                  targets: [PropertyDamage.Target.to_entry(target)],
                  variant: %{index: 0, name: target.name},
                  linearization: fresh_result.linearization,
                  stacktrace: Map.get(fresh_result, :stacktrace)
                )

              {:ok, new_report}
            end
        end
      after
        EventQueue.stop(event_queue)
      end
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

  @doc """
  Explain why each command in a failure's shrunk sequence is needed.

  Delegates to `PropertyDamage.Analysis.explain/1`.
  See that module for detailed documentation.
  """
  @spec explain(FailureReport.t()) :: map()
  defdelegate explain(report), to: PropertyDamage.Analysis

  @doc """
  Find the minimal change that eliminates the failure.

  Delegates to `PropertyDamage.Analysis.isolate_trigger/1`.
  See that module for detailed documentation.
  """
  @spec isolate_trigger(FailureReport.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate isolate_trigger(report, opts \\ []), to: PropertyDamage.Analysis

  @doc """
  Generate a reproducible test case from a failure.

  Delegates to `PropertyDamage.Analysis.generate_test/2`.
  See that module for detailed documentation.
  """
  @spec generate_test(FailureReport.t(), keyword()) :: String.t()
  defdelegate generate_test(report, opts \\ []), to: PropertyDamage.Analysis

  # ============================================================================
  # Persistence API
  # ============================================================================

  @doc """
  Save a failure report to disk for later analysis or regression testing.

  ## Options

  - `:filename` - Custom filename (default: auto-generated from metadata)
  - `:overwrite` - Whether to overwrite existing files (default: false)

  ## Examples

      {:error, failure} = PropertyDamage.run(model: M, targets: [A])

      # Save with auto-generated name
      {:ok, path} = PropertyDamage.save_failure(failure, "failures/")

      # Save with custom name
      {:ok, path} = PropertyDamage.save_failure(failure, "failures/", filename: "currency-bug.pd")
  """
  @spec save_failure(FailureReport.t(), Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  defdelegate save_failure(report, directory, opts \\ []),
    to: PropertyDamage.Persistence,
    as: :save

  @doc """
  Load a previously saved failure report.

  ## Examples

      {:ok, failure} = PropertyDamage.load_failure("failures/currency-bug.pd")
      PropertyDamage.replay(failure)
  """
  @spec load_failure(Path.t()) :: {:ok, FailureReport.t()} | {:error, term()}
  defdelegate load_failure(path), to: PropertyDamage.Persistence, as: :load

  @doc """
  List all saved failures in a directory.

  ## Options

  - `:sort` - Sort order: `:newest`, `:oldest`, `:seed` (default: `:newest`)
  - `:filter` - Filter function `(metadata -> boolean)`

  ## Examples

      failures = PropertyDamage.list_failures("failures/")

      # Only check failures
      failures = PropertyDamage.list_failures("failures/",
        filter: &(&1.failure_type == :check_failed))
  """
  @spec list_failures(Path.t(), keyword()) :: [map()]
  defdelegate list_failures(directory, opts \\ []), to: PropertyDamage.Persistence, as: :list

  @doc """
  Delete a saved failure file.
  """
  @spec delete_failure(Path.t()) :: :ok | {:error, term()}
  defdelegate delete_failure(path), to: PropertyDamage.Persistence, as: :delete

  # ============================================================================
  # Replay API
  # ============================================================================

  @doc """
  Replay a failure sequence step-by-step for debugging.

  Executes each command in the shrunk sequence and returns detailed
  information about each step including events and projection states.

  ## Options

  - `:targets` - Single-entry target list overriding the system to replay
    against (default: the report's reference target)
  - `:stop_on_failure` - Stop at first failure (default: true)

  ## Example

      {:error, failure} = PropertyDamage.run(model: M, targets: [A])
      {:ok, steps} = PropertyDamage.replay(failure)

      Enum.each(steps, fn step ->
        IO.puts("[\#{step.index}] \#{step.command_name}")
        IO.inspect(step.projections)
      end)

  For interactive stepping, use `PropertyDamage.Replay` directly:

      {:ok, session} = PropertyDamage.Replay.start(failure)
      {:ok, session, step} = PropertyDamage.Replay.step(session)
  """
  @spec replay(FailureReport.t(), keyword()) ::
          {:ok, [PropertyDamage.Replay.step()]} | {:error, term()}
  defdelegate replay(failure, opts \\ []), to: PropertyDamage.Replay, as: :run

  # ============================================================================
  # Seed Library API
  # ============================================================================

  @doc """
  Load a seed library from disk.

  Returns an empty library if the file doesn't exist.

  ## Example

      {:ok, library} = PropertyDamage.load_seed_library("seeds.json")
  """
  @spec load_seed_library(Path.t()) :: {:ok, PropertyDamage.SeedLibrary.t()} | {:error, term()}
  defdelegate load_seed_library(path \\ "property_damage_seeds.json"),
    to: PropertyDamage.SeedLibrary,
    as: :load

  @doc """
  Save a seed library to disk.

  ## Example

      :ok = PropertyDamage.save_seed_library(library, "seeds.json")
  """
  @spec save_seed_library(PropertyDamage.SeedLibrary.t(), Path.t()) :: :ok | {:error, term()}
  defdelegate save_seed_library(library, path \\ "property_damage_seeds.json"),
    to: PropertyDamage.SeedLibrary,
    as: :save

  @doc """
  Add a failure to the seed library.

  ## Options

  - `:tags` - Categorization tags (e.g., `[:currency, :race_condition]`)
  - `:description` - Human-readable description

  ## Example

      {:error, failure} = PropertyDamage.run(model: M, targets: [A])
      {:ok, library} = PropertyDamage.add_to_seed_library(library, failure,
        tags: [:currency_mismatch],
        description: "Capture with different currency than authorization"
      )
  """
  @spec add_to_seed_library(PropertyDamage.SeedLibrary.t(), FailureReport.t(), keyword()) ::
          {:ok, PropertyDamage.SeedLibrary.t()} | {:error, term()}
  defdelegate add_to_seed_library(library, failure, opts \\ []),
    to: PropertyDamage.SeedLibrary,
    as: :add

  # ============================================================================
  # Coverage API
  # ============================================================================

  @doc """
  Get coverage statistics from a test result.

  Accepts both a single sequence/failure result and an aggregate `{:ok, stats}`
  from a multi-run `run/1` invoked with `coverage: true` (the latter returns the
  pre-merged `stats.coverage` tracker). An aggregate result produced without
  `coverage: true` raises `ArgumentError`.

  ## Example

      result = PropertyDamage.run(model: M, targets: [A], coverage: true)
      coverage = PropertyDamage.coverage(result, M)
      IO.puts(PropertyDamage.Coverage.format(coverage))
  """
  @spec coverage({:ok, map()} | {:error, FailureReport.t()}, module()) ::
          PropertyDamage.Coverage.t()
  defdelegate coverage(result, model), to: PropertyDamage.Coverage, as: :from_result

  @doc """
  Per-invariant anti-vacuity coverage for a run result (DR-026).

  Joins the run's per-check firings (`result.check_fires`, accumulated
  across every generated sequence) against the model's `check_catalog/1`,
  with no re-execution. Each entry reports whether the invariant was exercised:

      result = PropertyDamage.run(model: M, targets: [A])
      for inv <- PropertyDamage.check_coverage(result, M), not inv.covered? do
        IO.puts("never exercised: \#{inv.id}")
      end

  Each entry is a map with `:projection`, `:id`, `:name`, `:description`,
  `:kinds` (the distinct check kinds), `:fire_count` (summed over the invariant's
  checks), and `:covered?` (`fire_count > 0`). Ordered like the catalog. Works on
  a passing `{:ok, stats}` or a failing `{:error, report}` result, though on a
  failed run the fire map is partial by nature (anti-vacuity is a passing-run
  concern).
  """
  @spec check_coverage({:ok, map()} | {:error, FailureReport.t()} | map(), module()) :: [
          %{
            projection: module(),
            id: atom(),
            name: atom(),
            description: String.t() | nil,
            kinds: [atom()],
            fire_count: non_neg_integer(),
            covered?: boolean()
          }
        ]
  def check_coverage(result, model) do
    fires = extract_check_fires(result)

    model
    |> PropertyDamage.Model.check_catalog()
    |> Enum.map(fn %{projection: projection, id: id, invariant: invariant, checks: checks} ->
      fire_count =
        Enum.reduce(checks, 0, fn check, acc ->
          acc + Map.get(fires, {projection, check.name}, 0)
        end)

      %{
        projection: projection,
        id: id,
        name: invariant.name,
        description: invariant.description,
        kinds: checks |> Enum.map(& &1.kind) |> Enum.uniq(),
        fire_count: fire_count,
        covered?: fire_count > 0
      }
    end)
  end

  defp extract_check_fires({:ok, stats}), do: Map.get(stats, :check_fires, %{})

  defp extract_check_fires({:error, %FailureReport{check_fires: fires}}),
    do: fires || %{}

  defp extract_check_fires(%{check_fires: fires}), do: fires || %{}
  defp extract_check_fires(_), do: %{}

  @doc """
  The model's invariant catalog (DR-026).

  The union of every projection's declared invariants, keyed `{projection, id}`,
  each entry carrying the `%PropertyDamage.Invariants.Invariant{}` and the checks
  (with their kinds) that validate it. See `PropertyDamage.Model.check_catalog/1`.
  """
  @spec check_catalog(module()) :: [
          %{
            projection: module(),
            id: atom(),
            invariant: PropertyDamage.Invariants.Invariant.t(),
            checks: [%{name: atom(), kind: :synchronous | :lifecycle | :eventual}]
          }
        ]
  defdelegate check_catalog(model), to: PropertyDamage.Model

  # ============================================================================
  # Check Helpers
  # ============================================================================

  @doc """
  Convenience function to fail a check with a message and optional data.

  Use this in projection checks when you don't need a custom exception type.

  ## Examples

      # Simple failure
      PropertyDamage.fail!("balance is negative")

      # With context data
      PropertyDamage.fail!("balance is negative", balance: -50, account_id: "acc_123")

      # In a projection check
      @check every: 1
      def assert_balance_positive(state, _cmd) do
        if state.balance < 0 do
          PropertyDamage.fail!("negative balance", balance: state.balance)
        end
      end

  ## Custom Exceptions

  For richer error context, define your own exception types:

      defmodule MyApp.BalanceViolation do
        defexception [:balance, :requirement]

        def message(%{balance: b}) do
          "Balance is negative: \#{b}"
        end
      end

      # Then raise directly:
      raise %MyApp.BalanceViolation{balance: -50, requirement: "REQ-001"}
  """
  @spec fail!(String.t(), keyword()) :: no_return()
  def fail!(message, data \\ []) do
    raise %PropertyDamage.CheckFailed{message: message, data: Map.new(data)}
  end

  # ============================================================================
  # Model-Free Execution (Static Regression Tests)
  # ============================================================================

  @doc """
  Execute a fixed command sequence without a model.

  This function provides a model-free execution path for static regression tests
  where you want to run a specific command sequence and assert on the raw event
  log directly, without using model-defined projections or checks.

  ## Use Cases

  - **Regression tests**: Run a specific sequence that reproduced a bug
  - **Integration tests**: Execute commands with real injector adapters
  - **Debugging**: Capture full SUT behavior including webhooks/callbacks

  ## Options

  - `:targets` - A list with exactly one entry (required): an adapter module or
    `{AdapterModule, config:, injectors:}`. `config:` is passed to
    `adapter.setup/1` (default: `%{}`); `injectors:` lists injector adapter
    modules (default: `[]`). `mocks:` is not supported here and raises. See
    `PropertyDamage.Target`.

  ## Returns

  - `{:ok, event_log}` - List of `EventLog.Entry` structs containing all events
  - `{:error, %PropertyDamage.Failure{}}` - a `:adapter_error` (with `partial_events`)

  ## Example

      # Simple execution
      commands = [
        %CreateUser{name: "alice"},
        %CreateOrder{user_id: 1, amount: 100}
      ]

      {:ok, events} = PropertyDamage.execute(commands, targets: [MyAdapter])

      # Assert on returned events
      assert length(events) == 2
      assert hd(events).event.__struct__ == UserCreated

  ## With Injector Adapters

  When testing end-to-end flows with webhooks or async callbacks:

      {:ok, events} = PropertyDamage.execute(commands,
        targets: [
          {MyAdapter,
           injectors: [WebhookAdapter],
           config: %{base_url: "http://localhost:4000"}}
        ]
      )

      # Assert on injected webhook events
      assert Enum.any?(events, fn entry ->
        entry.source == :injector and
        match?(%WebhookReceived{status: "completed"}, entry.event)
      end)

  ## Comparison with Direct Adapter Calls

  For simple tests that only need command return values (no injector events),
  calling the adapter directly is simpler:

      {:ok, adapter_ctx} = MyAdapter.setup(%{})
      {:ok, events} = MyAdapter.execute(%CreateUser{name: "alice"}, adapter_ctx)
      assert [%UserCreated{name: "alice"}] = events
      MyAdapter.teardown(adapter_ctx)

  Use `execute/2` when you need the full infrastructure: injector adapters,
  event queue, external() value resolution across commands, etc.
  """
  @spec execute([struct()], keyword()) ::
          {:ok, [PropertyDamage.EventLog.Entry.t()]} | {:error, term()}
  def execute(commands, opts) when is_list(commands) do
    opts = Options.validate_execute!(opts)

    [target] = opts[:targets]
    Options.reject_unsupported_target_keys!([target], [:mocks], "PropertyDamage.execute/2")
    %{adapter: adapter, injectors: injectors, config: config} = target

    # Start event queue for injectors. Its stop is guaranteed by the outer
    # `after` below so that a raise in injector or adapter setup cannot leak it
    # (A6); injector/adapter setup therefore lives inside the outer try.
    {:ok, event_queue} = EventQueue.start_link()

    try do
      # Setup injector adapters
      setup_injectors(injectors, event_queue)

      # Setup main adapter
      case adapter.setup(config) do
        {:ok, adapter_context} ->
          context = %{
            adapter_context: adapter_context,
            event_queue: event_queue
          }

          sequence = Sequence.linear(commands)

          try do
            Executor.execute_raw(sequence, adapter, context)
          after
            # Cleanup. The event queue is stopped by the outer `after`.
            adapter.teardown(adapter_context)
            teardown_injectors(injectors)
          end

        {:error, reason} ->
          # Cleanup injectors on setup failure; the event queue is stopped by
          # the outer `after`.
          teardown_injectors(injectors)
          {:error, Failure.setup_failed(reason)}
      end
    after
      EventQueue.stop(event_queue)
    end
  end

  # ============================================================================
  # External Values (Server-Generated IDs)
  # ============================================================================

  @doc """
  Mark a field as server-generated (external) in event struct definitions.

  Use `external()` as the default value for fields that will be populated by
  the System Under Test (SUT) during execution, such as auto-generated IDs,
  timestamps, or transaction references.

  ## Basic Usage

      defmodule MyApp.Events.OrderCreated do
        import PropertyDamage, only: [external: 0]

        # id is server-generated, amount comes from the command
        defstruct [:amount, :customer_id, id: external()]
      end

  ## Multiple Externals

  Events can have multiple external fields:

      defmodule MyApp.Events.PaymentProcessed do
        import PropertyDamage, only: [external: 0]

        defstruct [
          payment_id: external(),
          transaction_ref: external(),
          :order_id,
          :amount
        ]
      end

  ## Nested Externals

  Externals are supported in nested maps:

      defstruct [
        ids: %{transaction: external(), confirmation: external()},
        :amount
      ]

  ## Fixed-Length Lists

  Externals are supported in fixed-length lists:

      defstruct [
        item_ids: [external(), external(), external()],
        :batch_name
      ]

  ## How It Works

  1. In your simulator, return events with external fields unset. `simulate/2`
     returns a bare list of event structs; `id: external()` is implicit:

      def simulate(%CreateOrder{amount: amt}, _state) do
        [%OrderCreated{amount: amt}]
      end

  2. The framework automatically:
     - Detects external markers during simulation
     - Creates internal placeholders to track dependencies (these flow into
       projection state in place of the marker)
     - Resolves placeholders with real values from the SUT

  3. In projections, you receive concrete values at execution time:

      def apply(state, %OrderCreated{id: id, amount: amt}) do
        put_in(state.orders[id], %{amount: amt})  # id is a real value
      end

  4. To make a later command consume a server-generated value, route a
     placeholder out of state in the model's `overrides:` function. During
     generation the projection holds placeholders, which
     `PropertyDamage.Generator.external_from/2` surfaces as a seeded choice:

      # in the model's command list
      {ViewOrder,
       when: fn state -> map_size(state.orders) > 0 end,
       overrides: fn state ->
         %{order_id: PropertyDamage.Generator.external_from(state, path: [:id])}
       end}

     The chosen placeholder resolves to the real id before `ViewOrder` runs.

  ## Limitations

  Variable-length lists where the count isn't known at struct definition
  time are not supported. If you need a variable number of external IDs,
  mark the entire list as `external()` and have the SUT return the complete list.

  ## See Also

  - `PropertyDamage.External` - Implementation details and path detection
  """
  @spec external() :: PropertyDamage.External.t()
  defdelegate external(), to: PropertyDamage.External

  @doc """
  Mark a command field as a client-minted, run-scoped value (DR-034).

  Use inside a command generator to send a value that must be **unique per run
  yet reproducible** — a request UUID or idempotency key sent to a System Under
  Test you cannot reset between runs:

      def generator(overrides) do
        StreamData.fixed_map(%{
          request_id: StreamData.constant(PropertyDamage.mint_per_run(:uuid)),
          amount: StreamData.integer(1..100)
        })
      end

  The field holds a marker during generation (so the plan stays a pure function
  of the seed and is positionally identical across runs), and resolves at
  execution to a value derived from the run's `run_nonce`/`mint_epoch` and the
  field's coordinates. Hold `(seed, run_number)` and vary the nonce to re-run
  the identical plan with fresh minted values on a shared SUT.

  Contrast with `external/0`, which captures a value the SUT *returns*;
  `mint_per_run` mints a value the client *sends*.

  ## Kinds

  - `:uuid` - an RFC 4122 (version 4) UUID string.
  - `{:hex, n}` - `n` lowercase hex characters.
  - `{module, function}` - escape hatch; `function` receives the derived bytes
    (a binary) and returns the value. Anonymous functions are rejected: markers
    persist inside plans/traces and must survive `binary_to_term`.
  """
  @spec mint_per_run(PropertyDamage.Mint.kind()) :: PropertyDamage.Mint.t()
  defdelegate mint_per_run(kind), to: PropertyDamage.Mint, as: :new

  @doc """
  Audit that a model's generation is a pure function of the seed (DR-037).

  Generation MUST be deterministic in `(seed, model, generation opts)`: all
  nondeterminism (clock, `:rand`, client-minted ids, environment) belongs
  behind an execution-time seam, never in a generator / `when:` / `overrides:` /
  projection. This realizes the model's generated sequence twice at each of N
  seeds and asserts the two are structurally equal, catching impurity at
  dev/CI time before it breaks `seed: N` reproduction and
  `PropertyDamage.RunComparison`'s fingerprint guard.

  Returns `:ok`, or `{:error, %{seed: seed, divergence: divergence}}` for the
  first diverging seed. See `PropertyDamage.Audit` for options and
  `guides/deterministic_generation.md` for the deterministic patterns; `mix
  pd.audit` wraps this for CI gating.
  """
  @spec audit(module(), keyword()) :: PropertyDamage.Audit.result()
  def audit(model, opts \\ []), do: PropertyDamage.Audit.run(model, opts)

  @doc """
  Audit that a model's projection `apply/2` is a pure function of its inputs
  (P8 / DR-040).

  Companion to `audit/2`: folds each seed's generated plan through every
  projection twice (using the model's simulator to predict events) and names any
  projection whose two folds disagree — i.e. one that read a clock, a counter,
  or the environment in `apply/2`. Generation-only (no adapter/SUT), the dev/CI
  early warning for the runtime projection-purity check
  (`PropertyDamage.FailureReport.verify_projections/1`). `mix pd.audit` runs it
  alongside the generation audit.

  Returns `:ok`, or `{:error, %{seed: seed, modules: [module()]}}`.
  """
  @spec audit_projections(module(), keyword()) ::
          :ok | {:error, %{seed: integer(), modules: [module()]}}
  def audit_projections(model, opts \\ []),
    do: PropertyDamage.Audit.projection_purity(model, opts)

  @doc false
  defmacro __using__(_opts) do
    quote do
      import PropertyDamage, only: []
    end
  end
end
