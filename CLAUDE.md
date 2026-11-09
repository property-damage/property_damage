# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

PropertyDamage is a stateful property-based testing (SPBT) framework for Elixir. It generates random sequences of operations against a System Under Test, verifies invariants hold throughout, and automatically shrinks failures to minimal reproductions.

## Repository scope

This is the PropertyDamage framework library, and it is public. Keep it framework-only: application, demo, example, and consumer code that merely *uses* PropertyDamage (including in tests, fixtures, and docs) belongs in a separate consumer project, not in this repo. Anything committed here is permanently public through merged-PR history even if later deleted from `main`, so confirm a change is framework scope before opening a PR.

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

### Four core behaviours

All user-facing contracts are defined as behaviours:

- **Command** (`lib/property_damage/command.ex`) — Pure generator interface. Defines `generator/1` returning `StreamData.t(map())`. Commands are stateless semantic definitions; state-dependent logic (preconditions, overrides) belongs in the Model.
- **Model** (`lib/property_damage/model.ex`) — Orchestrates which commands run and when. Required: `commands/0` (list of command specs with optional `weight:`, `when:`, `overrides:` options) and `command_sequence_projection/0`. Optional: `check_projections/0`, `simulator/0`, lifecycle hooks.
- **Projection** (`lib/property_damage/model/projection.ex`) — State reducers. Required: `init/0`, `apply/2`. Check projections use `@check` attributes (`every: N`, `every: CommandModule`) for sync checks and `@eventually` for eventual consistency checks.
- **Adapter** (`lib/property_damage/adapter.ex`) — Bridge to the SUT. Lifecycle: `setup/1` → `execute/3` × N → `teardown/1`. Execute returns `{:ok, [events]}` or `{:error, reason}`. Supports sub-adapters via `delegate_execution/1` macro.

A **Target** (`lib/property_damage/target.ex`) is one system a run executes against: an adapter plus its configuration.

### Execution flow

1. **Symbolic phase**: Draw a command sequence from a seed, with `%PropertyDamage.Placeholder{}` values standing in for fields the SUT will mint (`external()`); no SUT interaction. Model filters commands by `when:` predicates, selects by weight, generates via command generator + `overrides:` values.
2. **Concrete phase**: `PropertyDamage.run/1` delegates to the campaign loop (`PropertyDamage.Campaign`, `lib/property_damage/campaign.ex`), which hands each sequence to the run driver, `Runner.execute/2` (`lib/property_damage/runner.ex`), which runs it through the Scheduler. The Scheduler runs one Variant process per target in lockstep. Each Variant executes commands through the Adapter, resolving placeholders to the real values from SUT events. Events flow through projections. Checks fire at their configured `every:` or `at:` points, and `@compare` observations are compared across targets after each root. Every kind of run takes this one path, trace capture and trigger isolation included: a property run against one system, a differential run (several systems compared on the same sequence), or a path-equivalence run (one system reached by two command paths, outcomes compared). A root is a top-level generated command; the comparison happens after each root.
3. **Shrinking**: On failure, the shrinker repeats a cycle of sequence shrinking (drop roots, collapse expansions; an expansion is a command that unfolds into child commands) then argument simplification. Preserves failure equivalence (same type, same or earlier location). The shrinker runs no candidate itself: it hands each one to an oracle (`Runner.shrink_oracle/2`), which runs it through `Runner.execute/2` and answers a `Shrinker.Outcome`.

### Key subsystems

- **Scheduler / Variant** (`lib/property_damage/scheduler.ex`, `lib/property_damage/variant.ex`): Runs one sequence on every target in lockstep, one Variant process per target, and compares observations at each boundary.
- **Executor** (`lib/property_damage/executor.ex`, `lib/property_damage/executor/stepping.ex`, `lib/property_damage/executor/step.ex`): Runs one command, with placeholder resolution, settle, projection updates and checks. `Executor.Stepping` is the public one-command-at-a-time seam that Variant and Replay use; it composes the step primitives of `Executor.Step`, the leaf module the other executor modules call and that calls none of them back.
- **Shrinker** (`lib/property_damage/shrinker.ex`): Hierarchical and linear shrinking strategies, judged by an oracle that runs each candidate. Deterministic given seed.
- **External / Placeholder** (`lib/property_damage/external.ex`, `lib/property_damage/placeholder.ex`) — Symbolic value system for server-generated data. `external()` (public) marks an event field the SUT mints; internally each such field becomes a `%PropertyDamage.Placeholder{}` that is created during simulation, resolved from real SUT events, and threaded into later commands.
- **Settle** (`lib/property_damage/settle.ex`) — Retry logic for eventually consistent systems. Commands declare `:async` or `:probe` semantics.
- **Export** (`lib/property_damage/export/`) — Generate ExUnit tests, scripts (curl/Python/Elixir), Livebook notebooks from failures.
- **RunTrace / RunComparison** (`lib/property_damage/run_trace.ex`, `lib/property_damage/run_comparison.ex`): `RunTrace` is the full record of one run; `RunComparison` localizes where passing and failing runs diverge.
- **Failure / FailureReport / Persistence** (`lib/property_damage/failure.ex`, `lib/property_damage/failure_report.ex`, `lib/property_damage/persistence.ex`): Failure record, the explained report built from it, and versioned save/load.

### Test support

Test support modules live in `test/support/` and are compiled during test via `elixirc_paths(:test)` in mix.exs. Key files: `test_commands.ex`, `test_model.ex`, `test_projections.ex`, `test_adapter.ex`.

## Verification gauntlet

Run before declaring any change done, and again before any merge:

1. `mix test`
2. `mix format --check-formatted` — root AND each touched bench under `benches/*`
   (the root formatter does not cover bench projects)
3. `mix credo --strict` (CI gates on it)

Never pipe a gating command (`cmd | tail` makes tail's exit code the gate).
Redirect long output to a file instead. Judge `gh pr checks` by its own exit code.

## Evidence standards

- A defect fix or behavior-change claim ships with a test proven RED against the
  pre-change code.
- Detection-shaped features (assertions, coverage, mutation, forensics) need a
  control proving the test can fail: a seeded bug, a removed invariant, or a
  non-reproduction control. Empty command lists and always-true assertions are
  vacuous fixtures, not evidence.
- Before trusting an untested module, grep for callers of its public entry points
  and drive its headline documented path end-to-end with non-trivial fixtures.

## Conventions

- Pre-v1: clean breaking changes over deprecations and shims.
- Persistence format changes bump the version; loaders refuse older versions.
- Consequential design choices get a Decision Record in `docs/decisions/`
  (keep the DR index current).
- Every guide snippet is executed before commit.

## Specs and documentation

- **OpenSpec** (`openspec/`) — Behavioral specifications across 13 domains (command, model, projection, execution-engine, shrinking, etc.) under `openspec/specs/`. Requirements use RFC 2119 keywords (SHALL, MUST, SHOULD, MAY) with Given/When/Then scenarios, and reference Decision Records in `docs/decisions/`. Conventions are in `openspec/config.yaml`. When changing observable behavior, check whether the affected domain spec needs updating.
- **Guides** (`guides/`) — User-facing guides wired into ex_doc via the `extras` in mix.exs. New features or behavior changes often need a corresponding guide update.

## Dependencies

- `stream_data` — Property-based data generation
- `telemetry` — Instrumentation
- `nimble_options` — Option validation
- `jason` — JSON encoding (required dependency)
