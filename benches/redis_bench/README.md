# Redis Bench

PropertyDamage exercised against [Redis](https://redis.io) over the network, as
a self-contained mix project (`{:property_damage, path: "../.."}`). This is the
**external-SUT** rung of the bench ladder: the first
out-of-BEAM, network-attached SUT (6a/6c were in-process, 6b was
Postgres-via-Ecto).

The SUT is a Redis-backed atomic register. `INCR` is atomic and linearizable on
a single instance, so a faithful adapter is always linearizable. That is the
same canonical register as the 6c ETS bench, but reached over a real socket.

What it validates:

- **Baseline** (`test/redis_bench_test.exs`): the read-consistency invariant
  (a `GET` returns exactly the count tallied from prior `INCR`s) holds against
  real Redis, linearly.
- **Non-vacuity** (`test/seeded_bug_test.exs`): a `StaleReadAdapter` that
  increments faithfully but reports every read as the initial `0`. The first
  read after any increment is then inconsistent, and PropertyDamage shrinks it
  to the minimal `Increment -> ReadValue` pair.
- **Branching + linearization** (`test/parallel_linearization_test.exs`): the
  parallel-execution rung. A non-atomic `GetThenSet` (`GET`, compute `+1`, `SET`
  -- two round-trips) is the racing command; atomic `INCR` is the safe contrast.
  Two layers: (1) a *physical* race over two real connections with a barrier
  that releases both writes only after both reads, so the non-atomic
  read-modify-write leaves the register at 1 after two increments (a lost
  update) while `INCR` under the identical schedule leaves it at 2; (2) the
  framework's own detection under `branching:` -- atomic `Increment` branches
  and faithful `GetThenSet` branches are never falsely flagged (across seeds),
  while a `LostUpdateAdapter` that reports every write from a stale snapshot
  produces lost-update events `PropertyDamage.Linearization` refutes, surfacing
  a `:linearization_failed` failure that shrinks to the minimal two
  `GetThenSet` commands. What layer 2 detects is a stale report under
  sequential calls, not a race: the executor runs branches sequentially over one shared context
  and checks linearizability of the observed events *analytically* (it does not
  run branches concurrently), so the lost update is injected at the adapter
  level -- the same technique as the framework's `ets_linearization_test.exs`;
  layer (1) supplies the genuine physical race that grounds it.

## Infrastructure

The bench owns a dedicated, ephemeral Redis container (see
`docker-compose.yml`), independent of anything on the host. `mix test` brings it
up automatically and idempotently:

```bash
mix deps.get
mix test            # brings Redis up, runs
mix bench.db.down   # tear Redis down when finished
```

Redis runs with persistence off, so every fresh container starts from a clean
slate. The first `mix test` boots the container (~2-3s); subsequent runs reuse the
healthy container and are instant. Teardown is a separate, explicit command
rather than automatic per run, so repeated runs stay fast and a crashed run
never leaves a half-removed container behind.

### Requirements

Docker with the Compose v2 plugin (`docker compose ... --wait`) must be on your
`PATH`. If you do not have Docker, set `PD_REDIS_URL` (below) to point at any
Redis you provide; the container step is then skipped entirely.

### Mix tasks

- `mix bench.db.up` — bring Redis up (or no-op if already healthy, or if
  `PD_REDIS_URL` is set). Runs automatically before `mix test`.
- `mix bench.db.down` — stop and remove the container and volumes.
- `mix test` — `bench.db.up` + the tests.

### Configuration (environment variables)

- `PD_REDIS_PORT` — host port the container publishes Redis on (default `6390`,
  chosen to avoid the conventional 6379).
- `PD_REDIS_URL` — if set (and non-empty), the container step is skipped and the
  baseline connects to this Redis instead. This is the CI path (point it at a
  service container) and the escape hatch for hosts without Docker:

  ```bash
  export PD_REDIS_URL="redis://localhost:6379"
  mix test
  ```

## Layout

- `docker-compose.yml` — the dedicated Redis container
- `config/config.exs` — endpoint resolution (reads the env vars above)
- `lib/redis_bench.ex` — top module + `RedisBench.Conn` (connection helper)
- `lib/redis_bench/commands.ex` — events + the `Increment` / `ReadValue` /
  `GetThenSet` commands
- `lib/redis_bench/model.ex` — projection with the read-consistency invariant,
  simulator, the atomic `RedisBench.Model`, and `RedisBench.RmwModel` (the
  read-modify-write model for the branching + linearization suite)
- `lib/redis_bench/adapter.ex` — the faithful adapter (drives `INCR` / `GET` /
  `GET`+`SET`)
