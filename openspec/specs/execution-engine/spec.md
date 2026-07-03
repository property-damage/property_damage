# Execution Engine Specification

## Purpose

Defines the two-phase execution model, adapter lifecycle, external field markers and placeholder resolution, event injection, and mock service support that together form the core runtime of the PropertyDamage SPBT framework.

Reference DRs: DR-011 (External Field Markers), DR-021 (Placeholder Resolution Identity), DR-015 (Adapter Separation), DR-016 (Injector Pattern), DR-018 (Resource Polling), DR-024 (Lifecycle-Boundary Assertions), DR-025 (Continuous Async-Observation Checking), DR-026 (Invariant Catalog and Anti-Vacuity Coverage), DR-029 (Executor Internal Stage Architecture), DR-030 (Command-Correlated Injector Events). DR-010 (Symbolic References) is superseded.

## Requirements

### Requirement: Two-Phase Execution

The system SHALL execute command sequences in two distinct phases: a symbolic generation phase that produces command sequences without contacting the SUT, followed by a concrete execution phase that runs commands against the SUT and resolves placeholder values to real ones.

#### Scenario: Symbolic phase generates commands without SUT interaction
- **WHEN** the framework generates a command sequence
- **THEN** all commands SHALL contain placeholders for server-generated values
- **AND** no adapter calls SHALL be made during generation

#### Scenario: Concrete phase executes commands and resolves values
- **WHEN** the framework transitions to the concrete execution phase
- **THEN** each command SHALL be executed against the SUT via the adapter
- **AND** placeholders SHALL be replaced with concrete values captured from the SUT's events

### Requirement: Adapter Lifecycle

The adapter SHALL follow a strict setup/execute/teardown lifecycle: `setup/1` is called once to establish context, `execute/3` is called for each command in the sequence, and `teardown/1` is called once for cleanup. `teardown/1` receives the `setup/1` return exactly (the `user_context`). Lifecycle-boundary assertions (DR-024) are evaluated at the edges of this lifecycle: `@trigger at: :startup` assertions after `setup/1` and before the first command, and `@trigger at: :teardown` assertions on the settled state before `teardown/1`.

#### Scenario: Normal adapter lifecycle
- **WHEN** a command sequence is executed
- **THEN** the framework SHALL call `setup/1` exactly once before any command execution
- **AND** the framework SHALL call `execute/3` once per command in sequence order
- **AND** the framework SHALL call `teardown/1` exactly once after all commands complete

#### Scenario: Teardown on failure
- **WHEN** a command execution fails mid-sequence
- **THEN** the framework SHALL still call `teardown/1` for cleanup
- **AND** the framework SHALL log a warning if teardown itself raises an error

#### Scenario: Shrink attempts repeat the full lifecycle
- **WHEN** the shrinker re-executes a candidate sequence
- **THEN** the framework SHALL run the full setup/execute/teardown lifecycle for each shrink attempt

#### Scenario: Startup assertions gate the initial state
- **WHEN** a projection declares an `@trigger at: :startup` assertion
- **THEN** the framework SHALL evaluate it on the initial `init/0` state after `setup/1` and before the first `execute/3`
- **AND** a failing startup assertion SHALL halt the run before any command is executed

#### Scenario: Teardown assertions evaluate the settled state
- **WHEN** a run completes cleanly and a projection declares an `@trigger at: :teardown` assertion
- **THEN** the framework SHALL evaluate it once on the merged final projection state after both state pollers and resource pollers have finalized
- **AND** it SHALL be evaluated before `teardown/1` is called
- **AND** `teardown/1` SHALL still be called regardless of the assertion's verdict

#### Scenario: Teardown assertions do not run on early abort
- **WHEN** a run aborts before reaching the settled state (for example an adapter error, a synchronous `@trigger` failure, or a reference-resolution error)
- **THEN** `@trigger at: :teardown` assertions SHALL NOT be evaluated
- **AND** the framework SHALL report the proximate failure rather than a settled-state assertion result

### Requirement: Finalize-Chain Ordering and Precedence (DR-029)

