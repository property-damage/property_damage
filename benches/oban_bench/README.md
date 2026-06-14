# Oban Bench

PropertyDamage exercised against [Oban](https://hex.pm/packages/oban) on real
Postgres, as a self-contained mix project (`{:property_damage, path: "../.."}`).
This is the **eventual-consistency** rung of the bench ladder: the effect of a
command (an incremented counter) only becomes visible *after* Oban drains its
queue asynchronously, so the model must wait for it rather than assert
synchronously.

What it validates:

- **`@poll_state` / settle / resource pollers end to end**: `Increment` enqueues
  a real Oban job; an adapter resource poller watches the database between
  commands and streams the observed counter value back as events; a
  `@poll_state` invariant asserts the observed value eventually matches what was
  enqueued. This drives the R4 eventual-consistency pipeline against real async
  job processing rather than the framework's own mocks.
- **Non-vacuity** (`test/seeded_bug_test.exs`): a deliberately buggy worker that
  completes its job without performing the increment. The observed value never
  catches up, so PropertyDamage catches it via the `@poll_state` timeout and
  shrinks it to the minimal reproduction (a single `Increment`).

## Postgres

The bench owns a dedicated, ephemeral Postgres container (see
`docker-compose.yml`), independent of any Postgres on the host. `mix test`
brings it up automatically and idempotently:

```bash
mix deps.get
mix test            # brings the DB container up, creates+migrates, runs
mix bench.db.down   # tear the container down when finished
```

The container starts from a clean slate every time (its data lives in a tmpfs).
The first `mix test` boots Postgres (~2-3s); subsequent runs reuse the healthy
container and are instant. Teardown is deliberately a separate, explicit command
rather than automatic per run, so repeated runs stay fast and a crashed run
never leaves a half-removed container behind.

Configuration:

- `PD_OBAN_PG_PORT` — host port for the container (default `5434`).
- `PD_OBAN_DATABASE_URL` — if set, the container step is skipped and the bench
  connects to this database instead. This is the CI path (point it at a service
  container), and the escape hatch for hosts without Docker.

## Layout

- `docker-compose.yml` — the dedicated Postgres container
- `config/config.exs` — Repo + Oban config (reads the env vars above)
- `lib/oban_bench/worker.ex` — the async work (increment a counter)
- `lib/oban_bench/db.ex` — small SQL helpers (increment, value, job state)
- `lib/oban_bench/commands.ex` — events + the `Increment` command
- `lib/oban_bench/model.ex` — projection with the `@poll_state` invariant,
  simulator, model
- `lib/oban_bench.ex` — the adapter (enqueues jobs, starts resource pollers)

## Note: the invariant checked here

The bench checks the **eventual-consistency** property (the effect lands within
the window). Stronger value-level properties (exactly-once under retries, Oban
`unique` deduplication, linearization under concurrent jobs) are a natural
extension and belong with the parallel/linearization rung (6c).
