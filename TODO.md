# PropertyDamage TODO

Remaining features and improvements for PropertyDamage.

## Interactive Debugger

Step-through execution and debugging tools for analyzing test failures.

**Features:**
- **Command Stepper**: Navigate through command execution step-by-step, viewing state before/after each command
- **What-If Analysis**: Modify a command in a failing sequence and see how outcomes change
- **Invariant Tester**: Test a specific invariant against current state without running full sequence
- **Ref Graph Visualization**: Visual graph showing entity relationships and dependencies
- **Shrink Debugger**: Step through shrinking process to understand why a sequence can't shrink further
- **Watch Expressions**: Monitor specific state paths/values as execution progresses
- **Breakpoints**: Pause execution when specific conditions are met (command type, state predicate, event pattern)

**Implementation:**
- `PropertyDamage.Debugger` module with interactive REPL
- Integration with Livebook for visual debugging
- State snapshots at each step
- Diff visualization between steps

---

## OpenAPI Scaffolding

Improve `mix pd.scaffold` to generate complete models and adapters from OpenAPI specifications.

**Features:**
- Parse OpenAPI 3.0/3.1 specs (JSON and YAML)
- Generate command modules from endpoint definitions
- Generate event structs from response schemas
- Generate adapter with HTTP client code
- Generate basic model with command weights
- Support for authentication schemes
- Handle path parameters, query parameters, request bodies
- Generate generators for request body fields based on schema types

**Implementation:**
- Enhance `lib/mix/tasks/pd.scaffold.ex`
- Add OpenAPI parser (leverage existing libraries)
- Template system for generated code
- Configuration for customizing output

---

## Performance Optimization

Speed improvements for test execution and shrinking.

**Features:**
- **Parallel Execution**: Run multiple test sequences concurrently
- **Shrinking Cache**: Cache shrink attempt results to avoid redundant checks
- **Lazy Event Generation**: Defer event creation until needed
- **Command Pool**: Pre-generate command candidates for faster selection
- **Incremental State**: Only recompute changed projections
- **Early Termination**: Stop checks as soon as first failure found
- **Memory Optimization**: Stream large sequences instead of holding in memory

**Implementation:**
- Benchmark suite for measuring improvements
- Configurable parallelism levels
- Profile-guided optimization
- Optional compilation of hot paths

---

## CI/CD Regression Runner

Dedicated tooling for running regression tests in continuous integration pipelines.

**Features:**
- **Automatic Discovery**: Find all seed libraries and failure files in project
- **Smart Parallelization**: Distribute seeds across CI workers
- **Flaky Detection**: Track seeds that intermittently pass/fail
- **Failure Aggregation**: Group similar failures in CI reports
- **GitHub Actions Integration**: Pre-built action for easy setup
- **JUnit/TAP Output**: Standard formats for CI systems
- **Bisect Support**: Find which commit introduced a regression
- **Caching**: Cache successful seeds to speed up subsequent runs

**Implementation:**
- `mix pd.ci` task for CI environments
- Configuration via `propertydamage.ci.exs` or environment variables
- Integration with common CI systems (GitHub Actions, GitLab CI, CircleCI)
- Slack/email notifications for failures

---

## Oracle-Based Testing

Native support for comparing SUT against a trusted reference implementation (oracle).

**Concept:**
- An "oracle" is a trusted reference implementation that defines correct behavior
- Run the same commands against both SUT and oracle, compare results
- Failures occur when SUT diverges from oracle behavior

**Use Cases:**
- Testing new implementation against legacy system
- Validating optimized version against slow-but-correct reference
- Comparing across language implementations (e.g., Elixir port vs original Python)
- Database migration validation (old schema vs new schema)
- Verifying refactored code matches original behavior

**Features:**
- **Dual Adapter Execution**: Run commands through both oracle and SUT adapters
- **Result Comparison Strategies**:
  - Exact match (byte-for-byte identical)
  - Semantic equivalence (logically equivalent, different representation)
  - Subset matching (SUT returns at least what oracle returns)
  - Custom comparators for domain-specific equivalence
- **Divergence Reporting**: Clear output showing where and how results differ
- **Timing Tolerance**: Handle speed differences between oracle and SUT
- **Selective Comparison**: Compare only specific fields/events

**Implementation:**
- `PropertyDamage.Oracle` module
- Oracle adapter configuration in model
- `oracle_adapter` option for `PropertyDamage.run/1`
- Comparison functions: `Oracle.compare/3`, `Oracle.equivalent?/3`
- Divergence report generation

**API Design:**
```elixir
PropertyDamage.run(
  model: MyModel,
  adapter: MyNewAdapter,           # SUT
  oracle_adapter: MyLegacyAdapter, # Oracle (reference)
  oracle_config: %{base_url: "http://legacy:4000"},
  comparison: :semantic,           # or :exact, :subset, &custom/2
  on_divergence: :fail             # or :warn, :record
)
```

**Ergonomics:**
- Single command definition works against both oracle and SUT
- Clear failure output: "Oracle returned X, SUT returned Y"
- Optional oracle (fall back to model-only validation when not provided)

---

## Polish & Release Prep

Final preparation for v1.0 release to Hex.pm.

**Tasks:**
- [ ] Review and update all module documentation
- [ ] Ensure all public functions have @doc and @spec
- [ ] Add usage examples to key modules
- [ ] Review CHANGELOG.md for completeness
- [ ] Update README.md with final feature list
- [ ] Add LICENSE file
- [ ] Configure hex.pm package metadata
- [ ] Set up CI for automated testing
- [ ] Create GitHub release with release notes
- [ ] Publish to hex.pm
- [ ] Announce on Elixir Forum/social media

**Documentation:**
- API reference completeness check
- Tutorial/guide review
- Example projects verification
- Livebook notebook testing

---

## Completed Features

For reference, these features have been implemented:

- [x] Core framework (commands, events, projections, models, adapters)
- [x] Shrinking & Analysis
- [x] Failure management (persistence, seed library, regression)
- [x] Coverage (command, transition, state class)
- [x] Flakiness detection
- [x] Load testing
- [x] Export (ExUnit, scripts, Livebook)
- [x] Mutation testing
- [x] Property & Invariant suggestions
- [x] Failure intelligence (fingerprinting, similarity, clustering)
- [x] Chaos engineering (Nemesis with 10 operations)
- [x] Telemetry & Livebook integration
- [x] Model validation
- [x] Integration testing framework
- [x] Documentation (guides, CHANGELOG, ExDoc config)
