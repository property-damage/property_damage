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
- **Server-generated identifiers (`external()`)** (`lib/oban_bench/job_refs.ex`):
  `Oban.insert` returns a database-generated integer job id, exactly the shape
  `external()` models. `EnqueueJob` produces a `JobEnqueued` event whose `job_id`
  is declared `external()`; two distinct consumers, `CancelJob` and
  `ReadJobState`, each receive that id resolved to the real value. Jobs are
  inserted far in the future (`schedule_in`) so they sit `scheduled` and never
  run, which makes cancellation deterministic. The `cancelled_jobs_not_runnable`
  invariant asserts a cancelled job is never left runnable.
  - The load-bearing claim (`test/job_refs_shrink_test.exs`): **shrinking
    preserves the producer of a consumed placeholder.** A seeded-bug adapter
    whose `CancelJob` silently no-ops leaves the job `scheduled`; PropertyDamage
    catches the violation and shrinks it to exactly `[EnqueueJob, CancelJob]`,
    keeping the producing insert before the failing consumer (if the producer
    were dropped, the consumer's id could not resolve and the failure would not
    reproduce). `test/job_refs_test.exs` is the paired control (faithful cancel
    is green) and proves the `when:`-gated consumers actually ran via coverage
    counts.

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

### Requirements

Docker with the Compose v2 plugin (`docker compose ... --wait`) must be on your
`PATH`. If you do not have Docker, set `PD_OBAN_DATABASE_URL` (below) to point at
any Postgres you provide; the container step is then skipped entirely.

### Mix tasks

- `mix bench.db.up` — bring the container up (or no-op if already healthy, or
  if `PD_OBAN_DATABASE_URL` is set). Runs automatically before `mix test`.
- `mix bench.db.down` — stop and remove the container and its volume.
- `mix test` — `bench.db.up` + `ecto.create` + `ecto.migrate` + the tests.

### Configuration (environment variables)

- `PD_OBAN_PG_PORT` — host port the container publishes Postgres on
  (default `5434`). Both `docker-compose.yml` and `config/config.exs` read it,
  so they never drift. The in-container credentials are
  `postgres` / `postgres`, database `pd_oban_bench`.
- `PD_OBAN_DATABASE_URL` — if set (and non-empty), the container step is skipped
  and the bench connects to this database instead. This is the CI path (point it
  at a service container) and the escape hatch for hosts without Docker. It is an
  Ecto URL:

  ```bash
  export PD_OBAN_DATABASE_URL="ecto://postgres:postgres@localhost:5432/pd_oban_bench"
  mix test
  ```

  When this is set, `PD_OBAN_PG_PORT` is ignored (the port comes from the URL).

## Layout

- `docker-compose.yml` — the dedicated Postgres container
- `config/config.exs` — Repo + Oban config (reads the env vars above)
- `lib/oban_bench/worker.ex` — the async work (increment a counter)
- `lib/oban_bench/db.ex` — small SQL helpers (increment, value, job state)
- `lib/oban_bench/commands.ex` — events + the `Increment` command
- `lib/oban_bench/model.ex` — projection with the `@poll_state` invariant,
  simulator, model
- `lib/oban_bench/job_refs.ex` — the `external()` server-generated-id bench
  (producer/consumer commands, projection, simulator, model, adapter)
- `lib/oban_bench.ex` — the adapter (enqueues jobs, starts resource pollers)

## Note: the invariant checked here

The bench checks the **eventual-consistency** property (the effect lands within
the window). Stronger value-level properties (exactly-once under retries, Oban
`unique` deduplication, linearization under concurrent jobs) are a natural
extension and belong with the parallel/linearization rung (6c).
