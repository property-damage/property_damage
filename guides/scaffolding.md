# Scaffolding a Test Suite from OpenAPI

Writing commands, events, an adapter, and a model by hand for a REST API is a
lot of boilerplate. `mix pd.scaffold` reads an OpenAPI specification and emits
all of it for you: one command per operation, event structs from the response
schemas, an HTTP adapter that drives the API, and a model wiring the commands
together with sensible weights. You then fill in the parts a spec cannot know
(what your invariants are, how responses map to events) and run.

This guide takes you from a spec file to generated code you can read, and points
you at a complete, runnable worked example that ships in this repository.

> Assumes only general Elixir and a project that already depends on
> `property_damage`. No prior PropertyDamage knowledge is required.

## 1. Start from a spec

Save this minimal OpenAPI 3 document as `widgets.json`. It has two operations
(create and fetch), a path parameter, a request body with an enum, and a
server-generated `id` — enough to exercise every part of the generator:

```json
{
  "openapi": "3.0.3",
  "info": { "title": "Widget API", "version": "1.0.0" },
  "servers": [{ "url": "http://localhost:4000" }],
  "paths": {
    "/widgets": {
      "post": {
        "operationId": "createWidget",
        "summary": "Create a widget",
        "requestBody": {
          "required": true,
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": ["name"],
                "properties": {
                  "name": { "type": "string", "minLength": 1, "maxLength": 40 },
                  "color": { "type": "string", "enum": ["red", "green", "blue"] }
                }
              }
            }
          }
        },
        "responses": {
          "201": {
            "description": "The created widget",
            "content": {
              "application/json": {
                "schema": { "$ref": "#/components/schemas/Widget" }
              }
            }
          }
        }
      }
    },
    "/widgets/{id}": {
      "get": {
        "operationId": "getWidget",
        "summary": "Fetch a widget by id",
        "parameters": [
          { "name": "id", "in": "path", "required": true,
            "schema": { "type": "string", "format": "uuid" } }
        ],
        "responses": {
          "200": {
            "description": "The widget",
            "content": {
              "application/json": {
                "schema": { "$ref": "#/components/schemas/Widget" }
              }
            }
          },
          "404": { "description": "Not found" }
        }
      }
    }
  },
  "components": {
    "schemas": {
      "Widget": {
        "type": "object",
        "required": ["id", "name"],
        "properties": {
          "id": { "type": "string", "format": "uuid" },
          "name": { "type": "string" },
          "color": { "type": "string" }
        }
      }
    }
  }
}
```

YAML specs work too (`.yaml`/`.yml`) if you add `{:yaml_elixir, "~> 2.9"}`. You
can also pass a URL to `--from` instead of a local file.

## 2. Preview, then generate

Start with `--dry-run` to see what would be produced without writing anything:

```console
$ mix pd.scaffold --from widgets.json --output lib/widget_test --namespace WidgetTest --dry-run
Loading OpenAPI spec from widgets.json...
API: Widget API (1.0.0)
Found 2 operations to generate

[DRY RUN] Would generate:

Commands:
  - WidgetTest.Commands.CreateWidget (POST /widgets)
  - WidgetTest.Commands.GetWidget (GET /widgets/{id})

Events:
  - WidgetTest.Events.WidgetCreated
  - WidgetTest.Events.WidgetRetrieved

Adapter:
  - WidgetTest.Adapter

Model:
  - WidgetTest.Model
```

Drop `--dry-run` to write the files:

```console
$ mix pd.scaffold --from widgets.json --output lib/widget_test --namespace WidgetTest
Loading OpenAPI spec from widgets.json...
API: Widget API (1.0.0)
Found 2 operations to generate

Generating commands...
  lib/widget_test/commands/create_widget.ex
  lib/widget_test/commands/get_widget.ex

Generating events...
  lib/widget_test/events/widget_created.ex
  lib/widget_test/events/widget_retrieved.ex

Generating adapter...
  lib/widget_test/adapter.ex

Generating model...
  lib/widget_test/model.ex

✓ Generated 2 commands in lib/widget_test

Next steps:
  1. Review and customize generators in command generator/1 callbacks
  2. Define events/3 (command, status, response) to map responses to events
  3. Add when:/with: options in Model's commands() for preconditions
  4. Implement simulate/2 in Model for expected events
  5. Configure authentication in adapter
```