After the last command of a run (linear or merged-branch), the framework SHALL finalize the run through a fixed chain of stages in this order: finalize `@poll_state` pollers (draining the event queue and evaluating async checks during the await window), finalize resource pollers, drain the settled-state event queue (evaluating async checks on the folded events), then evaluate the `@trigger at: :teardown` checkpoint on the settled state. When more than one failure is live at finalize time, the framework SHALL report exactly one, by this precedence (highest first): an async `@trigger every:` violation observed during the `@poll_state` await drain, then a `@poll_state` poll timeout/error, then an async `@trigger every:` violation observed during the settled-state drain, then a resource-poller error, then a failing `@trigger at: :teardown` checkpoint. The two async violations SHALL carry the observing event's `command_index` as the reported failure index. This ordering is an internal invariant (no observable-behavior change); it is owned by `PropertyDamage.Executor.Finalization` and locked by dedicated ordering-guard tests so the chain cannot be silently reordered.

#### Scenario: An async drain violation preempts a concurrent poll timeout
- **WHEN** an async `@trigger every:` assertion trips on an event folded during the `@poll_state` await drain while a `@poll_state` poller is also timing out
- **THEN** the framework SHALL report the async assertion violation, at the observing event's `command_index`, rather than the poll timeout

#### Scenario: A settled-state drain violation preempts a resource-poller error
- **WHEN** an async `@trigger every:` assertion trips on an event folded during the settled-state drain while a resource poller has also errored
- **THEN** the framework SHALL report the async assertion violation, at the observing event's `command_index`, rather than the resource-poller error

### Requirement: Explicit Stutter RNG and Determinism (DR-029)

Stutter (idempotency-retry) decisions SHALL be driven by an explicit RNG threaded through the executor, NOT by the process-global `:rand` stream. For each command the framework SHALL derive a fresh generator state from the run's seed and the command's index, so a command's stutter decisions (whether to stutter, how many retries, and inter-retry delays) depend only on the run seed and that command's index, not on draws consumed by earlier commands or earlier runs in the campaign. The run seed used as the RNG base SHALL be the run's effective seed (the same value reported for reproduction), so re-running with the same campaign seed reproduces the same stutter decisions. Sequence generation determinism is unaffected: it is seeded separately via the generator's per-run seed.

This determinism is self-consistent (same seed produces the same decisions) and preserves shrink failure-equivalence (DR-017). It is NOT a guarantee of byte-identical reproduction of any prior process-global `:rand` stream.

Because stutter decisions are reproducible, stutter failures (idempotency violations and stutter-retry execution failures) SHALL be shrinkable. The shrinker SHALL reproduce a stutter failure with stutter forced on (probability 1.0, preserving the original command filter, comparison mode, and max-repeats) so that index-shift under sequence truncation cannot un-stutter the offending command, and SHALL minimize the failure to its smallest reproduction. Forced-stutter reproduction SHALL apply only when the original failure is a stutter failure; for all other failure types the shrinker SHALL re-run without stutter.

#### Scenario: Same seed reproduces the same stutter outcome
- **WHEN** a sequence is run twice with the same run seed and stutter enabled
- **THEN** the stutter decisions, event log, and result SHALL be identical

#### Scenario: A stutter idempotency violation shrinks to its minimal reproduction
- **WHEN** a run fails with an idempotency violation caused by a single non-idempotent command embedded in a longer sequence
- **THEN** the shrinker SHALL reproduce the violation with stutter forced on and minimize the sequence to the offending command

#### Scenario: Non-stutter shrinking is not perturbed by stutter
- **WHEN** a run fails for a non-stutter reason (for example a `@trigger` assertion)
- **THEN** the shrinker SHALL re-run candidates without stutter, exactly as for a run with stutter disabled

### Requirement: Adapter Execute Arguments (user_context and runtime)

`execute/3` SHALL receive three arguments: the resolved command, the `user_context`, and a `%PropertyDamage.Runtime{}` handle (DR-027). The `user_context` SHALL be exactly what the adapter's `setup/1` returned, with no framework keys merged in. The framework's per-command affordances SHALL travel on the runtime handle: an `inject` function for mid-execution event injection, a `start_poller` function for background resource polling, and a `stutter` field that is populated only on stutter/idempotency retries (and `nil` on the first execution).

