# Integration Testing with PropertyDamage

This guide covers running PropertyDamage tests against live services using
the integration testing tools and scripts.

## Overview

Integration testing runs your PropertyDamage model and adapter against a real
running service instead of mocks. This finds issues that only appear when
interacting with real infrastructure:

- Network timing issues
- Database constraints and race conditions
- Serialization/deserialization bugs
- Service startup and shutdown behavior

## Prerequisites

- Docker and Docker Compose (for containerized testing)
- Elixir 1.14+ with Mix
- Your service running or ability to start it

## Quick Start

### Using the Mix Task

```bash
# Run integration tests against a running service
mix pd.integration \
  --model MyApp.Model \
  --adapter MyApp.HTTPAdapter \
  --url http://localhost:4000 \
  --runs 100
```

### Using Test Scripts

PropertyDamage includes ready-to-use test scripts for example services:

```bash
# ToyBank integration tests
./scripts/test_toybank.sh --runs 100

# TravelBooking integration tests
./scripts/test_travelbooking.sh --runs 100
```

## The `mix pd.integration` Task

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

### Examples

```bash
# Basic test run
mix pd.integration \
  --model ToyBankTest.Model \
  --adapter ToyBankTest.Adapters.HTTPAdapter \
  --url http://localhost:4555

# Generate JUnit report for CI
mix pd.integration \
  --model ToyBankTest.Model \
  --adapter ToyBankTest.Adapters.HTTPAdapter \
  --url http://localhost:4555 \
  --runs 500 \
  --report junit \
  --report-path reports/integration.xml

# Bug hunting mode - find 10 unique bugs
mix pd.integration \
  --model ToyBankTest.Model \
  --adapter ToyBankTest.Adapters.HTTPAdapter \
  --url http://localhost:4555 \
  --hunt 10 \
  --save-failures bugs/

# Quick smoke test - stop on first failure
mix pd.integration \
  --model ToyBankTest.Model \
  --adapter ToyBankTest.Adapters.HTTPAdapter \
  --url http://localhost:4555 \
  --runs 10 \
  --stop-on-fail
```

## ToyBank Integration Testing

ToyBank is a banking service with accounts, authorizations, and captures.

### Starting ToyBank

```bash
cd /path/to/toy_bank

# Using Docker Compose (recommended for testing)
docker compose -f docker-compose.test.yml up -d

# Or start manually
docker compose -f docker-compose.dev.yml up -d  # Database only
mix ecto.setup
mix phx.server
```

### Running Tests

```bash
# Use the test script (handles startup/teardown)
./scripts/test_toybank.sh --runs 100

# Or run manually with mix
mix pd.integration \
  --model ToyBankTest.Model \
  --adapter ToyBankTest.Adapters.HTTPAdapter \
  --url http://localhost:4555
```

### Test Script Options

```bash
./scripts/test_toybank.sh --help

Options:
  --runs N          Number of test runs (default: 100)
  --hunt N          Bug hunt mode: find N unique bugs
  --chaos           Enable chaos testing with ChaosModel
  --report FORMAT   Generate report: markdown, junit, json
  --keep-running    Don't stop ToyBank after tests
  --skip-start      Assume ToyBank is already running
  --verbose         Show detailed output
```

### Chaos Testing

The ToyBank docker-compose.test.yml includes Toxiproxy for fault injection:

```bash
# Start with chaos testing support
cd /path/to/toy_bank
docker compose -f docker-compose.test.yml --profile chaos up -d

# Run chaos tests through Toxiproxy (port 4556)
./scripts/test_toybank.sh --chaos --runs 50
```

## TravelBooking Integration Testing

TravelBooking is an in-memory travel booking service with flights, hotels, and bookings.

### Starting TravelBooking

```bash
cd /path/to/travel_booking

# Using Docker Compose
docker compose -f docker-compose.test.yml up -d

# Or run locally (simpler - no database required)
mix deps.get
mix run --no-halt
```

### Running Tests

```bash
# Use the test script
./scripts/test_travelbooking.sh --runs 100

# Or run manually
mix pd.integration \
  --model TravelBookingTest.Model \
  --adapter TravelBookingTest.Adapters.HTTPAdapter \
  --url http://localhost:4445
```

### Test Script Options

```bash
./scripts/test_travelbooking.sh --help

Options:
  --runs N          Number of test runs (default: 100)
  --commands N      Max commands per run (default: 50)
  --hunt N          Bug hunt mode: find N unique bugs
  --chaos           Enable chaos testing with ChaosModel
  --lifecycle       Use BookingLifecycleModel (state transitions)
  --report FORMAT   Generate report: markdown, junit, json
  --keep-running    Don't stop TravelBooking after tests
  --skip-start      Assume TravelBooking is already running
  --local           Run TravelBooking locally (no Docker)
  --verbose         Show detailed output
```

### Different Models

