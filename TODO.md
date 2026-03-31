# PropertyDamage TODO

Remaining features and improvements for PropertyDamage.

## Re-Shrink with Larger Budget

Allow resuming shrinking from a previous result when the shrunk case is still too large.

**Features:**
- Re-trigger shrinking with more time/iterations from a previous best result
- Persistence/caching of command sequences (not just seeds)
- CLI/API for "resume shrinking from X with budget Y"

**Design questions:**
- How to reference a cached sequence? (hash? timestamp? user-provided name?)
- What format for persistence? (binary term, JSON, Elixir literal?)
- Store intermediate shrink states or just the best-so-far?

---

## Shrinking Configuration

Expand beyond boolean `@read_only` and `:prefer_remove`/`:neutral`/`:prefer_keep` to richer shrinking hints.

**Ideas:**
- Numeric priority/weight for finer-grained control
- User-provided shrinking strategy callback
- Domain-informed hints: "this command is more likely to trigger failures"

**Affects:**
- Shrinking algorithm must respect priorities/weights
- Documentation needs guidance on tuning for efficient shrinking

---

## Pluggable Data Generator

Allow alternatives to StreamData at the Model level.

**Features:**
- Generator interface abstraction (generate, shrink)
- Configurable at Model level, default to StreamData
- Graceful handling when alternative generator doesn't support shrinking

**Considerations:**
- PropCheck, custom generators, or external sources
- How shrinking interacts with non-StreamData generators

---

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
- [x] Differential testing (oracle testing, performance comparison, baselines)
- [x] OpenAPI scaffolding (full code generation from specs)
- [x] Documentation (guides, CHANGELOG, ExDoc config)