That is your first visible result: a complete test scaffold on disk, already
`mix format`-clean (the task runs the formatter over everything it emits).

### Useful options

| Option | Effect |
|--------|--------|
| `--from` | Path or URL to the spec (JSON or YAML). **Required.** |
| `--output` | Output directory (default `lib/generated/`). |
| `--namespace` | Module prefix; inferred from `--output` if omitted. |
| `--operations` | Comma-separated `operationId`s to generate a subset. |
| `--commands-only` | Emit only command modules, no adapter/model. |
| `--base-url` | Override the spec's `servers` URL. |
| `--dry-run` | Print the plan without writing files. |

## 3. Tour the generated code

### Commands — one per operation

Each operation becomes a `PropertyDamage.Command` with a `StreamData` generator
inferred from the schema (an enum becomes `member_of`, a bounded string becomes
`string/2` with those bounds, a `uuid` becomes a real UUID generator). The HTTP
method and path ride along as `__http_*__` helpers the adapter reads:

```elixir
defmodule WidgetTest.Commands.CreateWidget do
  @moduledoc """
  POST /widgets - Create a widget
  ...
  """

  use PropertyDamage.Command
  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:color, :name]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      color: StreamData.member_of(["red", "green", "blue"]),
      name: StreamData.string(:alphanumeric, min_length: 1, max_length: 40)
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end

  # Map an HTTP response to events (fill this in — next step 2).
  def events(command, status, response) do
    _ = {command, status, response}
    []
  end

  def __http_method__, do: :post
  def __http_path__, do: "/widgets"
end
```

`GetWidget` is generated the same way; because it is a read, it is emitted with
`use PropertyDamage.Command, shrink: :prefer_remove` (the shrinker drops reads
first) and its path parameter shows up as `def __path_params__, do: [:id]`.

### Events — from response schemas

Every 2xx response schema becomes an event struct. A field named `id` is treated
as **server-generated** and defaults to `external()`, PropertyDamage's marker for
a value the System Under Test mints (see the *Writing Commands* guide for how
`external()` values flow into later commands):

```elixir
defmodule WidgetTest.Events.WidgetCreated do
  @moduledoc """
  The created widget
  ...
  """

  import PropertyDamage, only: [external: 0]

  defstruct [:color, :name, id: external()]

  # color: string (optional)
  # id: UUID (required)
  # name: string (required)
end
```

### Adapter — drives the real API

The adapter has one `execute/2` clause per command that builds the URL (filling
path params), body, and query string, then calls the API. It prefers
[`Req`](https://hex.pm/packages/req) when present and falls back to Erlang's
built-in `:httpc`, so no HTTP dependency is required. Note the contract: **every
completed HTTP response becomes events** via the command's `events/3`; `{:error,
_}` is reserved for transport failures, so a `404` or `409` is an observation you
can assert on, not an error.

```elixir
@impl true
def execute(%Commands.CreateWidget{} = cmd, ctx, _runtime) do
  url = build_url(ctx.base_url, cmd.__struct__.__http_path__(), cmd)
  full_url = if (q = build_query(cmd)) != "", do: url <> "?" <> q, else: url
  body = build_body(cmd)

  case http_request(:post, full_url, body, []) do
    {:ok, status, response} -> {:ok, cmd.__struct__.events(cmd, status, response)}
    {:error, reason} -> {:error, reason}
  end
