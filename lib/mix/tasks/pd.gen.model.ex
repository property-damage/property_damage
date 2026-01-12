defmodule Mix.Tasks.Pd.Gen.Model do
  @moduledoc """
  Generate a PropertyDamage model module.

  ## Usage

      mix pd.gen.model MyApp.TestModel

  ## Options

      --commands COMMANDS    Comma-separated list of command module names
      --projection NAME      State projection module name
      --assertions NAMES     Comma-separated list of assertion projection names

  ## Examples

      # Basic model
      mix pd.gen.model MyApp.TestModel

      # Model with commands specified
      mix pd.gen.model MyApp.TestModel --commands CreateUser,UpdateUser,DeleteUser

      # Full specification
      mix pd.gen.model MyApp.TestModel \\
        --commands CreateUser,UpdateUser,DeleteUser \\
        --projection MyApp.Projections.ModelState \\
        --assertions BalanceInvariant,ConsistencyInvariant
  """

  use Mix.Task

  @shortdoc "Generate a PropertyDamage model module"

  @impl true
  def run(args) do
    {opts, argv, _} =
      OptionParser.parse(args,
        strict: [commands: :string, projection: :string, assertions: :string]
      )

    case argv do
      [module_name] ->
        generate_model(module_name, opts)

      [] ->
        Mix.shell().error("Usage: mix pd.gen.model MODULE_NAME [OPTIONS]")
        Mix.shell().error("Run `mix help pd.gen.model` for more information.")

      _ ->
        Mix.shell().error("Expected exactly one module name")
    end
  end

  defp generate_model(module_name, opts) do
    commands = parse_list(Keyword.get(opts, :commands, ""))
    projection = Keyword.get(opts, :projection)
    assertions = parse_list(Keyword.get(opts, :assertions, ""))

    path = module_to_path(module_name)
    dir = Path.dirname(path)

    File.mkdir_p!(dir)

    content = generate_content(module_name, commands, projection, assertions)

    File.write!(path, content)

    Mix.shell().info("Generated #{path}")
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  1. Create command modules listed in commands/0")
    Mix.shell().info("  2. Create the state projection module")
    Mix.shell().info("  3. Create assertion projection modules")
    Mix.shell().info("  4. Create an adapter module")
    Mix.shell().info("  5. Run: PropertyDamage.run(model: #{module_name}, adapter: YourAdapter)")
  end

  defp parse_list(""), do: []
  defp parse_list(str), do: String.split(str, ",") |> Enum.map(&String.trim/1)

  defp module_to_path(module_name) do
    module_name
    |> String.replace(".", "/")
    |> Macro.underscore()
    |> then(&"lib/#{&1}.ex")
  end

  defp generate_content(module_name, commands, projection, assertions) do
    # Infer namespace from module name
    parts = String.split(module_name, ".")
    namespace = Enum.slice(parts, 0..-2//1) |> Enum.join(".")

    commands_section = generate_commands_section(commands, namespace)
    projection_section = generate_projection_section(projection, namespace)
    assertions_section = generate_assertions_section(assertions, namespace)

    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      PropertyDamage model for testing.

      TODO: Add description of what this model tests.

      ## Usage

          PropertyDamage.run(
            model: #{module_name},
            adapter: #{namespace}.Adapter,
            max_runs: 100
          )
      \"\"\"

      @behaviour PropertyDamage.Model

      #{commands_section}

      @impl true
      def commands do
        [
          # TODO: Adjust weights based on desired command frequency
          # Higher weight = more frequent generation
          #{generate_commands_list(commands)}
        ]
      end

      @impl true
      def state_projection do
        #{projection_section}
      end

      @impl true
      def extra_projections do
        [
          #{assertions_section}
        ]
      end

      # Optional: Uncomment to enable lifecycle hooks
      #
      # def setup_once(config) do
      #   # One-time setup (not repeated during shrinking)
      #   :ok
      # end
      #
      # def setup_each(config) do
      #   # Reset state before each test run
      #   :ok
      # end
      #
      # def teardown_each(config) do
      #   :ok
      # end
      #
      # def teardown_once(config) do
      #   :ok
      # end
      #
      # def terminate?(state, command, events) do
      #   # Return true to stop command generation
      #   false
      # end
    end
    """
  end

  defp generate_commands_section([], namespace) do
    """
    alias #{namespace}.Commands.{
        # TODO: Add your command modules here
        # CreateEntity,
        # UpdateEntity,
        # DeleteEntity
      }
    """
  end

  defp generate_commands_section(commands, namespace) do
    command_list = Enum.join(commands, ",\n    ")

    """
    alias #{namespace}.Commands.{
        #{command_list}
      }
    """
  end

  defp generate_commands_list([]) do
    """
    # {3, CreateEntity},   # High weight - frequent
          # {2, UpdateEntity},   # Medium weight
          # {1, DeleteEntity}    # Low weight - rare
    """
  end

  defp generate_commands_list(commands) do
    commands
    |> Enum.with_index(1)
    |> Enum.map(fn {cmd, idx} ->
      # Give decreasing weights
      weight = max(1, 4 - idx)
      "{#{weight}, #{cmd}}"
    end)
    |> Enum.join(",\n      ")
  end

  defp generate_projection_section(nil, namespace) do
    "#{namespace}.Projections.ModelState"
  end

  defp generate_projection_section(projection, _namespace) do
    projection
  end

  defp generate_assertions_section([], namespace) do
    "# #{namespace}.Projections.SomeInvariant"
  end

  defp generate_assertions_section(assertions, _namespace) do
    Enum.join(assertions, ",\n      ")
  end
end
