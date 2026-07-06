defmodule Mix.Tasks.Pd.ScaffoldTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Pd.Scaffold
  alias PropertyDamage.Export.HTTPSpec

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

  # Mirrors benches/openapi_bench so the "generated code is real" checks below
  # can actually compile what the scaffold emits. Includes a client-supplied
  # `id` uuid field: the scaffold must emit a dependency-free generator for it
  # (no Ecto), so the generated code compiles with PD's deps alone.
  @kv_spec %{
    "openapi" => "3.0.3",
    "info" => %{"title" => "KV", "version" => "1.0.0"},
    "servers" => [%{"url" => "http://localhost:4010"}],
    "paths" => %{
      "/kv/{key}" => %{
        "put" => %{
          "operationId" => "putValue",
          "parameters" => [
            %{
              "name" => "key",
              "in" => "path",
              "required" => true,
              "schema" => %{"type" => "integer", "minimum" => 0, "maximum" => 4}
            }
          ],
          "requestBody" => %{
            "required" => true,
            "content" => %{
              "application/json" => %{
                "schema" => %{
                  "type" => "object",
                  "required" => ["value"],
                  "properties" => %{
                    "value" => %{"type" => "integer"},
                    "id" => %{"type" => "string", "format" => "uuid"}
                  }
                }
              }
            }
          },
          "responses" => %{
            "200" => %{
              "description" => "ok",
              "content" => %{
                "application/json" => %{
                  "schema" => %{
                    "type" => "object",
                    "properties" => %{
                      "key" => %{"type" => "integer"},
                      "value" => %{"type" => "integer"}
                    }
                  }
                }
              }
            }
          }
        },
        "get" => %{
          "operationId" => "getValue",
          "parameters" => [
            %{
              "name" => "key",
              "in" => "path",
              "required" => true,
              "schema" => %{"type" => "integer", "minimum" => 0, "maximum" => 4}
            }
          ],
          "responses" => %{"200" => %{"description" => "ok"}}
        }
      }
    }
  }

  # The scaffold is a 0%-tested codegen surface; the substring checks elsewhere
  # in this file never compile what they assert on. These checks do: they
  # generate, then compile and format-check the real output, which is the only
  # way to catch drift like a non-PD-contract adapter return, missing @impl /
  # required-callback warnings, undefined-module warnings, or stray whitespace.
  describe "generated code is real (compiles + format-stable)" do
    test "every generated artifact is mix-format stable" do
      ns = "PdScaffoldRealTest.FormatStable"
      ops = Scaffold.extract_operations(@kv_spec, nil)
      api_info = Scaffold.extract_api_info(@kv_spec, nil)

      sources =
        Enum.map(ops, &Scaffold.generate_command(&1, ns)) ++
          [
            Scaffold.generate_event(sample_event(), ns),
            Scaffold.generate_adapter(ops, ns, api_info, []),
            Scaffold.generate_model(ops, ns)
          ]

      for code <- sources do
        assert code == reformat(code),
               "generated source is not mix-format stable:\n#{code}"
      end
    end

    test "the generated suite compiles with zero warnings/errors" do
      ns = "PdScaffoldRealTest.Compiles"
      ops = Scaffold.extract_operations(@kv_spec, nil)
      api_info = Scaffold.extract_api_info(@kv_spec, nil)

      # Commands first (the adapter pattern-matches on their structs), then the
      # event, adapter, and model.
      ordered =
        Enum.map(ops, &Scaffold.generate_command(&1, ns)) ++
          [
            Scaffold.generate_event(sample_event(), ns),
            Scaffold.generate_adapter(ops, ns, api_info, []),
            Scaffold.generate_model(ops, ns)
          ]

      {_, diagnostics} =
        Code.with_diagnostics(fn ->
          Enum.each(ordered, &Code.compile_string/1)
        end)

      assert diagnostics == [],
             "generated code emitted compiler diagnostics:\n" <>
               Enum.map_join(diagnostics, "\n", &inspect/1)

      # The codegen contract that makes it usable by the executor:
      assert function_exported?(Module.concat(ns, "Commands.PutValue"), :events, 3)
      get_value = Module.concat(ns, "Commands.GetValue")
      assert function_exported?(get_value, :command_spec, 1)
      assert get_value.command_spec([]).shrink == :prefer_remove
      adapter = Module.concat(ns, "Adapter")
      assert function_exported?(adapter, :execute, 3)
      # timeout/1 is a required Adapter callback; `use` must inject the default.
      assert function_exported?(adapter, :timeout, 1)
    end

    test "the generated adapter maps responses to events (not the raw body)" do
      ns = "PdScaffoldRealTest.AdapterReturn"
      ops = Scaffold.extract_operations(@kv_spec, nil)
      api_info = Scaffold.extract_api_info(@kv_spec, nil)

      adapter_code = Scaffold.generate_adapter(ops, ns, api_info, [])

      # PropertyDamage rejects {:ok, non-list}; the adapter must funnel the HTTP
      # response through the command's events/3 and return {:ok, events}.
      assert adapter_code =~ "{:ok, cmd.__struct__.events(cmd, status, response)}"
      refute adapter_code =~ "{:ok, response} -> {:ok, response}"
    end

    test "the generated adapter exposes a correct, compilable http_spec/2 for export" do
      ns = "PdScaffoldRealTest.HttpSpec"
      ops = Scaffold.extract_operations(@kv_spec, nil)
      api_info = Scaffold.extract_api_info(@kv_spec, nil)

      ordered =
        Enum.map(ops, &Scaffold.generate_command(&1, ns)) ++
          [Scaffold.generate_adapter(ops, ns, api_info, [])]

      {_, diagnostics} =
        Code.with_diagnostics(fn -> Enum.each(ordered, &Code.compile_string/1) end)

      assert diagnostics == [],
             "generated code emitted compiler diagnostics:\n" <>
               Enum.map_join(diagnostics, "\n", &inspect/1)

      adapter = Module.concat(ns, "Adapter")

      # Export (StepPlan) detects the mapping via function_exported?/3, so the
      # generated adapter must expose http_spec/2 with no hand-written glue.
      assert function_exported?(adapter, :http_spec, 2)

      put = Module.concat(ns, "Commands.PutValue")
      spec = adapter.http_spec(struct(put, key: 3, value: 7), %{})

      # OpenAPI path template ({key}) rendered to the HTTPSpec :param form; the
      # path param split out of the JSON body; the body carries the rest.
      assert %HTTPSpec{
               method: :put,
               path: "/kv/:key",
               path_params: %{key: 3},
               body: %{value: 7}
             } = spec

      # A read command with only a path param renders the same path and no body.
      get = Module.concat(ns, "Commands.GetValue")
      get_spec = adapter.http_spec(struct(get, key: 2), %{})
      assert get_spec.method == :get
      assert get_spec.path == "/kv/:key"
      assert get_spec.path_params == %{key: 2}
      refute HTTPSpec.has_body?(get_spec)
    end
  end

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

  describe "streamdata_generator_for_type/3" do
    test "generates a seeded, non-constant UUID generator (no Ecto, distinct draws)" do
      gen = streamdata_generator_for_type(:uuid, "id", "body")

      # No external dependency, and not `constant`: repeated draws within a run
      # (e.g. client-supplied ids) must differ, while staying seeded so the run
      # is reproducible and shrinkable.
      refute gen =~ "Ecto"
      refute gen =~ "constant"
      assert gen =~ "StreamData"

      # The emitted generator is self-contained; evaluate and exercise it.
      {generator, _} = Code.eval_string(gen)
      samples = Enum.take(generator, 8)

      v4 = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      assert Enum.all?(samples, &Regex.match?(v4, &1)),
             "expected valid v4 UUIDs, got #{inspect(samples)}"

      assert length(Enum.uniq(samples)) == length(samples),
             "expected distinct UUIDs across draws, got #{inspect(samples)}"
    end

    test "generates email generator" do
      gen = streamdata_generator_for_type(:email, "email", "body")
      assert gen =~ "@example.com"
      assert gen =~ "StreamData"
    end

    test "generates enum generator" do
      gen = streamdata_generator_for_type({:enum, ["a", "b", "c"]}, "status", "body")
      assert gen =~ "StreamData.member_of"
      assert gen =~ ~s(["a", "b", "c"])
    end

    test "generates integer range generator" do
      gen = streamdata_generator_for_type({:integer, 1, 100}, "count", "body")
      assert gen =~ "StreamData.integer(1..100)"
    end

    test "generates boolean generator" do
      gen = streamdata_generator_for_type(:boolean, "active", "body")
      assert gen =~ "StreamData.boolean()"
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
      assert code =~ "def generator(overrides"
      assert code =~ "merge_overrides(overrides)"
      assert code =~ "StreamData.fixed_map()"
      # events/3 is status-aware so non-2xx responses can become events too
      assert code =~ "def events(command, status, response)"
    end

    test "generates GET command as read_only (shrink: :prefer_remove)" do
      operations = extract_operations(@sample_openapi_spec, nil)
      list_pets = Enum.find(operations, &(&1.operation_id == "listPets"))

      code = generate_command(list_pets, "PetStore")

      assert code =~ "use PropertyDamage.Command, shrink: :prefer_remove"
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
      # id field uses external() since it's server-generated; keyword entries
      # must come last in a list literal, so bare fields precede `id: external()`
      assert code =~ "defstruct [:name, id: external()]"
      assert code =~ "import PropertyDamage, only: [external: 0]"
      assert code =~ "Generated from operation: createPet"

      # The emitted struct must actually parse (a keyword-before-atom ordering
      # is a SyntaxError that string matching alone would miss).
      assert {:ok, _ast} = Code.string_to_quoted(code)
    end
  end

  describe "generate_adapter/4" do
    test "generates adapter with execute clauses" do
      operations = extract_operations(@sample_openapi_spec, nil)
      auth_schemes = extract_auth_schemes(@sample_openapi_spec)
      api_info = extract_api_info(@sample_openapi_spec, nil)

      code = generate_adapter(operations, "PetStore", api_info, auth_schemes)

      assert code =~ "defmodule PetStore.Adapter do"
      # use (not @behaviour) so the default timeout/1 callback is injected
      assert code =~ "use PropertyDamage.Adapter"
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
      assert code =~ "@behaviour PropertyDamage.Model"
      assert code =~ "def commands do"
      # GET has weight 5
      assert code =~ "{Commands.ListPets, weight: 5}"
      # POST has weight 3
      assert code =~ "{Commands.CreatePet, weight: 3}"
      # DELETE has weight 1
      assert code =~ "{Commands.DeletePet, weight: 1}"
      assert code =~ "def command_sequence_projection do"
      assert code =~ "def assertion_projections do"
    end
  end

  # A path parameter and a request-body field can share a name (e.g. `id`),
  # which collapsed into `defstruct [:id, :id]` and failed to compile.
  @collision_spec %{
    "openapi" => "3.0.0",
    "info" => %{"title" => "Collision", "version" => "1.0.0"},
    "paths" => %{
      "/things/{id}" => %{
        "put" => %{
          "operationId" => "updateThing",
          "parameters" => [
            %{
              "name" => "id",
              "in" => "path",
              "required" => true,
              "schema" => %{"type" => "string"}
            }
          ],
          "requestBody" => %{
            "required" => true,
            "content" => %{
              "application/json" => %{
                "schema" => %{
                  "type" => "object",
                  "required" => ["id"],
                  "properties" => %{
                    "id" => %{"type" => "string"},
                    "value" => %{"type" => "integer"}
                  }
                }
              }
            }
          },
          "responses" => %{"200" => %{"description" => "ok"}}
        }
      }
    }
  }

  describe "generate_command/2 field name collisions (H2a)" do
    test "a path param and a body field sharing a name compile without diagnostics" do
      [op] = Scaffold.extract_operations(@collision_spec, nil)
      code = Scaffold.generate_command(op, "PdScaffoldCollisionTest")

      # A duplicate defstruct/map key emits compiler warnings (a hard error under
      # --warnings-as-errors), so generated code must be diagnostic-clean.
      {_, diagnostics} =
        Code.with_diagnostics(fn -> Code.compile_string(code) end)

      assert diagnostics == [],
             "generated command emitted compiler diagnostics:\n" <>
               Enum.map_join(diagnostics, "\n", &inspect/1) <> "\n\nSource:\n#{code}"
    end
  end

  # Two operations that both omit operationId used to derive the same module
  # name ("UnnamedOperation"), scaffolding to the same file and silently
  # overwriting the first.
  @nil_opid_spec %{
    "openapi" => "3.0.0",
    "info" => %{"title" => "NoIds", "version" => "1.0.0"},
    "paths" => %{
      "/foo" => %{"get" => %{"responses" => %{"200" => %{"description" => "ok"}}}},
      "/bar" => %{"get" => %{"responses" => %{"200" => %{"description" => "ok"}}}}
    }
  }

  describe "extract_operations/2 missing operationId (H2b)" do
    test "operations without operationId get distinct module names/filenames" do
      ops = Scaffold.extract_operations(@nil_opid_spec, nil)
      assert length(ops) == 2

      module_names = Enum.map(ops, & &1.module_name)

      assert length(Enum.uniq(module_names)) == 2,
             "expected distinct module names, got #{inspect(module_names)}"

      filenames = Enum.map(module_names, &(Macro.underscore(&1) <> ".ex"))

      assert length(Enum.uniq(filenames)) == 2,
             "expected distinct filenames, got #{inspect(filenames)}"
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

  # Re-run a source string through the formatter (idempotent for format-clean
  # output). Mirrors the scaffold's own internal formatting step.
  defp reformat(code) do
    (code |> Code.format_string!() |> IO.iodata_to_binary()) <> "\n"
  end

  defp sample_event do
    %{
      name: "ValueRetrieved",
      fields: [
        %{name: "key", type: :integer, required: true, description: ""},
        %{name: "value", type: :integer, required: true, description: ""}
      ],
      description: "The stored key/value pair",
      operation: "getValue"
    }
  end

  # Helper aliases for cleaner tests
  defp extract_api_info(spec, override), do: Scaffold.extract_api_info(spec, override)
  defp extract_operations(spec, filter), do: Scaffold.extract_operations(spec, filter)
  defp extract_auth_schemes(spec), do: Scaffold.extract_auth_schemes(spec)
  defp schema_to_type(schema), do: Scaffold.schema_to_type(schema)
  defp to_module_name(name), do: Scaffold.to_module_name(name)
  defp to_field_name(name), do: Scaffold.to_field_name(name)
  defp infer_weight(op), do: Scaffold.infer_weight(op)

  defp streamdata_generator_for_type(type, name, source),
    do: Scaffold.streamdata_generator_for_type(type, name, source)

  defp generate_command(op, namespace), do: Scaffold.generate_command(op, namespace)
  defp generate_event(event, namespace), do: Scaffold.generate_event(event, namespace)
  defp generate_adapter(ops, ns, info, auth), do: Scaffold.generate_adapter(ops, ns, info, auth)
  defp generate_model(operations, namespace), do: Scaffold.generate_model(operations, namespace)
  defp infer_namespace(path), do: Scaffold.infer_namespace(path)
end
