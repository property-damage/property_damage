defmodule PropertyDamage.Differential do
  @moduledoc """
  Differential testing for comparing multiple implementations.

  Differential testing runs the same command sequences against multiple targets
  (adapters) and compares results. This enables:

  - **Oracle testing**: Compare SUT against a reference implementation
  - **Performance comparison**: Compare latency/throughput across implementations
  - **Regression testing**: Compare old vs new versions
  - **Migration validation**: Compare legacy vs new systems

  ## Basic Usage

      # Oracle testing (correctness comparison)
      PropertyDamage.Differential.run(
        model: MyModel,
        targets: [
          {OracleAdapter, role: :reference},
          {SUTAdapter, name: "new-impl"}
        ],
        compare: :correctness
      )

      # Performance comparison
      PropertyDamage.Differential.run(
        model: MyModel,
        targets: [
          {ImplA, name: "redis-backend"},
          {ImplB, name: "postgres-backend"}
        ],
        compare: :performance
      )

  ## Same Adapter, Different Configurations

  A key use case is comparing the same adapter with different configurations:

      PropertyDamage.Differential.run(
        model: MyModel,
        targets: [
          {HTTPAdapter, role: :reference, opts: [base_url: "https://prod.example.com"]},
          {HTTPAdapter, name: "staging", opts: [base_url: "https://staging.example.com"]}
        ],
        compare: :correctness
      )

  ## Time-Separated Execution

  Run against one system now, save results, compare later:

      # Save baseline
      PropertyDamage.Differential.run(
        model: MyModel,
        targets: [{ProdAdapter, name: "v2.3"}],
        compare: :performance,
        export_to: "baselines/v2.3.json"
      )

      # Later, compare against baseline
      PropertyDamage.Differential.run(
        model: MyModel,
        targets: [{ProdAdapter, name: "v2.4"}],
        compare: :performance,
        baseline: "baselines/v2.3.json"
      )

  ## Execution Modes

  - `:interleaved` - Execute commands round-robin across targets (default for correctness)
  - `:sequential` - Execute full sequence on each target (default for performance)

  When using `baseline:`, execution is implicitly sequential.

  ## Equivalence Strategies

  For correctness comparison:

  - `:exact` - Results must be identical (default)
  - `:structural` - Ignore common non-deterministic fields (id, timestamps)
  - Custom function - `fn ref_result, target_result -> boolean`
  """

  alias PropertyDamage.{Generator, Sequence, Options, Placeholder}
  alias PropertyDamage.Differential.{Target, Result, Baseline, Equivalence}

  @type compare_mode :: :correctness | :performance | :both

  @type target_spec ::
          {module()}
          | {module(), keyword()}

  @type equivalence_strategy :: :exact | :structural | (term(), term() -> boolean())

  @doc """
  Run differential testing against multiple targets.

  ## Required Options

  - `:model` - Model module implementing PropertyDamage.Model
  - `:targets` - List of target specifications (see Target Specification below)
  - `:compare` - Comparison mode: `:correctness`, `:performance`, or `:both`

  ## Target Specification

  Each target is a tuple of `{AdapterModule}` or `{AdapterModule, opts}`:

  - `name:` - Display name for reporting (default: derived from module)
  - `role:` - Set to `:reference` for oracle testing
  - `opts:` - Options passed to adapter's `setup/1`

  Examples:

      {MyAdapter}
      {MyAdapter, name: "staging"}
      {MyAdapter, role: :reference, opts: [url: "http://prod"]}

  ## Optional Options

  - `:max_commands` - Maximum commands per sequence (default: 50)
  - `:max_runs` - Number of test sequences to run (default: 100)
  - `:seed` - Random seed for reproducibility
  - `:execution` - `:interleaved` or `:sequential`
  - `:equivalence` - Equivalence strategy (default: `:exact`)
  - `:baseline` - Path to baseline file for comparison
  - `:export_to` - Path to export results for future baseline
  - `:metrics` - Performance metrics to collect (default: `[:latency, :throughput]`)
  - `:percentiles` - Latency percentiles (default: `[50, 95, 99]`)
  - `:warmup_runs` - Runs to discard before measuring (default: 0)
  - `:verbose` - Print progress (default: false)

  ## Returns

  - `{:ok, %Result{}}` - Differential testing completed
  - `{:error, reason}` - Setup or validation failed
  """
  @spec run(keyword()) :: {:ok, Result.t()} | {:error, term()}
  def run(opts) do
    opts = Options.validate_differential!(opts)

    with {:ok, config} <- build_config(opts),
         {:ok, targets} <- parse_targets(config.targets),
         {:ok, baseline} <- maybe_load_baseline(config.baseline) do
      # Determine execution mode
      execution_mode = determine_execution_mode(config, baseline)

      # Run the appropriate execution strategy
      result =
        case execution_mode do
          :interleaved ->
            run_interleaved(config, targets, baseline)

          :sequential ->
            run_sequential(config, targets, baseline)
        end

      # Maybe export results
      case result do
        {:ok, result} ->
          if config.export_to do
            :ok = Baseline.export(result, config, config.export_to)
          end

          {:ok, result}

        error ->
          error
      end
    end
  end

  # ============================================================================
  # Configuration
  # ============================================================================

  defp build_config(opts) do
    config = %{
      model: opts[:model],
      targets: opts[:targets],
      compare: opts[:compare],
      max_commands: opts[:max_commands],
      max_runs: opts[:max_runs],
      seed: opts[:seed] || :rand.uniform(1_000_000_000),
      execution: opts[:execution],
      equivalence: opts[:equivalence],
      baseline: opts[:baseline],
      export_to: opts[:export_to],
      metrics: opts[:metrics],
      percentiles: opts[:percentiles],
      warmup_runs: opts[:warmup_runs],
      verbose: opts[:verbose],
      adapter_config: opts[:adapter_config]
    }

    {:ok, config}
  end

  defp parse_targets(target_specs) do
    targets =
      target_specs
      |> Enum.with_index()
      |> Enum.map(fn {spec, index} ->
        Target.parse(spec, index)
      end)

    # Validate: only one reference for correctness mode
    references = Enum.filter(targets, &(&1.role == :reference))

    cond do
      length(references) > 1 ->
        {:error, {:invalid_targets, "only one target can have role: :reference"}}

      true ->
        {:ok, targets}
    end
  end

  defp determine_execution_mode(config, baseline) do
    cond do
      # Baseline comparison requires sequential
      baseline != nil ->
        :sequential

      # Explicit setting
      config.execution != nil ->
        config.execution

      # Default based on comparison mode
      config.compare == :performance ->
        :sequential

      config.compare == :both ->
        :sequential

      true ->
        :interleaved
    end
  end

  defp maybe_load_baseline(nil), do: {:ok, nil}

  defp maybe_load_baseline(path) do
    Baseline.load(path)
  end

  # ============================================================================
  # Interleaved Execution
  # ============================================================================

  defp run_interleaved(config, targets, _baseline) do
    # Seed the RNG
    :rand.seed(:exsss, {config.seed, config.seed, config.seed})

    # Setup all targets
    with {:ok, target_contexts} <- setup_all_targets(targets, config) do
      try do
        result = run_interleaved_loop(config, targets, target_contexts, 0, [])
        {:ok, result}
      after
        teardown_all_targets(targets, target_contexts)
      end
    end
  end

  defp run_interleaved_loop(config, targets, _target_contexts, run_number, divergences)
       when run_number >= config.max_runs do
    # All runs complete
    build_result(config, targets, divergences, %{})
  end

  defp run_interleaved_loop(config, targets, target_contexts, run_number, divergences) do
    # Generate a command sequence
    generator_opts = [max_commands: config.max_commands]
    generator = Generator.generate_sequence(config.model, generator_opts)
    sequence = generate_one(generator)
    commands = Sequence.to_list(sequence)

    if config.verbose do
      IO.puts("Run #{run_number + 1}/#{config.max_runs}: #{length(commands)} commands")
    end

    # Execute interleaved
    case execute_interleaved(config, targets, target_contexts, commands) do
      {:ok, _results} ->
        # No divergence, continue
        run_interleaved_loop(config, targets, target_contexts, run_number + 1, divergences)

      {:divergence, divergence} ->
        # Found a divergence
        new_divergences = [divergence | divergences]

        # For correctness mode, we might want to stop on first divergence
        # or collect multiple - for now, collect all
        run_interleaved_loop(config, targets, target_contexts, run_number + 1, new_divergences)
    end
  end

  defp execute_interleaved(config, targets, target_contexts, commands) do
    # Initialize state for each target
    initial_states =
      for target <- targets, into: %{} do
        {target.name,
         %{
           projections: init_projections(config.model),
           refs: %{},
           event_log: [],
           results: []
         }}
      end

    # Execute each command on all targets
    execute_interleaved_commands(config, targets, target_contexts, commands, initial_states, 0)
  end

  defp execute_interleaved_commands(_config, _targets, _target_contexts, [], states, _index) do
    {:ok, states}
  end

  defp execute_interleaved_commands(
         config,
         targets,
         target_contexts,
         [command | rest],
         states,
         index
       ) do
    # Execute command on each target and collect results
    target_results =
      for target <- targets do
        context = Map.get(target_contexts, target.name)
        state = Map.get(states, target.name)

        # Resolve refs
        resolved_command = resolve_refs(command, state.refs)

        # Execute
        start_time = System.monotonic_time(:microsecond)
        result = target.adapter.execute(resolved_command, context)
        end_time = System.monotonic_time(:microsecond)
        latency_us = end_time - start_time

        {target.name, result, latency_us, resolved_command}
      end

    # Check for divergences
    case check_divergence(config, targets, target_results, command, index) do
      :ok ->
        # Update states with results
        new_states =
          Enum.reduce(target_results, states, fn {name, result, _latency, _cmd}, acc ->
            state = Map.get(acc, name)

            new_state =
              case result do
                {:ok, events} ->
                  # Update refs and projections
                  refs = maybe_bind_ref(command, events, state.refs)
                  projections = apply_events(state.projections, events)

                  %{
                    state
                    | refs: refs,
                      projections: projections,
                      event_log: state.event_log ++ events,
                      results: state.results ++ [result]
                  }

                {:error, _reason} ->
                  %{state | results: state.results ++ [result]}
              end

            Map.put(acc, name, new_state)
          end)

        execute_interleaved_commands(
          config,
          targets,
          target_contexts,
          rest,
          new_states,
          index + 1
        )

      {:divergence, divergence} ->
        {:divergence, divergence}
    end
  end

  defp check_divergence(config, targets, target_results, command, index) do
    # Find reference target
    reference = Enum.find(targets, &(&1.role == :reference))

    if reference && config.compare in [:correctness, :both] do
      ref_result = find_result(target_results, reference.name)

      # Check each non-reference target against reference
      divergent =
        Enum.find(target_results, fn {name, result, _latency, _cmd} ->
          name != reference.name &&
            !Equivalence.equivalent?(ref_result, result, config.equivalence)
        end)

      case divergent do
        nil ->
          :ok

        {name, result, _latency, _cmd} ->
          {:divergence,
           %{
             seed: config.seed,
             command: command,
             step: index,
             reference_result: ref_result,
             results: Map.new(target_results, fn {n, r, _l, _c} -> {n, r} end),
             divergent_target: name,
             divergent_result: result
           }}
      end
    else
      # No correctness check needed
      :ok
    end
  end

  defp find_result(target_results, name) do
    case Enum.find(target_results, fn {n, _r, _l, _c} -> n == name end) do
      {_, result, _, _} -> result
      nil -> nil
    end
  end

  # ============================================================================
  # Sequential Execution
  # ============================================================================

  defp run_sequential(config, targets, baseline) do
    # Seed the RNG
    :rand.seed(:exsss, {config.seed, config.seed, config.seed})

    # Pre-generate all sequences
    sequences = generate_sequences(config)

    # If we have a baseline, use its sequences instead
    sequences =
      if baseline do
        Enum.map(baseline.runs, & &1.commands)
      else
        sequences
      end

    # Run each target sequentially
    target_results =
      for target <- targets do
        if config.verbose do
          IO.puts("Running target: #{target.name}")
        end

        run_data = run_target_sequential(config, target, sequences)
        {target.name, run_data}
      end
      |> Map.new()

    # Compare results
    compare_sequential_results(config, targets, target_results, baseline, sequences)
  end

  defp generate_sequences(config) do
    generator_opts = [max_commands: config.max_commands]
    generator = Generator.generate_sequence(config.model, generator_opts)

    for _ <- 1..config.max_runs do
      sequence = generate_one(generator)
      Sequence.to_list(sequence)
    end
  end

  defp run_target_sequential(config, target, sequences) do
    # Setup target
    adapter_opts = Map.merge(config.adapter_config, target.opts)

    case target.adapter.setup(adapter_opts) do
      {:ok, context} ->
        try do
          runs =
            sequences
            |> Enum.with_index()
            |> Enum.map(fn {commands, run_index} ->
              is_warmup = run_index < config.warmup_runs

              run_data = run_single_sequence(config, target, context, commands)
              Map.put(run_data, :is_warmup, is_warmup)
            end)

          %{
            runs: runs,
            setup_success: true
          }
        after
          target.adapter.teardown(context)
        end

      {:error, reason} ->
        %{
          runs: [],
          setup_success: false,
          setup_error: reason
        }
    end
  end

  defp run_single_sequence(config, target, context, commands) do
    initial_state = %{
      projections: init_projections(config.model),
      refs: %{},
      event_log: [],
      results: [],
      timings: []
    }

    final_state =
      Enum.reduce(commands, initial_state, fn command, state ->
        resolved_command = resolve_refs(command, state.refs)

        start_time = System.monotonic_time(:microsecond)
        result = target.adapter.execute(resolved_command, context)
        end_time = System.monotonic_time(:microsecond)
        latency_us = end_time - start_time

        case result do
          {:ok, events} ->
            refs = maybe_bind_ref(command, events, state.refs)
            projections = apply_events(state.projections, events)

            %{
              state
              | refs: refs,
                projections: projections,
                event_log: state.event_log ++ events,
                results: state.results ++ [result],
                timings: state.timings ++ [latency_us]
            }

          {:error, _reason} ->
            %{state | results: state.results ++ [result], timings: state.timings ++ [latency_us]}
        end
      end)

    %{
      commands: commands,
      results: final_state.results,
      timings: final_state.timings,
      event_log: final_state.event_log
    }
  end

  defp compare_sequential_results(config, targets, target_results, baseline, sequences) do
    # Calculate metrics for each target
    metrics =
      for target <- targets, into: %{} do
        run_data = Map.get(target_results, target.name)
        target_metrics = calculate_metrics(config, run_data)
        {target.name, target_metrics}
      end

    # If we have a baseline, add its metrics
    metrics =
      if baseline do
        Map.put(metrics, baseline.target_name, baseline.aggregate_metrics)
      else
        metrics
      end

    # Check for divergences in correctness mode
    divergences =
      if config.compare in [:correctness, :both] do
        find_sequential_divergences(config, targets, target_results, baseline, sequences)
      else
        []
      end

    {:ok, build_result(config, targets, divergences, metrics)}
  end

  defp find_sequential_divergences(config, targets, target_results, baseline, sequences) do
    # Find reference
    reference = Enum.find(targets, &(&1.role == :reference))

    ref_data =
      cond do
        baseline != nil ->
          # Compare against baseline
          %{runs: baseline.runs, name: baseline.target_name}

        reference != nil ->
          # Compare against reference target
          %{runs: Map.get(target_results, reference.name).runs, name: reference.name}

        true ->
          nil
      end

    if ref_data do
      # Compare each target's results against reference
      targets
      |> Enum.filter(fn t -> t.name != ref_data.name end)
      |> Enum.flat_map(fn target ->
        target_data = Map.get(target_results, target.name)

        if target_data.setup_success do
          compare_run_results(config, ref_data, target, target_data, sequences)
        else
          []
        end
      end)
    else
      []
    end
  end

  defp compare_run_results(config, ref_data, target, target_data, sequences) do
    ref_data.runs
    |> Enum.zip(target_data.runs)
    |> Enum.zip(sequences)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{{ref_run, target_run}, commands}, run_index} ->
      ref_run.results
      |> Enum.zip(target_run.results)
      |> Enum.zip(commands)
      |> Enum.with_index()
      |> Enum.filter(fn {{{ref_result, target_result}, _cmd}, _idx} ->
        !Equivalence.equivalent?(ref_result, target_result, config.equivalence)
      end)
      |> Enum.map(fn {{{ref_result, target_result}, command}, step} ->
        %{
          seed: config.seed,
          run_index: run_index,
          command: command,
          step: step,
          reference_result: ref_result,
          reference_name: ref_data.name,
          divergent_target: target.name,
          divergent_result: target_result
        }
      end)
    end)
  end

  defp calculate_metrics(_config, run_data) do
    # Filter out warmup runs and failed setups
    if run_data.setup_success do
      valid_runs = Enum.filter(run_data.runs, fn run -> !run.is_warmup end)

      all_timings =
        valid_runs
        |> Enum.flat_map(& &1.timings)
        |> Enum.sort()

      if length(all_timings) > 0 do
        %{
          latency_p50: percentile(all_timings, 50),
          latency_p95: percentile(all_timings, 95),
          latency_p99: percentile(all_timings, 99),
          latency_mean: mean(all_timings),
          latency_min: Enum.min(all_timings),
          latency_max: Enum.max(all_timings),
          total_commands: length(all_timings),
          error_count: count_errors(valid_runs),
          error_rate: error_rate(valid_runs)
        }
      else
        %{error: :no_data}
      end
    else
      %{error: :setup_failed, reason: run_data.setup_error}
    end
  end

  defp percentile(sorted_list, p) when length(sorted_list) > 0 do
    k = p / 100.0 * (length(sorted_list) - 1)
    f = :erlang.trunc(k)
    c = f + 1

    if c >= length(sorted_list) do
      Enum.at(sorted_list, f)
    else
      d0 = Enum.at(sorted_list, f) * (c - k)
      d1 = Enum.at(sorted_list, c) * (k - f)
      d0 + d1
    end
  end

  defp mean(list) when length(list) > 0 do
    Enum.sum(list) / length(list)
  end

  defp count_errors(runs) do
    runs
    |> Enum.flat_map(& &1.results)
    |> Enum.count(&match?({:error, _}, &1))
  end

  defp error_rate(runs) do
    total = runs |> Enum.flat_map(& &1.results) |> length()

    if total > 0 do
      count_errors(runs) / total
    else
      0.0
    end
  end

  # ============================================================================
  # Result Building
  # ============================================================================

  defp build_result(config, targets, divergences, metrics) do
    status =
      cond do
        length(divergences) > 0 -> :divergent
        true -> :equivalent
      end

    reference = Enum.find(targets, &(&1.role == :reference))

    %Result{
      mode: config.compare,
      execution: determine_execution_mode(config, nil),
      runs: config.max_runs,
      seed: config.seed,
      reference: if(reference, do: reference.name, else: nil),
      status: status,
      divergences: divergences,
      metrics: metrics,
      targets: Enum.map(targets, & &1.name)
    }
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp setup_all_targets(targets, config) do
    results =
      for target <- targets do
        adapter_opts = Map.merge(config.adapter_config, target.opts)

        case target.adapter.setup(adapter_opts) do
          {:ok, context} -> {:ok, target.name, context}
          {:error, reason} -> {:error, target.name, reason}
        end
      end

    errors = Enum.filter(results, &match?({:error, _, _}, &1))

    if length(errors) > 0 do
      # Teardown any that succeeded
      for {:ok, name, ctx} <- results do
        target = Enum.find(targets, &(&1.name == name))
        target.adapter.teardown(ctx)
      end

      {:error, name} = hd(errors)
      {:error, {:target_setup_failed, name}}
    else
      contexts = Map.new(results, fn {:ok, name, ctx} -> {name, ctx} end)
      {:ok, contexts}
    end
  end

  defp teardown_all_targets(targets, contexts) do
    for target <- targets do
      context = Map.get(contexts, target.name)

      if context do
        target.adapter.teardown(context)
      end
    end

    :ok
  end

  defp generate_one(generator) do
    case Enumerable.reduce(generator, {:cont, nil}, fn val, _ -> {:halt, val} end) do
      {:halted, value} -> value
      {:done, _} -> []
    end
  end

  defp init_projections(model) do
    state_projection = model.state_projection()

    extra_projections =
      if function_exported?(model, :extra_projections, 0) do
        model.extra_projections()
      else
        []
      end

    all_projections = [state_projection | extra_projections]

    for projection <- all_projections, into: %{} do
      {projection, projection.init()}
    end
  end

  defp resolve_refs(command, refs) do
    # Deep resolve refs in command
    do_resolve_refs(command, refs)
  end

  defp do_resolve_refs(%PropertyDamage.Ref{ref: ref_key} = ref, refs) do
    case Map.get(refs, ref_key) do
      # Leave unresolved
      nil -> ref
      value -> value
    end
  end

  # Handle new Placeholder structs - if resolved, use value; otherwise leave as-is
  defp do_resolve_refs(%Placeholder{resolved: nil} = p, _refs), do: p
  defp do_resolve_refs(%Placeholder{resolved: value}, _refs), do: value

  defp do_resolve_refs(%{__struct__: _} = struct, refs) do
    struct
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {k, do_resolve_refs(v, refs)} end)
    |> Map.new()
    |> then(&struct(struct.__struct__, &1))
  end

  defp do_resolve_refs(map, refs) when is_map(map) do
    for {k, v} <- map, into: %{} do
      {do_resolve_refs(k, refs), do_resolve_refs(v, refs)}
    end
  end

  defp do_resolve_refs(list, refs) when is_list(list) do
    Enum.map(list, &do_resolve_refs(&1, refs))
  end

  defp do_resolve_refs(tuple, refs) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> do_resolve_refs(refs)
    |> List.to_tuple()
  end

  defp do_resolve_refs(other, _refs), do: other

  defp maybe_bind_ref(command, events, refs) do
    command_module = command.__struct__

    if function_exported?(command_module, :creates_ref, 0) do
      case command_module.creates_ref() do
        nil ->
          refs

        ref_field ->
          case events do
            [first_event | _] ->
              value = Map.get(first_event, ref_field)

              case Map.get(command, ref_field) do
                %PropertyDamage.Ref{ref: ref_key} ->
                  Map.put(refs, ref_key, value)

                _ ->
                  refs
              end

            [] ->
              refs
          end
      end
    else
      refs
    end
  end

  defp apply_events(projections, events) do
    Enum.reduce(events, projections, fn event, projs ->
      for {projection, state} <- projs, into: %{} do
        {projection, projection.apply(state, event)}
      end
    end)
  end
end
