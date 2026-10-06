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
    Comparison,
    Coverage,
    EventQueue,
    Executor,
    Expansion,
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
          optional(:compare_counts) => Scheduler.compare_counts(),
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
  - `:compare` - `[converge_within: ms]`: how long the comparison of two or
    more targets waits at a boundary for their `@compare` observations to
    agree (default `[converge_within: 5_000]`)
  - `:latency` - Measures each target's latency per command and returns it
    in `stats.metrics` (default `false`); requires `concurrency: :serial`.
    `true` only measures. A keyword list adds `warmup: n` (the first `n` runs
    are left out of the metrics, default `0`) and a budget judged once after
    the last run (see "Latency Budget")

  ## Several Targets

  Each linear run executes its command sequence against every target in
  lockstep (`PropertyDamage.Scheduler`): every target executes command `r`,
  their boundary observations scheduled there are compared, and only once they
  agree does any target start command `r + 1`. Targets are compared only
  through the functions the model's projections mark with `@compare`: a run
  with two or more targets whose model declares none is an error before any
  adapter is set up. Each target runs in its own process with its own event queue,
  injectors, mocks and pollers, and is set up and torn down once per run.
  `latency:` requires `concurrency: :serial`, because overlapping targets
  would mix their load into each other's latency.

  A model's fixtures are commands: `c:PropertyDamage.Model.setup_each/0` lists
  the setup commands and `c:PropertyDamage.Model.teardown_each/0` the teardown
  commands, drawn with each run's sequence. Every target executes them through
  the engine, in this order per run: its adapter's `setup/1`, the `@check at:
  :startup` checks, the setup commands, the roots, the final boundary, the
  `@check at: :teardown` checks, the teardown commands, and its adapter's
  `teardown/1`. Every path that executes the run again (a branching run, each
  shrink attempt, the reproduction, `shrink_further/2`, the seed-library
  replay, `replay/2`) runs them the same way; the shrinker never removes or
  simplifies a setup command and draws the teardown commands again for each
  candidate. A failing setup command, a check that fails on a setup
  command's event, or an `external()` a setup command produces that stays
  unresolved is a setup failure (`kind: :setup_failed`).

  ## Latency Budget

  `latency:` takes any of `p50`, `p95`, `p99` and `mean`, each a keyword list
  with `max: {n, :milliseconds | :seconds | :minutes}` (an absolute bound, `n`
  a positive integer) and/or `max_ratio: ratio` (a positive number: the
  target's statistic divided by the reference's). A bare integer has no unit
  and is an option error.

      latency: [warmup: 2, p95: [max_ratio: 1.5], p99: [max: {800, :milliseconds}]]

  The budget is judged once, after the last run passes, on the metrics of the
  measured runs: every target is judged on `max:`, every target but the
  reference on `max_ratio:` (which needs at least two targets). A breach ends
  the campaign with a report of `kind: :latency_exceeded`. It names the target,
  the statistic, the measured value and the limit, and it is neither shrunk nor
  re-executed: latency is statistical, so re-run the seed to reproduce it. A run
  that fails for another reason ends the campaign first, and the budget is
  never judged.

  The metrics of each target are `p50`, `p95`, `p99`, `mean`, `min` and `max`
  in microseconds, `commands` (the commands timed) and `by_command` (`p95` and
  `commands` per root command module). A target with no timed command has
  `%{error: :no_data}` and is never judged.

  The first failure ends the campaign: a target whose boundary observation
  still differs from the reference's at the convergence bound
  (`kind: :diverged`) or is still pending there (`kind: :did_not_converge`), a
  failing check in any target, a setup failure or an execution failure. The
  report names the target in `variant`.

  A failure is shrunk and reproduced the same way for one target or several:
  every shrink attempt runs the candidate sequence on every target through the
  scheduler (each target set up and torn down per attempt), and a candidate
  counts only if it fails with the same kind, check name and failing target
  (`PropertyDamage.Shrinker.failure_signature/2`). The shrunk sequence is then
  run once more, and the report describes that reproduction; when it does not
  fail the same way, the report keeps the original run. A setup failure
  implicates no command and is reported unshrunk.

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
  - `:using` - The predicate deciding whether a retry agrees with the
    original, called `using.(original_events, retry_events)` with the contract
    of `@compare`'s `using:` (default `&==/2`)

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
    `seed`, `targets` (`[%{index:, name:}]`), the coverage keys,
    `compare_counts` (per `@compare` key `{projection, function}`: the
    boundaries it was compared at, waited at, and the time waited), and under
    `latency:` the latency `metrics` of each target, keyed by target name
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
    # The reproduction command prints `latency:` as the caller wrote it, which
    # validation normalizes away.
    latency_given = Keyword.get(opts, :latency, false)

    # Validate options with NimbleOptions - applies defaults and provides helpful errors
    opts = Options.validate_run!(opts)

    model = opts[:model]
    targets = opts[:targets]

    # Two or more targets are compared only through @compare observations:
    # refuse a model without any before anything runs, `validate:` or not.
    Comparison.check_model!(model, length(targets))
    # A model that still defines a removed lifecycle hook fails here, before
    # any target is set up.
    PropertyDamage.Model.check_lifecycle!(model)
    # The rules for expansions/0, and the run options it rules out, fail here
    # too, before any target is set up.
    Expansion.check_options!(model, opts)
    Expansion.check_model!(model)
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
      stutter: opts[:stutter],
      stutter_config: Stutter.parse_config(opts[:stutter]),
      check_mode: opts[:check_mode],
      seed_library: seed_library,
      coverage: opts[:coverage],
      concurrency: opts[:concurrency],
      compare: opts[:compare],
      measure_latency: opts[:latency] != false,
      latency: latency_given,
      latency_budget: opts[:latency]
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
          compare_counts: Comparison.zero_counts(ctx.model),
          tracker: if(ctx.coverage, do: Coverage.new(ctx.model), else: nil),
          total_commands: 0,
          setup_commands: 0,
          teardown_commands: 0,
          expansion_counts: Map.new(ctx.targets, &{&1.name, %{}}),
          samples: [],
          last_run: nil
        }

        run_loop(ctx, 0, acc)
    end
  end

  defp run_loop(ctx, run_number, acc) when run_number >= ctx.max_runs do
    metrics = campaign_metrics(ctx, acc.samples)

    case judge_latency(ctx, metrics) do
      [] -> finish_campaign(ctx, acc, metrics)
      breaches -> report_failure(ctx, latency_report(ctx, acc, metrics, breaches))
    end
  end

  defp run_loop(ctx, run_number, acc) do
    case run_once(ctx, run_number, acc) do
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

  # The budget is judged once, after every run passed, so the report is not
  # localized to a command and nothing is shrunk or re-executed. It records the
  # last run's sequence, seed and number.
  defp latency_report(ctx, acc, metrics, [{target, failure} | rest]) do
    last = acc.last_run

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
      failure_reason: failure,
      kind: :latency_exceeded,
      variant: variant_of(target),
      shrink_iterations: 0,
      shrink_time_ms: 0,
      model: ctx.model,
      targets: ctx.target_entries,
      concurrency: ctx.concurrency,
      compare: ctx.compare,
      stutter: ctx.stutter,
      max_commands: ctx.max_commands,
      check_fires: acc.fires,
      compare_counts: acc.compare_counts,
      other_failures:
        for({other, other_failure} <- rest) do
          %{variant: variant_of(other), root: nil, failure: other_failure}
        end,
      latency: ctx.latency,
      metrics: metrics
    )
  end

  # One run: generate its sequence (setup commands, roots and teardown
  # commands), then execute it. Returns `{:pass, acc}` or the run's
  # `{:error, failure}`.
  defp run_once(ctx, run_number, acc) do
    # Generate a command sequence, deterministically derived from the seed.
    # Run 0 uses the base seed itself so a reported seed reproduces exactly
    # with max_runs: 1.
    run_seed = Generator.run_seed(ctx.seed, run_number)
    sequence = generate_one(ctx, run_seed)
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

    run = %{
      sequence: sequence,
      expansion: expand(ctx, sequence, run_seed),
      seed: ctx.seed,
      run_seed: run_seed,
      run_number: run_number,
      start: seq_start_time
    }

    if ctx.branching,
      do: run_branching(ctx, run, acc),
      else: run_lockstep(ctx, run, acc)
  end

  # A linear sequence runs on every target through the lockstep scheduler,
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

    # Coverage and check firings come from the reference target's run (DR-026).
    acc =
      case outcome.results do
        [%{} = reference | _] -> accumulate_coverage(acc, reference, run.sequence)
        _ -> acc
      end

    acc = record_sample(acc, ctx, run, outcome)

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
             last_run: Map.take(run, [:sequence, :run_seed, :run_number])
         }}

      _failure ->
        # The report carries the metrics measured up to this failed run.
        ctx = Map.put(ctx, :measured_metrics, campaign_metrics(ctx, acc.samples))
        handle_failure(ctx, lockstep_found(run, outcome, acc.fires, acc.expansion_counts))
    end
  end

  # Runs a generated linear sequence on every target. `run.seed` and
  # `run.run_number` derive the run's effective seed.
  defp schedule(ctx, run) do
    {:ok, outcome} =
      Scheduler.run(
        model: ctx.model,
        targets: ctx.targets,
        commands: Sequence.to_list(run.sequence),
        variants: Expansion.schedule(ctx.targets, run.expansion),
        setup_commands: run.sequence.setup,
        teardown_commands: run.sequence.teardown,
        placeholder_registry: run.sequence.registry,
        seed: run.seed,
        run_number: run.run_number,
        run_nonce: ctx.run_nonce,
        # The exploration run is epoch 0 (DR-034); shrink attempts and the
        # reproduction re-execution draw later epochs.
        mint_epoch: 0,
        concurrency: ctx.concurrency,
        compare: ctx.compare,
        measure_latency: ctx.measure_latency,
        stutter_config: ctx.stutter_config,
        check_mode: ctx.check_mode
      )

    outcome
  end

  # A branching sequence runs on the one target through the linear engine.
  defp run_branching(ctx, run, acc) do
    case execute_branching(ctx, run) do
      {:ok, result} = run_result ->
        Telemetry.sequence_stop(run.start, %{
          run_number: run.run_number,
          success: result.success,
          commands_executed: Sequence.command_count(run.sequence),
          variant: if(result.success, do: nil, else: variant_of(ctx.target))
        })

        acc = accumulate_coverage(acc, result, run.sequence)

        if result.success do
          {:pass,
           %{
             acc
             | total_commands: acc.total_commands + Sequence.command_count(run.sequence),
               setup_commands: acc.setup_commands + length(run.sequence.setup),
               teardown_commands: acc.teardown_commands + length(run.sequence.teardown)
           }}
        else
          handle_failure(ctx, branching_found(ctx, run, run_result, acc.fires))
        end

      # Executor.run returns {:error, reason} when the adapter's setup/1
      # fails: a setup failure of the one target, never shrunk.
      {:error, _reason} = run_result ->
        handle_failure(ctx, branching_found(ctx, run, run_result, acc.fires))
    end
  end

  defp execute_branching(ctx, run) do
    target = ctx.target

    RunServices.with_services(target, fn event_queue, mock_registry ->
      Executor.run(run.sequence, ctx.model, target.adapter,
        config: target.config,
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
        mint_epoch: 0,
        telemetry: Telemetry.engine_context(variant_of(target), run.run_number),
        setup_commands: run.sequence.setup,
        teardown_commands: run.sequence.teardown
      )
    end)
  end

  # A failure a run found, in one shape for the lockstep and the branching path:
  # the run that found it (sequence, effective seed, run number), the whole-run
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
      result: Enum.at(outcome.results, outcome.failure.variant.index)
    }
  end

  defp branching_found(ctx, run, run_result, fires) do
    {failure, result} =
      case run_result do
        {:ok, result} ->
          {%{
             kind: FailureReport.kind_of(result.failure_reason),
             variant: variant_of(ctx.target),
             root: result.failed_at_index,
             reason: result.failure_reason,
             stacktrace: result.stacktrace
           }, result}

        {:error, reason} ->
          {%{
             kind: :setup_failed,
             variant: variant_of(ctx.target),
             root: nil,
             reason: Failure.setup_failed(reason),
             stacktrace: nil
           }, nil}
      end

    %{
      sequence: run.sequence,
      expansion: nil,
      expansion_counts: %{},
      run_seed: run.run_seed,
      run_number: run.run_number,
      fires: fires,
      compare_counts: Comparison.zero_counts(ctx.model),
      failure: failure,
      other_failures: [],
      result: result
    }
  end

  defp variant_of(target), do: %{index: target.index, name: target.name}

  # Under `latency:`, each run at or after the warm-up contributes its
  # per-target timings to the metrics.
  defp record_sample(%{samples: samples} = acc, ctx, run, outcome) do
    if ctx.measure_latency and run.run_number >= Keyword.fetch!(ctx.latency_budget, :warmup) do
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
  defp campaign_metrics(%{measure_latency: false}, _samples), do: nil
  defp campaign_metrics(ctx, samples), do: LatencyMetrics.calculate(ctx.targets, samples)

  defp put_metrics(stats, nil), do: stats
  defp put_metrics(stats, metrics), do: Map.put(stats, :metrics, metrics)

  # The run's sequence: its setup commands and roots from the run seed, then
  # its teardown commands drawn against the state the roots leave.
  defp generate_one(ctx, run_seed) do
    sequence = Generator.generate_value(ctx.generator, run_seed)
    Generator.teardown_commands(ctx.model, sequence, run_seed)
  end

  # Every target's concrete sequence for a generated linear sequence: the roots
  # with each target's expansions realized, before any target is set up. A
  # branching run has one target and runs its sequence as generated.
  defp expand(%{branching: branching}, _sequence, _run_seed) when branching != nil, do: nil

  defp expand(ctx, sequence, run_seed) do
    if Expansion.defines?(ctx.model),
      do: Expansion.expand(ctx.model, sequence, ctx.targets, run_seed),
      else: Expansion.identity(sequence, ctx.targets)
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

  # Injector wiring for `execute/2`, shared with PropertyDamage.Variant.
  defp setup_injectors(injectors, event_queue),
    do: RunServices.setup_injectors(injectors, event_queue)

  defp teardown_injectors(injectors), do: RunServices.teardown_injectors(injectors)

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
  # commands included, on every target (through the lockstep scheduler, or the
  # linear engine for a branching run). A failure, when this seed is the
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

      {:failed, %{failure: %{kind: :setup_failed}} = found} ->
        {:error, report} = handle_failure(ctx, found)
        {:setup_failed, report}

      {:failed, found} ->
        {:fail, replay_refresh(found.failure.reason), replay_report(ctx, found, build_rep?)}
    end
  end

  # Replay is a pre-exploration phase; whole-run anti-vacuity coverage is an
  # exploration concern, so no firings are accumulated here.
  defp replay_run(ctx, run) do
    if ctx.branching do
      case execute_branching(ctx, run) do
        {:ok, %{success: true}} -> :passed
        run_result -> {:failed, branching_found(ctx, run, run_result, %{})}
      end
    else
      outcome = schedule(ctx, run)

      if outcome.failure,
        do: {:failed, lockstep_found(run, outcome, %{}, Expansion.counts(run.expansion))},
        else: :passed
    end
  end

  defp replay_report(ctx, found, true) do
    {:error, report} = handle_failure(ctx, found)
    report
  end

  defp replay_report(_ctx, _found, false), do: nil

  # Refresh descriptive metadata from the new failure. Keep the prior
  # failure_type if the reason did not classify (nil); check_name is
  # legitimately nil for many failure types, so it is refreshed as-is.
  defp replay_refresh(reason) do
    {failure_type, check_name} = FailureReport.classify_reason(reason)
    [check_name: check_name] ++ if(failure_type, do: [failure_type: failure_type], else: [])
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

  # The failure path of every run, for one target or several: shrink the
  # sequence, reproduce the shrunk sequence once, and report. A target's setup
  # failure implicates no command, so it is reported as found, unshrunk.
  defp handle_failure(ctx, %{failure: %{kind: :setup_failed}} = found) do
    report_failure(ctx, failure_report(ctx, found, :found))
  end

  defp handle_failure(ctx, found) do
    # One mint-epoch source for this whole logical run (DR-034): shrink attempts
    # and the reproduction re-execution below all draw from it, so no two SUT
    # executions in this run send the same client-minted values on a
    # non-resettable SUT. Epoch 0 was the exploration run.
    mint_epoch_counter = :atomics.new(1, signed: false)

    {shrunk_sequence, shrink_iterations, shrink_time_ms} =
      if ctx.shrink do
        shrink_result =
          Shrinker.shrink(found.sequence,
            failed_at_index: found.failure.root,
            failure_reason: found.failure.reason,
            variant_index: found.failure.variant.index,
            model: ctx.model,
            targets: ctx.targets,
            concurrency: ctx.concurrency,
            compare: ctx.compare,
            check_mode: ctx.check_mode,
            config: ctx.shrinker_config,
            # Stutter failures are shrinkable (DR-029): the shrinker reproduces
            # them with stutter forced on (probability 1.0), so they minimize to
            # the offending command rather than being skipped.
            stutter_config: ctx.stutter_config,
            # The run's effective seed: every attempt runs as run 0 of it, so
            # the per-target RNG and the stutter base track the original run.
            rng_seed: found.run_seed,
            run_nonce: ctx.run_nonce,
            mint_epoch_counter: mint_epoch_counter
          )

        {shrink_result.sequence, shrink_result.iterations, shrink_result.time_ms}
      else
        {found.sequence, 0, 0}
      end

    shrink = %{iterations: shrink_iterations, time_ms: shrink_time_ms}

    # Re-execute the shrunk sequence to get fresh state (the original result has
    # state from before shrinking). The reproduction is a fresh SUT execution:
    # it gets its own mint epoch from the shared counter (DR-034).
    fresh_epoch = :atomics.add_get(mint_epoch_counter, 1, 1)

    # Normally the re-execution reproduces the failure on the (possibly smaller)
    # shrunk sequence, giving the report fresh state and a minimal repro. But an
    # intermittent failure may not reproduce on this single re-run, or may fail
    # differently (another kind, another target). Then the report falls back to
    # the original failing run: its sequence, reason, index, target and state.
    expansion = reproduction_expansion(ctx, shrunk_sequence, found)

    report =
      case reproduce(ctx, shrunk_sequence, found, fresh_epoch, expansion) do
        {:reproduced, failure, result, other_failures} ->
          reproduced = %{
            found
            | failure: failure,
              result: result,
              other_failures: other_failures,
              expansion: expansion
          }

          failure_report(ctx, reproduced, {:shrunk, shrunk_sequence, fresh_epoch, shrink})

        # A passing re-run, or a re-execution whose adapter setup failed: not
        # a reproduction.
        _not_reproduced ->
          failure_report(ctx, found, {:fallback, shrink})
      end

    report_failure(ctx, report)
  end

  # Runs the shrunk sequence once: a linear sequence on every target through
  # the scheduler, a branching one on the one target through the linear engine,
  # each with its own services. For a stutter failure, stutter is forced on
  # with the run's seed so the fresh state carries the reproduced violation
  # (DR-029). Returns `{:reproduced, failure, result, other_failures}` when its
  # primary failure has the found failure's signature (kind, name, target),
  # whatever its other failures, `{:setup_failed, reason}`
  # when a target's setup failed, else `:not_reproduced`.
  defp reproduce(ctx, sequence, found, epoch, expansion \\ nil)

  defp reproduce(ctx, %Sequence{branches: nil} = sequence, found, epoch, expansion) do
    {:ok, outcome} =
      Scheduler.run(
        model: ctx.model,
        targets: ctx.targets,
        commands: Sequence.to_list(sequence),
        variants: expansion && Expansion.schedule(ctx.targets, expansion),
        setup_commands: sequence.setup,
        teardown_commands: sequence.teardown,
        placeholder_registry: sequence.registry,
        seed: found.run_seed,
        run_number: 0,
        run_nonce: ctx.run_nonce,
        mint_epoch: epoch,
        concurrency: ctx.concurrency,
        compare: ctx.compare,
        stutter_config: repro_stutter_config(found.failure.reason, ctx.stutter_config),
        check_mode: ctx.check_mode
      )

    case outcome.failure do
      nil ->
        :not_reproduced

      %{kind: :setup_failed, reason: reason} ->
        {:setup_failed, reason}

      failure ->
        if same_failure?(failure, found.failure),
          do:
            {:reproduced, failure, Enum.at(outcome.results, failure.variant.index),
             outcome.other_failures},
          else: :not_reproduced
    end
  end

  defp reproduce(ctx, sequence, found, epoch, _expansion) do
    target = ctx.target

    run_result =
      RunServices.with_services(target, fn event_queue, mock_registry ->
        Executor.run(sequence, ctx.model, target.adapter,
          config: target.config,
          event_queue: event_queue,
          mock_registry: mock_registry,
          stutter_config: repro_stutter_config(found.failure.reason, ctx.stutter_config),
          rng_seed: found.run_seed,
          run_nonce: ctx.run_nonce,
          mint_epoch: epoch,
          telemetry: Telemetry.engine_context(variant_of(target), found.run_number),
          setup_commands: sequence.setup,
          teardown_commands: sequence.teardown
        )
      end)

    case run_result do
      {:ok, %{success: false, failure_reason: %Failure{type: %Failure.Setup{}} = reason}} ->
        {:setup_failed, reason}

      {:ok, %{success: false, failure_reason: %Failure{} = reason} = result} ->
        failure = %{
          found.failure
          | root: result.failed_at_index,
            reason: reason,
            stacktrace: result.stacktrace
        }

        if same_failure?(failure, found.failure),
          do: {:reproduced, failure, result, []},
          else: :not_reproduced

      {:error, reason} ->
        {:setup_failed, Failure.setup_failed(reason)}

      _passed ->
        :not_reproduced
    end
  end

  # What every target runs when the shrunk sequence is reproduced: the run's
  # own concrete sequences when shrinking kept the sequence, else every root
  # as itself.
  defp reproduction_expansion(_ctx, _sequence, %{expansion: nil}), do: nil
  defp reproduction_expansion(_ctx, sequence, %{sequence: sequence} = found), do: found.expansion

  defp reproduction_expansion(ctx, sequence, _found),
    do: Expansion.identity(sequence, ctx.targets)

  defp same_failure?(failure, found_failure) do
    Shrinker.failure_signature(failure.reason, failure.variant.index) ==
      Shrinker.failure_signature(found_failure.reason, found_failure.variant.index)
  end

  # The report of a found failure. `:found` reports it as the run found it (no
  # shrinking); `{:fallback, shrink}` likewise, after a shrink whose result did
  # not reproduce; `{:shrunk, sequence, epoch, shrink}` reports the reproduction
  # of the shrunk sequence (`found` then holds the reproduction's failure and
  # result).
  defp failure_report(ctx, found, how) do
    {shrunk_sequence, plan_source, mint_epoch, shrink} =
      case how do
        :found -> {found.sequence, :generated, 0, %{iterations: 0, time_ms: 0}}
        {:fallback, shrink} -> {found.sequence, :generated, 0, shrink}
        {:shrunk, sequence, epoch, shrink} -> {sequence, :shrunk, epoch, shrink}
      end

    result = found.result || %{}
    failure = found.failure

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
      failure_reason: failure.reason,
      kind: failure.kind,
      variant: failure.variant,
      shrink_iterations: shrink.iterations,
      shrink_time_ms: shrink.time_ms,
      event_log: Map.get(result, :event_log, []),
      projections: Map.get(result, :projections, %{}),
      projections_before: Map.get(result, :projections_before),
      command_fold_ordinals: Map.get(result, :command_fold_ordinals, %{}),
      linearization: Map.get(result, :linearization),
      stacktrace: failure.stacktrace,
      model: ctx.model,
      targets: ctx.target_entries,
      concurrency: ctx.concurrency,
      compare: ctx.compare,
      stutter: ctx.stutter,
      max_commands: ctx.max_commands,
      check_fires: found.fires,
      other_failures: Enum.map(found.other_failures, &other_failure/1),
      compare_counts: found.compare_counts,
      expansion: report_expansion(ctx, found, shrunk_sequence),
      expansion_counts: found.expansion_counts,
      latency: Map.get(ctx, :latency, false),
      metrics: Map.get(ctx, :measured_metrics)
    )
  end

  # The concrete sequences of the run the report describes; a branching run
  # ran its one target's roots as generated.
  defp report_expansion(_ctx, %{expansion: %{} = expansion}, _sequence), do: expansion
  defp report_expansion(ctx, _found, sequence), do: Expansion.identity(sequence, [ctx.target])

  defp other_failure(failure),
    do: %{variant: failure.variant, root: failure.root, failure: failure.reason}

  # Announces a failure report and returns it as the run's result.
  defp report_failure(ctx, failure_report) do
    # Terminal failure notification (DR-022): the verbose consumer renders this
    # as the failure summary. The authoritative result is the returned report.
    Reporter.emit(ctx.reporter, fn ->
      %RunResult{
        outcome: :error,
        failure: failure_report,
        kind: failure_report.kind,
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

  The re-shrink runs exactly as the run's own shrinking does: every candidate
  runs on every target through the lockstep scheduler, and a candidate counts
  only if it fails with the report's kind, check name and failing target. The
  smaller sequence is then reproduced once; a report whose shrunk sequence does
  not reproduce comes back unchanged. A `:setup_failed` report implicates no
  command and comes back unchanged.

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
  - `:targets` - One or more target entries overriding the systems to
    re-execute against, reference first (default: the report's `targets`); see
    `PropertyDamage.Target`
  - `:concurrency` - `:serial` or `:parallel`, as on `PropertyDamage.run/1`
    (default: the report's `concurrency`)
  - `:compare` - `[converge_within: ms]`, as on `PropertyDamage.run/1`
    (default: the report's `compare`)

  The re-shrink also uses the report's `stutter` configuration: a stutter
  failure re-runs with stutter forced on, as the run's own shrink does.

  ## Returns

  - `{:ok, new_failure_report}` - Shrinking succeeded, possibly smaller sequence
  - `{:error, reason}` - Shrinking failed: `:missing_model_or_adapter` when the
    report records no model or no target, or the setup `%PropertyDamage.Failure{}`
    when a target's adapter `setup/1` fails on the re-execution

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
    cond do
      is_nil(report.model) or is_nil(FailureReport.reference_target(report)) ->
        {:error, :missing_model_or_adapter}

      report.kind in [:setup_failed, :latency_exceeded] ->
        {:ok, report}

      true ->
        targets = Options.override_targets!(opts, report.targets)

        do_shrink_further(report, targets, opts)
    end
  end

  defp do_shrink_further(report, targets, opts) do
    strategy = Keyword.get(opts, :strategy, :thorough)

    ctx = %{
      model: report.model,
      targets: targets,
      target: hd(targets),
      # Carry the original run's nonce (DR-034) so re-shrinking mints the same
      # class of run-scoped values.
      run_nonce: report.trace && report.trace.run_nonce,
      concurrency: Keyword.get(opts, :concurrency, report.concurrency),
      compare: shrink_further_compare(report, opts),
      stutter: report.stutter,
      stutter_config: Stutter.parse_config(report.stutter),
      check_mode: :halt
    }

    found = %{
      sequence: FailureReport.shrunk_sequence(report),
      run_seed: report.seed,
      run_number: report.run_number,
      failure: %{
        kind: report.kind,
        variant: report.variant || variant_of(ctx.target),
        root: report.failed_at_index,
        reason: report.failure_reason,
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
        concurrency: ctx.concurrency,
        compare: ctx.compare,
        # A stutter failure re-shrinks with stutter forced on (DR-029), as in
        # the run's own failure path.
        stutter_config: ctx.stutter_config,
        config:
          ShrinkerConfig.new(
            max_iterations: strategy_iterations(strategy, opts),
            max_time_ms: strategy_time(strategy, opts),
            shrink_arguments: Keyword.get(opts, :shrink_arguments, true),
            granularity_threshold: strategy_threshold(strategy)
          ),
        # The report's seed is the run's effective seed.
        rng_seed: report.seed,
        run_nonce: ctx.run_nonce,
        mint_epoch_counter: mint_epoch_counter
      )

    fresh_epoch = :atomics.add_get(mint_epoch_counter, 1, 1)

    # As in the run's failure path: only adopt the further-shrunk sequence on a
    # genuine reproduction. A re-execution that passes or fails differently
    # confirms nothing, so the incoming report comes back unchanged.
    case reproduce(ctx, shrink_result.sequence, found, fresh_epoch) do
      {:reproduced, failure, result, other_failures} ->
        elapsed = System.monotonic_time(:millisecond) - start_time

        {:ok,
         FailureReport.new(
           seed: report.seed,
           run_number: report.run_number,
           original_sequence: report.original_sequence,
           shrunk_sequence: shrink_result.sequence,
           failed_at_index: failure.root,
           failure_reason: failure.reason,
           kind: failure.kind,
           variant: failure.variant,
           shrink_iterations: report.shrink_iterations + shrink_result.iterations,
           shrink_time_ms: report.shrink_time_ms + elapsed,
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
           compare_counts: report.compare_counts,
           other_failures: Enum.map(other_failures, &other_failure/1),
           stutter: ctx.stutter,
           max_commands: report.max_commands,
           linearization: Map.get(result, :linearization),
           stacktrace: failure.stacktrace
         )}

      # A re-execution whose adapter setup fails cannot confirm a further
      # shrink; surface the setup failure.
      {:setup_failed, reason} ->
        {:error, reason}

      :not_reproduced ->
        {:ok, report}
    end
  end

  # The convergence bound of a re-shrink: the `compare:` option, validated as
  # on `run/1`, else the report's.
  defp shrink_further_compare(report, opts) do
    if Keyword.has_key?(opts, :equivalence) do
      raise ArgumentError,
            "`equivalence:` was removed; targets are compared only through `@compare` " <>
              "functions, each deciding agreement with its own `using:` predicate"
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
