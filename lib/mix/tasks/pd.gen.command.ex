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
    Mix.shell().info("  1. Fill in the field generators in generator/1")
    Mix.shell().info("  2. Add to your model's commands/0 (use when: for preconditions)")

    if creates_ref do
      Mix.shell().info("  3. Create a corresponding event module")
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
        other -> "\n  @impl true\n  def semantics, do: :#{other}\n"
      end

    creates_ref_function =
      if creates_ref do
        "\n  @impl true\n  def creates_ref, do: :#{creates_ref}\n"
      else
        ""
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

      @behaviour PropertyDamage.Command

      defstruct #{defstruct_line}

      @impl true
      def generator(#{overrides_param} \\\\ %{}) do
        # Returns a StreamData generator of field maps; the framework maps each
        # to a %#{module_name}{} struct.
        #{generator_body}
      end
    #{semantics_function}#{creates_ref_function}end
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
