defmodule PropertyDamage.TargetedGeneration do
  @moduledoc """
  Behaviour for guiding command generation toward interesting target states.

  Random generation spends too much time in "boring" states and rarely reaches
  edge cases. Targeted generation solves this by:

  1. Defining **target states** - Conditions that represent interesting scenarios
  2. Using **fitness functions** - Scoring how close current state is to targets
  3. **Evolutionary algorithms** - Breeding successful seeds to explore faster

  ## Why Targeted Generation?

  Consider an order management system. Random generation might produce:
  - 90% of runs: 0-5 orders, no edge cases
  - 9% of runs: 5-20 orders, some complexity
  - 1% of runs: 20+ orders, potential edge cases

  With targeted generation:
  - Define target: "account with 50+ orders and pending refunds"
  - Fitness rewards: order count, pending operations, balance near limits
  - Evolutionary pressure: mutate seeds that get closer to targets

  ## Usage

  Implement this behaviour alongside your Model:

      defmodule MyTest.OrderModel do
        @behaviour PropertyDamage.Model
        @behaviour PropertyDamage.TargetedGeneration

        @impl PropertyDamage.TargetedGeneration
        def targets do
          [
            %{
              name: :high_order_count,
              condition: fn state -> map_size(state.orders) >= 50 end,
              priority: 10
            },
            %{
              name: :pending_refunds,
              condition: fn state ->
                Enum.count(state.orders, fn {_, o} -> o.status == :refund_pending end) >= 3
              end,
              priority: 5
            }
          ]
        end

        @impl PropertyDamage.TargetedGeneration
        def fitness(state) do
          base = map_size(state.orders) / 50.0
          pending = Enum.count(state.orders, &match?({_, %{status: :pending}}, &1))
          base + pending * 0.1
        end
      end

  Then run with guided generation:

      PropertyDamage.GuidedRunner.run(
        model: MyTest.OrderModel,
        adapter: MyAdapter,
        generations: 10,
        population_size: 20
      )
  """

  @typedoc """
  A target state definition.

  - `:name` - Atom identifying this target (for reporting)
  - `:condition` - Function that returns true when target is reached
  - `:priority` - Higher priority targets are weighted more in fitness
  """
  @type target :: %{
          name: atom(),
          condition: (state :: map() -> boolean()),
          priority: pos_integer()
        }

  @doc """
  Return the list of target states for guided generation.

  Each target defines a "interesting" state that is more likely to expose bugs.
  The generator will try to produce command sequences that reach these states.

  ## Example

      def targets do
        [
          %{
            name: :high_order_count,
            condition: fn state -> map_size(state.orders) >= 50 end,
            priority: 10
          }
        ]
      end
  """
  @callback targets() :: [target()]

  @doc """
  Calculate fitness score for a state.

  Higher scores indicate states closer to interesting targets. The fitness
  function guides the evolutionary algorithm toward better command sequences.

  ## Parameters

  - `state` - The current projection state

  ## Returns

  A float where higher values indicate more interesting states.

  ## Example

      def fitness(state) do
        # Score based on order count and complexity
        order_score = map_size(state.orders) / 50.0
        pending_score = count_pending(state) * 0.1
        order_score + pending_score
      end
  """
  @callback fitness(state :: map()) :: float()

  @doc """
  (Optional) Custom command weighting based on current state and targets.

  Override this to dynamically adjust command probabilities based on
  which targets haven't been reached yet.

  ## Example

      def command_weights(state, unreached_targets) do
        if :high_order_count in unreached_targets do
          # Increase weight of CreateOrder when trying to reach high count
          %{CreateOrder => 10, CancelOrder => 1}
        else
          %{}  # Use default weights
        end
      end
  """
  @callback command_weights(state :: map(), unreached_targets :: [atom()]) :: %{
              module() => pos_integer()
            }

  @optional_callbacks [command_weights: 2]

  # ============================================================================
  # Utility Functions
  # ============================================================================

  @doc """
  Check which targets have been reached in the given state.
  """
  @spec reached_targets(module(), map()) :: [atom()]
  def reached_targets(model, state) do
    if implements_behaviour?(model) do
      model.targets()
      |> Enum.filter(fn %{condition: cond} -> cond.(state) end)
      |> Enum.map(& &1.name)
    else
      []
    end
  end

  @doc """
  Check which targets have NOT been reached in the given state.
  """
  @spec unreached_targets(module(), map()) :: [atom()]
  def unreached_targets(model, state) do
    if implements_behaviour?(model) do
      all_targets = Enum.map(model.targets(), & &1.name)
      reached = reached_targets(model, state)
      all_targets -- reached
    else
      []
    end
  end

  @doc """
  Calculate fitness for a state using the model's fitness function.
  """
  @spec calculate_fitness(module(), map()) :: float()
  def calculate_fitness(model, state) do
    if implements_behaviour?(model) do
      model.fitness(state)
    else
      0.0
    end
  end

  @doc """
  Check if a module implements the TargetedGeneration behaviour.
  """
  @spec implements_behaviour?(module()) :: boolean()
  def implements_behaviour?(module) do
    function_exported?(module, :targets, 0) and function_exported?(module, :fitness, 1)
  end
end
