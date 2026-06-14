defmodule Mix.Tasks.Pd.Gen.Command do
  @moduledoc """
  Generate a PropertyDamage command module.

  ## Usage

      mix pd.gen.command MyApp.Commands.CreateUser

  ## Options

      --creates-ref NAME    (DEPRECATED) Field name for ref this command creates.
                            Use `external()` in event structs instead.
      --semantics SEM       Command semantics (sync, probe, async)
      --fields FIELDS       Comma-separated field names

  ## Note on creates_ref Deprecation

  The `--creates-ref` option is deprecated. Instead of declaring refs on commands,
  use `external()` markers in your event struct definitions:

      defmodule MyApp.Events.UserCreated do
        import PropertyDamage, only: [external: 0]
        defstruct [:name, :email, id: external()]  # id is server-generated
      end

  See `PropertyDamage.external/0` for full documentation.

  ## Examples

      # Basic command
      mix pd.gen.command MyApp.Commands.CreateUser

      # Probe command with fields
      mix pd.gen.command MyApp.Commands.GetUser --semantics probe --fields user_ref

      # Command with multiple fields
      mix pd.gen.command MyApp.Commands.UpdateUser --fields user_ref,name,email
  """

  use Mix.Task

  @shortdoc "Generate a PropertyDamage command module"

  @impl true
  def run(args) do
    {opts, argv, _} =
      OptionParser.parse(args,
        strict: [creates_ref: :string, semantics: :string, fields: :string]
      )

    case argv do
      [module_name] ->
        generate_command(module_name, opts)

      [] ->
        Mix.shell().error("Usage: mix pd.gen.command MODULE_NAME [OPTIONS]")
        Mix.shell().error("Run `mix help pd.gen.command` for more information.")

      _ ->
        Mix.shell().error("Expected exactly one module name")
    end
  end

  defp generate_command(module_name, opts) do
    creates_ref = Keyword.get(opts, :creates_ref)
    semantics = Keyword.get(opts, :semantics, "sync")
    fields = parse_fields(Keyword.get(opts, :fields, ""))

    # Warn about deprecated --creates-ref option
    if creates_ref do
      Mix.shell().info("""
      WARNING: --creates-ref is deprecated.
      Use external() in event struct definitions instead:

          defmodule MyApp.Events.YourEvent do
            import PropertyDamage, only: [external: 0]
            defstruct [:other_field, #{creates_ref}: external()]
          end

      See `PropertyDamage.external/0` for documentation.
      """)
    end

    # Parse module name to get path
    path = module_to_path(module_name)
    dir = Path.dirname(path)

    # Ensure directory exists
    File.mkdir_p!(dir)

    # Generate content
    content = generate_content(module_name, fields, creates_ref, semantics)

    # Write file
    File.write!(path, content)

    Mix.shell().info("Generated #{path}")
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  1. Implement the generator in new!/2")
    Mix.shell().info("  2. Add precondition logic if needed")
    Mix.shell().info("  3. Add to your model's commands/0")

    if creates_ref do
      Mix.shell().info("  4. Create a corresponding event module")
    end
  end

  defp parse_fields(""), do: []
  defp parse_fields(fields), do: String.split(fields, ",") |> Enum.map(&String.trim/1)

  defp module_to_path(module_name) do
    path =
      module_name
      |> String.split(".")
      |> Enum.map_join("/", &Macro.underscore/1)

    "lib/#{path}.ex"
  end

  defp generate_content(module_name, fields, creates_ref, semantics) do
    fields_atoms = Enum.map(fields, &String.to_atom/1)
    defstruct_line = if fields == [], do: "[]", else: inspect(fields_atoms)

    semantics_function =
      case semantics do
        "sync" -> ""
        other -> "\n  def semantics, do: :#{other}\n"
      end

    creates_ref_function =
      if creates_ref do
        "\n  def creates_ref, do: :#{creates_ref}\n"
      else
        ""
      end

    generator_body = generate_generator_body(fields)

    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      TODO: Add description for this command.
      \"\"\"

      @behaviour PropertyDamage.Command

      defstruct #{defstruct_line}

      @impl true
      def precondition(_state) do
        # TODO: Return true if this command can be generated in current state
        true
      end

      @impl true
      def new!(state, overrides \\\\ %{}) do
        #{generator_body}
      end
    #{semantics_function}#{creates_ref_function}end
    """
  end

  defp generate_generator_body([]) do
    "StreamData.constant(%__MODULE__{})"
  end

  defp generate_generator_body(fields) do
    field_generators =
      fields
      |> Enum.map_join(",\n      ", fn field ->
        if String.ends_with?(field, "_ref") do
          "#{field}: StreamData.constant(:TODO_pick_from_state)"
        else
          "#{field}: StreamData.constant(:TODO)"
        end
      end)

    """
    %{
          #{field_generators}
        }
        |> PropertyDamage.Generator.merge_overrides(overrides)
        |> StreamData.fixed_map()
        |> StreamData.map(&struct!(__MODULE__, &1))
    """
  end
end
