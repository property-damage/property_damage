defmodule Mix.Tasks.Pd.Scaffold do
  @shortdoc "Generate command modules from OpenAPI specification"
  @moduledoc """
  Generate PropertyDamage command module skeletons from an OpenAPI specification.

  This dramatically reduces the initial setup time for testing REST APIs by
  automatically creating command modules with:

  - Correct struct fields from request body schemas
  - Typed field specifications
  - Placeholder generator functions
  - Adapter execute hints

  ## Usage

      # From an OpenAPI JSON file
      mix pd.scaffold --from openapi.json --output lib/my_app_test/commands/

      # From a URL
      mix pd.scaffold --from https://api.example.com/openapi.json --output lib/

      # Only specific operations
      mix pd.scaffold --from openapi.json --operations createUser,updateUser

  ## Options

  - `--from` - Path or URL to OpenAPI spec (JSON or YAML)
  - `--output` - Output directory for generated files (default: lib/commands/)
  - `--operations` - Comma-separated list of operationIds to generate
  - `--namespace` - Module namespace prefix (e.g., MyAppTest.Commands)
  - `--dry-run` - Print what would be generated without writing files

  ## What Gets Generated

  For each operation in the OpenAPI spec, a command module is created:

  ```elixir
  defmodule MyAppTest.Commands.CreateUser do
    @moduledoc \"\"\"
    POST /users - Create a new user

    Generated from OpenAPI operationId: createUser
    \"\"\"

    use PropertyDamage.Command

    defstruct [:name, :email, :role]

    @impl true
    def new!(state, generators) do
      %__MODULE__{
        name: # TODO: Add generator
        email: # TODO: Add generator
        role: # TODO: Add generator
      }
    end

    # ... other callbacks
  end
  ```

  ## After Generation

  You'll need to:

  1. Implement generators in `new!/2` for each field
  2. Define the `events/2` callback based on response
  3. Add preconditions if needed
  4. Register commands in your Model
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          from: :string,
          output: :string,
          operations: :string,
          namespace: :string,
          dry_run: :boolean
        ]
      )

    from = Keyword.get(opts, :from) || Mix.raise("--from is required")
    output = Keyword.get(opts, :output, "lib/commands/")
    namespace = Keyword.get(opts, :namespace, "Commands")
    dry_run = Keyword.get(opts, :dry_run, false)

    operations_filter =
      case Keyword.get(opts, :operations) do
        nil -> nil
        ops -> String.split(ops, ",") |> MapSet.new()
      end

    # Load and parse OpenAPI spec
    Mix.shell().info("Loading OpenAPI spec from #{from}...")

    spec =
      case load_spec(from) do
        {:ok, spec} -> spec
        {:error, reason} -> Mix.raise("Failed to load spec: #{inspect(reason)}")
      end

    # Extract operations
    operations = extract_operations(spec, operations_filter)
    Mix.shell().info("Found #{length(operations)} operations to generate")

    if dry_run do
      Mix.shell().info("\n[DRY RUN] Would generate:")

      for op <- operations do
        Mix.shell().info("  - #{op.module_name} (#{op.method} #{op.path})")
      end
    else
      # Ensure output directory exists
      File.mkdir_p!(output)

      # Generate files
      for op <- operations do
        content = generate_command(op, namespace)
        filename = Macro.underscore(op.module_name) <> ".ex"
        path = Path.join(output, filename)

        Mix.shell().info("Generating #{path}...")
        File.write!(path, content)
      end

      Mix.shell().info("\nGenerated #{length(operations)} command modules in #{output}")
      Mix.shell().info("\nNext steps:")
      Mix.shell().info("  1. Implement generators in new!/2")
      Mix.shell().info("  2. Define events/2 based on expected responses")
      Mix.shell().info("  3. Add commands to your Model")
    end
  end

  # ============================================================================
  # Spec Loading
  # ============================================================================

  defp load_spec(path_or_url) do
    content =
      if String.starts_with?(path_or_url, "http") do
        case Req.get(path_or_url) do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          {:ok, %{status: status}} -> {:error, {:http_error, status}}
          {:error, reason} -> {:error, reason}
        end
      else
        File.read(path_or_url)
      end

    case content do
      {:ok, body} when is_binary(body) ->
        parse_spec(body, path_or_url)

      {:ok, body} when is_map(body) ->
        {:ok, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_spec(content, path) do
    cond do
      String.ends_with?(path, ".yaml") or String.ends_with?(path, ".yml") ->
        # Would need a YAML parser - for now just support JSON
        {:error, :yaml_not_supported}

      true ->
        Jason.decode(content)
    end
  end

  # ============================================================================
  # Operation Extraction
  # ============================================================================

  defp extract_operations(spec, filter) do
    paths = Map.get(spec, "paths", %{})

    for {path, methods} <- paths,
        {method, op} <- methods,
        method in ["get", "post", "put", "patch", "delete"],
        operation_id = Map.get(op, "operationId"),
        filter == nil or MapSet.member?(filter, operation_id) do
      %{
        operation_id: operation_id,
        module_name: to_module_name(operation_id),
        method: String.upcase(method),
        path: path,
        summary: Map.get(op, "summary", ""),
        description: Map.get(op, "description", ""),
        parameters: extract_parameters(op, spec),
        request_body: extract_request_body(op, spec),
        responses: extract_responses(op, spec)
      }
    end
  end

  defp to_module_name(nil), do: "UnnamedOperation"

  defp to_module_name(operation_id) do
    operation_id
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> Macro.camelize()
  end

  defp extract_parameters(op, spec) do
    params = Map.get(op, "parameters", [])

    Enum.map(params, fn param ->
      param = resolve_ref(param, spec)

      %{
        name: Map.get(param, "name"),
        in: Map.get(param, "in"),
        required: Map.get(param, "required", false),
        schema: resolve_ref(Map.get(param, "schema", %{}), spec),
        description: Map.get(param, "description", "")
      }
    end)
  end

  defp extract_request_body(op, spec) do
    case Map.get(op, "requestBody") do
      nil ->
        nil

      body ->
        body = resolve_ref(body, spec)
        content = Map.get(body, "content", %{})

        # Prefer JSON content type
        json_schema =
          get_in(content, ["application/json", "schema"]) ||
            get_in(content, [Access.at(0), "schema"])

        case json_schema do
          nil -> nil
          schema -> resolve_ref(schema, spec)
        end
    end
  end

  defp extract_responses(op, spec) do
    responses = Map.get(op, "responses", %{})

    for {status, response} <- responses, into: %{} do
      response = resolve_ref(response, spec)
      content = Map.get(response, "content", %{})
      schema = get_in(content, ["application/json", "schema"])

      {status,
       %{
         description: Map.get(response, "description", ""),
         schema: schema && resolve_ref(schema, spec)
       }}
    end
  end

  defp resolve_ref(%{"$ref" => ref}, spec) do
    # Handle #/components/schemas/Foo references
    case String.split(ref, "/") do
      ["#", "components", "schemas", name] ->
        get_in(spec, ["components", "schemas", name]) || %{}

      ["#", "components", "parameters", name] ->
        get_in(spec, ["components", "parameters", name]) || %{}

      ["#", "components", "requestBodies", name] ->
        get_in(spec, ["components", "requestBodies", name]) || %{}

      ["#", "components", "responses", name] ->
        get_in(spec, ["components", "responses", name]) || %{}

      _ ->
        %{}
    end
  end

  defp resolve_ref(other, _spec), do: other

  # ============================================================================
  # Code Generation
  # ============================================================================

  defp generate_command(op, namespace) do
    fields = collect_fields(op)
    field_atoms = Enum.map(fields, fn f -> String.to_atom(f.name) end)

    """
    defmodule #{namespace}.#{op.module_name} do
      @moduledoc \"\"\"
      #{op.method} #{op.path}#{if op.summary != "", do: " - #{op.summary}", else: ""}

      #{if op.description != "", do: op.description <> "\n\n", else: ""}Generated from OpenAPI operationId: #{op.operation_id}
      \"\"\"

      use PropertyDamage.Command

      defstruct #{inspect(field_atoms)}

    #{generate_field_types(fields)}
      @impl true
      def new!(state, generators) do
        %__MODULE__{
    #{generate_field_assignments(fields)}    }
      end

      @impl true
      def precondition(_state), do: true

      @impl true
      def events(_command, response) do
        # TODO: Define events based on #{op.method} #{op.path} response
        # Example:
        # [%MyEvent{id: response["id"]}]
        []
      end

      @impl true
      def ref(_command, response) do
        # TODO: Return a ref if this command creates a resource
        # Example: response["id"]
        nil
      end

      # Adapter hint: #{op.method} #{op.path}
      # Parameters: #{inspect(Enum.map(op.parameters, & &1.name))}
    end
    """
  end

  defp collect_fields(op) do
    # Collect from parameters
    param_fields =
      op.parameters
      |> Enum.filter(&(&1.in in ["path", "query", "body"]))
      |> Enum.map(fn p ->
        %{
          name: to_field_name(p.name),
          type: schema_to_type(p.schema),
          required: p.required,
          description: p.description,
          source: p.in
        }
      end)

    # Collect from request body
    body_fields =
      case op.request_body do
        nil ->
          []

        schema ->
          properties = Map.get(schema, "properties", %{})
          required = MapSet.new(Map.get(schema, "required", []))

          Enum.map(properties, fn {name, prop_schema} ->
            %{
              name: to_field_name(name),
              type: schema_to_type(prop_schema),
              required: MapSet.member?(required, name),
              description: Map.get(prop_schema, "description", ""),
              source: "body"
            }
          end)
      end

    param_fields ++ body_fields
  end

  defp to_field_name(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> Macro.underscore()
  end

  defp schema_to_type(%{"type" => "string", "format" => "uuid"}), do: "uuid"
  defp schema_to_type(%{"type" => "string", "format" => "date-time"}), do: "datetime"
  defp schema_to_type(%{"type" => "string", "format" => "email"}), do: "email"
  defp schema_to_type(%{"type" => "string", "enum" => values}), do: {:enum, values}
  defp schema_to_type(%{"type" => "string"}), do: "string"
  defp schema_to_type(%{"type" => "integer"}), do: "integer"
  defp schema_to_type(%{"type" => "number"}), do: "number"
  defp schema_to_type(%{"type" => "boolean"}), do: "boolean"
  defp schema_to_type(%{"type" => "array"}), do: "list"
  defp schema_to_type(%{"type" => "object"}), do: "map"
  defp schema_to_type(_), do: "any"

  defp generate_field_types(fields) do
    fields
    |> Enum.map(fn f ->
      type_str = format_type(f.type)

      "  # @type #{f.name}: #{type_str}#{if f.description != "", do: " - #{f.description}", else: ""}"
    end)
    |> Enum.join("\n")
    |> then(&(&1 <> "\n\n"))
  end

  defp format_type({:enum, values}), do: "#{inspect(values)}"
  defp format_type(type), do: type

  defp generate_field_assignments(fields) do
    fields
    |> Enum.map(fn f ->
      generator_hint = generator_hint(f.type, f.name)
      "      #{f.name}: #{generator_hint}"
    end)
    |> Enum.join(",\n")
    |> then(&(&1 <> "\n"))
  end

  defp generator_hint("uuid", _), do: "UUID.uuid4() # or use generators.uuid.()"

  defp generator_hint("email", name) do
    # Generate a string like: "\#{Enum.random(?a..?z)}_foo@example.com"
    "\"\#" <> "{Enum.random(?a..?z)}_" <> name <> "@example.com\""
  end

  defp generator_hint("string", _), do: ~S[StreamData.string(:alphanumeric) |> Enum.at(0)]
  defp generator_hint("integer", _), do: "Enum.random(1..1000)"
  defp generator_hint("number", _), do: ":rand.uniform() * 1000"
  defp generator_hint("boolean", _), do: "Enum.random([true, false])"
  defp generator_hint({:enum, values}, _), do: "Enum.random(#{inspect(values)})"
  defp generator_hint(_, _), do: "nil # TODO: Add generator"
end
