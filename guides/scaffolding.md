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
server-generated `id`, enough to exercise every part of the generator:

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

Projection:
  - WidgetTest.Projections.State
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

Generating projection...
  lib/widget_test/projections/state.ex

✓ Generated 2 commands in lib/widget_test

Next steps:
  1. Review and customize generators in command generator/1 callbacks
  2. Define events/3 (command, status, response) to map responses to events
  3. Add when:/overrides: options in Model's commands() for preconditions
  4. Add a simulator module with simulate/2 and name it in the Model's simulator/0
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
| `--commands-only` | Write only the command and event modules, with no adapter, model or projection. It refuses to overwrite existing command or event files, like a full run. |
| `--base-url` | Override the spec's `servers` URL. |
| `--dry-run` | Print the plan without writing files. |
| `--force` | Overwrite files that already exist. Without it, the task refuses and names them. |

## 3. Tour the generated code

### Commands: one per operation

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

  use PropertyDamage.Command, observables: [WidgetTest.Events.WidgetCreated]
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

  # Map an HTTP response to events. The adapter calls this for every
  # completed HTTP response (fill this in: next step 2).
  def events(command, status, response) do
    _ = {command, status, response}
    []
  end

  def __http_method__, do: :post
  def __http_path__, do: "/widgets"
end
```

`GetWidget` is generated the same way; because it is a read, it is emitted with
`use PropertyDamage.Command, shrink: :prefer_remove, observables:
[WidgetTest.Events.WidgetRetrieved]` (the shrinker drops reads first) and its path parameter shows up as `def __path_params__, do: [:id]`.

### Events: from response schemas

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

  # color: string (set by events/3; may be :unset)
  # id: UUID (set by events/3; may be :unset)
  # name: string (set by events/3; may be :unset)
end
```

The trailing comments list each response field and its type. The `events/3` you
write in the command sets them, and a field may be `:unset` when your mapping
does not record it.

### Adapter: drives the real API

