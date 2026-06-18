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
        use PropertyDamage

        @model MyApp.TestModel
        @adapter MyApp.TestAdapter

        property_damage "system maintains invariants" do
          max_commands: 50,
          max_runs: 100
        end
      end

  ## Running Directly

      PropertyDamage.run(
        model: MyApp.TestModel,
        adapter: MyApp.TestAdapter,
        max_commands: 50,
        max_runs: 100
      )

  ## Debugging Failures

  When a test fails, PropertyDamage provides rich tools for understanding what went wrong:

      {:error, failure} = PropertyDamage.run(model: M, adapter: A)

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

  Track interesting seeds for regression testing:

      {:ok, library} = PropertyDamage.load_seed_library("seeds.json")
      {:ok, library} = PropertyDamage.add_to_seed_library(library, failure, tags: [:bug])
      PropertyDamage.save_seed_library(library, "seeds.json")

  See `PropertyDamage.SeedLibrary` for details.

  ## Coverage Metrics

  Track how thoroughly your model is being exercised:

      coverage = PropertyDamage.coverage(result, MyModel)
      IO.puts(PropertyDamage.Coverage.format(coverage))

  See `PropertyDamage.Coverage` for details.

  ## Flakiness Detection

  Detect non-deterministic behavior in your SUT:

      PropertyDamage.check_determinism(Model, Adapter, seed, runs: 10)
      flaky = PropertyDamage.discover_flaky_seeds(Model, Adapter, num_seeds: 20)

  See `PropertyDamage.Flakiness` for details.

  ## Architecture

  The framework consists of several layers:

  - **Tier 0 (Core Types)**: Ref, Command, Projection, Model behaviours
  - **Tier 1 (Execution)**: Adapter, EventQueue, InjectorAdapter, Executor
  - **Tier 2 (Shrinking)**: Validator, Shrinker, dependency graph
  - **Tier 3 (Analysis)**: Analysis, Replay, Coverage, Flakiness
  - **Utilities**: Persistence, SeedLibrary, mix tasks

  See the individual module documentation for detailed information on each component.
  """

  alias PropertyDamage.{
    EventQueue,
    Executor,
    FailureReport,
    Generator,
    Options,
    Progress.Printer,
    Progress.Reporter,
    Progress.RunResult,
    Progress.RunUpdate,
    Sequence,
    Shrinker,
    Stutter,
    Telemetry,
    Validation
  }

  alias PropertyDamage.Shrinker.Config, as: ShrinkerConfig

  @typedoc """
  Result statistics from a successful run.
  """
  @type stats :: %{
          runs: non_neg_integer(),
          total_commands: non_neg_integer(),
          seed: integer()
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
  - `:adapter` - Adapter module implementing PropertyDamage.Adapter

  ## Optional Options

  - `:max_commands` - Maximum commands per sequence (default: 50)
  - `:max_runs` - Number of test sequences to run (default: 100)
  - `:seed` - Random seed for reproducibility (default: random)
  - `:injector_adapters` - List of InjectorAdapter modules (default: [])
  - `:adapter_config` - Config passed to adapter.setup/1 (default: %{})
  - `:shrink` - Whether to shrink failing sequences (default: true)
  - `:shrinker_config` - ShrinkerConfig struct for tuning shrinking
  - `:on_failure` - Callback function receiving failure_report (default: nil)
  - `:regression` - Keyword list for automatic regression test management (see below)
  - `:verbose` - Print progress and configuration (default: false)
  - `:validate` - Run configuration validation first (default: true)
  - `:branching` - Keyword list for parallel branching (see below)
  - `:stutter` - Map for idempotency testing (see below)

  ## Branching Options

  Pass `branching: [...]` to generate branching (parallel) sequences:

  - `:branch_probability` - Probability of creating a branch point (default: 0.2)
  - `:max_branches` - Maximum number of parallel branches (default: 3)
  - `:max_branch_length` - Maximum commands per branch (default: 5)
  - `:min_prefix_length` - Minimum commands before branching (default: 3)

  Branching sequences enable detection of race conditions by executing
  commands in parallel branches and checking linearizability.

  ## Stutter Options (Idempotency Testing)

  Pass `stutter: %{...}` to enable idempotency testing:

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

  This option integrates with `:on_failure` - both can be used together.

  ## Returns

  - `{:ok, stats}` - All runs passed
  - `{:error, failure_report}` - A run failed

  ## Examples

      # Basic usage
      PropertyDamage.run(model: MyModel, adapter: MyAdapter)

      # With options
      PropertyDamage.run(
        model: MyModel,
        adapter: MyAdapter,
        max_commands: 100,
        max_runs: 1000,
        seed: 12345
      )

      # With failure callback
      PropertyDamage.run(
        model: MyModel,
        adapter: MyAdapter,
        on_failure: fn failure_report ->
          IO.puts("Failed at command \#{failure_report.failed_at_index}")
        end
      )

      # With automatic regression management
      PropertyDamage.run(
        model: MyModel,
        adapter: MyAdapter,
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
    adapter = opts[:adapter]
    max_commands = opts[:max_commands]
    max_runs = opts[:max_runs]
    seed = opts[:seed] || :rand.uniform(1_000_000_000)
    injector_adapters = opts[:injector_adapters]
    adapter_config = opts[:adapter_config]
    shrink = opts[:shrink]
    shrinker_config = opts[:shrinker_config] || ShrinkerConfig.new()
    on_failure = build_on_failure_callback(opts)
    verbose = opts[:verbose]
    validate = opts[:validate]
    branching = opts[:branching]
    stutter_config = Stutter.parse_config(opts[:stutter])

    # Unified progress projection (DR-022): one reporter fans out to the verbose
    # printer (if any), the user `on_progress:` callback (if any), and telemetry
    # (only when a handler is attached). With no consumers it is inert and the
    # run loop builds no %Progress{}.
    reporter =
      Reporter.new([
        if(verbose, do: Printer.consumer(model, adapter, opts)),
        opts[:on_progress],
        Telemetry.progress_consumer([:test_run])
      ])

    # Validate configuration
    if validate do
      {:ok, warnings} = Validation.validate!(model, adapter, injector_adapters: injector_adapters)

      if verbose do
        Validation.print_summary(model, adapter, warnings)
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

    # Setup once (if model implements it)
    setup_once_result =
      if function_exported?(model, :setup_once, 1) do
        model.setup_once(%{adapter_config: adapter_config})
      else
        :ok
      end

    case setup_once_result do
      :ok ->
        # Emit telemetry for run start
        telemetry_metadata = %{
          model: model,
          adapter: adapter,
          max_runs: max_runs,
          max_commands: max_commands,
          seed: seed
        }

        start_time = System.system_time()
        Telemetry.run_start(telemetry_metadata)

        try do
          result =
            do_run(
              model,
              adapter,
              max_commands,
              max_runs,
              seed,
              injector_adapters,
              adapter_config,
              shrink,
              shrinker_config,
              on_failure,
              reporter,
              branching,
              stutter_config
            )

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
            model.teardown_once(%{})
          end
        end

      {:error, reason} ->
        {:error, %{setup_once_failed: reason}}
    end
  end

  defp do_run(
         model,
         adapter,
         max_commands,
         max_runs,
         seed,
         injector_adapters,
         adapter_config,
         shrink,
         shrinker_config,
         on_failure,
         reporter,
         branching,
         stutter_config
       ) do
    # Seed the process RNG (consumed by execution-time randomness such as
    # stutter decisions; sequence generation is seeded explicitly per run
    # via Generator.generate_value/2, NOT through the process RNG)
    :rand.seed(:exsss, seed)

    # Campaign start (DR-022): the verbose consumer renders this as the header.
    Reporter.emit(reporter, fn ->
      %RunUpdate{phase: :start, run_number: 0, total_runs: max_runs}
    end)

    # Generate sequences and run
    generator_opts = [max_commands: max_commands]

    generator_opts =
      if branching, do: Keyword.put(generator_opts, :branching, branching), else: generator_opts

    generator = Generator.generate_sequence(model, generator_opts)

    run_loop(
      generator,
      model,
      adapter,
      max_runs,
      seed,
      injector_adapters,
      adapter_config,
      shrink,
      shrinker_config,
      on_failure,
      reporter,
      stutter_config,
      0,
      0
    )
  end

  defp run_loop(
         _generator,
         _model,
         _adapter,
         max_runs,
         seed,
         _injector_adapters,
         _adapter_config,
         _shrink,
         _shrinker_config,
         _on_failure,
         reporter,
         _stutter_config,
         run_number,
         total_commands
       )
       when run_number >= max_runs do
    stats = %{runs: max_runs, total_commands: total_commands, seed: seed}

    Reporter.emit(reporter, fn ->
      %RunResult{
        outcome: :ok,
        runs_completed: max_runs,
        total_commands: total_commands,
        seed: seed
      }
    end)

    {:ok, stats}
  end

  defp run_loop(
         generator,
         model,
         adapter,
         max_runs,
         seed,
         injector_adapters,
         adapter_config,
         shrink,
         shrinker_config,
         on_failure,
         reporter,
         stutter_config,
         run_number,
         total_commands
       ) do
    # Generate a command sequence, deterministically derived from the seed.
    # Run 0 uses the base seed itself so a reported seed reproduces exactly
    # with max_runs: 1.
    run_seed = Generator.run_seed(seed, run_number)
    sequence = generate_one(generator, run_seed)
    command_count = Sequence.command_count(sequence)

    # Per-run heartbeat (DR-022). run_number is reported 1-based for consumers.
    Reporter.emit(reporter, fn ->
      %RunUpdate{
        phase: :run,
        run_number: run_number + 1,
        total_runs: max_runs,
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

    # Setup each (if model implements it)
    setup_each_result =
      if function_exported?(model, :setup_each, 1) do
        model.setup_each(%{adapter_config: adapter_config, run_number: run_number})
      else
        :ok
      end

    case setup_each_result do
      :ok ->
        # Start event queue for injectors
        {:ok, event_queue} = EventQueue.start_link()

        # Setup injector adapters
        setup_injectors(injector_adapters, event_queue)

        try do
          # Execute the sequence
          {:ok, result} =
            Executor.run(sequence, model, adapter,
              adapter_config: adapter_config,
              event_queue: event_queue,
              stutter_config: stutter_config
            )

          # Emit telemetry for sequence stop
          Telemetry.sequence_stop(seq_start_time, %{
            run_number: run_number,
            success: result.success,
            commands_executed: command_count
          })

          if result.success do
            # Success - continue to next run
            run_loop(
              generator,
              model,
              adapter,
              max_runs,
              seed,
              injector_adapters,
              adapter_config,
              shrink,
              shrinker_config,
              on_failure,
              reporter,
              stutter_config,
              run_number + 1,
              total_commands + command_count
            )
          else
            # Failure - shrink and report. Pass the run's EFFECTIVE seed so
            # the report's "reproduce with this seed" is exact (run 0 of a
            # reproduction derives the identical sequence from it).
            handle_failure(
              sequence,
              result,
              model,
              adapter,
              adapter_config,
              event_queue,
              shrink,
              shrinker_config,
              on_failure,
              reporter,
              run_seed,
              run_number
            )
          end
        after
          # Teardown injectors
          teardown_injectors(injector_adapters)
          EventQueue.stop(event_queue)

          # Teardown each
          if function_exported?(model, :teardown_each, 1) do
            model.teardown_each(%{})
          end
        end

      {:error, reason} ->
        {:error, %{setup_each_failed: reason, run_number: run_number}}
    end
  end

  defp generate_one(generator, run_seed) do
    Generator.generate_value(generator, run_seed)
  end

  defp setup_injectors(injector_adapters, event_queue) do
    for adapter <- injector_adapters do
      if function_exported?(adapter, :setup, 1) do
        adapter.setup(%{event_queue: event_queue})
      end
    end
  end

  defp teardown_injectors(injector_adapters) do
    for adapter <- injector_adapters do
      if function_exported?(adapter, :teardown, 1) do
        adapter.teardown(%{})
      end
    end
  end

  defp handle_failure(
         sequence,
         result,
         model,
         adapter,
         adapter_config,
         event_queue,
         shrink,
         shrinker_config,
         on_failure,
         reporter,
         seed,
         run_number
       ) do
    # Skip shrinking for stutter-related failures since:
    # 1. The failure is about SUT idempotency, not the command sequence
    # 2. Shrinking without stutter won't reproduce the failure
    should_shrink = shrink and not stutter_failure?(result.failure_reason)

    {shrunk_sequence, shrink_iterations, shrink_time_ms} =
      if should_shrink do
        shrink_result =
          Shrinker.shrink(sequence,
            failed_at_index: result.failed_at_index,
            failure_reason: result.failure_reason,
            model: model,
            adapter: adapter,
            adapter_config: adapter_config,
            config: shrinker_config,
            event_queue: event_queue
          )

        {shrink_result.sequence, shrink_result.iterations, shrink_result.time_ms}
      else
        {sequence, 0, 0}
      end

    # Re-execute shrunk sequence to get fresh event log and state
    # (the original result has state from before shrinking)
    {:ok, fresh_result} =
      Executor.run(shrunk_sequence, model, adapter,
        adapter_config: adapter_config,
        event_queue: event_queue
      )

    # Create rich failure report with fresh state from shrunk sequence
    failure_report =
      FailureReport.new(
        seed: seed,
        run_number: run_number,
        original_sequence: sequence,
        shrunk_sequence: shrunk_sequence,
        failed_at_index: fresh_result.failed_at_index,
        failure_reason: fresh_result.failure_reason,
        shrink_iterations: shrink_iterations,
        shrink_time_ms: shrink_time_ms,
        event_log: fresh_result.event_log,
        projections: fresh_result.projections,
        projections_before: fresh_result.projections_before,
        model: model,
        adapter: adapter,
        linearization: fresh_result.linearization,
        stacktrace: Map.get(fresh_result, :stacktrace)
      )

    # Terminal failure notification (DR-022): the verbose consumer renders this
    # as the failure summary. The authoritative result is the returned report.
    Reporter.emit(reporter, fn ->
      %RunResult{outcome: :error, failure: failure_report}
    end)

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
  defp stutter_failure?({:idempotency_violation, _}), do: true
  defp stutter_failure?({:stutter_execution_failed, _}), do: true
  defp stutter_failure?(_), do: false

  # Build the on_failure callback from :on_failure and :regression options
  defp build_on_failure_callback(opts) do
    on_failure = Keyword.get(opts, :on_failure)
    regression = Keyword.get(opts, :regression)

    cond do
      # Both options specified - compose them
      on_failure != nil and regression != nil ->
        regression_handler = PropertyDamage.Regression.handler(regression)

        fn failure_report ->
          on_failure.(failure_report)
          regression_handler.(failure_report)
        end

      # Only on_failure specified
      on_failure != nil ->
        on_failure

      # Only regression specified
      regression != nil ->
        PropertyDamage.Regression.handler(regression)

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

  - `:max_iterations` - Maximum shrink attempts (default: 5000)
  - `:max_time_ms` - Maximum time for shrinking in ms (default: 60000)
  - `:strategy` - Shrinking strategy (default: :thorough)
    - `:quick` - Fast shrinking, may miss some reductions
    - `:thorough` - Balanced approach (default)
    - `:exhaustive` - Try all possible reductions (slow)
  - `:shrink_arguments` - Whether to shrink argument values (default: true)
  - `:adapter_config` - Adapter configuration (uses report's adapter if not specified)

  ## Returns

  - `{:ok, new_failure_report}` - Shrinking succeeded, possibly smaller sequence
  - `{:error, reason}` - Shrinking failed (e.g., missing model/adapter)

  ## Example

      {:error, failure} = PropertyDamage.run(model: M, adapter: A)

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
    adapter = report.adapter

    if is_nil(model) or is_nil(adapter) do
      {:error, :missing_model_or_adapter}
    else
      adapter_config = Keyword.get(opts, :adapter_config, %{})

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

        # Perform shrinking on the already-shrunk sequence
        shrink_result =
          Shrinker.shrink(report.shrunk_sequence,
            failed_at_index: report.failed_at_index,
            failure_reason: report.failure_reason,
            model: model,
            adapter: adapter,
            adapter_config: adapter_config,
            config: shrinker_config,
            event_queue: event_queue
          )

        # Re-execute to get fresh state
        {:ok, fresh_result} =
          Executor.run(shrink_result.sequence, model, adapter,
            adapter_config: adapter_config,
            event_queue: event_queue
          )

        end_time = System.monotonic_time(:millisecond)

        # Create updated failure report
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
            projections: fresh_result.projections,
            projections_before: fresh_result.projections_before,
            model: model,
            adapter: adapter,
            linearization: fresh_result.linearization,
            stacktrace: Map.get(fresh_result, :stacktrace)
          )

        {:ok, new_report}
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

      {:error, failure} = PropertyDamage.run(model: M, adapter: A)

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

  - `:adapter_config` - Override adapter configuration
  - `:stop_on_failure` - Stop at first failure (default: true)

  ## Example

      {:error, failure} = PropertyDamage.run(model: M, adapter: A)
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

      {:error, failure} = PropertyDamage.run(model: M, adapter: A)
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

  ## Example

      result = PropertyDamage.run(model: M, adapter: A)
      coverage = PropertyDamage.coverage(result, M)
      IO.puts(PropertyDamage.Coverage.format(coverage))
  """
  @spec coverage({:ok, map()} | {:error, FailureReport.t()}, module()) ::
          PropertyDamage.Coverage.t()
  defdelegate coverage(result, model), to: PropertyDamage.Coverage, as: :from_result

  # ============================================================================
  # Flakiness Detection API
  # ============================================================================

  @doc """
  Check if a seed produces deterministic results.

  Runs the same seed multiple times to detect non-deterministic behavior
  in the system under test.

  ## Options

  - `:runs` - Number of times to run (default: 5)
  - `:adapter_config` - Adapter configuration
  - `:max_commands` - Maximum commands per run (default: 50)
  - `:verbose` - Print progress (default: false)

  ## Returns

  - `{:ok, :deterministic}` - Same result every time
  - `{:ok, :flaky, stats}` - Different results, with statistics
  - `{:error, reason}` - Check failed

  ## Example

      case PropertyDamage.check_determinism(M, A, 512902757, runs: 10) do
        {:ok, :deterministic} ->
          IO.puts("Seed is deterministic")

        {:ok, :flaky, stats} ->
          IO.puts("FLAKY: passed \#{stats.passes}/\#{stats.runs} times")
      end
  """
  @spec check_determinism(module(), module(), integer(), keyword()) ::
          PropertyDamage.Flakiness.result()
  defdelegate check_determinism(model, adapter, seed, opts \\ []),
    to: PropertyDamage.Flakiness,
    as: :check

  @doc """
  Discover flaky seeds by testing random seeds.

  ## Options

  - `:num_seeds` - Number of random seeds to test (default: 10)
  - `:runs_per_seed` - Runs per seed (default: 3)
  - `:verbose` - Print progress (default: false)

  ## Returns

  List of `{seed, flaky_stats}` for seeds that are flaky.

  ## Example

      flaky_seeds = PropertyDamage.discover_flaky_seeds(M, A, num_seeds: 20)
      IO.puts("Found \#{length(flaky_seeds)} flaky seeds")
  """
  @spec discover_flaky_seeds(module(), module(), keyword()) ::
          [{integer(), PropertyDamage.Flakiness.flaky_stats()}]
  defdelegate discover_flaky_seeds(model, adapter, opts \\ []),
    to: PropertyDamage.Flakiness,
    as: :discover_flaky

  # ============================================================================
  # Assertion Helpers
  # ============================================================================

  @doc """
  Convenience function to fail an assertion with a message and optional data.

  Use this in projection assertions when you don't need a custom exception type.

  ## Examples

      # Simple failure
      PropertyDamage.fail!("balance is negative")

      # With context data
      PropertyDamage.fail!("balance is negative", balance: -50, account_id: "acc_123")

      # In a projection assertion
      @trigger every: 1
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
    raise %PropertyDamage.AssertionFailed{message: message, data: Map.new(data)}
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

  - `:adapter` - Adapter module (required)
  - `:injector_adapters` - List of injector adapter modules (default: `[]`)
  - `:adapter_config` - Config passed to `adapter.setup/1` (default: `%{}`)

  ## Returns

  - `{:ok, event_log}` - List of `EventLog.Entry` structs containing all events
  - `{:error, {:adapter_error, reason, partial_events}}` - Adapter failed

  ## Example

      # Simple execution
      commands = [
        %CreateUser{name: "alice"},
        %CreateOrder{user_id: 1, amount: 100}
      ]

      {:ok, events} = PropertyDamage.execute(commands, adapter: MyAdapter)

      # Assert on returned events
      assert length(events) == 2
      assert hd(events).event.__struct__ == UserCreated

  ## With Injector Adapters

  When testing end-to-end flows with webhooks or async callbacks:

      {:ok, events} = PropertyDamage.execute(commands,
        adapter: MyAdapter,
        injector_adapters: [WebhookAdapter],
        adapter_config: %{base_url: "http://localhost:4000"}
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

    adapter = opts[:adapter]
    injector_adapters = opts[:injector_adapters]
    adapter_config = opts[:adapter_config]

    # Start event queue for injectors
    {:ok, event_queue} = EventQueue.start_link()

    # Setup injector adapters
    setup_injectors(injector_adapters, event_queue)

    # Setup main adapter
    case adapter.setup(adapter_config) do
      {:ok, adapter_context} ->
        context = %{
          adapter_context: adapter_context,
          event_queue: event_queue
        }

        sequence = Sequence.linear(commands)

        try do
          Executor.execute_raw(sequence, adapter, context)
        after
          # Cleanup
          adapter.teardown(adapter_context)
          teardown_injectors(injector_adapters)
          EventQueue.stop(event_queue)
        end

      {:error, reason} ->
        # Cleanup event queue and injectors on setup failure
        teardown_injectors(injector_adapters)
        EventQueue.stop(event_queue)
        {:error, {:adapter_setup_failed, reason}}
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
     placeholder out of state in the model's `with:` function. During
     generation the projection holds placeholders, which
     `PropertyDamage.Generator.external_from/2` surfaces as a seeded choice:

      # in the model's command list
      {ViewOrder,
       when: fn state -> map_size(state.orders) > 0 end,
       with: fn state ->
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

  @doc false
  defmacro __using__(_opts) do
    quote do
      import PropertyDamage, only: []

      Module.register_attribute(__MODULE__, :property_damage_model, persist: true)
      Module.register_attribute(__MODULE__, :property_damage_adapter, persist: true)
    end
  end
end