end
```

If the spec declares `securitySchemes`, the adapter also gets a
`build_auth_headers/1` helper and its moduledoc shows the matching
`adapter_config` keys (`bearer_token:`, `api_key:`, `basic_auth:`).

### Model — command weights, projection slots

The model lists the commands with inferred weights (reads > creates > updates >
deletes) and leaves you two `TODO`s: the state projection and any assertion
projections.

```elixir
def commands do
  [
    {Commands.GetWidget, weight: 5},
    {Commands.CreateWidget, weight: 3}
  ]
end

@impl true
def command_sequence_projection do
  raise "command_sequence_projection/0 not implemented - add your state projection module"
end
```

## 4. Fill in what the spec cannot know

The scaffold gets you a faithful *client*; you still supply the *meaning*. The
generated files' "next steps" footer lists exactly what is left:

1. **Map responses to events** — implement each command's `events/3`. Keying on
   status is the norm:

   ```elixir
   def events(_command, 201, %{"id" => id, "name" => name, "color" => color}) do
     [%WidgetTest.Events.WidgetCreated{id: id, name: name, color: color}]
   end

   def events(_command, _status, _body), do: []
   ```

2. **Write a state projection with invariants** — this is the part that catches
   bugs. It reduces events into model state and asserts properties with
   `@trigger`. See *Writing Effective Invariants* and *Coverage and Invariant
   Catalogs*.

3. **Wire the projection into the model** — replace the `raise` in
   `command_sequence_projection/0`, and list assertion projections.

4. **Add a simulator** (`simulate/2`) if you want state-dependent command
   selection (`when:`/`with:`) during the symbolic phase.

5. **Point the adapter at your API** via `adapter_config: %{base_url: ...}` and
   any auth keys.

## 5. See it run against a real API

The `openapi_bench` project in this repository is a complete, CI-gated worked
example of exactly this flow. Its `lib/generated/` is real `mix pd.scaffold`
output (from `spec/openapi.json`, a tiny key/value register API) with only the
documented next-steps filled in; the invariant lives in a hand-written
projection (`OpenapiBench.Consistency`). The System Under Test is an in-process
HTTP server, so you can run the whole loop with no external services:

```console
$ cd benches/openapi_bench
$ mix test
...........
Finished in 1.7 seconds (0.00s async, 1.7s sync)
Result: 11 passed
```

The payoff is `seeded_bug_test.exs`. The bench can flip a `bug` flag that makes
the SUT answer `PUT` with `200` but silently drop the write. The **unmodified
generated client** catches the resulting read-consistency violation and the
shrinker reduces it to the minimal reproduction:

```elixir
{:error, report} =
  PropertyDamage.run(
    model: OpenapiBench.Generated.Model,
    adapter: OpenapiBench.Generated.Adapter,
    adapter_config: %{base_url: OpenapiBench.Server.base_url(), bug: true},
    max_commands: 25, max_runs: 50, seed: 1, verbose: false
  )

PropertyDamage.Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(report))
```

produces:

```elixir
[
  %OpenapiBench.Generated.Commands.PutValue{key: 3, value: 71},
  %OpenapiBench.Generated.Commands.GetValue{key: 3}
]

# report.failure_reason:
{:assertion_failed, :read_consistent,
 %PropertyDamage.AssertionFailed{
   message: "GET key=3 returned :unset, model expects 71",
   data: %{key: 3, actual: :unset, expected: 71}
 }}
```

Two commands, one key: write a value, read it back, and the read disagrees.
Because the bug lives in the SUT and not in a hand-written adapter, this is
honest proof that the generated code drives the API for real.

## Regenerating

Re-running `mix pd.scaffold` overwrites the generated files. Keep your fill-ins
(events/3, projections, model wiring) in separate modules or under version
control so a regeneration only touches the generated base. `openapi_bench`
follows this convention: the generated client is regenerated verbatim, while the
projection and simulator are hand-written alongside it.

## Where to go next

- **Writing Effective Invariants** — the projection assertions that catch bugs.
- **Coverage and Invariant Catalogs** — prove your invariants are actually
  exercised (anti-vacuity).
- **Writing Commands** — how `external()` values flow from one command to the
  next.
- **Debugging Failures** — read, replay, and export the failures you find.
