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
    adapter: OpenapiBench.Generated.Adapter,
    adapter_config: %{base_url: OpenapiBench.Server.base_url()},
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

The bench's SUT has a seedable defect: pass `bug: true` in `adapter_config` and
`PUT` answers `200` but silently drops the write, so a later `GET` on the same
key comes back `404`. The generated client's read-consistency invariant catches
it, and `run/1` returns `{:error, result}`:

```elixir
{:error, result} =
  PropertyDamage.Integration.run(
    model: OpenapiBench.Generated.Model,
    adapter: OpenapiBench.Generated.Adapter,
    adapter_config: %{base_url: OpenapiBench.Server.base_url(), bug: true},
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
save; see [Debugging Failures](debugging_failures.md).

## The `mix pd.integration` Task

`mix pd.integration` runs the same workflow from the shell. Unlike the
programmatic quick start above, the task runs in its **own** VM, so the service
must already be running **separately** and be reachable over the network.

### Required Options

| Option | Description |
|--------|-------------|
| `--model` | Your PropertyDamage model module (e.g., `MyApp.Model`) |
| `--adapter` | Your adapter module (e.g., `MyApp.HTTPAdapter`) |
| `--url` | Base URL of the running service |

### Optional Options

| Option | Description | Default |
|--------|-------------|---------|
| `--runs` | Number of test sequences to run | 100 |
| `--commands` | Maximum commands per sequence | 50 |
| `--health` | Health check URL to wait for | `{url}/api/health` |
| `--report` | Report format: `terminal`, `markdown`, `junit`, `json` | terminal |
| `--report-path` | Output path for report file | auto-generated |
| `--save-failures` | Directory to save failing sequences | - |
| `--stop-on-fail` | Stop immediately on first failure | false |
| `--hunt N` | Bug hunt mode: run until N unique bugs found | - |
| `--quiet` | Suppress progress output | false |

### About the health check

`mix pd.integration` **always** performs a health check before the first run and
has no flag to skip it: it polls `--health` (defaulting to `{url}/api/health`)
until it answers with a `2xx` status. Point `--health` at any endpoint your
service answers with `2xx`. If your service has no health route, use the
programmatic `PropertyDamage.Integration.run/1` shown above instead: there the
`:health_check` option is optional.

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
{:ok, result} =
  PropertyDamage.Integration.run(
    model: OpenapiBench.Generated.Model,
    adapter: OpenapiBench.Generated.Adapter,
    adapter_config: %{base_url: "http://localhost:4010"},
    max_runs: 100,
    max_commands: 50,
    # Optional: wait for the service to become healthy before the first run.
    health_check: %{
      url: "http://localhost:4010/kv/0",
      timeout_ms: 30_000,
      retries: 30
    },
    # Optional: write a report file.
    report: %{format: :markdown, path: "reports/integration.md"},
    # Optional: save each failing sequence as JSON here.
    save_failures: "bugs/"
  )

if result.success do
  IO.puts("All #{result.total_runs} runs passed!")
else
  IO.puts("#{result.failed} runs failed")
end
```

### Bug Hunting

`hunt_bugs/1` keeps running until it collects a target number of *unique*
failures (deduplicated by fingerprint), rather than a fixed number of runs:

```elixir
{:ok, bugs} =
  PropertyDamage.Integration.hunt_bugs(
    model: OpenapiBench.Generated.Model,
    adapter: OpenapiBench.Generated.Adapter,
    adapter_config: %{base_url: "http://localhost:4010", bug: true},
    stop_after: 3,
    max_runs: :unlimited,
    save_to: "discovered_bugs/"
  )

# Each bug is %{fingerprint, failure, occurrences, first_seen_run}.
for bug <- bugs do
  IO.puts("#{inspect(bug.fingerprint.check_name)}: " <>
          "seed #{bug.failure.seed}, seen #{bug.occurrences}x " <>
          "(first on run #{bug.first_seen_run})")
end
```

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
  "model": "Elixir.OpenapiBench.Generated.Model",
  "adapter": "Elixir.OpenapiBench.Generated.Adapter",
  "failures": []
}
```

## Best Practices

### 1. Reset state between runs

Each run should start from a clean SUT so failures reproduce independently. The
bench does this in its model's `setup_each/1`, which resets the register before
every sequence. For your own service, either expose a reset endpoint or pass a
`:reset_fn` to `PropertyDamage.Integration.run/1`.

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

To keep a shrunk, replayable `.pd` failure instead, save it from a
`PropertyDamage.run` failure report (see [Static Regression
Tests](static_regression_tests.md)), then replay it:

```bash
# Re-run the failing sequence against the SUT and print a verdict. The exit code
# answers "does the bug still reproduce?": non-zero = yes, zero = fixed.
mix pd.replay bugs/read_consistent-seed352687743.pd

# Show per-step events and projection state
mix pd.replay bugs/read_consistent-seed352687743.pd --verbose
```

The `.pd` file records its own model and adapter, so no `--model` / `--adapter`
flags are needed; those modules just have to be compiled in the current project.
Because the exit code is a regression signal, `mix pd.replay` drops straight into
a CI gate or a `git bisect`.

For custom adapter config (e.g. a different base URL) or stutter, replay
programmatically:

```elixir
{:ok, failure} = PropertyDamage.load_failure("bugs/read_consistent-seed352687743.pd")
PropertyDamage.replay(failure, adapter_config: %{base_url: "http://localhost:4010"})
```

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
- Use a `:reset_fn` (or a per-sequence reset like the bench's `setup_each/1`)
- See [Chaos Engineering](chaos_engineering.md) to deliberately surface races

## Next Steps

- [Writing Effective Invariants](writing_invariants.md) - Improve test quality
- [Debugging Failures](debugging_failures.md) - Analyze and fix bugs
- [Chaos Engineering](chaos_engineering.md) - Fault injection testing