#### Scenario: user_context is exactly the setup return
- **WHEN** the adapter receives its arguments in `execute/3`
- **THEN** the second argument SHALL equal the value returned by `setup/1`
- **AND** it SHALL NOT contain framework keys such as `:inject`, `:start_poller`, or `:stutter`

#### Scenario: Inject available on the runtime
- **WHEN** the adapter receives the runtime in `execute/3`
- **THEN** `runtime.inject` SHALL be a callable 1-arity function
- **AND** calling it with an event struct SHALL immediately update projections

#### Scenario: Start poller available on the runtime
- **WHEN** the adapter receives the runtime in `execute/3`
- **THEN** `runtime.start_poller` SHALL be a callable 1-arity function
- **AND** calling it with poller options SHALL spawn a background resource poller

#### Scenario: Stutter populated on retries only
- **WHEN** stutter testing is enabled and a command is retried
- **THEN** `runtime.stutter` SHALL be a map with attempt number, is_retry flag, and idempotency key, and `PropertyDamage.Runtime.stuttering?/1` SHALL return `true`
- **AND** on the first execution (attempt 1) `runtime.stutter` SHALL be `nil` and `stuttering?/1` SHALL return `false`

### Requirement: Injector Adapter for External Events

The system SHALL support injector adapters that receive events from external sources (webhooks, callbacks, message queues) and push them to a shared event queue for the executor to process.

#### Scenario: Injector adapter lifecycle
- **WHEN** injector adapters are configured
- **THEN** each injector adapter SHALL have its `setup/1` called to start listening
- **AND** incoming payloads SHALL be transformed via `to_event/1` and pushed to the event queue
- **AND** `teardown/1` SHALL be called to stop listening after the run completes

#### Scenario: Emits declaration for validation
- **WHEN** an injector adapter declares event types via `@emits`
- **THEN** the framework SHALL validate that the model's injectable events cover all declared types

### Requirement: Command Delegation to Sub-Adapters

The system SHALL support a delegation macro that routes specific command types to dedicated sub-adapter modules, enabling modular organization of complex adapters.

#### Scenario: Delegated command execution
- **WHEN** an adapter defines `delegate_execution for: [CommandA, CommandB], to: SubAdapter`
- **THEN** executing `CommandA` or `CommandB` SHALL invoke `SubAdapter.execute/3`
- **AND** the sub-adapter SHALL receive the same `user_context` and `runtime` as the parent adapter

#### Scenario: Multiple delegation targets
- **WHEN** an adapter delegates different commands to different sub-adapters
- **THEN** each command SHALL be routed to the correct sub-adapter based on its type

### Requirement: External Field Markers

The system SHALL support `external()` markers in event struct definitions to identify fields whose values are generated by the SUT. External fields SHALL be automatically detected, captured from the producing command's events during concrete execution, and used to resolve placeholders held by downstream commands.

#### Scenario: Single external field
- **WHEN** an event struct defines a field with `external()` as its default value
- **THEN** the framework SHALL recognize that field as server-generated
- **AND** the concrete value SHALL be captured from the adapter's returned (or injected) event

#### Scenario: Multiple and nested external fields
- **WHEN** an event struct defines multiple external fields or external fields nested in maps
- **THEN** all external field paths SHALL be tracked (e.g., `[:ids, :transaction]`)
- **AND** each SHALL be resolved independently during execution

#### Scenario: Downstream resolution
- **WHEN** a later command field holds a placeholder for an external value produced earlier
- **THEN** the framework SHALL replace the placeholder with the captured concrete value before executing that command
- **AND** if the placeholder has not been resolved (its producer has not run), execution SHALL fail

#### Scenario: Placeholder identity
- **WHEN** placeholders are compared
- **THEN** identity SHALL be determined by the placeholder's stable id, not by display labels

### Requirement: Shared Event Queue

The system SHALL provide a shared event queue where injector adapters push incoming events. The executor SHALL drain pending events from the queue after each command execution.

#### Scenario: Event queue lifecycle
- **WHEN** a test run begins
- **THEN** the framework SHALL start an event queue
- **AND** injector adapters SHALL receive the queue reference for pushing events
- **AND** the framework SHALL stop the queue after the run completes

