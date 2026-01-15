defmodule Mix.Tasks.Pd.Gen.Projection do
  @moduledoc """
  Generate a PropertyDamage projection module.

  ## Usage

      mix pd.gen.projection MyApp.Projections.ModelState

  ## Options

      --type TYPE    Projection type: state or assertion (default: state)

  ## Examples

      # State projection
      mix pd.gen.projection MyApp.Projections.ModelState

      # Assertion projection (invariant checker)
      mix pd.gen.projection MyApp.Projections.BalanceInvariant --type assertion
  """

  use Mix.Task

  @shortdoc "Generate a PropertyDamage projection module"

  @impl true
  def run(args) do
    {opts, argv, _} = OptionParser.parse(args, strict: [type: :string])

    case argv do
      [module_name] ->
        type = Keyword.get(opts, :type, "state")
        generate_projection(module_name, type)

      [] ->
        Mix.shell().error("Usage: mix pd.gen.projection MODULE_NAME [OPTIONS]")
        Mix.shell().error("Run `mix help pd.gen.projection` for more information.")

      _ ->
        Mix.shell().error("Expected exactly one module name")
    end
  end

  defp generate_projection(module_name, type) do
    path = module_to_path(module_name)
    dir = Path.dirname(path)

    File.mkdir_p!(dir)

    content =
      case type do
        "state" ->
          generate_state_projection(module_name)

        "assertion" ->
          generate_assertion_projection(module_name)

        _ ->
          Mix.shell().error("Unknown projection type: #{type}")
          Mix.shell().error("Use 'state' or 'assertion'")
          System.halt(1)
      end

    File.write!(path, content)

    Mix.shell().info("Generated #{path}")
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  1. Add event aliases at the top")
    Mix.shell().info("  2. Implement apply/2 or apply/3 for each event")

    if type == "assertion" do
      Mix.shell().info("  3. Implement check/1 with your invariant")
    end
  end

  defp module_to_path(module_name) do
    module_name
    |> String.replace(".", "/")
    |> Macro.underscore()
    |> then(&"lib/#{&1}.ex")
  end

  defp generate_state_projection(module_name) do
    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      State projection for tracking model state.

      TODO: Add description of what state this projection tracks.
      \"\"\"

      @behaviour PropertyDamage.Model.Projection

      # TODO: Add event aliases
      # alias MyApp.Events.{Created, Updated, Deleted}

      @impl true
      def init do
        %{
          # TODO: Add initial state fields
          # entities: %{}
        }
      end

      @impl true
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
    end
    """
  end

  defp generate_assertion_projection(module_name) do
    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      Assertion projection for checking invariants.

      TODO: Add description of what invariant this projection checks.
      \"\"\"

      @behaviour PropertyDamage.AssertionProjection

      # TODO: Add event aliases
      # alias MyApp.Events.{Created, Updated, Deleted}

      @impl true
      def init do
        %{
          # TODO: Add state needed for invariant checking
        }
      end

      @impl true
      # Track state needed for checks
      # def apply(state, %Created{} = event) do
      #   # Update state to track what we need to check
      #   state
      # end

      def apply(state, _event), do: state

      @impl true
      def check(state) do
        # TODO: Implement your invariant check
        # Return :ok if invariant holds
        # Return {:violated, "message"} if invariant is violated

        # Example:
        # if some_condition_violated?(state) do
        #   {:violated, "Description of what went wrong"}
        # else
        #   :ok
        # end

        :ok
      end
    end
    """
  end
end
