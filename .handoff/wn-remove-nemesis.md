# Handoff ledger: wn-remove-nemesis

Ownership handoff package for this branch. Two tiers, and the difference is the
whole point: **Record** is contemporaneous evidence, **Reconstruction** is
written afterwards. Never edit a past Record entry, and never let Reconstruction
contradict the Record.

## Contract

Source: the maintainer's ruling of 2026-11-06 that fault injection leaves the command engine as a clean break: no neutral landing pads (a `:fault` source or kind with nothing behind it), no requirements spec kept without an implementation. A replacement approach is out of scope.

Asked:

- Remove `PropertyDamage.Nemesis`, its three built-in modules, the Toxiproxy client, `PropertyDamage.Executor.Nemesis`, the generator's nemesis branch, the validation and model checks for nemesis modules, `Executor.State.active_faults`, the `nemesis_module` field of event-log entries, the `:nemesis_error` failure kind everywhere it was matched, and the `:nemesis` event source everywhere it was rendered.
- Bump the persistence format to `17`; refuse older files; accept no event source outside the engine's own list.
- Delete the chaos engineering guide and the fault-injection spec; correct every guide, the README, CLAUDE.md, the notebook, the spec index and the other specs; `mix docs --warnings-as-errors` stays at zero warnings.
- The Redis bench loses its Toxiproxy service, proxy adapter and fault-injection suites and runs against plain Redis in CI.
- A decision record supersedes DR-031 and DR-038 and annotates DR-029; CHANGELOG Unreleased carries a breaking Removed entry.
- Tests that used a nemesis only as a fixture keep their assertion on another fixture; only tests whose subject was nemesis behavior are deleted; the report lists kept, rewritten and deleted counts.

Acceptance criteria:

- `grep -rniE 'nemesis|toxiproxy' lib test guides README.md CLAUDE.md openspec benches notebooks priv mix.exs .github scripts` returns no hit; hits remain only in released CHANGELOG history and in decision records.
- A format-16 file is refused with the version error; a file written by the current code round-trips; a file whose event log names a source outside `EventLog.Entry.sources/0` is refused.
- Every tracked fixture under `benches/` and `test/` that carried format 16 is regenerated or deleted.
- The full local gate passes, including the two zero-infrastructure benches.

Non-goals: a replacement fault-injection design; the branching mode (another branch); `Persistence.list/1` on directories that mix loadable and unreadable files (pre-existing, filed).

## Sessions

Sessions that worked on this branch, with their transcripts. This is the
citation layer: it makes PR-time mining exact instead of a time-window guess.

- 2026-11-06T21:26 · `e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4` · `/home/work_bc/.claude/projects/-home-work-bc-dev-property-damage/e432b9d0-c4a9-401a-8e66-f9d0b4d30cf4.jsonl`

## Record

Append-only, contemporaneous, never edited after the fact.

### 2026-11-06T21:26 · commit · a11b971

test(persistence): pin format 17, refusal of format 16 and of unknown event sources

A saved file of an older format must be refused, and a current-format file
whose event log names a source the engine never produces must not load. Nothing
pinned either rule, so a version bump or a stray source could pass unnoticed.

Add tests for the format-16 refusal by load/1 and load_trace/1 (against a
committed format-16 fixture), the version-17 header and round trip, the refusal
of an unknown event source in a report, its reference trace and a standalone
trace, and the round trip of every source the engine produces. The tests are
checked in before the change they describe, so the refusal, header and
unknown-source tests fail until that change lands.

**Files:** `test/fixtures/persistence/format_16_report.pd`, `test/property_damage/persistence_format_version_test.exs`

### 2026-11-06T21:42 · commit · 7f98233

refactor!: remove Nemesis fault injection and the Toxiproxy client

Fault injection ran as commands, which broke the split between the model
(it decides what runs) and commands (pure generators). The generator had
to dispatch a second kind of command with its own callbacks, the executor
ran it on a separate path, and the failure and event-log vocabulary
carried a kind and a source for it. Fault injection will be approached
again outside the command engine; this change removes it and ships no
replacement.

Removed: the Nemesis behaviour, NetworkLatency, NetworkPartition,
PacketLoss, the Toxiproxy client, the executor stage and its
active_faults state, the generator branch and the validation checks for
fault-injection commands, Failure.nemesis_error/1 and the :nemesis_error
kind, and the :nemesis event source with the nemesis_module field.
Tests whose subject was fault injection are deleted; tests that used a
fault injector only as a fixture keep their assertions on a plain
command.

The persistence format becomes version 17: files of version 16 and older
are refused. The loader also refuses an event-log entry whose source is
not one the engine produces (EventLog.Entry.sources/0), with
{:error, {:unknown_event_source, source}}.

BREAKING CHANGE: the Nemesis behaviour, its three built-in modules, the
Toxiproxy client, the :nemesis_error failure kind and the :nemesis event
source are gone. Saved failure files of format 16 and older no longer
load.

