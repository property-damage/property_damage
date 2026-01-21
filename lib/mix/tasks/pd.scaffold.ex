defmodule Mix.Tasks.Pd.Scaffold do
  @shortdoc "Generate complete PropertyDamage test suite from OpenAPI specification"
  @moduledoc """
  Generate a complete PropertyDamage test suite from an OpenAPI specification.

  This dramatically reduces setup time for testing REST APIs by automatically
  generating:

  - Command modules with generators
  - Event structs from response schemas
  - HTTP adapter with execute clauses
  - Model module with command weights
  - Authentication support

  ## Usage

      # Generate everything from an OpenAPI spec
      mix pd.scaffold --from openapi.json --output lib/my_app_test/

      # From a URL
      mix pd.scaffold --from https://api.example.com/openapi.json --output lib/

      # Only specific operations
      mix pd.scaffold --from openapi.json --operations createUser,updateUser

      # Generate only commands (skip adapter/model)
      mix pd.scaffold --from openapi.json --commands-only

      # Preview without writing files
      mix pd.scaffold --from openapi.json --dry-run

  ## Options

  - `--from` - Path or URL to OpenAPI spec (JSON or YAML)
  - `--output` - Output directory for generated files (default: lib/generated/)
  - `--operations` - Comma-separated list of operationIds to generate
  - `--namespace` - Module namespace prefix (e.g., MyAppTest)
  - `--commands-only` - Only generate command modules
  - `--dry-run` - Print what would be generated without writing files
  - `--base-url` - Base URL for the API (overrides spec's servers)

  ## What Gets Generated

  ### Commands (one per operation)

  ```elixir
  defmodule MyAppTest.Commands.CreateUser do
    use PropertyDamage.Command
    defstruct [:name, :email, :role]

    @impl true
    def new!(_state, _generators) do
      %__MODULE__{
        name: Faker.Person.name(),
        email: Faker.Internet.email(),
        role: Enum.random(["admin", "user", "guest"])
      }
    end
    # ...
  end
  ```

  ### Events (from response schemas)

  ```elixir
  defmodule MyAppTest.Events.UserCreated do
    defstruct [:id, :name, :email, :role, :created_at]
  end
  ```

  ### Adapter

  ```elixir
  defmodule MyAppTest.Adapter do
    @behaviour PropertyDamage.Adapter

    def execute(%Commands.CreateUser{} = cmd, ctx) do
      Req.post!(ctx.base_url <> "/users", json: Map.from_struct(cmd)).body
    end
    # ...
  end
  ```

  ### Model

  ```elixir
  defmodule MyAppTest.Model do
    @behaviour PropertyDamage.Model

    def commands do
      [
        {5, Commands.CreateUser},
        {3, Commands.GetUser},
        # ...
      ]
    end

    def state_projection, do: MyAppTest.Projections.State
    def extra_projections, do: [MyAppTest.Projections.UniqueUsers]
  end
  ```

  ## YAML Support

  YAML files (.yaml, .yml) are supported if `yaml_elixir` is installed:

      {:yaml_elixir, "~> 2.9"}

  ## After Generation

  1. Review and customize generators in command `generator/1` callbacks
  2. Define events/2 to map responses to your event structs
  3. Add preconditions (when:) and overrides (with:) in the Model's commands()
  4. Implement simulate/2 in the Model for expected events
  5. Configure authentication in the adapter
  6. Add invariants/projections to the model
  """

  use Mix.Task

  # Suppress warnings for optional Req/YamlElixir dependencies (guarded at runtime)
  @compile {:no_warn_undefined, [Req, YamlElixir]}

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
          dry_run: :boolean,
          commands_only: :boolean,
          base_url: :string
        ]
      )

    from = Keyword.get(opts, :from) || Mix.raise("--from is required")
    output = Keyword.get(opts, :output, "lib/generated/")
    namespace = Keyword.get(opts, :namespace) || infer_namespace(output)
    dry_run = Keyword.get(opts, :dry_run, false)
    commands_only = Keyword.get(opts, :commands_only, false)
    base_url_override = Keyword.get(opts, :base_url)

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

    # Extract API info
    api_info = extract_api_info(spec, base_url_override)
    Mix.shell().info("API: #{api_info.title} (#{api_info.version})")

    # Extract operations
    operations = extract_operations(spec, operations_filter)
    Mix.shell().info("Found #{length(operations)} operations to generate")

    # Extract authentication schemes
    auth_schemes = extract_auth_schemes(spec)

    if length(auth_schemes) > 0 do
      Mix.shell().info("Authentication: #{Enum.map(auth_schemes, & &1.name) |> Enum.join(", ")}")
    end

    if dry_run do
      print_dry_run(operations, namespace, commands_only, auth_schemes)
    else
      generate_files(operations, namespace, output, commands_only, api_info, auth_schemes)
    end
  end

  # ============================================================================
  # Spec Loading
  # ============================================================================

  defp load_spec(path_or_url) do
    content =
      if String.starts_with?(path_or_url, "http") do
        fetch_url(path_or_url)
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

  defp fetch_url(url) do
    if Code.ensure_loaded?(Req) do
      case Req.get(url) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: status}} -> {:error, {:http_error, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      # Fallback to :httpc if Req not available
      Application.ensure_all_started(:inets)
      Application.ensure_all_started(:ssl)

      case :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary) do
        {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
        {:ok, {{_, status, _}, _, _}} -> {:error, {:http_error, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_spec(content, path) do
    cond do
      String.ends_with?(path, ".yaml") or String.ends_with?(path, ".yml") ->
        parse_yaml(content)

      String.contains?(content, "openapi:") and not String.starts_with?(content, "{") ->
        # Looks like YAML content even without .yaml extension
        parse_yaml(content)

      true ->
        Jason.decode(content)
    end
  end

  defp parse_yaml(content) do
    if Code.ensure_loaded?(YamlElixir) do
      YamlElixir.read_from_string(content)
    else
      {:error,
       {:yaml_not_supported,
        "Install yaml_elixir to parse YAML specs: {:yaml_elixir, \"~> 2.9\"}"}}
    end
  end

  # ============================================================================
  # API Info Extraction (public for testing)
  # ============================================================================

  @doc false
  def extract_api_info(spec, base_url_override) do
    info = Map.get(spec, "info", %{})
    servers = Map.get(spec, "servers", [])

    base_url =
      base_url_override ||
        case servers do
          [%{"url" => url} | _] -> url
          _ -> "http://localhost:4000"
        end

    %{
      title: Map.get(info, "title", "API"),
      version: Map.get(info, "version", "1.0.0"),
      description: Map.get(info, "description", ""),
      base_url: base_url
    }
  end

  @doc false
  def extract_auth_schemes(spec) do
    security_schemes = get_in(spec, ["components", "securitySchemes"]) || %{}

    Enum.map(security_schemes, fn {name, scheme} ->
      %{
        name: name,
        type: Map.get(scheme, "type"),
        scheme: Map.get(scheme, "scheme"),
        bearer_format: Map.get(scheme, "bearerFormat"),
        in: Map.get(scheme, "in"),
        param_name: Map.get(scheme, "name"),
        description: Map.get(scheme, "description", "")
      }
    end)
  end

  # ============================================================================
  # Operation Extraction (public for testing)
  # ============================================================================

  @doc false
  def extract_operations(spec, filter) do
    paths = Map.get(spec, "paths", %{})

    for {path, methods} <- paths,
        {method, op} <- methods,
        is_map(op),
        method in ["get", "post", "put", "patch", "delete"],
        operation_id = Map.get(op, "operationId"),
        filter == nil or MapSet.member?(filter, operation_id) do
      %{
        operation_id: operation_id,
        module_name: to_module_name(operation_id),
        method: String.upcase(method),
        method_atom: String.to_atom(method),
        path: path,
        summary: Map.get(op, "summary", ""),
        description: Map.get(op, "description", ""),
        parameters: extract_parameters(op, spec),
        request_body: extract_request_body(op, spec),
        responses: extract_responses(op, spec),
        tags: Map.get(op, "tags", []),
        security: Map.get(op, "security", [])
      }
    end
    |> Enum.sort_by(& &1.operation_id)
  end

  @doc false
  def to_module_name(nil), do: "UnnamedOperation"

  @doc false
  def to_module_name(operation_id) do
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
        field_name: to_field_name(Map.get(param, "name")),
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
        required = Map.get(body, "required", false)

        # Prefer JSON content type
        json_schema =
          get_in(content, ["application/json", "schema"]) ||
            get_first_content_schema(content)

        case json_schema do
          nil -> nil
          schema -> %{schema: resolve_ref(schema, spec), required: required}
        end
    end
  end

  defp get_first_content_schema(content) when map_size(content) > 0 do
    {_type, data} = Enum.at(content, 0)
    Map.get(data, "schema")
  end

  defp get_first_content_schema(_), do: nil

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
    case String.split(ref, "/") do
      ["#", "components", component_type, name] ->
        get_in(spec, ["components", component_type, name]) || %{}

      _ ->
        %{}
    end
  end

  defp resolve_ref(other, _spec), do: other || %{}

  # ============================================================================
  # File Generation
  # ============================================================================

  defp print_dry_run(operations, namespace, commands_only, auth_schemes) do
    Mix.shell().info("\n[DRY RUN] Would generate:\n")

    Mix.shell().info("Commands:")

    for op <- operations do
      Mix.shell().info("  - #{namespace}.Commands.#{op.module_name} (#{op.method} #{op.path})")
    end

    # Events from responses
    events = collect_event_names(operations)

    if length(events) > 0 do
      Mix.shell().info("\nEvents:")

      for event <- events do
        Mix.shell().info("  - #{namespace}.Events.#{event}")
      end
    end

    unless commands_only do
      Mix.shell().info("\nAdapter:")
      Mix.shell().info("  - #{namespace}.Adapter")

      if length(auth_schemes) > 0 do
        Mix.shell().info("    (with #{length(auth_schemes)} auth scheme(s))")
      end

      Mix.shell().info("\nModel:")
      Mix.shell().info("  - #{namespace}.Model")
    end
  end

  defp generate_files(operations, namespace, output, commands_only, api_info, auth_schemes) do
    # Create directory structure
    commands_dir = Path.join(output, "commands")
    events_dir = Path.join(output, "events")
    File.mkdir_p!(commands_dir)
    File.mkdir_p!(events_dir)

    # Generate commands
    Mix.shell().info("\nGenerating commands...")

    for op <- operations do
      content = generate_command(op, namespace)
      filename = Macro.underscore(op.module_name) <> ".ex"
      path = Path.join(commands_dir, filename)
      Mix.shell().info("  #{path}")
      File.write!(path, content)
    end

    # Generate events
    events_data = collect_events_data(operations)

    if length(events_data) > 0 do
      Mix.shell().info("\nGenerating events...")

      for event <- events_data do
        content = generate_event(event, namespace)
        filename = Macro.underscore(event.name) <> ".ex"
        path = Path.join(events_dir, filename)
        Mix.shell().info("  #{path}")
        File.write!(path, content)
      end
    end

    unless commands_only do
      # Generate adapter
      Mix.shell().info("\nGenerating adapter...")
      adapter_content = generate_adapter(operations, namespace, api_info, auth_schemes)
      adapter_path = Path.join(output, "adapter.ex")
      Mix.shell().info("  #{adapter_path}")
      File.write!(adapter_path, adapter_content)

      # Generate model
      Mix.shell().info("\nGenerating model...")
      model_content = generate_model(operations, namespace)
      model_path = Path.join(output, "model.ex")
      Mix.shell().info("  #{model_path}")
      File.write!(model_path, model_content)
    end

    Mix.shell().info("\n✓ Generated #{length(operations)} commands in #{output}")

    Mix.shell().info("\nNext steps:")
    Mix.shell().info("  1. Review and customize generators in command generator/1 callbacks")
    Mix.shell().info("  2. Define events/2 to map responses to event structs")
    Mix.shell().info("  3. Add when:/with: options in Model's commands() for preconditions")
    Mix.shell().info("  4. Implement simulate/2 in Model for expected events")
    Mix.shell().info("  5. Configure authentication in adapter")
  end

  # ============================================================================
  # Command Generation
  # ============================================================================

  @doc false
  def generate_command(op, namespace) do
    fields = collect_fields(op)
    field_atoms = Enum.map(fields, fn f -> String.to_atom(f.name) end)

    path_params = Enum.filter(op.parameters, &(&1.in == "path"))
    query_params = Enum.filter(op.parameters, &(&1.in == "query"))

    """
    defmodule #{namespace}.Commands.#{op.module_name} do
      @moduledoc \"\"\"
      #{op.method} #{op.path}#{if op.summary != "", do: " - #{op.summary}", else: ""}

      #{String.trim(op.description)}

      Generated from OpenAPI operationId: #{op.operation_id}

      Note: Preconditions and state-dependent overrides should be defined in the Model's
      commands/0 using `when:` and `with:` options. Simulate logic belongs in the Model's
      `simulate/2` callback.
      \"\"\"

      @behaviour PropertyDamage.Command
      import PropertyDamage.Generator, only: [merge_overrides: 2]

      defstruct #{inspect(field_atoms)}

    #{generate_field_docs(fields)}
      @impl true
      def generator(overrides \\\\ %{}) do
        %{
    #{generate_field_generators(fields)}    }
        |> merge_overrides(overrides)
        |> StreamData.fixed_map()
      end

      def events(command, response) do
        # TODO: Map response to events
        # Example: [%#{namespace}.Events.#{infer_event_name(op)}{}]
        _ = {command, response}
        []
      end

      #{if op.method == "POST", do: "# DEPRECATED: Use external() in event structs instead of creates_ref\n  # def creates_ref, do: :id\n  # See: event struct below should use `defstruct [id: external(), ...]`", else: ""}

      #{if op.method in ["GET", "HEAD", "OPTIONS"], do: "def read_only?, do: true", else: ""}

      # HTTP Info (for adapter)
      def __http_method__, do: :#{String.downcase(op.method)}
      def __http_path__, do: "#{op.path}"
      #{if length(path_params) > 0, do: "def __path_params__, do: #{inspect(Enum.map(path_params, &String.to_atom(&1.field_name)))}", else: ""}
      #{if length(query_params) > 0, do: "def __query_params__, do: #{inspect(Enum.map(query_params, &String.to_atom(&1.field_name)))}", else: ""}
    end
    """
  end

  defp collect_fields(op) do
    # Collect from path/query parameters
    param_fields =
      op.parameters
      |> Enum.filter(&(&1.in in ["path", "query"]))
      |> Enum.map(fn p ->
        %{
          name: p.field_name,
          original_name: p.name,
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

        %{schema: schema} ->
          properties = Map.get(schema, "properties", %{})
          required = MapSet.new(Map.get(schema, "required", []))

          Enum.map(properties, fn {name, prop_schema} ->
            %{
              name: to_field_name(name),
              original_name: name,
              type: schema_to_type(prop_schema),
              required: MapSet.member?(required, name),
              description: Map.get(prop_schema, "description", ""),
              source: "body"
            }
          end)
      end

    param_fields ++ body_fields
  end

  @doc false
  def to_field_name(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> Macro.underscore()
  end

  @doc false
  def schema_to_type(%{"type" => "string", "format" => "uuid"}), do: :uuid
  def schema_to_type(%{"type" => "string", "format" => "date-time"}), do: :datetime
  def schema_to_type(%{"type" => "string", "format" => "date"}), do: :date
  def schema_to_type(%{"type" => "string", "format" => "email"}), do: :email
  def schema_to_type(%{"type" => "string", "format" => "uri"}), do: :uri
  def schema_to_type(%{"type" => "string", "enum" => values}), do: {:enum, values}

  def schema_to_type(%{"type" => "string", "minLength" => min, "maxLength" => max}),
    do: {:string, min, max}

  def schema_to_type(%{"type" => "string", "minLength" => min}), do: {:string, min, 100}
  def schema_to_type(%{"type" => "string", "maxLength" => max}), do: {:string, 1, max}
  def schema_to_type(%{"type" => "string", "pattern" => pattern}), do: {:pattern, pattern}
  def schema_to_type(%{"type" => "string"}), do: :string

  def schema_to_type(%{"type" => "integer", "minimum" => min, "maximum" => max}),
    do: {:integer, min, max}

  def schema_to_type(%{"type" => "integer", "minimum" => min}), do: {:integer, min, 10000}
  def schema_to_type(%{"type" => "integer", "maximum" => max}), do: {:integer, 0, max}
  def schema_to_type(%{"type" => "integer"}), do: :integer

  def schema_to_type(%{"type" => "number", "minimum" => min, "maximum" => max}),
    do: {:number, min, max}

  def schema_to_type(%{"type" => "number"}), do: :number
  def schema_to_type(%{"type" => "boolean"}), do: :boolean
  def schema_to_type(%{"type" => "array", "items" => items}), do: {:array, schema_to_type(items)}
  def schema_to_type(%{"type" => "array"}), do: {:array, :any}
  def schema_to_type(%{"type" => "object"}), do: :map
  def schema_to_type(_), do: :any

  defp generate_field_docs(fields) do
    fields
    |> Enum.map(fn f ->
      type_str = format_type_doc(f.type)
      req = if f.required, do: "required", else: "optional"
      desc = if f.description != "", do: " - #{f.description}", else: ""
      "  # #{f.name}: #{type_str} (#{req}, #{f.source})#{desc}"
    end)
    |> Enum.join("\n")
    |> then(&(&1 <> "\n\n"))
  end

  defp format_type_doc(:uuid), do: "UUID"
  defp format_type_doc(:email), do: "email"
  defp format_type_doc(:datetime), do: "datetime"
  defp format_type_doc(:date), do: "date"
  defp format_type_doc(:uri), do: "URI"
  defp format_type_doc(:string), do: "string"
  defp format_type_doc(:integer), do: "integer"
  defp format_type_doc(:number), do: "number"
  defp format_type_doc(:boolean), do: "boolean"
  defp format_type_doc(:map), do: "map"
  defp format_type_doc(:any), do: "any"
  defp format_type_doc({:enum, values}), do: "enum #{inspect(values)}"
  defp format_type_doc({:string, min, max}), do: "string[#{min}..#{max}]"
  defp format_type_doc({:integer, min, max}), do: "integer[#{min}..#{max}]"
  defp format_type_doc({:number, min, max}), do: "number[#{min}..#{max}]"
  defp format_type_doc({:array, inner}), do: "array of #{format_type_doc(inner)}"
  defp format_type_doc({:pattern, p}), do: "string matching #{p}"

  defp generate_field_generators(fields) do
    fields
    |> Enum.map(fn f ->
      generator = streamdata_generator_for_type(f.type, f.name, f.source)
      "      #{f.name}: #{generator}"
    end)
    |> Enum.join(",\n")
    |> then(&(&1 <> "\n"))
  end

  @doc false
  def streamdata_generator_for_type(:uuid, _name, _source) do
    "StreamData.constant(Ecto.UUID.generate())"
  end

  def streamdata_generator_for_type(:email, name, _source) do
    ~s[StreamData.map(StreamData.positive_integer(), &"test_#{name}_\#{&1}@example.com")]
  end

  def streamdata_generator_for_type(:datetime, _name, _source) do
    "StreamData.constant(DateTime.utc_now() |> DateTime.to_iso8601())"
  end

  def streamdata_generator_for_type(:date, _name, _source) do
    "StreamData.constant(Date.utc_today() |> Date.to_iso8601())"
  end

  def streamdata_generator_for_type(:uri, name, _source) do
    ~s[StreamData.map(StreamData.positive_integer(), &"https://example.com/#{name}/\#{&1}")]
  end

  def streamdata_generator_for_type(:string, _name, _source) do
    "StreamData.string(:alphanumeric, min_length: 5, max_length: 20)"
  end

  def streamdata_generator_for_type({:string, min, max}, _name, _source) do
    "StreamData.string(:alphanumeric, min_length: #{min}, max_length: #{max})"
  end

  def streamdata_generator_for_type({:pattern, _pattern}, _name, _source) do
    "# TODO: Generate string matching pattern\n      StreamData.constant(nil)"
  end

  def streamdata_generator_for_type(:integer, _name, _source) do
    "StreamData.integer(1..1000)"
  end

  def streamdata_generator_for_type({:integer, min, max}, _name, _source) do
    "StreamData.integer(#{min}..#{max})"
  end

  def streamdata_generator_for_type(:number, _name, _source) do
    "StreamData.float(min: 0.0, max: 1000.0)"
  end

  def streamdata_generator_for_type({:number, min, max}, _name, _source) do
    "StreamData.float(min: #{min}, max: #{max})"
  end

  def streamdata_generator_for_type(:boolean, _name, _source) do
    "StreamData.boolean()"
  end

  def streamdata_generator_for_type({:enum, values}, _name, _source) do
    "StreamData.member_of(#{inspect(values)})"
  end

  def streamdata_generator_for_type({:array, inner_type}, name, source) do
    inner_gen = streamdata_generator_for_type(inner_type, name, source)
    "StreamData.list_of(#{inner_gen}, min_length: 1, max_length: 3)"
  end

  def streamdata_generator_for_type(:map, _name, _source) do
    "StreamData.constant(%{})"
  end

  def streamdata_generator_for_type(:any, name, source) do
    "# TODO: Implement generator for #{name} (#{source})\n      StreamData.constant(nil)"
  end

  defp infer_event_name(op) do
    base =
      cond do
        String.starts_with?(op.operation_id || "", "create") -> "Created"
        String.starts_with?(op.operation_id || "", "update") -> "Updated"
        String.starts_with?(op.operation_id || "", "delete") -> "Deleted"
        String.starts_with?(op.operation_id || "", "get") -> "Retrieved"
        String.starts_with?(op.operation_id || "", "list") -> "Listed"
        true -> "Completed"
      end

    # Extract resource name from operationId
    resource =
      (op.operation_id || "Resource")
      |> String.replace(~r/^(create|update|delete|get|list|find|search)/, "")
      |> Macro.camelize()

    resource <> base
  end

  # ============================================================================
  # Event Generation
  # ============================================================================

  defp collect_event_names(operations) do
    operations
    |> Enum.flat_map(fn op ->
      op.responses
      |> Enum.filter(fn {status, _} -> status in ["200", "201", "202"] end)
      |> Enum.map(fn _ -> infer_event_name(op) end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp collect_events_data(operations) do
    operations
    |> Enum.flat_map(fn op ->
      op.responses
      |> Enum.filter(fn {status, resp} ->
        status in ["200", "201", "202"] and resp.schema != nil
      end)
      |> Enum.map(fn {_status, resp} ->
        fields = extract_schema_fields(resp.schema)

        %{
          name: infer_event_name(op),
          fields: fields,
          description: resp.description,
          operation: op.operation_id
        }
      end)
    end)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  defp extract_schema_fields(%{"properties" => props} = schema) do
    required = MapSet.new(Map.get(schema, "required", []))

    Enum.map(props, fn {name, prop} ->
      %{
        name: to_field_name(name),
        original_name: name,
        type: schema_to_type(prop),
        required: MapSet.member?(required, name),
        description: Map.get(prop, "description", "")
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp extract_schema_fields(_), do: []

  @doc false
  def generate_event(event, namespace) do
    field_atoms = Enum.map(event.fields, fn f -> String.to_atom(f.name) end)

    # Check if event has id field that should be external()
    has_id_field = Enum.any?(event.fields, fn f -> f.name == "id" end)

    defstruct_line =
      if has_id_field do
        # Use external() for id field (server-generated)
        non_id_fields = Enum.reject(field_atoms, &(&1 == :id))

        "[id: external()" <>
          if(non_id_fields != [], do: ", " <> inspect_fields(non_id_fields), else: "") <> "]"
      else
        inspect(field_atoms)
      end

    import_line =
      if has_id_field do
        "import PropertyDamage, only: [external: 0]\n\n  "
      else
        ""
      end

    """
    defmodule #{namespace}.Events.#{event.name} do
      @moduledoc \"\"\"
      #{event.description}

      Generated from operation: #{event.operation}
      \"\"\"

      #{import_line}defstruct #{defstruct_line}

    #{generate_event_field_docs(event.fields)}end
    """
  end

  defp inspect_fields(fields) do
    Enum.map_join(fields, ", ", fn f -> ":#{f}" end)
  end

  defp generate_event_field_docs(fields) do
    fields
    |> Enum.map(fn f ->
      type_str = format_type_doc(f.type)
      req = if f.required, do: "required", else: "optional"
      desc = if f.description != "", do: " - #{f.description}", else: ""
      "  # #{f.name}: #{type_str} (#{req})#{desc}"
    end)
    |> Enum.join("\n")
    |> then(&(&1 <> "\n"))
  end

  # ============================================================================
  # Adapter Generation
  # ============================================================================

  @doc false
  def generate_adapter(operations, namespace, api_info, auth_schemes) do
    """
    defmodule #{namespace}.Adapter do
      @moduledoc \"\"\"
      HTTP adapter for #{api_info.title}.

      Generated from OpenAPI spec version #{api_info.version}.

      ## Configuration

      Pass configuration via `adapter_config`:

          PropertyDamage.run(
            model: #{namespace}.Model,
            adapter: #{namespace}.Adapter,
            adapter_config: %{
              base_url: "#{api_info.base_url}",
              #{generate_auth_config_example(auth_schemes)}
            }
          )
      \"\"\"

      @behaviour PropertyDamage.Adapter

      alias #{namespace}.Commands

      @impl true
      def setup(config) do
        base_url = Map.get(config, :base_url, "#{api_info.base_url}")
        {:ok, Map.put(config, :base_url, base_url)}
      end

      @impl true
      def teardown(_config), do: :ok

    #{generate_execute_clauses(operations, namespace, auth_schemes)}

      # ============================================================================
      # Helpers
      # ============================================================================

      defp build_url(base_url, path, cmd) do
        # Replace path parameters
        path =
          if function_exported?(cmd.__struct__, :__path_params__, 0) do
            Enum.reduce(cmd.__struct__.__path_params__(), path, fn param, acc ->
              value = Map.get(cmd, param)
              String.replace(acc, "{" <> to_string(param) <> "}", to_string(value))
            end)
          else
            path
          end

        base_url <> path
      end

      defp build_query(cmd) do
        if function_exported?(cmd.__struct__, :__query_params__, 0) do
          cmd.__struct__.__query_params__()
          |> Enum.map(fn param -> {param, Map.get(cmd, param)} end)
          |> Enum.reject(fn {_, v} -> is_nil(v) end)
          |> URI.encode_query()
        else
          ""
        end
      end

      defp build_body(cmd) do
        # Get body fields (exclude path and query params)
        path_params =
          if function_exported?(cmd.__struct__, :__path_params__, 0),
            do: cmd.__struct__.__path_params__(),
            else: []

        query_params =
          if function_exported?(cmd.__struct__, :__query_params__, 0),
            do: cmd.__struct__.__query_params__(),
            else: []

        excluded = MapSet.new(path_params ++ query_params)

        cmd
        |> Map.from_struct()
        |> Enum.reject(fn {k, _} -> MapSet.member?(excluded, k) end)
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()
      end

    #{generate_auth_helpers(auth_schemes)}
      defp http_request(method, url, body, headers) do
        # Using Req if available, otherwise fall back to :httpc
        if Code.ensure_loaded?(Req) do
          req_request(method, url, body, headers)
        else
          httpc_request(method, url, body, headers)
        end
      end

      defp req_request(method, url, body, headers) do
        opts =
          [method: method, url: url, headers: headers]
          |> maybe_add_body(method, body)

        case Req.request(opts) do
          {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
            {:ok, resp_body}

          {:ok, %{status: status, body: resp_body}} ->
            {:error, {status, resp_body}}

          {:error, reason} ->
            {:error, reason}
        end
      end

      defp maybe_add_body(opts, method, body) when method in [:post, :put, :patch] and body != %{} do
        Keyword.put(opts, :json, body)
      end

      defp maybe_add_body(opts, _, _), do: opts

      defp httpc_request(method, url, body, headers) do
        Application.ensure_all_started(:inets)
        Application.ensure_all_started(:ssl)

        headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

        request =
          case method do
            :get ->
              {to_charlist(url), headers}

            _ ->
              body_str = if body == %{}, do: "", else: Jason.encode!(body)
              {to_charlist(url), headers, ~c"application/json", body_str}
          end

        case :httpc.request(method, request, [], body_format: :binary) do
          {:ok, {{_, status, _}, _, resp_body}} when status in 200..299 ->
            {:ok, Jason.decode!(resp_body)}

          {:ok, {{_, status, _}, _, resp_body}} ->
            {:error, {status, resp_body}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
    """
  end

  defp generate_execute_clauses(operations, namespace, auth_schemes) do
    operations
    |> Enum.map(fn op -> generate_execute_clause(op, namespace, auth_schemes) end)
    |> Enum.join("\n")
  end

  defp generate_execute_clause(op, _namespace, auth_schemes) do
    has_auth = length(auth_schemes) > 0

    """
      @impl true
      def execute(%Commands.#{op.module_name}{} = cmd, ctx) do
        url = build_url(ctx.base_url, cmd.__struct__.__http_path__(), cmd)
        query = build_query(cmd)
        full_url = if query != "", do: url <> "?" <> query, else: url
        body = build_body(cmd)
        headers = #{if has_auth, do: "build_auth_headers(ctx)", else: "[]"}

        case http_request(:#{String.downcase(op.method)}, full_url, body, headers) do
          {:ok, response} -> {:ok, response}
          {:error, reason} -> {:error, reason}
        end
      end
    """
  end

  defp generate_auth_config_example([]), do: "# No authentication configured"

  defp generate_auth_config_example(schemes) do
    schemes
    |> Enum.map(fn scheme ->
      case scheme.type do
        "apiKey" ->
          "api_key: \"your-api-key\""

        "http" when scheme.scheme == "bearer" ->
          "bearer_token: \"your-token\""

        "http" when scheme.scheme == "basic" ->
          "basic_auth: {\"username\", \"password\"}"

        _ ->
          "# #{scheme.name}: configure as needed"
      end
    end)
    |> Enum.join(",\n              ")
  end

  defp generate_auth_helpers([]), do: ""

  defp generate_auth_helpers(schemes) do
    header_builders =
      schemes
      |> Enum.map(fn scheme ->
        case scheme.type do
          "apiKey" when scheme.in == "header" ->
            """
                  if api_key = Map.get(ctx, :api_key) do
                    [{"#{scheme.param_name}", api_key} | acc]
                  else
                    acc
                  end
            """

          "http" when scheme.scheme == "bearer" ->
            """
                  if token = Map.get(ctx, :bearer_token) do
                    [{"Authorization", "Bearer " <> token} | acc]
                  else
                    acc
                  end
            """

          "http" when scheme.scheme == "basic" ->
            """
                  case Map.get(ctx, :basic_auth) do
                    {user, pass} ->
                      encoded = Base.encode64(user <> ":" <> pass)
                      [{"Authorization", "Basic " <> encoded} | acc]
                    _ ->
                      acc
                  end
            """

          _ ->
            "      acc"
        end
      end)
      |> Enum.join("\n")

    """
      defp build_auth_headers(ctx) do
        []
        |> then(fn acc ->
    #{header_builders}
        end)
      end
    """
  end

  # ============================================================================
  # Model Generation
  # ============================================================================

  @doc false
  def generate_model(operations, namespace) do
    # Group operations by tag or HTTP method for weighting
    commands_with_weights =
      operations
      |> Enum.map(fn op ->
        weight = infer_weight(op)
        {weight, "Commands.#{op.module_name}"}
      end)
      |> Enum.sort_by(fn {w, _} -> -w end)

    commands_list =
      commands_with_weights
      |> Enum.map(fn {weight, mod} -> "      {#{weight}, #{mod}}" end)
      |> Enum.join(",\n")

    """
    defmodule #{namespace}.Model do
      @moduledoc \"\"\"
      PropertyDamage model for API testing.

      Generated from OpenAPI spec. Customize command weights and add projections/assertions.
      \"\"\"

      @behaviour PropertyDamage.Model

      alias #{namespace}.Commands
      # alias #{namespace}.Events
      # alias #{namespace}.Projections

      @impl true
      def commands do
        [
    #{commands_list}
        ]
      end

      @impl true
      def state_projection do
        # TODO: Add state tracking projection
        # Example: Projections.ResourceState
        raise "state_projection/0 not implemented - add your state projection module"
      end

      @impl true
      def extra_projections do
        # TODO: Add extra projections (with @trigger/@poll_state assertions)
        # Example: [Projections.ResourceExists, Projections.ValidState]
        []
      end

      # Optional lifecycle callbacks
      # @impl true
      # def setup_once(config), do: {:ok, config}
      #
      # @impl true
      # def setup_each(config), do: {:ok, config}
      #
      # @impl true
      # def teardown_each(_config), do: :ok
      #
      # @impl true
      # def teardown_once(_config), do: :ok
    end
    """
  end

  @doc false
  def infer_weight(op) do
    cond do
      # Read operations - higher weight (more common)
      op.method == "GET" -> 5
      # Create operations - medium weight
      op.method == "POST" -> 3
      # Update operations - lower weight
      op.method in ["PUT", "PATCH"] -> 2
      # Delete operations - lowest weight
      op.method == "DELETE" -> 1
      # Default
      true -> 2
    end
  end

  @doc false
  def infer_namespace(output) do
    output
    |> Path.split()
    |> Enum.drop_while(&(&1 in ["lib", "test"]))
    |> Enum.map(&Macro.camelize/1)
    |> Enum.join(".")
    |> then(fn
      "" -> "Generated"
      ns -> ns
    end)
  end
end