TravelBooking has multiple models for different testing scenarios:

```bash
# Full model - all commands
./scripts/test_travelbooking.sh --runs 100

# Lifecycle model - focuses on booking state transitions
./scripts/test_travelbooking.sh --lifecycle --runs 100

# Chaos model - includes fault injection
./scripts/test_travelbooking.sh --chaos --runs 50
```

## Docker Compose Test Configurations

Both example services include `docker-compose.test.yml` files optimized for testing:

### ToyBank docker-compose.test.yml

```yaml
services:
  db:
    # PostgreSQL with no persistent volume (ephemeral)
    # Uses port 5433 to avoid conflicts with dev

  app:
    # ToyBank with health check
    # Includes database migration on startup

  toxiproxy:
    # Optional chaos testing proxy
    # Activated with: --profile chaos

  db-reset:
    # Helper to reset database between runs
    # Usage: docker compose run --rm db-reset
```

### TravelBooking docker-compose.test.yml

```yaml
services:
  app:
    # TravelBooking with health check
    # In-memory storage (no database needed)

  toxiproxy:
    # Optional chaos testing proxy

  data-reset:
    # Reset in-memory data
    # Usage: docker compose run --rm data-reset

  enable-fixes:
    # Enable all bug fixes

  disable-fixes:
    # Disable all bug fixes (for bug hunting)
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Integration Tests

on: [push, pull_request]

jobs:
  integration:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Start services
        run: docker compose -f docker-compose.test.yml up -d

      - name: Wait for services
        run: |
          timeout 60 bash -c 'until curl -s http://localhost:4555/api/health; do sleep 1; done'

      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.16'
          otp-version: '26'

      - name: Run integration tests
        run: |
          mix deps.get
          mix pd.integration \
            --model ToyBankTest.Model \
            --adapter ToyBankTest.Adapters.HTTPAdapter \
            --url http://localhost:4555 \
            --runs 200 \
            --report junit \
            --report-path reports/integration.xml

      - name: Upload test results
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: test-results
          path: reports/

      - name: Publish test results
        uses: EnricoMi/publish-unit-test-result-action@v2
        if: always()
        with:
          files: reports/*.xml

      - name: Stop services
        if: always()
        run: docker compose -f docker-compose.test.yml down -v
```

### Makefile Example

```makefile
.PHONY: test-integration test-chaos test-hunt

# Start test services
test-services-up:
	docker compose -f docker-compose.test.yml up -d
	@echo "Waiting for services..."
	@timeout 60 bash -c 'until curl -s http://localhost:4555/api/health; do sleep 1; done'

# Stop test services
test-services-down:
	docker compose -f docker-compose.test.yml down -v

# Run integration tests
test-integration: test-services-up
	mix pd.integration \
		--model ToyBankTest.Model \
		--adapter ToyBankTest.Adapters.HTTPAdapter \
		--url http://localhost:4555 \
		--runs 100 \
		--report markdown \
		--report-path reports/integration.md
	$(MAKE) test-services-down

# Run chaos tests
test-chaos:
	docker compose -f docker-compose.test.yml --profile chaos up -d
	@timeout 60 bash -c 'until curl -s http://localhost:4555/api/health; do sleep 1; done'
	mix pd.integration \
		--model ToyBankTest.ChaosModel \
		--adapter ToyBankTest.Adapters.HTTPAdapter \
		--url http://localhost:4556 \
		--runs 50
	docker compose -f docker-compose.test.yml down -v

# Bug hunting
test-hunt: test-services-up
	mix pd.integration \
		--model ToyBankTest.Model \
		--adapter ToyBankTest.Adapters.HTTPAdapter \
		--url http://localhost:4555 \
		--hunt 10 \
		--save-failures bugs/
	$(MAKE) test-services-down
```

## Programmatic API

You can also use the integration testing API directly in Elixir:

```elixir
# Run integration tests
{:ok, result} = PropertyDamage.Integration.run(
  model: ToyBankTest.Model,
  adapter: ToyBankTest.Adapters.HTTPAdapter,
  adapter_config: %{base_url: "http://localhost:4555"},
  max_runs: 100,
  max_commands: 50,
  health_check: %{
    url: "http://localhost:4555/api/health",
    timeout_ms: 30_000,
    retries: 30
  },
  report: %{
    format: :markdown,
    path: "reports/integration.md"
  },
  save_failures: "bugs/"
)

# Check results
if result.success do
  IO.puts("All tests passed!")
  IO.puts("Runs: #{result.total_runs}")
else
  IO.puts("Tests failed!")
  IO.puts("Failures: #{result.failed}")
end
```

### Bug Hunting

