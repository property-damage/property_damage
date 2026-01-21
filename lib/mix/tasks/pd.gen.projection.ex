defmodule Mix.Tasks.Pd.Gen.Projection do
  @moduledoc """
  Generate a PropertyDamage projection module.

  Projections track state and optionally define assertions using `@trigger` or
  `@poll_state` attributes.

  ## Usage

      mix pd.gen.projection MyApp.Projections.ModelState

  ## Examples

      mix pd.gen.projection MyApp.Projections.ModelState
      mix pd.gen.projection MyApp.Projections.BalanceInvariant

  ## Generated Template

  The generated projection includes:

  - `init/0` - Initialize projection state
  - `apply/2` - Apply commands/events to state (with example)
  - `@trigger` assertion example (synchronous)
  - `@poll_state` assertion example (temporal/eventual consistency)

  ## More Information

  See `PropertyDamage.Model.Projection` for full documentation on:

  - State tracking with `apply/2`
  - Synchronous assertions with `@trigger`
  - Temporal assertions with `@poll_state`
  """

  use Mix.Task

  @shortdoc "Generate a PropertyDamage projection module"

  @impl true
  def run(args) do
    {_opts, argv, _} = OptionParser.parse(args, strict: [])

    case argv do
      [module_name] ->
        generate_projection(module_name)

      [] ->
        Mix.shell().error("Usage: mix pd.gen.projection MODULE_NAME")
        Mix.shell().error("Run `mix help pd.gen.projection` for more information.")

      _ ->
        Mix.shell().error("Expected exactly one module name")
    end
  end

  defp generate_projection(module_name) do
    path = module_to_path(module_name)
    dir = Path.dirname(path)

    File.mkdir_p!(dir)

    content = generate_projection_content(module_name)

    File.write!(path, content)

    Mix.shell().info("Generated #{path}")
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  1. Add event aliases at the top")
    Mix.shell().info("  2. Implement apply/2 for each event to track state")
    Mix.shell().info("  3. Add assertions with @trigger or @poll_state attributes")
  end

  defp module_to_path(module_name) do
    module_name
    |> String.replace(".", "/")
    |> Macro.underscore()
    |> then(&"lib/#{&1}.ex")
  end

  defp generate_projection_content(module_name) do
    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Projection for tracking state and defining assertions.

      TODO: Add description of what this projection tracks/checks.
      \"\"\"

      use PropertyDamage.Model.Projection

      # TODO: Add event aliases
      # alias MyApp.Events.{Created, Updated, Deleted}

      def init do
        %{
          # TODO: Add initial state fields
          # entities: %{}
        }
      end

      # ============================================================================
      # State Tracking
      # ============================================================================

      # Handle events with ref (for entity creation)
      # def apply(state, %Created{} = event, ref) do
      #   put_in(state, [:entities, ref], event.data)
      # end

      # Handle events without ref
      # def apply(state, %Updated{} = event) do
      #   update_in(state, [:entities, event.id], fn e -> %{e | name: event.name} end)
      # end

      # Catch-all (required)
      def apply(state, _event), do: state
      def apply(state, _event, _ref), do: state

      # ============================================================================
      # Synchronous Assertions (@trigger)
      # ============================================================================

      # Example: Check invariant after every step
      # @trigger every: 1
      # def assert_total_non_negative(state, _cmd_or_event) do
      #   if state.total < 0 do
      #     PropertyDamage.fail!("total is negative", total: state.total)
      #   end
      # end

      # Example: Check invariant after specific event
      # @trigger every: OrderCreated
      # def assert_order_tracked(state, %OrderCreated{id: id}) do
      #   unless Map.has_key?(state.orders, id) do
      #     PropertyDamage.fail!("order not tracked", order_id: id)
      #   end
      # end

      # ============================================================================
      # Temporal Assertions (@poll_state)
      # ============================================================================

      # Example: Check eventual consistency after an event
      # The function returns a predicate that is polled until true or timeout
      #
      # @poll_state after: PaymentInitiated, timeout: 5, interval: {100, :milliseconds}
      # def payment_confirmed(_state, %PaymentInitiated{id: id}) do
      #   fn s -> s.payments[id] == :confirmed end
      # end
    end
    """
  end
end