#### Scenario: Draining after each command
- **WHEN** a command finishes executing
- **THEN** the executor SHALL drain all pending events from the queue
- **AND** drained events SHALL be processed through projections
- **AND** drained events SHALL be evaluated against `@trigger every:` assertions (DR-025)
- **AND** each entry SHALL record the source adapter module and timestamp

#### Scenario: Correlated injector events attributed to their command (DR-030)
- **WHEN** a drained injector event satisfies the `match` predicate of a command's registered `awaits/2` declaration
- **THEN** the entry's `command_index` SHALL be the declaring command's index, rather than the ambient `nil`
- **AND** when several commands' matchers accept the same event, the first-registered command SHALL win and the framework SHALL log an overlap diagnostic
- **AND** an injector event matching no registered await SHALL fold with `command_index: nil` as before

### Requirement: Mock Service Adapter

The system SHALL support mock service adapters that stand in for third-party services the SUT calls, allowing the SUT to reach controlled mock endpoints instead of real services. Mock adapters SHALL maintain state, respond to SUT requests, and optionally inject events. Mock services SHALL be reachable through the public `PropertyDamage.run/1` API via the `mock_services:` option, which accepts a list of mock adapter modules or `{module, config}` tuples.

#### Scenario: Framework owns the per-run mock lifecycle
- **WHEN** a run declares `mock_services:`
- **THEN** the framework SHALL start a mock service registry for the run, register each declared mock (initializing its state), and call each mock's `setup/1` with the entry's config merged with the framework channels (`:registry` and `:event_queue`)
- **AND** the framework SHALL call each mock's `teardown/1` and stop the registry at the end of the run
- **AND** the same registry SHALL be reused across a failure's shrink attempts and the reproduction re-execution, so a mock-dependent failure keeps reproducing as it minimizes

#### Scenario: Mock service intercepts SUT calls
- **WHEN** a mock service is configured and the SUT (or its adapter stand-in) makes an outbound call
- **THEN** the caller SHALL reach the mock through the registry handed to the adapter on the runtime handle (`runtime.mock_registry`), driving the mock's `handle_request/2`
- **AND** the mock SHALL return controlled responses based on its current state

#### Scenario: Mock state evolves with commands
- **WHEN** a command configures mock behavior (e.g., switch from success to decline)
- **THEN** the framework SHALL call each mock's `on_command/2` before the command executes
- **AND** the mock's internal state SHALL update so subsequent SUT requests reflect the new behavior

#### Scenario: Mock injects events
- **WHEN** the SUT calls the mock and events are pushed into the registry
- **THEN** after the command the framework SHALL flush those events, fold them into projection state (recording them with `source: :mock`), and notify each mock via `on_event/2`

### Requirement: Assertions on Asynchronously-Observed Events

The executor SHALL evaluate `@trigger every:` assertions on every observed event, including events observed asynchronously rather than returned by a command (DR-025): resource-poller and injector-adapter events drained from the shared event queue, mock-service events, and nemesis events, as well as events folded during the finalize-time drains (the `@poll_state` await drain and the settled-state drain). Each asynchronously-observed event SHALL be folded into projection state and then evaluated against the synchronous-assertion dispatch **incrementally** — one event at a time, on the state produced by folding that event — with the per-event counters (`:step`, `:event`, and the event module) advancing as for a command's own event. Assertion mode (DR-014) SHALL be honored, including halting mid-drain under `:halt`.

#### Scenario: Assertion fires on a poller-observed event
- **WHEN** a resource poller injects an event that matches an `@trigger every:` assertion
- **THEN** the executor SHALL evaluate that assertion on the projection state after the event is folded in
- **AND** the per-event counters SHALL advance as for a command's own event

#### Scenario: Violation reported at the observing event
- **WHEN** an `@trigger every:` assertion fails on an asynchronously-observed event
- **THEN** the failure SHALL be reported as a named assertion failure located at that event's `command_index`
- **AND** it SHALL be distinct from an `@trigger at: :teardown` settled-state failure (which has no position) and from a `@poll_state` poll timeout

