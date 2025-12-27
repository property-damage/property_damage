# Changelog

All notable changes to PropertyDamage will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2024-12-27

### Added

#### Core Framework
- Stateful property-based testing with commands, events, and projections
- Two-phase execution (symbolic and concrete)
- Symbolic references for entity IDs
- Automatic shrinking of failing sequences
- Seed-based reproducibility

#### Command System
- `PropertyDamage.Command` behaviour for defining operations
- Two-layer generator architecture (`generator/1` and `new!/2`)
- Command preconditions for state-aware generation
- Ref extraction for entity relationships

#### Projections
- `PropertyDamage.Projection` behaviour for state tracking
- State projections for model state
- Assertion projections for invariant checking
- Configurable check triggers (`:always`, `:end_of_sequence`)
- Sampling support for expensive checks

#### Model System
- `PropertyDamage.Model` behaviour for test configuration
- Weighted command selection
- Lifecycle hooks (`setup_each/1`, `teardown_each/1`)

#### Adapter System
- `PropertyDamage.Adapter` behaviour for SUT integration
- Setup and teardown lifecycle
- Context passing between executions

#### Parallel Execution
- Branching sequences for race condition testing
- Linearization checking for parallel results
- Parallel shrinking support

#### Shrinking
- Automatic sequence minimization
- Command removal strategies
- Value simplification
- Ref dependency analysis
- Exhaustive shrinking option

#### Analysis & Debugging
- Causal explanation of failures
- Trigger isolation
- Step-by-step replay
- State diff comparison
- Sequence diagrams (Mermaid, PlantUML, WebSequenceDiagrams)
- Diff-based trace comparison

#### Failure Management
- Failure persistence (save/load)
- Seed library for regression testing
- Automatic regression test management
- Failure fingerprinting and clustering
- Similar failure detection
- Fix verification

#### Coverage
- Command coverage metrics
- Transition coverage
- State class coverage
- Multiple output formats (terminal, markdown, JSON)

#### Flakiness Detection
- Non-deterministic behavior detection
- Pass rate analysis
- Likely cause identification

#### Load Testing
- SPBT-based load generation
- Configurable ramp strategies (linear, step, spike, wave)
- Real-time metrics collection
- Report generation

#### Export
- ExUnit test generation
- Script generation (curl, Elixir, Python)
- Livebook notebook generation
- Markdown reports

#### Mutation Testing
- Adapter response mutation
- Multiple operators (value, omission, status, event, boundary)
- Mutation score calculation
- Weakness analysis
- Actionable suggestions

#### Property & Invariant Suggestions
- Model analysis for missing checks
- Pattern detection
- Priority-based recommendations

#### Failure Intelligence
- Pattern detection across failures
- Similarity scoring
- Fix verification with seed variations

#### Chaos Engineering (Nemesis)
- `PropertyDamage.Nemesis` behaviour for fault injection
- Network operations:
  - `NetworkLatency` - Add latency with jitter
  - `NetworkPartition` - Full/asymmetric partitions
  - `PacketLoss` - Simulate packet loss
- Resource operations:
  - `MemoryPressure` - Memory allocation stress
  - `CPUStress` - Scheduler stress
  - `ResourceExhaustion` - File descriptors, ports, ETS, processes
- Time operations:
  - `ClockSkew` - Clock drift and jumps
- Process operations:
  - `ProcessKill` - Kill by name, pattern, supervisor
  - `SlowIO` - Artificial I/O delay
- Security operations:
  - `CertificateExpiry` - TLS certificate failures
- Auto-restore support
- Toxiproxy integration

#### Telemetry
- Comprehensive telemetry events
- Event collector for dashboards
- HTML dashboard rendering

#### Livebook Integration
- Interactive visualization dashboard
- Results tables and command statistics
- Charts (bar, histogram, pie, heatmap, timeline)
- Live monitoring
- Command stepper
- Failure exploration

#### OpenAPI Scaffolding
- Generate command modules from OpenAPI specs

### Documentation
- Comprehensive README with all features
- Example projects (Counter, ToyBank, TravelBooking)
- User guides:
  - Getting Started
  - Writing Effective Invariants
  - Debugging Failures
  - Chaos Engineering with Nemesis
- Interactive Livebook demo notebook
- ExDoc configuration with module groups

[Unreleased]: https://github.com/example/property_damage/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/example/property_damage/releases/tag/v0.1.0
