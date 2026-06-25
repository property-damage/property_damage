# gitea_bench

The **dual-transport** rung of the PropertyDamage bench ladder: one
transport-agnostic model, executed two ways, compared by an oracle.

PropertyDamage's thesis is that a model defines *intent* (commands and invariants)
independent of how that intent is carried out. This bench makes the claim concrete
against [Gitea](https://about.gitea.com), a self-hosted git forge whose every
operation exists both as a REST API call and as an equivalent web-UI interaction:

- `GiteaBench.Model` defines a chain of intents — CreateUser → CreateRepo →
  CreateIssue → CreateLabel → AddLabelToIssue → CloseIssue — with `when:`/`with:`
  wiring the dependencies and `GiteaBench.State` declaring the invariants. It never
  mentions API or UI.
- `GiteaBench.ApiAdapter` realizes each intent against Gitea's **REST API**.
- `GiteaBench.UiAdapter` realizes the same intents by driving the **web UI** with
  Playwright (filling forms, clicking buttons, toggling the label dropdown).

## The oracle

`PropertyDamage.Differential.run/1` generates one command sequence and runs it
against both adapters (API as the reference), asserting they reach identical
observable state. Both adapters build their events from the **same neutral
observation read** (the REST read API), so the only thing that varies is *how the
mutation was performed*. The differential therefore answers one precise question:

> After the same intent is carried out via REST versus via the browser, is the
> resulting forge state identical?

Two design points make this honest:

- **Parity through acting-as-user.** Gitea's UI can only create a repo under the
  acting account, so both transports authenticate *as* the relevant user (the API
  via basic auth, the UI by logging in). User creation is the one admin-scoped step.
- **Linking by name, not id.** Commands are chained by client-chosen, stable keys
  (login, `owner/name`, per-repo issue number), identical across both transports,
  so each navigates to the same logical entity. Server-assigned ids and timestamps
  are ignored via `equivalence: :structural`.

## Non-vacuity

`test/seeded_divergence_test.exs` proves the oracle can fail. With `seed_bug: true`
the UI adapter fills the *wrong colour* when creating a label. The model never
specifies a label's colour, so none of its own invariants fire on a single
transport — only comparing the two transports reveals that the same intent produced
different state. Without the flag, the same sequences are equivalent.

## Layout

```
lib/gitea_bench/
  events.ex      shared event structs (both adapters emit the same shapes)
  commands.ex    six transport-agnostic command intents
  state.ex       model state + DR-026 invariants + @trigger assertions
  model.ex       commands/0 (weight/when/with), simulator
  gitea.ex       readiness, per-run reset, REST mutations + neutral observers
  api_adapter.ex REST transport
  ui_adapter.ex  Playwright transport (acts-as-user, seeded-bug flag)
```

## Running

```bash
mix test          # brings up two Gitea instances + installs Chromium, then runs
mix bench.db.down # explicit teardown
```

`mix test` runs `bench.db.up` (two ephemeral `gitea/gitea` containers on ports
3101/3102, each with a known admin) and `playwright.install` (Chromium) before the
suite. Set `PD_GITEA_API_URL` / `PD_GITEA_UI_URL` to point at external instances
(CI service containers / BYO); then no containers are started. Requires Docker and
Node on the host.

### Notes

- Each adapter's `setup/1` resets its instance (purges non-admin users) so reused
  containers never leak state between runs, and both transports start every run
  from identical empty forges.
- `Differential.run/1` sets each target up only once, so the differential tests
  loop with `max_runs: 1`: a fresh setup per call resets both forges, giving a
  clean comparison per generated sequence.
- Browser automation is slow; command/run counts are kept modest.