#### Scenario: Halt mode stops mid-drain
- **WHEN** assertion mode is `:halt` and an `@trigger every:` assertion fails while draining asynchronously-observed events
- **THEN** the executor SHALL stop draining and fail the run at the offending event
- **AND** subsequent queued events SHALL NOT be folded or asserted

#### Scenario: Finalize-time drains are checked
- **WHEN** events are folded during the finalize-time drains (the `@poll_state` await drain or the settled-state drain)
- **THEN** those events SHALL be evaluated against `@trigger every:` assertions, and a violation SHALL surface as a run failure rather than being folded silently

### Requirement: Per-Assertion Firing and Whole-Run Coverage Accumulation (DR-026)

The executor SHALL record how many times each assertion actually fired during a run, keyed by its owning projection and name. An assertion counts as fired whenever its function is invoked, regardless of whether it passes or fails, at every evaluation site: synchronous dispatch on commands and observed events (including the asynchronous paths of DR-025), lifecycle `at:` boundaries (DR-024), and `@poll_state` poller spawn. Per-assertion firing counts SHALL merge across parallel branches the same way the existing assertion counters do. Firing counts SHALL be accumulated across all generated sequences of the run and attached to the result as `result.assertion_fires`.

#### Scenario: Firing recorded at every evaluation site
- **WHEN** an assertion is evaluated via `every:`, an `at:` boundary, an asynchronously-observed event, or a spawned `@poll_state` poller
- **THEN** the executor SHALL increment that assertion's firing count, regardless of pass or fail

#### Scenario: Poller spawn counts as firing
- **WHEN** a `@poll_state` poller is spawned because a matching `after:` event was observed
- **THEN** the executor SHALL count the assertion as having fired, even if the poller later times out or remains pending at shutdown

#### Scenario: Firing accumulates across the whole run
- **WHEN** a run executes multiple generated sequences
- **THEN** `result.assertion_fires` SHALL reflect firing counts summed across all sequences, not a single representative sequence

#### Scenario: Per-assertion firing merges across branches
- **WHEN** execution branches in parallel and assertions fire in different branches
- **THEN** the per-assertion firing counts SHALL merge by the same delta-from-prefix rule as the existing assertion counters

### Requirement: Pre-Run Validation

The system SHALL verify model and adapter configuration before beginning execution, detecting misconfigurations early rather than at runtime.

#### Scenario: Validation catches missing configuration
- **WHEN** the model or adapter is misconfigured (e.g., missing required projections or undeclared commands)
- **THEN** the framework SHALL report validation errors before any commands execute

#### Scenario: Validation passes for correct configuration
- **WHEN** the model and adapter are correctly configured
- **THEN** validation SHALL succeed and execution SHALL proceed

### Requirement: Seed Library Replay Phase

When the `seed_library:` option is enabled and the library is non-empty, the system SHALL run a replay phase before random exploration, as a sibling of the random run loop inside the same run lifecycle (DR-023). The phase SHALL reuse the existing per-sequence machinery (`setup_each` → executor → `teardown_each`, event queue, injectors) under the single `setup_once`/teardown the run already owns, and SHALL NOT invoke `PropertyDamage.run/1` recursively.

#### Scenario: Replay precedes exploration
- **WHEN** the seed library is enabled and non-empty
- **THEN** the system SHALL replay each stored seed once (most-recently-discovered first) before generating any random sequence
- **AND** each replayed seed SHALL be regenerated by run-0 derivation (the stored seed reproduces its original sequence while generators are byte-stable)

#### Scenario: Replays do not consume the exploration budget
- **WHEN** seeds are replayed
- **THEN** the replays SHALL NOT count against `max_runs`, which remains the exploration budget

#### Scenario: Halt on a still-failing replay
- **WHEN** any replayed seed still fails
- **THEN** the system SHALL replay all seeds first (so every streak updates and pruning happens), then skip random exploration and return `{:error, failure}` for a representative still-failing seed
- **AND** that representative report SHALL be produced by shrinking the failing run to a minimal `FailureReport`, consistent with the normal failure contract

#### Scenario: Proceed when all replays pass
- **WHEN** every replayed seed passes
- **THEN** random exploration SHALL proceed normally
- **AND** an explicit `seed:` SHALL still get its exploration run after the replay phase

