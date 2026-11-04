# Integration Testing with PropertyDamage

This guide covers running PropertyDamage against a **live service** over HTTP,
using `PropertyDamage.Integration` and the `mix pd.integration` task.

## Overview

Integration testing runs your PropertyDamage model and adapter against a real
running service instead of an in-memory fake. This finds issues that only appear
when interacting with real infrastructure:

- Network timing issues
- Database constraints and race conditions
- Serialization/deserialization bugs
- Service startup and shutdown behavior

The core loop is simple: `PropertyDamage.Integration.run/1` runs your model
against the SUT `max_runs` times, optionally waits for a health endpoint first,
saves any failures, and produces a report. `mix pd.integration` is a thin CLI
wrapper over the same function.

## Prerequisites

- Elixir 1.17+ with Mix (general Elixir knowledge only)
- A running HTTP service to test against

This guide is runnable end to end against an in-repo bench: **`openapi_bench`**.
Its System Under Test is a tiny REST key/value register served **in-process**
(Bandit/Plug) inside the bench VM, so there is **no Docker and nothing to
install** beyond the bench's own deps. That makes it the lowest-friction way to
exercise the integration workflow; everything shown here applies unchanged to a
service running on another host (set the base URL accordingly).

## Quick Start

Everything below runs from the bench project:

```bash
cd benches/openapi_bench
mix deps.get
```

Start an IEx session. From there, boot the in-process SUT and run the
integration workflow against it:

```bash
iex -S mix
```

```elixir
# Boot the in-process REST server (idempotent). It listens on
# http://localhost:4010 by default; OpenapiBench.Server.base_url/0 returns it.
OpenapiBench.Server.ensure_started()

{:ok, result} =
  PropertyDamage.Integration.run(
    model: OpenapiBench.Generated.Model,
    targets: [{OpenapiBench.Generated.Adapter, config: %{base_url: OpenapiBench.Server.base_url()}}],
    max_runs: 20,
    max_commands: 25
  )
```

You get a live progress readout and a summary:

```
═════════════════════════════════════════════════════════════════
                 PROPERTYDAMAGE INTEGRATION TEST
═════════════════════════════════════════════════════════════════

Model:      OpenapiBench.Generated.Model
Adapter:    OpenapiBench.Generated.Adapter
Target:     http://localhost:4010
Runs:       20

Run   1/20:  25 commands ✓
Run   2/20:  25 commands ✓
...
Run  20/20:  25 commands ✓

─────────────────────────────────────────────────────────────────
✓ All 20 runs passed! (230ms)
```

`result` is a map: `%{success: true, total_runs: 20, passed: 20, failed: 0,
failures: [], duration_ms: ..., model: ..., adapter: ...}`.

### Seeing it catch a real bug

The bench's SUT has a seedable defect: pass `bug: true` in the target's `config:` and
`PUT` answers `200` but silently drops the write, so a later `GET` on the same
key comes back `404`. The generated client's read-consistency invariant catches
it, and `run/1` returns `{:error, result}`:

```elixir
{:error, result} =
  PropertyDamage.Integration.run(
    model: OpenapiBench.Generated.Model,
    targets: [{OpenapiBench.Generated.Adapter, config: %{base_url: OpenapiBench.Server.base_url(), bug: true}}],
    max_runs: 5,
    max_commands: 25
  )
```

```
Run   1/5: failed at command 1 ✗ (seed 352687743)
Run   2/5: failed at command 1 ✗ (seed 518096484)
...
─────────────────────────────────────────────────────────────────
✗ 5/5 runs failed (471ms)

First failure:
  Seed: 352687743
  Invariant: :read_consistent
```

