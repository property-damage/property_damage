# gitea_bench

The **dual-transport** rung of the PropertyDamage bench ladder: one
transport-agnostic model, executed two ways, compared by an oracle.

PropertyDamage's thesis is that a model defines *intent* (commands and invariants)
independent of how that intent is carried out. This bench makes the claim concrete
against [Gitea](https://about.gitea.com), a self-hosted git forge whose every
operation exists both as a REST API call and as an equivalent web-UI interaction:

- `GiteaBench.Model` defines a chain of intents — CreateUser → CreateRepo →
  CreateIssue → CreateLabel → AddLabelToIssue → CloseIssue — with `when:`/`overrides:`
  wiring the dependencies and `GiteaBench.State` declaring the invariants. It never
  mentions API or UI.
- `GiteaBench.ApiAdapter` realizes each intent against Gitea's **REST API**.
- `GiteaBench.UiAdapter` realizes the same intents by driving the **web UI** with
  Playwright (filling forms, clicking buttons, toggling the label dropdown).

## The oracle

`PropertyDamage.run/1` with both adapters as `targets:` generates one command
sequence and runs it against both (API as the reference), asserting they reach identical
observable state. The model says what "observable state" means through two `@compare`
observations, checked after the commands they are scheduled for:

- `GiteaBench.State.forge/2` (`@compare every: 1`): users, repos, issues (title,
  labels, open or closed) and label names.
- `GiteaBench.LabelColors.label_colors/2` (`@compare every: CreateLabel`): each
  label's color, keyed by repo and label name.

Both adapters build their events from the **same neutral
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
  so each navigates to the same logical entity. Neither observation holds a
  server-assigned id or timestamp, so the two forges compare with plain equality.

## Non-vacuity

`test/seeded_divergence_test.exs` proves the oracle can fail. With `seed_bug: true`
the UI adapter fills the *wrong colour* when creating a label. The model never
specifies a label's colour, so none of its own invariants fire on a single
transport — only the `label_colors` observation, comparing the two transports, reveals
that the same intent produced different state. Without the flag, the same sequences agree.

## Layout

```
lib/gitea_bench/
  events.ex      shared event structs (both adapters emit the same shapes)
  commands.ex    six transport-agnostic command intents
  state.ex       model state + DR-026 invariants + @check functions + forge observation
  label_colors.ex label color observation compared across transports
  model.ex       commands/0 (weight/when/with), simulator
  gitea.ex       readiness, per-run reset, REST mutations + neutral observers
  api_adapter.ex REST transport
  ui_adapter.ex  Playwright transport (acts-as-user, seeded-bug flag)
```

## Running

```bash
mix deps.get      # fetch deps (first run)
mix test          # brings up three Gitea instances + installs Chromium, then runs
mix bench.db.down # explicit teardown
```

`mix test` runs `bench.db.up` (three ephemeral `gitea/gitea` containers on ports
3101/3102/3103, each with a known admin — the 3103 instance runs gitea 1.24 for
the webhook-injector demo) and `playwright.install` (Chromium) before the
suite. Set `PD_GITEA_API_URL` / `PD_GITEA_UI_URL` to point at external instances
(CI service containers / BYO); then no containers are started. Requires Docker and
Node on the host.

### Notes

- Each adapter's `setup/1` resets its instance (purges non-admin users) so reused
  containers never leak state between runs, and both transports start every run
  from identical empty forges.
- `PropertyDamage.run/1` sets each target up at the start of every run, so a
  campaign resets both forges before every generated sequence. `setup/1` is
  idempotent, because a crashed run may leave state behind. The bench tests still
  call it once per seed (`max_runs: 1`) so each seed reports its own result.
- A failure or divergence returns `{:error, report}`: `report.kind` is the failure
  kind (`:diverged` for a divergence) and `report.variant` names the target, for
  example `%{index: 1, name: "ui"}`. A divergence is shrunk before it is reported.
- Browser automation is slow; command/run counts are kept modest.
