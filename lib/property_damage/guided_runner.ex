defmodule PropertyDamage.GuidedRunner do
  @moduledoc """
  Evolutionary algorithm runner for guided property-based testing.

  The GuidedRunner uses a genetic algorithm approach to find command sequences
  that reach interesting target states more quickly than random generation.

  ## How It Works

  1. **Initialize Population** - Start with random seeds (or provided initial seeds)
  2. **Evaluate Fitness** - Run each seed, calculate fitness based on final state
  3. **Select Best** - Keep top performers based on fitness and target coverage
  4. **Breed Next Generation** - Mutate and crossover selected seeds
  5. **Repeat** - Continue for configured number of generations

  ## Usage

      result = PropertyDamage.GuidedRunner.run(
        model: MyModel,
        adapter: MyAdapter,
        generations: 10,
        population_size: 20,
        max_commands: 100
      )

      case result do
        {:ok, stats} ->
          IO.puts("Best fitness: \#{stats.best_fitness}")
          IO.puts("Targets reached: \#{inspect(stats.targets_reached)}")

        {:error, failure} ->
          IO.puts("Found bug with seed \#{failure.seed}")
      end

  ## Configuration

  - `:generations` - Number of evolutionary generations (default: 10)
  - `:population_size` - Seeds per generation (default: 20)
  - `:elite_count` - Top seeds to preserve unchanged (default: 2)
  - `:mutation_rate` - Probability of seed mutation (default: 0.3)
  - `:crossover_rate` - Probability of seed crossover (default: 0.5)
  - `:initial_seeds` - Starting seeds (default: random)
  """

  alias PropertyDamage.{Executor, Generator, Sequence, TargetedGeneration, Options}

  @typedoc """
  Result statistics from a guided run.
  """
  @type stats :: %{
          generations_completed: non_neg_integer(),
          total_runs: non_neg_integer(),
          best_fitness: float(),
          best_seed: integer(),
          targets_reached: [atom()],
          all_targets: [atom()],
          fitness_history: [float()]
        }

  @typedoc """
  Guided run result.
  """
  @type result :: {:ok, stats()} | {:error, PropertyDamage.failure_report()}

  @doc """
  Run guided generation with evolutionary algorithm.

  ## Required Options

  - `:model` - Model module (must implement TargetedGeneration)
  - `:adapter` - Adapter module

  ## Optional Options

  - `:generations` - Number of generations (default: 10)
  - `:population_size` - Seeds per generation (default: 20)
  - `:elite_count` - Top seeds preserved unchanged (default: 2)
  - `:mutation_rate` - Mutation probability (default: 0.3)
  - `:max_commands` - Commands per sequence (default: 50)
  - `:initial_seeds` - Starting seed list (default: random)
  - `:verbose` - Print progress (default: false)

  ## Returns

  - `{:ok, stats}` - All runs passed, returns best fitness and coverage
  - `{:error, failure}` - A bug was found, returns failure details
  """
  @spec run(keyword()) :: result()
  def run(opts) do
    opts = Options.validate_guided_runner!(opts)

    model = opts[:model]
    adapter = opts[:adapter]

    # Validate model implements TargetedGeneration
    unless TargetedGeneration.implements_behaviour?(model) do
      raise ArgumentError,
            "Model #{inspect(model)} must implement PropertyDamage.TargetedGeneration"
    end

    generations = opts[:generations]
    population_size = opts[:population_size]
    verbose = opts[:verbose]

    # Initialize population
    initial_seeds =
      case opts[:initial_seeds] do
        nil -> Enum.map(1..population_size, fn _ -> random_seed() end)
        seeds -> seeds
      end

    all_targets = Enum.map(model.targets(), & &1.name)

    initial_state = %{
      population: initial_seeds,
      generation: 0,
      best_fitness: 0.0,
      best_seed: nil,
      targets_reached: MapSet.new(),
      fitness_history: [],
      total_runs: 0
    }

    # Run evolutionary loop
    result =
      Enum.reduce_while(1..generations, initial_state, fn gen, state ->
        if verbose do
          IO.puts("Generation #{gen}/#{generations} - Population: #{length(state.population)}")
        end

        case evaluate_generation(state.population, model, adapter, opts) do
          {:ok, evaluated} ->
            # Update statistics
            best = Enum.max_by(evaluated, & &1.fitness)

            new_targets =
              evaluated
              |> Enum.flat_map(& &1.targets_reached)
              |> MapSet.new()
              |> MapSet.union(state.targets_reached)

            if verbose do
              IO.puts("  Best fitness: #{Float.round(best.fitness, 3)}")
              IO.puts("  New targets: #{inspect(MapSet.to_list(new_targets))}")
            end

            # Check if we've found all targets
            all_reached = MapSet.size(new_targets) == length(all_targets)

            if all_reached and verbose do
              IO.puts("  All targets reached!")
            end

            # Select and breed next generation
            next_population = breed_next_generation(evaluated, opts)

            new_state = %{
              state
              | population: next_population,
                generation: gen,
                best_fitness: max(state.best_fitness, best.fitness),
                best_seed:
                  if(best.fitness > state.best_fitness, do: best.seed, else: state.best_seed),
                targets_reached: new_targets,
                fitness_history: state.fitness_history ++ [best.fitness],
                total_runs: state.total_runs + length(evaluated)
            }

            {:cont, new_state}

          {:error, failure} ->
            {:halt, {:error, failure}}
        end
      end)

    case result do
      {:error, failure} ->
        {:error, failure}

      final_state ->
        {:ok,
         %{
           generations_completed: final_state.generation,
           total_runs: final_state.total_runs,
           best_fitness: final_state.best_fitness,
           best_seed: final_state.best_seed,
           targets_reached: MapSet.to_list(final_state.targets_reached),
           all_targets: all_targets,
           fitness_history: final_state.fitness_history
         }}
    end
  end

  # Evaluate all seeds in a generation
  defp evaluate_generation(seeds, model, adapter, opts) do
    adapter_config = Keyword.get(opts, :adapter_config, %{})
    max_commands = opts[:max_commands]

    results =
      Enum.map(seeds, fn seed ->
        evaluate_seed(seed, model, adapter, adapter_config, max_commands)
      end)

    # Check for failures
    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, failure} -> {:error, failure}
      nil -> {:ok, Enum.map(results, fn {:ok, r} -> r end)}
    end
  end

  # Evaluate a single seed
  defp evaluate_seed(seed, model, adapter, adapter_config, max_commands) do
    # Seed RNG
    :rand.seed(:exsss, {seed, seed, seed})

    # Generate and execute sequence
    generator = Generator.generate_sequence(model, max_commands: max_commands)
    sequence = generate_one(generator)

    case Executor.run(sequence, model, adapter, adapter_config: adapter_config) do
      {:ok, result} ->
        if result.success do
          # Calculate fitness from final state
          command_sequence_projection = model.command_sequence_projection()
          final_state = Map.get(result.projections, command_sequence_projection)
          fitness = TargetedGeneration.calculate_fitness(model, final_state)
          targets = TargetedGeneration.reached_targets(model, final_state)

          {:ok,
           %{
             seed: seed,
             fitness: fitness,
             targets_reached: targets,
             command_count: Sequence.command_count(sequence)
           }}
        else
          # Found a bug
          {:error,
           %{
             seed: seed,
             run_number: 0,
             original_sequence: sequence,
             shrunk_sequence: sequence,
             failed_at_index: result.failed_at_index,
             failure_reason: result.failure_reason,
             shrink_iterations: 0,
             shrink_time_ms: 0
           }}
        end

      {:error, reason} ->
        {:error, %{seed: seed, failure_reason: reason}}
    end
  end

  # Generate one sequence from a StreamData generator
  defp generate_one(generator) do
    case Enumerable.reduce(generator, {:cont, nil}, fn val, _ -> {:halt, val} end) do
      {:halted, value} -> value
      {:done, _} -> Sequence.linear([])
    end
  end

  # Select best performers and breed next generation
  defp breed_next_generation(evaluated, opts) do
    population_size = opts[:population_size]
    elite_count = opts[:elite_count]
    mutation_rate = opts[:mutation_rate]
    crossover_rate = opts[:crossover_rate]

    # Sort by fitness (descending)
    sorted = Enum.sort_by(evaluated, & &1.fitness, :desc)

    # Elite selection - keep top performers unchanged
    elite = sorted |> Enum.take(elite_count) |> Enum.map(& &1.seed)

    # Tournament selection for breeding pool
    breeding_pool = tournament_select(sorted, population_size - elite_count)

    # Generate offspring through mutation and crossover
    offspring =
      breeding_pool
      |> Enum.chunk_every(2, 2, :discard)
      |> Enum.flat_map(fn
        [parent1, parent2] ->
          if :rand.uniform() < crossover_rate do
            [crossover(parent1, parent2), crossover(parent2, parent1)]
          else
            [parent1, parent2]
          end
      end)
      |> Enum.map(fn seed ->
        if :rand.uniform() < mutation_rate do
          mutate(seed)
        else
          seed
        end
      end)
      |> Enum.take(population_size - elite_count)

    # Pad with random seeds if needed
    needed = population_size - length(elite) - length(offspring)

    random_new =
      if needed > 0 do
        Enum.map(1..needed, fn _ -> random_seed() end)
      else
        []
      end

    elite ++ offspring ++ random_new
  end

  # Tournament selection
  defp tournament_select(evaluated, count, tournament_size \\ 3) do
    Enum.map(1..count, fn _ ->
      evaluated
      |> Enum.take_random(tournament_size)
      |> Enum.max_by(& &1.fitness)
      |> Map.get(:seed)
    end)
  end

  # Crossover two seeds (simple arithmetic crossover)
  defp crossover(seed1, seed2) do
    # XOR-based crossover
    div(seed1 + seed2, 2) + :rand.uniform(1000)
  end

  # Mutate a seed
  defp mutate(seed) do
    # Add random perturbation
    delta = :rand.uniform(100_000) - 50_000
    abs(seed + delta)
  end

  # Generate a random seed
  defp random_seed do
    :rand.uniform(1_000_000_000)
  end
end