### Requirement: Adapter Timeout (DR-032)

Each `adapter.execute/3` call SHALL be subject to a configurable per-command wall-clock timeout, in an ordinary core `Executor` run as well as in load-test workers. The default timeout SHALL be 30 seconds. Adapters MAY override the timeout per command type (an integer of seconds, or a `{n, unit}` tuple). Because enforcing a hard timeout requires a separately-killable process, the framework SHALL run `execute/3` in a child process; the `$callers` chain SHALL be propagated so connection-ownership mechanisms (e.g. Ecto `SQL.Sandbox`, Mox) resolve from that child.

#### Scenario: A wedged command times out instead of hanging
- **WHEN** an `execute/3` call exceeds the command's timeout in a core run
- **THEN** the framework SHALL stop waiting and surface a `CommandTimeoutError` through the adapter-error channel (so it flows through the failure report like any other adapter error)
- **AND** it SHALL NOT block the run indefinitely

#### Scenario: Default timeout applies
- **WHEN** an adapter does not override the timeout
- **THEN** each command execution SHALL time out after 30 seconds

#### Scenario: Per-command timeout override
- **WHEN** an adapter overrides the timeout for a specific command type
- **THEN** that command SHALL use the overridden timeout value
- **AND** the timeout MAY be specified as an integer (seconds) or a tuple with units (e.g., `{500, :milliseconds}`)

### Requirement: Reproducible Run Inputs (DR-034)

Every run SHALL be identified by a base `seed`, a `run_number`, and a `run_nonce`; every SUT execution within a logical run additionally carries a `mint_epoch`. The base seed and run number SHALL determine the generated plan: the effective seed is `Generator.run_seed(seed, run_number)`, and the plan is a pure function of that effective seed. The `run_nonce` SHALL be a 64-bit integer that is independent of plan generation and SHALL seed only the resolution of run-scoped minted values (DR-034, command domain). Each of `seed` and `run_nonce` SHALL be resolved as `explicit option || environment variable || random default`, reading `PD_SEED` and `PD_RUN_NONCE` respectively, mirroring how ExUnit selects and prints a random seed. The nonce's random default SHALL be drawn from entropy independent of the process RNG (e.g. `:crypto.strong_rand_bytes/1`), NEVER from `:rand`: ExUnit seeds each test process's `:rand` from the suite seed, so a process-RNG default would be silently pinned whenever a user reruns with `mix test --seed N`, re-minting colliding values against a non-resettable SUT — the exact failure the random default exists to prevent. The `mint_epoch` distinguishes SUT executions within one logical run: epoch 0 is the recorded exploration run; the shrinker SHALL assign a fresh epoch per shrink attempt; the report's reproduction execution and replays SHALL default to fresh epochs with an option to pin, so repeated executions do not re-send identical minted values to a non-resettable SUT. The chosen `seed`, `run_number`, `run_nonce`, and `mint_epoch` SHALL be recorded on the run's trace and report so the exact execution is reproducible. `mix test` SHALL NOT be required to forward a custom flag: ad-hoc reproduction SHALL be available through the environment variables, and programmatic reproduction through the persisted artifact.

#### Scenario: Random nonce by default, recorded, independent of the process RNG

- **WHEN** a run executes without an explicit `run_nonce` or `PD_RUN_NONCE`
- **THEN** the framework SHALL choose a random `run_nonce` from entropy independent of `:rand`
- **AND** SHALL record it on the trace/report so the run can be reproduced
- **AND** two invocations under the same `mix test --seed` SHALL still receive distinct nonces

#### Scenario: Pinned nonce and epoch reproduce minted values

- **WHEN** a run executes against a pristine SUT with a `run_nonce` and `mint_epoch` (option or `PD_RUN_NONCE`) equal to a prior run's recorded values
- **THEN** all run-scoped minted values SHALL be regenerated identically to that prior run

#### Scenario: Nonce is independent of the plan

- **WHEN** two runs share `seed` and `run_number` but differ in `run_nonce`
- **THEN** they SHALL execute the identical generated plan (equal plan fingerprints, DR-036)
- **AND** SHALL differ only in run-scoped minted values

#### Scenario: Shrink attempts do not collide on minted values

