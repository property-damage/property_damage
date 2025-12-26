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

  ## Architecture

  The framework consists of several layers:

  - **Tier 0 (Core Types)**: Ref, Command, Projection, Model behaviours
  - **Tier 1 (Execution)**: Adapter, EventQueue, InjectorAdapter, Executor
  - **Tier 2 (Shrinking)**: Validator, Shrinker, dependency graph
  - **Tier 3 (Integration)**: Main API, ExUnit integration, validation

  See the individual module documentation for detailed information on each component.
  """

  alias PropertyDamage.{
    Generator,
    Executor,
    Shrinker,
    Validation,
    EventQueue,
    Sequence,
    Stutter,
    FailureReport
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
  """
  @spec run(keyword()) :: {:ok, stats()} | {:error, failure_report()}
  def run(opts) do
    model = Keyword.fetch!(opts, :model)
    adapter = Keyword.fetch!(opts, :adapter)

    max_commands = Keyword.get(opts, :max_commands, 50)
    max_runs = Keyword.get(opts, :max_runs, 100)
    seed = Keyword.get(opts, :seed, :rand.uniform(1_000_000_000))
    injector_adapters = Keyword.get(opts, :injector_adapters, [])
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    shrink = Keyword.get(opts, :shrink, true)
    shrinker_config = Keyword.get(opts, :shrinker_config, ShrinkerConfig.new())
    on_failure = Keyword.get(opts, :on_failure)
    verbose = Keyword.get(opts, :verbose, false)
    validate = Keyword.get(opts, :validate, true)
    branching = Keyword.get(opts, :branching)
    stutter_config = Stutter.parse_config(Keyword.get(opts, :stutter))

    # Validate configuration
    if validate do
      {:ok, warnings} = Validation.validate!(model, adapter, injector_adapters: injector_adapters)

      if verbose do
        Validation.print_summary(model, adapter, warnings)
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
        try do
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
            verbose,
            branching,
            stutter_config
          )
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
         verbose,
         branching,
         stutter_config
       ) do
    # Seed the RNG
    :rand.seed(:exsss, {seed, seed, seed})

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
      verbose,
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
         _verbose,
         _stutter_config,
         run_number,
         total_commands
       )
       when run_number >= max_runs do
    {:ok, %{runs: max_runs, total_commands: total_commands, seed: seed}}
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
         verbose,
         stutter_config,
         run_number,
         total_commands
       ) do
    # Generate a command sequence
    sequence = generate_one(generator)
    command_count = Sequence.command_count(sequence)

    if verbose do
      branch_info =
        if Sequence.branching?(sequence),
          do: " (#{Sequence.branch_count(sequence)} branches)",
          else: ""

      IO.puts("Run #{run_number + 1}/#{max_runs}: #{command_count} commands#{branch_info}")
    end

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
              verbose,
              stutter_config,
              run_number + 1,
              total_commands + command_count
            )
          else
            # Failure - shrink and report
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
              seed,
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

  defp generate_one(generator) do
    # Use StreamData's internal generation to get a single value
    case Enumerable.reduce(generator, {:cont, nil}, fn val, _ -> {:halt, val} end) do
      {:halted, value} -> value
      {:done, _} -> []
    end
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

    # Create rich failure report
    failure_report =
      FailureReport.new(
        seed: seed,
        run_number: run_number,
        original_sequence: sequence,
        shrunk_sequence: shrunk_sequence,
        failed_at_index: result.failed_at_index,
        failure_reason: result.failure_reason,
        shrink_iterations: shrink_iterations,
        shrink_time_ms: shrink_time_ms,
        event_log: result.event_log,
        projections: result.projections,
        refs: result.refs,
        model: model,
        adapter: adapter,
        linearization: result.linearization
      )

    if on_failure do
      on_failure.(failure_report)
    end

    {:error, failure_report}
  end

  # Check if a failure reason is stutter-related (idempotency violation or execution failure)
  defp stutter_failure?({:idempotency_violation, _}), do: true
  defp stutter_failure?({:stutter_execution_failed, _}), do: true
  defp stutter_failure?(_), do: false

  @doc false
  defmacro __using__(_opts) do
    quote do
      import PropertyDamage, only: []

      Module.register_attribute(__MODULE__, :property_damage_model, persist: true)
      Module.register_attribute(__MODULE__, :property_damage_adapter, persist: true)
    end
  end
end
