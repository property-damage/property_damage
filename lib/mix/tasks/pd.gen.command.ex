defmodule Mix.Tasks.Pd.Gen.Command do
  @moduledoc """
  Generate a PropertyDamage command module.

  ## Usage

      mix pd.gen.command MyApp.Commands.CreateUser

  ## Options

      --semantics SEM       Command semantics (sync, probe, async)
      --fields FIELDS       Comma-separated field names

  ## Server-generated values

  Commands no longer declare the refs they create. Instead, mark
  server-generated fields with `external()` in your event struct definitions:

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
        strict: [semantics: :string, fields: :string]
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
    semantics = Keyword.get(opts, :semantics, "sync")
    fields = parse_fields(Keyword.get(opts, :fields, ""))

    # Parse module name to get path
    path = module_to_path(module_name)
    dir = Path.dirname(path)

    # Ensure directory exists
    File.mkdir_p!(dir)

    # Generate content
    content = generate_content(module_name, fields, semantics)

    # Write file
    File.write!(path, content)

    Mix.shell().info("Generated #{path}")
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  1. Fill in the field generators in generator/1")
    Mix.shell().info("  2. Add to your model's commands/0 (use when: for preconditions)")
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

  defp generate_content(module_name, fields, semantics) do
    fields_atoms = Enum.map(fields, &String.to_atom/1)
    defstruct_line = if fields == [], do: "[]", else: inspect(fields_atoms)

    # Static metadata (execution semantics, etc.) is declared on the single
    # command_spec/1 surface via `use` options (DR-028).
    use_line =
      case semantics do
        "sync" -> "use PropertyDamage.Command"
        other -> "use PropertyDamage.Command, execution: :#{other}"
      end

    generator_body = generate_generator_body(fields)
    # With no fields the body ignores overrides; underscore it to stay warning-free.
    overrides_param = if fields == [], do: "_overrides", else: "overrides"

    """
    defmodule #{module_name} do
      @moduledoc \"\"\"
      TODO: Add description for this command.

      Preconditions (when this command may run) belong in the model's
      `when:` option, not here.
      \"\"\"

      #{use_line}

      defstruct #{defstruct_line}

      @impl true
      def generator(#{overrides_param} \\\\ %{}) do
        # Returns a StreamData generator of field maps; the framework maps each
        # to a %#{module_name}{} struct.
        #{generator_body}
      end
    end
    """
  end

  defp generate_generator_body([]) do
    "StreamData.constant(%{})"
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
    """
  end
end