- **WHEN** the shrinker re-executes candidate sequences against a SUT that is not reset between attempts
- **THEN** each attempt SHALL carry a distinct `mint_epoch`, so minted values differ per attempt and cannot manufacture duplicate-identity failures that mask the real one

#### Scenario: Nonce is inert without run-scoped values

- **WHEN** a model declares no run-scoped minted fields
- **THEN** the `run_nonce` and `mint_epoch` SHALL have no effect on execution
- **AND** reproduction from `seed` and `run_number` alone SHALL be exact

### Requirement: Deterministic Symbolic Identity (DR-036)

Symbolic identity SHALL be deterministic so that two generations of the same plan are recognizably equal. A `%Placeholder{}` id SHALL be a pure function of its generation-time coordinates `(position, event_index, path)` rather than `make_ref/0`; run-scoped mint markers (DR-034) SHALL carry the same coordinate-derived identity. DR-021's split identity scheme is otherwise unchanged: consumers resolve by id, producers capture by structured position rebuilt per run. The framework SHALL expose a canonical plan fingerprint (`RunTrace.plan_fingerprint/1`, DR-033): a stable digest of the branch-structured command list with the derived `registry` excluded, and two plans SHALL be considered identical for comparison purposes (DR-035) exactly when their fingerprints are equal.

#### Scenario: Same plan generates equal

- **WHEN** the same plan is generated twice from the same effective seed
- **THEN** the two sequences SHALL be structurally equal, including all embedded placeholder and mint-marker identities
- **AND** their plan fingerprints SHALL be equal

#### Scenario: Fingerprint ignores the derived registry

- **WHEN** two same-plan sequences differ only in their derived `registry` state
- **THEN** their plan fingerprints SHALL be equal

#### Scenario: Cross-commit generator drift is detected

- **WHEN** traces are captured on two commits between which generators, command structs, or event structs changed such that the generated plan differs
- **THEN** their plan fingerprints SHALL differ, and run comparison SHALL refuse rather than misalign

### Requirement: Generation Determinism Audit (DR-037)

Generation SHALL be a pure function of `(seed, model, generation options)`, including user code: command generators, `when:`/`with:` predicates, the `command_sequence_projection`, and the simulator. All nondeterminism — the wall clock, `:rand`, `System.unique_integer/1`, client-minted identifiers, and environment — SHALL be reified at execution (adapter reification of a seeded relative offset, or `mint_per_run/1`, DR-034), never during generation. The framework SHALL provide an audit (`PropertyDamage.audit/2`, wrapped by `mix pd.audit`) that, for a deterministically chosen set of seeds, realizes a model's generated sequence twice at the same seed through the seeded path and asserts the two are structurally equal per the Deterministic Symbolic Identity requirement (DR-036); the audit SHALL be generation-only and SHALL NOT resolve mint markers or placeholders. On divergence the audit SHALL localize the first differing command position and its differing fields with actionable guidance, and `mix pd.audit` SHALL exit non-zero so CI gates on it. An impure model that fails this audit is exactly a model whose captured runs the run-comparison comparability guard (DR-035) will refuse.

#### Scenario: A pure model passes the audit

- **WHEN** `PropertyDamage.audit/2` runs against a model whose generation is a pure function of the seed, including one using `external/0` or `mint_per_run/1`
- **THEN** it SHALL return `:ok` for every audited seed, under both linear and branching generation options

#### Scenario: An impure generator is rejected

- **WHEN** a generator, `when:`/`with:` predicate, or projection reads process-varying state (the clock, `:rand`, `System.unique_integer/1`) so two same-seed generations differ
- **THEN** `PropertyDamage.audit/2` SHALL return `{:error, %{seed: seed, divergence: divergence}}` naming the first diverging seed and the first differing command position/fields
- **AND** `mix pd.audit` SHALL exit non-zero

#### Scenario: Time and client-minted values are reified at execution, not generation

- **WHEN** a model needs a timeliness-dependent value (a JWT `exp`) or a per-run-unique identifier
- **THEN** it SHALL carry a seeded relative offset (reified to absolute time in the adapter) or a `mint_per_run/1` marker in the plan, so the plan stays a pure function of the seed and the audit passes
