# Redis Bench

PropertyDamage exercised against [Redis](https://redis.io) over the network, as
a self-contained mix project (`{:property_damage, path: "../.."}`). This is the
**external-SUT + fault-injection** rung of the bench ladder: the first
out-of-BEAM, network-attached SUT (6a/6c were in-process, 6b was
Postgres-via-Ecto).

The SUT is a Redis-backed atomic register. `INCR` is atomic and linearizable on
a single instance, so a faithful adapter is always linearizable. That is the
same canonical register as the 6c ETS bench, but reached over a real socket, so
the connection can be routed through [Toxiproxy](https://github.com/Shopify/toxiproxy)
and degraded with latency / packet-loss / partition toxics to test consistency
under faults.

What it validates:

- **Baseline** (`test/redis_bench_test.exs`): the read-consistency invariant
  (a `GET` returns exactly the count tallied from prior `INCR`s) holds against
  real Redis with no faults, linearly.
- **Non-vacuity** (`test/seeded_bug_test.exs`): a `StaleReadAdapter` that
  increments faithfully but reports every read as the initial `0`. The first
  read after any increment is then inconsistent, and PropertyDamage shrinks it
  to the minimal `Increment -> ReadValue` pair.
- **Fault injection / live oracle** (`test/fault_injection_test.exs`): real
  network faults via [Toxiproxy](https://github.com/Shopify/toxiproxy) in front
  of Redis. Each fault is proven REAL by a differential (a latency toxic
  measurably slows the round-trip; a disabled proxy partitions the connection).
  Under a latency toxic, linearizability still holds (Redis stays atomic); under
  a partition, the `ProxyAdapter` reports `{:error, {:redis_unavailable, _}}` so
  PropertyDamage surfaces the fault honestly as a connection error rather than a
  false consistency violation. This is the oracle the nemesis audit builds on.

- **Nemesis audit** (`test/nemesis_audit_test.exs`): proves each of the 10
  built-in nemesis implementations either REALLY injects its fault (an
  observable differential) or is honestly reported as `simulated: true`. The
  network trio (`NetworkLatency` / `NetworkPartition` / `PacketLoss`) is driven
  through the bench's real Toxiproxy proxy (round-trip time / connectivity
  changes), the host-effect nemeses against real BEAM/host state (stress
  processes, allocated memory, ETS tables, a killed pid), and the cooperative
  ones (`ClockSkew` / `SlowIO` / `CertificateExpiry`) via their public API. Each
  also verifies `restore/2` lifts the fault. This retires the Phase 2 "chaos
  theater" finding.

## Infrastructure

The bench owns a dedicated, ephemeral Redis + Toxiproxy stack (see
`docker-compose.yml`), independent of anything on the host. `mix test` brings it
up automatically and idempotently:

```bash
mix deps.get
mix test            # brings the stack up, runs
mix bench.db.down   # tear the stack down when finished
```

Redis runs with persistence off, so every fresh container starts from a clean
slate. The first `mix test` boots the stack (~2-3s); subsequent runs reuse the
healthy containers and are instant. Teardown is a separate, explicit command
rather than automatic per run, so repeated runs stay fast and a crashed run
never leaves a half-removed container behind.

### Requirements

Docker with the Compose v2 plugin (`docker compose ... --wait`) must be on your
`PATH`. If you do not have Docker, set `PD_REDIS_URL` (below) to point at any
Redis you provide; the container step is then skipped entirely. (The
fault-injection suites additionally need Toxiproxy; see their own setup.)

### Mix tasks

- `mix bench.db.up` — bring the stack up (or no-op if already healthy, or if
  `PD_REDIS_URL` is set). Runs automatically before `mix test`.
- `mix bench.db.down` — stop and remove the containers and volumes.
- `mix test` — `bench.db.up` + the tests.

### Configuration (environment variables)

- `PD_REDIS_PORT` — host port the container publishes Redis on (default `6390`,
  chosen to avoid the conventional 6379).
- `PD_TOXIPROXY_PORT` — host port for the Toxiproxy control API (default `8474`).
- `PD_REDIS_PROXY_PORT` — host port for Redis *through* Toxiproxy (default
  `6391`). Read by both `docker-compose.yml` and `config/config.exs`, so they
  never drift.
- `PD_REDIS_URL` — if set (and non-empty), the container step is skipped and the
  baseline connects to this Redis instead. This is the CI path (point it at a
  service container) and the escape hatch for hosts without Docker:

  ```bash
  export PD_REDIS_URL="redis://localhost:6379"
  mix test
  ```

## Layout

- `docker-compose.yml` — the dedicated Redis + Toxiproxy stack
- `config/config.exs` — endpoint resolution (reads the env vars above)
- `lib/redis_bench.ex` — top module + `RedisBench.Conn` (connection helper)
- `lib/redis_bench/commands.ex` — events + the `Increment` / `ReadValue` commands
- `lib/redis_bench/model.ex` — projection with the read-consistency invariant,
  simulator, model
- `lib/redis_bench/adapter.ex` — the faithful adapter (drives `INCR` / `GET`)
- `lib/redis_bench/toxiproxy.ex` — Toxiproxy control-API client + latency probe
- `lib/redis_bench/proxy_adapter.ex` — adapter that drives Redis *through* the
  proxy and reports connection failures honestly