```elixir
# Run until we find 5 unique bugs
{:ok, bugs} = PropertyDamage.Integration.hunt_bugs(
  model: ToyBankTest.Model,
  adapter: ToyBankTest.Adapters.HTTPAdapter,
  adapter_config: %{base_url: "http://localhost:4555"},
  stop_after: 5,
  max_runs: :unlimited,
  save_to: "discovered_bugs/"
)

# Analyze findings. Each bug is %{fingerprint, failure, occurrences, first_seen_run}
for bug <- bugs do
  IO.puts("Fingerprint: #{bug.fingerprint}")
  IO.puts("Seed: #{bug.failure.seed}")
  IO.puts("Occurrences: #{bug.occurrences} (first seen on run #{bug.first_seen_run})")
end
```

## Report Formats

### Terminal (Default)

Real-time progress with colored output:

```
PropertyDamage Integration Test
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Progress: ████████████████████████████░░░░░░░░░░░░░░░░░░░░  56%
Runs: 56/100 | Passed: 54 | Failed: 2 | Duration: 23.4s

Recent failures:
  • Seed 12345678: Balance went negative after debit
  • Seed 87654321: Authorization not found after creation
```

### Markdown

Detailed report for documentation:

```markdown
# Integration Test Report

**Date**: 2024-12-27 15:30:00 UTC
**Model**: ToyBankTest.Model
**Runs**: 100

## Summary

| Metric | Value |
|--------|-------|
| Passed | 98 |
| Failed | 2 |
| Duration | 45.2s |

## Failures

### Failure 1: Balance went negative

**Seed**: 12345678
**Commands**: 5

...
```

### JUnit XML

For CI systems:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="PropertyDamage" tests="100" failures="2" time="45.2">
    <testcase name="Seed_12345678" time="0.45">
      <failure message="Balance went negative">...</failure>
    </testcase>
    ...
  </testsuite>
</testsuites>
```

### JSON

For programmatic analysis:

```json
{
  "success": false,
  "total_runs": 100,
  "passed": 98,
  "failed": 2,
  "model": "Elixir.MyApp.Model",
  "adapter": "Elixir.MyApp.Adapter",
  "failures": [
    {
      "seed": 12345678,
      "failure_reason": "Balance went negative",
      "shrunk_sequence": "..."
    }
  ]
}
```

## Best Practices

### 1. Use Ephemeral Data

Configure your test database/storage to reset between runs:

```bash
# Reset before each run
docker compose run --rm db-reset
mix pd.integration ...
```

### 2. Start Small, Scale Up

```bash
# Quick smoke test first
mix pd.integration --runs 10 --stop-on-fail

# Then comprehensive testing
mix pd.integration --runs 500
```

### 3. Save Failures for Regression

```bash
# Save all failures (written as bugs/failure_<timestamp>_run<N>.json)
mix pd.integration --save-failures bugs/
```

Replay a saved `.pd` failure with the mix task:

```bash
# Re-run the failing sequence against the SUT and print a verdict.
# Exit code answers "does the bug still reproduce?": non-zero = yes, zero = fixed.
mix pd.replay bugs/2025-12-26T14-30-00-check_failed-NonNegativeBalance-seed512902757.pd

# Show per-step events and projection state
mix pd.replay bugs/currency-bug.pd --verbose
```

The failure file already records its model and adapter, so no `--model` /
`--adapter` flags are needed; those modules just have to be compiled in the
current project. Because the exit code is a regression signal (non-zero while the
bug reproduces), `mix pd.replay` drops straight into a CI gate or a `git bisect`.

For custom adapter config or stutter (not exposed on the CLI), replay
programmatically instead:

```elixir
{:ok, failure} = PropertyDamage.load_failure("bugs/currency-bug.pd")
PropertyDamage.replay(failure, adapter_config: %{base_url: "http://localhost:4555"})
```

### 4. Use Appropriate Models

- **Standard Model**: Normal operations
- **Lifecycle Model**: Focus on state transitions
- **Chaos Model**: Include fault injection
- **Mock Model**: In-memory testing (fast)

### 5. Monitor in CI

- Generate JUnit reports for test result tracking
- Archive failure files as artifacts
- Set appropriate timeouts

## Troubleshooting

### Service Not Ready

```
ERROR: Service did not become ready within 60 seconds
```

**Solutions**:
- Increase health check timeout
- Check service logs: `docker compose logs app`
- Verify health endpoint is correct

### Connection Refused

```
** (Mint.TransportError) connection refused
```

**Solutions**:
- Verify service is running: `curl http://localhost:4555/api/health`
- Check port mappings in docker-compose
- Ensure no firewall blocking

### Flaky Tests

```
Test passes sometimes, fails other times with same seed
```

**Solutions**:
- Look for time-dependent behavior
- Check for external dependencies
- Use `--verbose` to see timing details
- Consider chaos testing to find race conditions

## Next Steps

- [Writing Effective Invariants](writing_invariants.md) - Improve test quality
- [Debugging Failures](debugging_failures.md) - Analyze and fix bugs
- [Chaos Engineering](chaos_engineering.md) - Fault injection testing