The adapter has one `execute/3` clause per command that builds the URL (filling
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
  query = build_query(cmd)
  full_url = if query != "", do: url <> "?" <> query, else: url
  body = build_body(cmd)
  headers = []

  case http_request(:post, full_url, body, headers) do
    {:ok, status, response} -> {:ok, cmd.__struct__.events(cmd, status, response)}
    {:error, reason} -> {:error, reason}
  end
end
```

The adapter also defines `http_spec/2`, which describes each command as an HTTP
call so `PropertyDamage.Export` can turn a failure into curl, Python or Elixir
scripts.

If the spec declares `securitySchemes`, the adapter also gets a
`build_auth_headers/1` helper and its moduledoc shows the matching
target `config:` keys (`bearer_token:`, `api_key:`, `basic_auth:`).

### Model: command weights, projection slots

The model lists the commands with inferred weights (reads > creates > updates >
deletes) and names a starter state projection, `Projections.State`, that
ignores every event. A `TODO` marks where to add check projections.

```elixir
def commands do
  [
    {Commands.GetWidget, weight: 5},
    {Commands.CreateWidget, weight: 3}
  ]
end

@impl true
def command_sequence_projection, do: Projections.State
```

## 4. Fill in what the spec cannot know

The scaffold gets you a faithful *client*; you still supply the *meaning*. The
task's printed "Next steps" footer (shown in step 2; the task prints it and
writes it to no file) lists five items. The steps below take them in a different
order. Item 1 (review the generators) is the tour in section 3, and item 3 (`when:`
and `overrides:`) goes with the simulator in item 4 below. The steps also add the
projection and the optional expansions.

1. **Map responses to events**: implement each command's `events/3`. Keying on
   status is the norm:

   ```elixir
   def events(_command, 201, %{"id" => id, "name" => name} = body) do
     color = Map.get(body, "color", :unset)
     [%WidgetTest.Events.WidgetCreated{id: id, name: name, color: color}]
   end

   def events(_command, _status, _body), do: []
   ```

2. **Write a state projection with invariants**: this is the part that catches
   bugs. It reduces events into model state and asserts properties with
   `@check`. See *Writing Effective Invariants* and *Coverage and Invariant
   Catalogs*.

3. **Wire the projection into the model**: fill in the generated
   `Projections.State` (or point `command_sequence_projection/0` at your own
   module), and list check projections.

4. **Add a simulator**: a module with `simulate/2`, named by the model's
   `simulator/0`. You need it if you want state-dependent command
   selection during the symbolic phase: the `when:` and `overrides:` options
   in the model's `commands/0` read the state that the simulator's events build.

5. **Point the adapter at your API** via `targets: [{Adapter, config: %{base_url: ...}}]` and
   any auth keys.

6. **Optionally, say which command sequences mean the same.** The generated model
   carries a commented `expansions/0` next to the setup and teardown callbacks. A
   root listed there may run, per target, as one of several sequences that mean
   the same once the root is done, and each target's `expansion:` option picks
   (`:random`, the default, `:identity` or `:reference`). See
   [Writing Commands](writing_commands.md#expansions-one-root-several-commands).

7. **Validate the model.** `mix pd.validate WidgetTest.Model WidgetTest.Adapter`
   checks the configuration. For a model with `expansions/0`, add `--seeds N`
   (default 100) to sample N root sequences and list every expansion entry with
   how often the sample realized it, and the entries it never did. `--seed S`
   starts the sample at seed `S`, and `--seed S --seeds 1` samples exactly what
   `seed: S, max_runs: 1` runs.

## 5. See it run against a real API

The `openapi_bench` project in this repository is a complete, CI-gated worked
example of exactly this flow. Its `lib/generated/` is real `mix pd.scaffold`
output (from `spec/openapi.json`, a tiny key/value register API) with the
documented next-steps filled in by hand, inside the generated files (each
command's `events/3`, the adapter's `setup/1` and the model wiring); the invariant lives in a hand-written
projection (`OpenapiBench.Consistency`). The System Under Test is an in-process
HTTP server, so you can run the whole loop with no external services:

```console
$ cd benches/openapi_bench
$ mix test
...
Finished in 1.7 seconds (0.00s async, 1.7s sync)
N tests, 0 failures
```

The timing and test count above are abridged and vary by release.

The payoff is `seeded_bug_test.exs`. The bench can flip a `bug` flag that makes
the SUT answer `PUT` with `200` but silently drop the write. The **generated
client with its next-step fill-ins** catches the resulting read-consistency violation and the
shrinker reduces it to the minimal reproduction:

```elixir
{:error, report} =
  PropertyDamage.run(
    model: OpenapiBench.Generated.Model,
    targets: [{OpenapiBench.Generated.Adapter, config: %{base_url: OpenapiBench.Server.base_url(), bug: true}}],
    max_commands: 25, max_runs: 50, seed: 1, verbose: false
  )

PropertyDamage.Sequence.to_list(PropertyDamage.FailureReport.shrunk_sequence(report))
```

produces a result like this (the keys and values vary with the seed; the `Failure.Check` struct also has `context` and `projection` fields, left out here):

```elixir
[
  %OpenapiBench.Generated.Commands.PutValue{key: 3, value: 71},
  %OpenapiBench.Generated.Commands.GetValue{key: 3}
]

# report.failure_reason:
%PropertyDamage.Failure{
  type: %PropertyDamage.Failure.Check{
    kind: :check_failed,
    name: :read_consistent,
    detail: %PropertyDamage.CheckFailed{
      message: "GET key=3 returned :unset, model expects 71",
      data: %{key: 3, actual: :unset, expected: 71}
    }
  }
}
```

Two commands, one key: write a value, read it back, and the read disagrees.
Because the bug lives in the SUT and not in a hand-written adapter, this is
honest proof that the generated code drives the API for real.

## Regenerating

Re-running `mix pd.scaffold` refuses to touch existing files unless you pass `--force`, which overwrites the generated files. Keep your fill-ins
(events/3, projections, model wiring) in separate modules or under version
control so a regeneration only touches the generated base. `openapi_bench` does
not follow this convention for its `events/3` clauses, adapter `setup/1` and
model wiring, which live inside `lib/generated/`, so a `--force` run there would
overwrite them. Only its projection and simulator are hand-written in separate
modules.

## Where to go next

- **Writing Effective Invariants**: the projection checks that catch bugs.
- **Coverage and Invariant Catalogs**: prove your invariants are actually
  exercised (anti-vacuity).
- **Writing Commands**: how `external()` values flow from one command to the
  next.
- **Debugging Failures**: read, replay, and export the failures you find.