(Seeds are random per run, so yours will differ.) Each entry in
`result.failures` is a `PropertyDamage.FailureReport` you can inspect, replay, or
save; see [Debugging Failures](debugging_failures.md). To read a failure as a
page in a browser, set `PD_REPORT_HTML=_build/pd_reports` before the run
(`PropertyDamage.Integration.run/1` and `mix pd.integration` read the variable;
`PropertyDamage.run/1` also takes a `report_html:` option). See
[The report in a browser](debugging_failures.md#the-report-in-a-browser).

## The `mix pd.integration` Task

`mix pd.integration` runs the same workflow from the shell. Unlike the
programmatic quick start above, the task runs in its **own** VM, so the service
must already be running **separately** and be reachable over the network.

### Required Options

| Option | Description |
|--------|-------------|
| `--model` | Your PropertyDamage model module (e.g., `MyApp.Model`) |
| `--adapter` | Your adapter module (e.g., `MyApp.HTTPAdapter`) |
| `--url` | Base URL of the running service (required unless the `PROPERTYDAMAGE_BASE_URL` environment variable is set) |

### Optional Options

| Option | Description | Default |
|--------|-------------|---------|
| `--runs` | Number of test sequences to run | `PROPERTYDAMAGE_RUNS`, else 100 |
| `--commands` | Maximum commands per sequence | 50 |
| `--health` | Health check URL to wait for | `{url}/api/health` |
| `--report` | Report format: `terminal`, `markdown`, `junit`, `json` | terminal |
| `--report-path` | Output path for report file | auto-generated |
| `--save-failures` | Directory to save failing sequences | - |
| `--stop-on-fail` | Stop immediately on first failure | false |
| `--hunt N` | Bug hunt mode: run until N unique bugs are found (see [Bug hunt mode](#bug-hunt-mode)) | - |
| `--verbose` | Show detailed progress | true |
| `--quiet` | Suppress progress output (overrides `--verbose`) | false |

The task reads two environment variables: `PROPERTYDAMAGE_BASE_URL` supplies the
base URL when `--url` is absent, and `PROPERTYDAMAGE_RUNS` supplies the default
run count when `--runs` is absent.

### About the health check

Without `--hunt`, `mix pd.integration` performs a health check before the first
run and has no flag to skip it: it polls `--health` (defaulting to `{url}/api/health`)
until it answers with a `2xx` status. Point `--health` at any endpoint your
service answers with `2xx`. If your service has no health route, use the
programmatic `PropertyDamage.Integration.run/1` shown above instead: there the
`:health_check` option is optional.

### Bug hunt mode

With `--hunt N`, the task runs no health check. It also ignores `--runs`, so the
hunt does not stop until it finds N unique bugs. If the service has fewer than
N bugs, the hunt runs until you stop it with Ctrl+C. `--commands`, `--report`
and `--stop-on-fail` do not apply to a hunt either.

### Running the task against the bench

The bench SUT is a pure REST resource with no `/api/health` route, so this
example points `--health` at a key we seed first. Because the task runs in a
separate VM (with no in-process store of its own), we also set `PD_OPENAPI_URL`
so the bench routes its per-sequence reset to the running server over HTTP.

In one terminal, start the server and leave it running:

```bash
cd benches/openapi_bench
iex -S mix
```

```elixir
OpenapiBench.Server.ensure_started()
```

In a second terminal, seed a key for the health check, then run the task:

```bash
cd benches/openapi_bench

# Give the health check a URL that returns 200.
curl -s -X PUT http://localhost:4010/kv/0 \
  -H 'content-type: application/json' -d '{"value": 1}'

PD_OPENAPI_URL=http://localhost:4010 mix pd.integration \
  --model OpenapiBench.Generated.Model \
  --adapter OpenapiBench.Generated.Adapter \
  --url http://localhost:4010 \
  --health http://localhost:4010/kv/0 \
  --runs 10
```

```
Health check (http://localhost:4010/kv/0)... ✓ OK
Run   1/10:  50 commands ✓
...
Run  10/10:  50 commands ✓

─────────────────────────────────────────────────────────────────
✓ All 10 runs passed! (205ms)
```

The task exits `0` when all runs pass and `1` on any failure (or `2` on a usage
error), so it drops straight into a CI gate.

### Examples

```bash
# Generate a JUnit report for CI
mix pd.integration \
  --model MyApp.Model \
  --adapter MyApp.HTTPAdapter \
  --url http://localhost:4000 \
  --runs 500 \
  --report junit \
  --report-path reports/integration.xml

# Bug hunting mode - run until 10 unique bugs are found
mix pd.integration \
  --model MyApp.Model \
  --adapter MyApp.HTTPAdapter \
  --url http://localhost:4000 \
  --hunt 10 \
  --save-failures bugs/

# Quick smoke test - stop on first failure
mix pd.integration \
  --model MyApp.Model \
  --adapter MyApp.HTTPAdapter \
  --url http://localhost:4000 \
  --runs 10 \
  --stop-on-fail
```

## Programmatic API

The quick start already used `PropertyDamage.Integration.run/1`. Its full option
set:

```elixir
run_result =
  PropertyDamage.Integration.run(
    model: OpenapiBench.Generated.Model,
    targets: [{OpenapiBench.Generated.Adapter, config: %{base_url: "http://localhost:4010"}}],
    max_runs: 100,
    max_commands: 50,
    # Optional: wait for the service to become healthy before the first run.
    health_check: %{
      url: "http://localhost:4010/kv/0",
      timeout_ms: 30_000,
      retries: 30,
      interval_ms: 1_000
    },
    # Optional: write a report file (its directory is created if missing).
    report: %{format: :markdown, path: "reports/integration.md"},
    # Optional: save each failing sequence as JSON here (created if missing).
    save_failures: "bugs/"
  )

# `run/1` returns {:error, result} when any run fails, so match both shapes.
case run_result do
  {:ok, result} -> IO.puts("All #{result.total_runs} runs passed!")
  {:error, result} -> IO.puts("#{result.failed} of #{result.total_runs} runs failed")
end
```

### Bug Hunting

`hunt_bugs/1` keeps running until it collects a target number of *unique*
failures (deduplicated by fingerprint), rather than a fixed number of runs:

```elixir
{:ok, bugs} =
  PropertyDamage.Integration.hunt_bugs(
    model: OpenapiBench.Generated.Model,
    targets: [{OpenapiBench.Generated.Adapter, config: %{base_url: "http://localhost:4010", bug: true}}],
    stop_after: 3,
    max_runs: 500,
    save_to: "discovered_bugs/"
  )

# Each bug is %{fingerprint, failure, occurrences, first_seen_run}. The list
# can hold fewer than `stop_after` entries, or none.
for bug <- bugs do
  IO.puts("#{inspect(bug.fingerprint.check_name)}: " <>
          "seed #{bug.failure.seed}, seen #{bug.occurrences}x " <>
          "(first on run #{bug.first_seen_run})")
end
```

Always set a finite `max_runs:`. The default is `:unlimited`, so a hunt that
never reaches `stop_after` unique bugs runs until you interrupt it. When the
bound is reached first, `hunt_bugs/1` still returns `{:ok, bugs}` with the bugs
found so far, which can be fewer than `stop_after` or an empty list.

## Report Formats

`--report` (CLI) or the `:report` option (programmatic) supports four formats.

### Terminal (default)

Real-time progress plus a summary block, as shown in the quick start.

### Markdown

A summary table plus a failures section, written to `--report-path`:

```markdown
# PropertyDamage Integration Test Report

## Summary

| Metric | Value |
|--------|-------|
| Model | `OpenapiBench.Generated.Model` |
| Adapter | `OpenapiBench.Generated.Adapter` |
| Duration | 205ms |
| Total Runs | 10 |
| Passed | 10 |
| Failed | 0 |
| Pass Rate | 100.0% |
```

### JUnit XML

For CI systems that ingest test results:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="PropertyDamage Integration" tests="10" failures="0" errors="0" time="0.205">
  <testcase name="run_1" classname="OpenapiBench.Generated.Model" time="0"/>
  ...
</testsuite>
```

### JSON

For programmatic analysis:

```json
{
  "success": true,
  "total_runs": 10,
  "passed": 10,
  "failed": 0,
  "model": "OpenapiBench.Generated.Model",
  "adapter": "OpenapiBench.Generated.Adapter",
  "duration_ms": 205,
  "failures": []
}
```

## Best Practices

### 1. Reset state between runs

Each run should start from a clean SUT so failures reproduce independently. The
bench resets its register in its adapter's `setup/1`, which runs before
every run, shrink attempt and replay, so a reset there must be idempotent: it can
find what a crashed run left. For your own service, either expose a reset endpoint or pass a `:reset_fn` to
`PropertyDamage.Integration.run/1`. If the service cannot be reset, see
[Cleaning Up a Shared Target](#cleaning-up-a-shared-target).

### 2. Start small, scale up

```bash
# Quick smoke test first
mix pd.integration --model MyApp.Model --adapter MyApp.HTTPAdapter \
  --url http://localhost:4000 --runs 10 --stop-on-fail

# Then a comprehensive run
mix pd.integration --model MyApp.Model --adapter MyApp.HTTPAdapter \
  --url http://localhost:4000 --runs 500
```

### 3. Save failures for regression

```bash
# Failures are written as bugs/failure_<timestamp>_run<N>.json
mix pd.integration --model MyApp.Model --adapter MyApp.HTTPAdapter \
  --url http://localhost:4000 --save-failures bugs/
```

To keep a shrunk, replayable `.pd` failure instead, save one of the failure
reports in `result.failures` (see [Static Regression
Tests](static_regression_tests.md)). `PropertyDamage.save_failure/2` names the
file after the time, the failure kind, the check and the seed, and returns its
path:

```elixir
{:ok, path} = PropertyDamage.save_failure(hd(result.failures), "failures/")
# path == "failures/20261104T002751-check_failed-read_consistent-seed920551348.pd"
# (your time and seed differ)
```

Then replay it. Against the bench, set `PD_OPENAPI_URL` as for the task above,
so the replay resets the running server:

```bash
# Re-run the failing sequence against the SUT and print a verdict. Exit codes:
# 0 = fixed, 1 = the bug still reproduces, 125 = the replay could not run (the
# project does not compile, the file fails to load or records no model or
# target, the sequence is branching, or the target's setup fails), 2 = usage
# error.
mix pd.replay failures/20261104T002751-check_failed-read_consistent-seed920551348.pd

# Show per-step events and projection state
mix pd.replay failures/20261104T002751-check_failed-read_consistent-seed920551348.pd --verbose
```

The `.pd` file records its own model and targets, so no `--model` / `--adapter`
flags are needed; those modules just have to be compiled in the current project.
Because the exit code is a regression signal, `mix pd.replay` drops straight into
a CI gate or a `git bisect`.

For custom adapter config (e.g. a different base URL), replay
programmatically. `targets:` replaces the recorded target config whole, so
carry over every recorded key the failure depends on (here `bug: true`), or
the replay runs against a different system and may pass:

```elixir
{:ok, failure} = PropertyDamage.load_failure("failures/20261104T002751-check_failed-read_consistent-seed920551348.pd")
PropertyDamage.replay(failure, targets: [{OpenapiBench.Generated.Adapter, config: %{base_url: "http://localhost:4010", bug: true}}])
```

Replay does not apply stutter. To re-shrink a failure that stutter found, use
`PropertyDamage.shrink_further/2`, which re-applies the report's `stutter:`
configuration (see [Idempotency Testing](idempotency_testing.md)).

## Cleaning Up a Shared Target

Some systems cannot be reset: a shared staging server, a tenant other teams
use. `Adapter.setup/1` cannot wipe them, and `Adapter.teardown/1` does not
know which ids the run created. For these, the model's `teardown_each/0`
returns teardown commands that delete what the run created.

The generator draws teardown commands after the last root, so an `overrides:`
function sees the state the roots left. In the example, `Remove` receives the
ids of every note the run created:

<!-- pd-doc-verify: runnable -->
```elixir
defmodule Shared.Events do
  defmodule NoteCreated do
    import PropertyDamage, only: [external: 0]
    defstruct [:text, note_id: external()]
  end

  defmodule NotesRemoved do
    defstruct [:note_ids]
  end
end

defmodule Shared.Commands do
  defmodule CreateNote do
    use PropertyDamage.Command
    import PropertyDamage.Generator, only: [merge_overrides: 2]

    defstruct [:text]

    @impl true
    def generator(overrides \\ %{}) do
      %{text: StreamData.string(:alphanumeric, min_length: 1)}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end

  defmodule Remove do
    use PropertyDamage.Command
    import PropertyDamage.Generator, only: [merge_overrides: 2]

    defstruct [:note_ids]

    @impl true
    def generator(overrides \\ %{}) do
      %{note_ids: []}
      |> merge_overrides(overrides)
      |> StreamData.fixed_map()
    end
  end
end

defmodule Shared.Notes do
  use PropertyDamage.Model.Projection

  alias Shared.Events.NoteCreated

  @impl true
  def init, do: %{note_ids: []}

  @impl true
  def apply(state, %NoteCreated{note_id: id}), do: %{state | note_ids: [id | state.note_ids]}
  def apply(state, _event), do: state
end

defmodule Shared.Model do
  @behaviour PropertyDamage.Model.Simulator
  use PropertyDamage.Model

  alias Shared.Commands.{CreateNote, Remove}
  alias Shared.Events.{NoteCreated, NotesRemoved}

  @impl true
  def commands, do: [CreateNote]

  # Runs after the last root, against the state that root left.
  @impl true
  def teardown_each do
    [{Remove, overrides: fn state -> %{note_ids: state.note_ids} end}]
  end

  @impl true
  def command_sequence_projection, do: Shared.Notes

  @impl true
  def simulator, do: __MODULE__

  @impl PropertyDamage.Model.Simulator
  def simulate(%CreateNote{text: text}, _state), do: [%NoteCreated{text: text}]
  def simulate(%Remove{note_ids: ids}, _state), do: [%NotesRemoved{note_ids: ids}]
end

defmodule Shared.Adapter do
  use PropertyDamage.Adapter

  alias Shared.Commands.{CreateNote, Remove}
  alias Shared.Events.{NoteCreated, NotesRemoved}

  # The shared server outlives every run; this agent stands in for it.
  @impl true
  def setup(%{server: server}), do: {:ok, %{server: server}}

  @impl true
  def teardown(_ctx), do: :ok

  @impl true
  def execute(%CreateNote{text: text}, %{server: server}, _runtime) do
    id = System.unique_integer([:positive])
    Agent.update(server, &Map.put(&1, id, text))
    {:ok, [%NoteCreated{text: text, note_id: id}]}
  end

  def execute(%Remove{note_ids: ids}, %{server: server}, _runtime) do
    Agent.update(server, &Map.drop(&1, ids))
    {:ok, [%NotesRemoved{note_ids: ids}]}
  end
end

{:ok, server} = Agent.start_link(fn -> %{} end)

{:ok, _stats} =
  PropertyDamage.run(
    model: Shared.Model,
    targets: [{Shared.Adapter, config: %{server: server}}],
    max_runs: 5,
    max_commands: 6,
    seed: 1
  )

# Every note the runs created is gone, though nothing reset the server.
0 = Agent.get(server, &map_size/1)
```

Teardown commands run after every execution, pass or fail, and after every
shrink attempt, so a failing run leaves the shared target clean as well. They
are best effort: an error or a raise is logged and never changes the verdict.
[Writing Commands](writing_commands.md#setup-and-teardown-commands) lists the
rules, the setup-failure causes, and where infrastructure reset and target
isolation belong.

## CI/CD Integration

Every in-repo bench is CI-gated: its `mix test` boots the SUT (in-process for
`openapi_bench`, via Docker for the others) and runs the property suite, so the
integration path is exercised on each push. Use the same shape for your own
service. A minimal GitHub Actions job for a service with a health endpoint:

```yaml
name: Integration Tests
on: [push, pull_request]

jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Start service
        run: docker compose up -d

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.17'
          otp-version: '27'

      - name: Run integration tests
        run: |
          mix deps.get
          mix pd.integration \
            --model MyApp.Model \
            --adapter MyApp.HTTPAdapter \
            --url http://localhost:4000 \
            --runs 200 \
            --report junit \
            --report-path reports/integration.xml

      - name: Publish results
        uses: EnricoMi/publish-unit-test-result-action@v2
        if: always()
        with:
          files: reports/*.xml
```

## Troubleshooting

### Service not ready

```
Health check (...)... ✗ FAILED
** (RuntimeError) Health check failed: :max_retries_exceeded
```

- Confirm the service is running and reachable: `curl http://localhost:4010/kv/0`
- Point `--health` at an endpoint that returns a `2xx` status
- Increase the health-check timeout / retries (programmatic `:health_check`)

### Connection refused

```
** (Mint.TransportError) connection refused
```

- Verify the service is listening on the expected host and port
- For the bench, make sure `OpenapiBench.Server.ensure_started()` ran in a
  session that is still alive

### Flaky results (passes sometimes, fails others)

- Look for time-dependent behavior or shared state not reset between runs
- Use a `:reset_fn`, or reset the service in an idempotent `Adapter.setup/1`
- See [Chaos Engineering](chaos_engineering.md) to deliberately surface races

## Next Steps

- [Writing Effective Invariants](writing_invariants.md) - Improve test quality
- [Debugging Failures](debugging_failures.md) - Analyze and fix bugs
- [Chaos Engineering](chaos_engineering.md) - Fault injection testing
