# kratos_bench

Validates **`PropertyDamage.MockServiceAdapter` / `MockServiceRegistry`** (feature
8, "mock third-party services") against a real SUT: **Ory Kratos**.

The mock is genuinely load-bearing here, which is the point. Kratos calls a
**blocking registration `web_hook`** (`response.parse: true`) and *acts on the
answer*: a 4xx aborts the flow **before any identity is persisted**, and a 2xx
body can **rewrite the identity's traits** before it is stored. PropertyDamage's
mock is the party answering that call, so what the mock says decides what Kratos
does. A fire-and-forget webhook (as in `gitea_bench`) cannot demonstrate this:
there the SUT ignores the response.

## The SUT

A single Ory Kratos container (`oryd/kratos:v1.3.1`) with an **in-memory DSN**, so
there is no database sidecar. Config is mounted from `config/kratos/`:

- `kratos.yml` — a registration flow whose `after.password` hooks are the blocking
  `web_hook` (pointing at the mock, `http://host.docker.internal:4500/registration`)
  followed by `session`.
- `identity.schema.json` — email (the password identifier) plus an optional `role`
  trait the mock's modify-response fills in.
- `registration.body.jsonnet` — the body Kratos POSTs to the mock (the submitted
  email), so the mock can key its injected event on it.

State lives only in memory; the adapter resets it via the admin API at the start
of each sequence, so runs are isolated without a volume.

### Pre-persistence, verified

The flagship invariant depends on the reject path leaving **no** identity behind.
That is a property of `response.parse: true` hooks: they run *pre-persistence* so
they can interrupt. Non-parse blocking hooks run *after* persistence and would
leave an identity. This was confirmed empirically against `v1.3.1` before the
bench was built (reject → `GET /admin/identities` stays empty; modify → the
persisted identity carries the mock-assigned role and metadata).

## Command surface

| Command | Mock decision / effect |
|---|---|
| `RegisterAccept` | mock returns 2xx unchanged → identity created |
| `RegisterReject` | mock returns 4xx → flow aborts, **no identity** |
| `RegisterModify` | mock returns 2xx + trait rewrite → identity created with role `mock-assigned` |
| `Login` (gated) | adapter logs in an existing identity; outcome observed |
| `ListIdentities` | adapter reads the admin identity set back (the reality checked) |
| `DeleteIdentity` (gated) | adapter deletes an existing identity |

`Login`/`DeleteIdentity` are `when:`-gated on an existing identity, so the model
ships a `Simulator` (otherwise the symbolic phase never populates the projection
and the gated commands are never generated). The headline test asserts via
`coverage: true` that both gated commands actually ran.

## Invariants (in `KratosBench.State`)

- **`identity_set_faithful`** — Kratos holds exactly the identities the mock
  accepted; a rejected registration leaves none.
- **`accepted_traits_faithful`** — an identity the mock *modified* carries the role
  trait the mock's response dictated.
- **`login_consistent`** — login succeeds exactly for identities the mock let
  Kratos create.

The mock injects `RegistrationHandled` (the model's *expectation*); the adapter
reads the *reality* back from Kratos (`IdentitiesListed`, `LoginAttempted`), and
the assertions compare the two.

### Non-vacuity (RED-first)

`test/invariants_test.exs` proves each invariant bites, via a seed that only that
invariant can catch, paired with a control on the same seeds proving no false
positive. The bugs live in the mock's response or the adapter's login, not in the
assertions:

- `reject_leaks` — the mock accepts a registration it should reject → caught by
  `identity_set_faithful`.
- `modify_ignored` — the mock skips the trait rewrite → caught by
  `accepted_traits_faithful`.
- `login_broken` — the adapter uses the wrong password → caught by
  `login_consistent`.

## Wiring note

`PropertyDamage.run/1` can own the mock lifecycle for you via its
`:mock_services` option (WP-C5): it starts a `MockServiceRegistry`, registers and
`setup/1`s each declared mock, drives `on_command/2` before each command, and
flushes the events the mock pushes after each command. This bench predates that
option and instead owns the registry itself: `KratosBench.Adapter` runs the
lifecycle (`start_link` → `register` → `notify_command` → `flush_events` → `stop`),
and the mock's own HTTP listener reads the mock's state (`get_handler_state/2`),
calls `handle_request/2`, and pushes the returned events back (`push_events/3`) on
each inbound web_hook. Both approaches are valid; the manual one is kept here
because Kratos reaches the mock over real HTTP and the listener needs the registry
pid at request time regardless. A migration onto `:mock_services` would hand the
listener that same pid through the mock's `setup/1` config.

## Running

```bash
mix test          # brings up the Kratos container, then runs
mix bench.db.down # tear the container down

# Point at an external Kratos instead (CI / BYO); nothing is started locally:
PD_KRATOS_PUBLIC_URL=http://host:4433 PD_KRATOS_ADMIN_URL=http://host:4434 mix test
```

The mock's web_hook listener binds `PD_KRATOS_MOCK_PORT` (default 4500) on the
host; Kratos reaches it at `host.docker.internal:4500` (mapped via `extra_hosts`).
If you change the port, update the `url` in `config/kratos/kratos.yml` too.