**Files:** `guides/chaos_engineering.md`, `lib/mix/tasks/pd.validate.ex`, `lib/property_damage.ex`, `lib/property_damage/diagram.ex`, `lib/property_damage/error.ex`, `lib/property_damage/error_origin.ex`, `lib/property_damage/event_log/entry.ex`, `lib/property_damage/executor.ex`, `lib/property_damage/executor/branching.ex`, `lib/property_damage/executor/events.ex`, `lib/property_damage/executor/nemesis.ex`, `lib/property_damage/executor/state.ex` (+57 more)

### 2026-11-06T21:46 · commit · 0dad0a0

docs: drop fault injection from the guides, README and specs

The README, the guides, the cheatsheet, the demo notebook, CLAUDE.md and
the specs still described the Nemesis behaviour, its built-in modules and
the Toxiproxy client, which no longer exist. A reader following them would
write code that cannot compile or validate.

Delete the chaos engineering guide and the fault-injection spec. Remove
the fault-injection passages and cross-links from the other guides and
specs, and from the demo notebook (Part 5). CLAUDE.md now lists four core
behaviours (Command, Model, Projection, Adapter) and the Target. The
persistence spec records format 17 and the refusal of an unknown event
source.

**Files:** `CLAUDE.md`, `README.md`, `guides/cheatsheet.md`, `guides/debugging_failures.md`, `guides/differential_testing.md`, `guides/getting_started.md`, `guides/integration_testing.md`, `guides/load_testing.md`, `guides/log_lines.md`, `guides/mocking_third_parties.md`, `guides/quickstart.md`, `guides/writing_commands.md` (+10 more)

### 2026-11-06T21:49 · commit · c3fb745

docs(decisions): record the removal of fault injection

The Nemesis behaviour and its Toxiproxy client are gone, but nothing in
docs/decisions said why or what supersedes DR-031 and DR-038. Record the
decision: fault injection as commands broke the split between the model
and pure-generator commands, it will be approached again outside the
command engine, and no replacement ships in this version.

Mark DR-031 and DR-038 as superseded, note the removed stage in DR-029,
add the index rows, and list the removal in the Unreleased section of the
changelog (a Removed entry and the format 17 change).

**Files:** `CHANGELOG.md`, `docs/decisions/DR-029-executor-stage-architecture.md`, `docs/decisions/DR-031-nemesis-generation-dispatch.md`, `docs/decisions/DR-038-nemesis-toxiproxy-config-and-partition.md`, `docs/decisions/DR-062-remove-fault-injection.md`, `docs/decisions/README.md`

### 2026-11-06T21:50 · commit · 074ccd6

refactor(redis_bench)!: run the bench against plain Redis

The Redis bench carried a Toxiproxy stack: a proxy service, an HTTP
client for its control API, an adapter that connected through the proxy
and two suites that drove the removed fault-injection modules. With
those modules gone the stack tests nothing, and the proxy container
slows the setup for no benefit.

Remove the toxiproxy service from docker-compose.yml, the Toxiproxy
client, the proxy adapter, the fault-injection and nemesis-audit suites,
the proxy settings in config and RedisBench.Conn, the inets application
that served the HTTP client, and the README sections. The bench.db.up
and bench.db.down aliases stay and now start and stop Redis only. In CI
the bench_redis job drops the toxiproxy service, its readiness step and
the proxy environment variables.

BREAKING CHANGE: the bench no longer reads PD_TOXIPROXY_URL,
PD_REDIS_PROXY_HOST, PD_REDIS_PROXY_PORT, PD_REDIS_UPSTREAM or
PD_TOXIPROXY_PORT.

**Files:** `.github/workflows/ci.yml`, `benches/redis_bench/README.md`, `benches/redis_bench/config/config.exs`, `benches/redis_bench/docker-compose.yml`, `benches/redis_bench/lib/redis_bench.ex`, `benches/redis_bench/lib/redis_bench/adapter.ex`, `benches/redis_bench/lib/redis_bench/proxy_adapter.ex`, `benches/redis_bench/lib/redis_bench/toxiproxy.ex`, `benches/redis_bench/mix.exs`, `benches/redis_bench/test/fault_injection_test.exs`, `benches/redis_bench/test/nemesis_audit_test.exs`, `benches/redis_bench/test/redis_bench_test.exs`

## Reconstruction

Written when the PR opened, from the agent reports kept outside the repo; labeled as reconstruction.

- The Record holds the five pre-rebase commits. The branch was rebased onto main after two sibling branches merged (a cycle-count CI gate and three end-to-end test files), with no conflicts, and two documentation commits followed; the hook did not capture the rebased shas.
- The test author reported: "No tracked .pd or .pdtrace fixture exists at format 16", so the only format-16 fixture is the locked one written for the refusal test.
- An independent verifier reported two residues after the first hand-back: CHANGELOG Unreleased "still carries 24 nemesis/Toxiproxy lines outside the Removed entry" and `guides/cheatsheet.md:3` "still reads 'all five core behaviours'"; both were fixed in the two documentation commits.
- The verifier also reported, outside the contract: "`Persistence.list/1` crashes (FunctionClauseError in DateTime.compare/2) on a directory mixing a loadable report with an unreadable `.pd`", pre-existing at base; filed as debt, not fixed here.
