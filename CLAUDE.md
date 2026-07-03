# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

PropertyDamage is a stateful property-based testing (SPBT) framework for Elixir. It generates random sequences of operations against a System Under Test, verifies invariants hold throughout, and automatically shrinks failures to minimal reproductions.

## Commands

```bash
# Dependencies
mix deps.get

# Run all tests
mix test

# Run a single test file
mix test test/property_damage/executor_test.exs

# Run a specific test by line number
mix test test/property_damage/executor_test.exs:42

# Format code
mix format

# Check formatting without writing
mix format --check-formatted

# Generate docs
mix docs
```

### Mix task generators

```bash
mix pd.gen.command ModuleName      # Generate a command stub
mix pd.gen.model ModuleName        # Generate a model with commands/projections
mix pd.gen.projection ModuleName   # Generate a projection stub
mix pd.gen.adapter ModuleName      # Generate an adapter stub
mix pd.scaffold ProjectName        # Full project scaffold
mix pd.validate                    # Validate model/adapter configuration
mix pd.integration                 # Run integration tests against live services
```

## Architecture

### Five core behaviours

All user-facing contracts are defined as behaviours:

- **Command** (`lib/property_damage/command.ex`) — Pure generator interface. Defines `generator/1` returning `StreamData.t(map())`. Commands are stateless semantic definitions; state-dependent logic (preconditions, overrides) belongs in the Model.
- **Model** (`lib/property_damage/model.ex`) — Orchestrates which commands run and when. Required: `commands/0` (list of command specs with optional `weight:`, `when:`, `with:` options) and `command_sequence_projection/0`. Optional: `assertion_projections/0`, `simulator/0`, lifecycle hooks.
- **Projection** (`lib/property_damage/model/projection.ex`) — State reducers. Required: `init/0`, `apply/2`. Assertion projections use `@trigger` attributes (`every: N`, `every: CommandModule`) for sync checks and `@poll_state` for eventual consistency checks.
- **Adapter** (`lib/property_damage/adapter.ex`) — Bridge to the SUT. Lifecycle: `setup/1` → `execute/2` × N → `teardown/1`. Execute returns `{:ok, [events]}` or `{:error, reason}`. Supports sub-adapters via `delegate_execution/1` macro.
- **Nemesis** (`lib/property_damage/nemesis.ex`) — Fault injection. Callbacks: `inject/2`, `restore/2`, `precondition/1`. 10 built-in implementations under `PropertyDamage.Nemesis.*`.

### Execution flow

1. **Symbolic phase**: Generate command sequence with symbolic refs (no SUT interaction). Model filters commands by `when:` predicates, selects by weight, generates via command generator + `with:` overrides.
2. **Concrete phase**: Execute against SUT via Adapter, resolving symbolic refs to real values. Events flow through projections. Assertions fire at configured trigger points.
3. **Shrinking**: On failure, two-phase shrink — sequence shrinking then argument simplification. Preserves failure equivalence (same type, same or earlier location).

### Key subsystems

- **Executor** (`lib/property_damage/executor.ex`) — Runs command sequences, handles branching (parallel) execution, ref resolution, projection updates.
- **Shrinker** (`lib/property_damage/shrinker.ex`) — Hierarchical and linear shrinking strategies. Deterministic given seed.
- **External / Placeholder** (`lib/property_damage/external.ex`, `lib/property_damage/placeholder.ex`) — Symbolic value system for server-generated data. `external()` (public) marks an event field the SUT mints; internally each such field becomes a `%PropertyDamage.Placeholder{}` that is created during simulation, resolved from real SUT events, and threaded into later commands.
- **Settle** (`lib/property_damage/settle.ex`) — Retry logic for eventually consistent systems. Commands declare `:async` or `:probe` semantics.
- **Export** (`lib/property_damage/export/`) — Generate ExUnit tests, scripts (curl/Python/Elixir), Livebook notebooks from failures.

### Test support

Test support modules live in `test/support/` and are compiled during test via `elixirc_paths(:test)` in mix.exs. Key files: `test_commands.ex`, `test_model.ex`, `test_projections.ex`, `test_adapter.ex`.

## Specs and documentation

- **OpenSpec** (`openspec/`) — Behavioral specifications across 14 domains (command, model, projection, execution-engine, shrinking, etc.) under `openspec/specs/`. Requirements use RFC 2119 keywords (SHALL, MUST, SHOULD, MAY) with Given/When/Then scenarios, and reference Decision Records (DR-001 through DR-020). Conventions are in `openspec/config.yaml`. When changing observable behavior, check whether the affected domain spec needs updating.
- **Guides** (`guides/`) — User-facing guides wired into ex_doc via the `extras` in mix.exs. New features or behavior changes often need a corresponding guide update.

## Dependencies

- `stream_data` — Property-based data generation
- `telemetry` — Instrumentation
- `nimble_options` — Option validation
- `jason` — JSON encoding (required dependency)
