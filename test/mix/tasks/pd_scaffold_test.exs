defmodule Mix.Tasks.Pd.ScaffoldTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Pd.Scaffold

  @sample_openapi_spec %{
    "openapi" => "3.0.0",
    "info" => %{
      "title" => "Pet Store API",
      "version" => "1.0.0",
      "description" => "A sample pet store API"
    },
    "servers" => [
      %{"url" => "https://api.petstore.example.com/v1"}
    ],
    "paths" => %{
      "/pets" => %{
        "get" => %{
          "operationId" => "listPets",
          "summary" => "List all pets",
          "parameters" => [
            %{
              "name" => "limit",
              "in" => "query",
              "required" => false,
              "schema" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
            }
          ],
          "responses" => %{
            "200" => %{
              "description" => "A list of pets",
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "array",
                    "items" => %{"$ref" => "#/components/schemas/Pet"}
                  }
                }
              }
            }
          }
        },
        "post" => %{
          "operationId" => "createPet",
          "summary" => "Create a pet",
          "requestBody" => %{
            "required" => true,
            "content" => %{
              "application/json" => %{
                "schema" => %{"$ref" => "#/components/schemas/NewPet"}
              }
            }
          },
          "responses" => %{
            "201" => %{
              "description" => "Pet created",
              "content" => %{
                "application/json" => %{
                  "schema" => %{"$ref" => "#/components/schemas/Pet"}
                }
              }
            }
          }
        }
      },
      "/pets/{petId}" => %{
        "get" => %{
          "operationId" => "getPet",
          "summary" => "Get a pet by ID",
          "parameters" => [
            %{
              "name" => "petId",
              "in" => "path",
              "required" => true,
              "schema" => %{"type" => "string", "format" => "uuid"}
            }
          ],
          "responses" => %{
            "200" => %{
              "description" => "Pet details",
              "content" => %{
                "application/json" => %{
                  "schema" => %{"$ref" => "#/components/schemas/Pet"}
                }
              }
            }
          }
        },
        "put" => %{
          "operationId" => "updatePet",
          "summary" => "Update a pet",
          "parameters" => [
            %{
              "name" => "petId",
              "in" => "path",
              "required" => true,
              "schema" => %{"type" => "string", "format" => "uuid"}
            }
          ],
          "requestBody" => %{
            "required" => true,
            "content" => %{
              "application/json" => %{
                "schema" => %{"$ref" => "#/components/schemas/NewPet"}
              }
            }
          },
          "responses" => %{
            "200" => %{
              "description" => "Pet updated",
              "content" => %{
                "application/json" => %{
                  "schema" => %{"$ref" => "#/components/schemas/Pet"}
                }
              }
            }
          }
        },
        "delete" => %{
          "operationId" => "deletePet",
          "summary" => "Delete a pet",
          "parameters" => [
            %{
              "name" => "petId",
              "in" => "path",
              "required" => true,
              "schema" => %{"type" => "string", "format" => "uuid"}
            }
          ],
          "responses" => %{
            "204" => %{
              "description" => "Pet deleted"
            }
          }
        }
      }
    },
    "components" => %{
      "schemas" => %{
        "Pet" => %{
          "type" => "object",
          "required" => ["id", "name"],
          "properties" => %{
            "id" => %{"type" => "string", "format" => "uuid"},
            "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
            "species" => %{"type" => "string", "enum" => ["dog", "cat", "bird", "fish"]},
            "age" => %{"type" => "integer", "minimum" => 0},
            "created_at" => %{"type" => "string", "format" => "date-time"}
          }
        },
        "NewPet" => %{
          "type" => "object",
          "required" => ["name"],
          "properties" => %{
            "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
            "species" => %{"type" => "string", "enum" => ["dog", "cat", "bird", "fish"]},
            "age" => %{"type" => "integer", "minimum" => 0}
          }
        }
      },
      "securitySchemes" => %{
        "bearerAuth" => %{
          "type" => "http",
          "scheme" => "bearer",
          "bearerFormat" => "JWT"
        },
        "apiKey" => %{
          "type" => "apiKey",
          "in" => "header",
          "name" => "X-API-Key"
        }
      }
    }
  }

  describe "extract_api_info/2" do
    test "extracts API title, version, and base URL" do
      info = extract_api_info(@sample_openapi_spec, nil)

      assert info.title == "Pet Store API"
      assert info.version == "1.0.0"
      assert info.base_url == "https://api.petstore.example.com/v1"
    end

    test "uses override base URL when provided" do
      info = extract_api_info(@sample_openapi_spec, "http://localhost:3000")

      assert info.base_url == "http://localhost:3000"
    end

    test "defaults to localhost when no servers" do
      spec = Map.delete(@sample_openapi_spec, "servers")
      info = extract_api_info(spec, nil)

      assert info.base_url == "http://localhost:4000"
    end
  end

  describe "extract_operations/2" do
    test "extracts all operations from paths" do
      operations = extract_operations(@sample_openapi_spec, nil)

      assert length(operations) == 5

      operation_ids = Enum.map(operations, & &1.operation_id)
      assert "listPets" in operation_ids
      assert "createPet" in operation_ids
      assert "getPet" in operation_ids
      assert "updatePet" in operation_ids
      assert "deletePet" in operation_ids
    end

    test "filters operations by operationId" do
      filter = MapSet.new(["createPet", "getPet"])
      operations = extract_operations(@sample_openapi_spec, filter)

      assert length(operations) == 2
      operation_ids = Enum.map(operations, & &1.operation_id)
      assert "createPet" in operation_ids
      assert "getPet" in operation_ids
      refute "listPets" in operation_ids
    end

    test "extracts HTTP method and path" do
      operations = extract_operations(@sample_openapi_spec, nil)
      create_pet = Enum.find(operations, &(&1.operation_id == "createPet"))

      assert create_pet.method == "POST"
      assert create_pet.path == "/pets"
    end

    test "extracts parameters" do
      operations = extract_operations(@sample_openapi_spec, nil)
      get_pet = Enum.find(operations, &(&1.operation_id == "getPet"))

      assert length(get_pet.parameters) == 1
      [param] = get_pet.parameters
      assert param.name == "petId"
      assert param.in == "path"
      assert param.required == true
    end

    test "resolves $ref in request body" do
      operations = extract_operations(@sample_openapi_spec, nil)
      create_pet = Enum.find(operations, &(&1.operation_id == "createPet"))

      assert create_pet.request_body != nil
      assert create_pet.request_body.schema["properties"]["name"] != nil
    end
  end

  describe "extract_auth_schemes/1" do
    test "extracts security schemes" do
      schemes = extract_auth_schemes(@sample_openapi_spec)

      assert length(schemes) == 2

      bearer = Enum.find(schemes, &(&1.name == "bearerAuth"))
      assert bearer.type == "http"
      assert bearer.scheme == "bearer"

      api_key = Enum.find(schemes, &(&1.name == "apiKey"))
      assert api_key.type == "apiKey"
      assert api_key.in == "header"
      assert api_key.param_name == "X-API-Key"
    end

    test "returns empty list when no security schemes" do
      spec = put_in(@sample_openapi_spec, ["components", "securitySchemes"], %{})
      schemes = extract_auth_schemes(spec)
      assert schemes == []
    end
  end

  describe "schema_to_type/1" do
    test "converts string types" do
      assert schema_to_type(%{"type" => "string"}) == :string
      assert schema_to_type(%{"type" => "string", "format" => "uuid"}) == :uuid
      assert schema_to_type(%{"type" => "string", "format" => "email"}) == :email
      assert schema_to_type(%{"type" => "string", "format" => "date-time"}) == :datetime
      assert schema_to_type(%{"type" => "string", "format" => "date"}) == :date
      assert schema_to_type(%{"type" => "string", "format" => "uri"}) == :uri
    end

    test "converts string with constraints" do
      assert schema_to_type(%{"type" => "string", "minLength" => 5, "maxLength" => 10}) ==
               {:string, 5, 10}

      assert schema_to_type(%{"type" => "string", "enum" => ["a", "b", "c"]}) ==
               {:enum, ["a", "b", "c"]}
    end

    test "converts numeric types" do
      assert schema_to_type(%{"type" => "integer"}) == :integer

      assert schema_to_type(%{"type" => "integer", "minimum" => 0, "maximum" => 100}) ==
               {:integer, 0, 100}

      assert schema_to_type(%{"type" => "number"}) == :number
    end

    test "converts other types" do
      assert schema_to_type(%{"type" => "boolean"}) == :boolean
      assert schema_to_type(%{"type" => "array"}) == {:array, :any}

      assert schema_to_type(%{"type" => "array", "items" => %{"type" => "string"}}) ==
               {:array, :string}

      assert schema_to_type(%{"type" => "object"}) == :map
    end
  end

  describe "to_module_name/1" do
    test "converts operationId to module name" do
      assert to_module_name("createPet") == "CreatePet"
      assert to_module_name("list_all_pets") == "ListAllPets"
      assert to_module_name("get-pet-by-id") == "GetPetById"
    end

    test "handles nil operationId" do
      assert to_module_name(nil) == "UnnamedOperation"
    end
  end

  describe "to_field_name/1" do
    test "converts parameter names to field names" do
      assert to_field_name("petId") == "pet_id"
      assert to_field_name("user-name") == "user_name"
      assert to_field_name("created_at") == "created_at"
    end
  end

  describe "infer_weight/1" do
    test "assigns higher weight to GET operations" do
      op = %{method: "GET"}
      assert infer_weight(op) == 5
    end

    test "assigns medium weight to POST operations" do
      op = %{method: "POST"}
      assert infer_weight(op) == 3
    end

    test "assigns lower weight to PUT/PATCH operations" do
      assert infer_weight(%{method: "PUT"}) == 2
      assert infer_weight(%{method: "PATCH"}) == 2
    end

    test "assigns lowest weight to DELETE operations" do
      op = %{method: "DELETE"}
      assert infer_weight(op) == 1
    end
  end

  describe "generator_for_type/3" do
    test "generates UUID generator" do
      gen = generator_for_type(:uuid, "id", "body")
      assert gen =~ "UUID"
    end

    test "generates email generator" do
      gen = generator_for_type(:email, "email", "body")
      assert gen =~ "@example.com"
      assert gen =~ "System.unique_integer"
    end

    test "generates enum generator" do
      gen = generator_for_type({:enum, ["a", "b", "c"]}, "status", "body")
      assert gen =~ "Enum.random"
      assert gen =~ ~s(["a", "b", "c"])
    end

    test "generates integer range generator" do
      gen = generator_for_type({:integer, 1, 100}, "count", "body")
      assert gen =~ "Enum.random(1..100)"
    end

    test "generates boolean generator" do
      gen = generator_for_type(:boolean, "active", "body")
      assert gen =~ "Enum.random([true, false])"
    end
  end

  describe "generate_command/2" do
    test "generates command module with proper structure" do
      operations = extract_operations(@sample_openapi_spec, nil)
      create_pet = Enum.find(operations, &(&1.operation_id == "createPet"))

      code = generate_command(create_pet, "PetStore")

      assert code =~ "defmodule PetStore.Commands.CreatePet do"
      assert code =~ "use PropertyDamage.Command"
      assert code =~ "defstruct"
      assert code =~ "def new!(state, _generators)"
      assert code =~ "def precondition(_state)"
      assert code =~ "def events(command, response)"
      # POST should not be read_only
      assert code =~ "@read_only false"
    end

    test "generates GET command as read_only" do
      operations = extract_operations(@sample_openapi_spec, nil)
      list_pets = Enum.find(operations, &(&1.operation_id == "listPets"))

      code = generate_command(list_pets, "PetStore")

      assert code =~ "@read_only true"
    end

    test "includes HTTP metadata functions" do
      operations = extract_operations(@sample_openapi_spec, nil)
      get_pet = Enum.find(operations, &(&1.operation_id == "getPet"))

      code = generate_command(get_pet, "PetStore")

      assert code =~ "def __http_method__, do: :get"
      assert code =~ "def __http_path__, do: \"/pets/{petId}\""
      assert code =~ "def __path_params__"
    end
  end

  describe "generate_event/2" do
    test "generates event struct" do
      event = %{
        name: "PetCreated",
        fields: [
          %{name: "id", type: :uuid, required: true, description: "Pet ID"},
          %{name: "name", type: :string, required: true, description: ""}
        ],
        description: "A new pet was created",
        operation: "createPet"
      }

      code = generate_event(event, "PetStore")

      assert code =~ "defmodule PetStore.Events.PetCreated do"
      assert code =~ "defstruct [:id, :name]"
      assert code =~ "Generated from operation: createPet"
    end
  end

  describe "generate_adapter/4" do
    test "generates adapter with execute clauses" do
      operations = extract_operations(@sample_openapi_spec, nil)
      auth_schemes = extract_auth_schemes(@sample_openapi_spec)
      api_info = extract_api_info(@sample_openapi_spec, nil)

      code = generate_adapter(operations, "PetStore", api_info, auth_schemes)

      assert code =~ "defmodule PetStore.Adapter do"
      assert code =~ "@behaviour PropertyDamage.Adapter"
      assert code =~ "def setup(config)"
      assert code =~ "def teardown(_config)"
      assert code =~ "def execute(%Commands.CreatePet{}"
      assert code =~ "def execute(%Commands.ListPets{}"
      assert code =~ "build_auth_headers"
      assert code =~ "bearer_token"
      assert code =~ "api_key"
    end

    test "generates adapter without auth when no schemes" do
      operations = extract_operations(@sample_openapi_spec, MapSet.new(["listPets"]))
      api_info = extract_api_info(@sample_openapi_spec, nil)

      code = generate_adapter(operations, "PetStore", api_info, [])

      assert code =~ "headers = []"
      refute code =~ "build_auth_headers"
    end
  end

  describe "generate_model/2" do
    test "generates model with weighted commands" do
      operations = extract_operations(@sample_openapi_spec, nil)

      code = generate_model(operations, "PetStore")

      assert code =~ "defmodule PetStore.Model do"
      assert code =~ "use PropertyDamage.Model"
      assert code =~ "def commands do"
      # GET has weight 5
      assert code =~ "{5, Commands.ListPets}"
      # POST has weight 3
      assert code =~ "{3, Commands.CreatePet}"
      # DELETE has weight 1
      assert code =~ "{1, Commands.DeletePet}"
      assert code =~ "def projections do"
      assert code =~ "def checks do"
    end
  end

  describe "infer_namespace/1" do
    test "infers namespace from output path" do
      assert infer_namespace("lib/my_app_test/") == "MyAppTest"
      assert infer_namespace("lib/foo/bar/baz/") == "Foo.Bar.Baz"
      assert infer_namespace("test/support/generated/") == "Support.Generated"
    end

    test "defaults to Generated when path is just lib" do
      assert infer_namespace("lib/") == "Generated"
    end
  end

  # Helper aliases for cleaner tests
  defp extract_api_info(spec, override), do: Scaffold.extract_api_info(spec, override)
  defp extract_operations(spec, filter), do: Scaffold.extract_operations(spec, filter)
  defp extract_auth_schemes(spec), do: Scaffold.extract_auth_schemes(spec)
  defp schema_to_type(schema), do: Scaffold.schema_to_type(schema)
  defp to_module_name(name), do: Scaffold.to_module_name(name)
  defp to_field_name(name), do: Scaffold.to_field_name(name)
  defp infer_weight(op), do: Scaffold.infer_weight(op)
  defp generator_for_type(type, name, source), do: Scaffold.generator_for_type(type, name, source)
  defp generate_command(op, namespace), do: Scaffold.generate_command(op, namespace)
  defp generate_event(event, namespace), do: Scaffold.generate_event(event, namespace)
  defp generate_adapter(ops, ns, info, auth), do: Scaffold.generate_adapter(ops, ns, info, auth)
  defp generate_model(operations, namespace), do: Scaffold.generate_model(operations, namespace)
  defp infer_namespace(path), do: Scaffold.infer_namespace(path)
end
