# Dual-Transport Testing

Many systems expose the same operations through more than one transport: a REST
API *and* a web UI, a gRPC service *and* a CLI, a v1 *and* a v2 endpoint. They are
supposed to behave identically, but they drift: a form validates a field the API
accepts, one path trims whitespace and the other doesn't, a default differs.

Dual-transport testing catches that drift with a single source of truth. You write
**one transport-agnostic model** (the intent) and **one adapter per transport** (the
realization), then use [differential testing](differential_testing.md) to assert
the transports agree. This guide shows the pattern and the decisions that make it
honest, using [Gitea](https://about.gitea.com) (a git forge with a REST API and an
equivalent web UI) as the running example. A complete, runnable version lives in
`benches/gitea_bench/`.

This guide builds on [Differential Testing](differential_testing.md); read that
first for the `PropertyDamage.Differential.run/1` API.

## The shape

```
              GiteaBench.Model           (intent: commands + invariants)
                /            \
       ApiAdapter            UiAdapter    (two realizations)
         (REST)              (Playwright)
            \                  /
             Differential.run/1           (oracle: results must agree)
```

The model never mentions a transport. It defines commands as pure intents and
declares invariants over the observed state. Each adapter knows how to *perform*
an intent against its transport, and `Differential.run/1` runs the same generated
sequence against both and compares the results:

```elixir
PropertyDamage.Differential.run(
  model: GiteaBench.Model,
  targets: [
    {GiteaBench.ApiAdapter, role: :reference, opts: [base_url: api_url]},
    {GiteaBench.UiAdapter, name: "ui", opts: [base_url: ui_url]}
  ],
  compare: :correctness,
  equivalence: :structural
)
```

The reference target is the oracle: divergences are reported as "the UI did
something the API didn't."

## The model is the intent

Write commands at the altitude of *what the user means*, not *how a transport does
it*. The Gitea chain is `CreateUser → CreateRepo → CreateIssue → CreateLabel →
AddLabelToIssue → CloseIssue`, wired together with `when:`/`with:` so each command
depends on state an earlier one produced (see
[Writing Commands](writing_commands.md)). None of it knows about HTTP verbs or CSS
selectors:

```elixir
def commands do
  [
    {CreateUser, weight: 3, with: &user_overrides/1},
    {CreateRepo, weight: 3, when: &has_users?/1, with: &repo_overrides/1},
    {CreateIssue, weight: 3, when: &has_repos?/1, with: &issue_overrides/1},
    # ...
  ]
end
```

The invariants live with the model too, and they hold *whichever transport ran the
sequence*. That is the whole point: you maintain one specification, not two test
suites that slowly disagree.

## Three decisions that make the oracle honest

A naive dual-transport setup compares apples to oranges and either passes
vacuously or fails on noise. Three choices keep the comparison meaningful.

### 1. Build events from a neutral observation read

If each adapter reports results in its own way (the API parses a JSON response, the
UI scrapes a page), you end up comparing *adapter implementations* rather than *SUT
behavior*. Instead, have **both** adapters build their events from the same neutral
read of the system:

```elixir
# ApiAdapter: mutate via REST, then observe via the read API
def execute(%CreateRepo{owner: owner, name: name}, %{client: client}, _runtime) do
  with :ok <- Gitea.create_repo(client, owner, name) do
    {:ok, [Gitea.repo_event(client, owner, name)]}   # neutral observation
  end
end

# UiAdapter: mutate via the browser, then observe the SAME way
def execute(%CreateRepo{owner: owner, name: name}, ctx, _runtime) do
  ui_create_repo(ctx.page, owner, name)
  {:ok, [Gitea.repo_event(ctx.client, owner, name)]} # same observer
end
```

Now the only thing that varies between targets is *how the mutation was performed*,
so the differential answers a precise question: **after the same intent is carried
out via REST versus via the browser, is the resulting state identical?** The read
being shared (here, the REST read API) is fine — it is the *mutating* transport
under test, not the observation.

### 2. Link by stable names, not server ids

Sequences chain commands together: `AddLabelToIssue` needs to refer to an issue
created earlier. If you link on server-assigned ids, the two instances may hand out
different ids and every later command targets a different entity. Link instead on
**client-chosen, stable keys** that are identical across transports — a login, an
`owner/name` repo path, a per-repo issue number — and ignore server ids in the
comparison with `equivalence: :structural`:

```elixir
compare: :correctness,
equivalence: :structural   # ignores :id, timestamps, uuids
```

Both transports then navigate to the same logical entity, and ids/timestamps never
cause spurious divergences. (If a later command genuinely consumes a
server-generated value, see the `external()` section of
[Differential Testing](differential_testing.md) — each target captures its own.)

### 3. Let the most constrained transport set the model's altitude

Transports are rarely perfectly symmetric, and the asymmetry dictates how you model
the intent. Gitea's API can create a repo *for any user* (an admin endpoint), but
its **UI can only create a repo under the account you are logged in as**. If the
model assumed the API's freedom, the UI adapter could never match it.

The fix is to model at the altitude both transports share: the repo is owned by the
acting user, and *both* adapters act **as** that user (the API via basic auth, the
UI by logging in and switching sessions). One operation — creating the user — is
genuinely admin-only, so it is the single asymmetric step, handled explicitly.

The general rule: **find the behavior both transports can express, and model
there.** When you cannot, make the asymmetry an explicit, named part of the model
rather than a hidden assumption.

## State isolation for a stateful SUT

A forge accumulates state, so each run must start clean or sequences collide
(creating `u0` twice fails the second time). Reset in the adapter's `setup/1`:

```elixir
def setup(config) do
  client = Gitea.new(config)
  :ok = Gitea.ensure_ready(client)
  :ok = Gitea.reset!(client)        # purge non-admin users, cascading to their data
  {:ok, %{client: client}}
end
```

One subtlety specific to differential testing: **`Differential.run/1` sets each
target up once and does not reset between its internal runs.** For a stateful SUT,
drive the run-loop yourself with `max_runs: 1`, so each call re-runs `setup/1` and
resets both instances:

```elixir
for seed <- 1..20 do
  {:ok, result} =
    PropertyDamage.Differential.run(
      model: GiteaBench.Model,
      targets: [{ApiAdapter, role: :reference, opts: api_opts}, {UiAdapter, name: "ui", opts: ui_opts}],
      compare: :correctness,
      equivalence: :structural,
      max_commands: 12,
      max_runs: 1,
      seed: seed
    )

  assert result.status == :equivalent, inspect(result.divergences, pretty: true)
end
```

`PropertyDamage.run/1` (a single adapter) *does* call `setup/1` per run, so it is
fine with `max_runs: N` directly. The looping pattern is only needed for the
differential path.

## Prove the oracle isn't vacuous

An oracle that can never fail tells you nothing. The strongest demonstration is a
bug in a property the model *deliberately doesn't specify*, so it can only be caught
by comparing transports — not by any single-transport assertion.

In the bench, a flag makes the UI adapter create labels with the **wrong color**.
The model never asserts anything about color, so a single-transport run stays green;
only the differential notices that the same `CreateLabel` intent produced a
different color via the UI:

```elixir
divergent = oracle(seed, seed_bug: true)
assert divergent.status == :divergent

[divergence | _] = divergent.divergences
assert %CreateLabel{} = divergence.command
{:ok, [ref]}  = divergence.reference_result
{:ok, [ui]}   = divergence.divergent_result
assert ref.name == ui.name
refute ref.color == ui.color           # caught only by the oracle
```

Without the flag, the same seeds are all `:equivalent` — so the divergence is the
bug, not flakiness. This is the canonical argument for what an oracle buys you over
single-transport assertions.

## Running it

The two instances are ephemeral containers brought up by the bench's own
`docker-compose` and `bench.db.up`/`bench.db.down` aliases, with a
`PD_GITEA_API_URL` / `PD_GITEA_UI_URL` escape hatch for pointing at external
instances (CI service containers / BYO). The UI adapter drives a real browser via
Playwright. See `benches/gitea_bench/README.md` for the full setup, and
[Integration Testing](integration_testing.md) for the general live-service pattern.

In CI, the bench runs as a dedicated job that provisions both instances and the
browser, then runs the suite unchanged.

## When to reach for this

Use dual-transport testing when:

- A system exposes the same operations through more than one interface (API + UI,
  CLI + API, SDK + raw protocol) and they must stay in lockstep.
- You are migrating between two implementations and want to prove equivalence
  before cutting over (pair it with the baseline export in
  [Differential Testing](differential_testing.md)).
- You have a trusted reference implementation and a new one to validate.

It is the wrong tool when the transports are *meant* to differ (e.g. a UI
deliberately exposes a subset of the API). There, model only the shared subset, or
test the transports separately.

## Next steps

- [Differential Testing](differential_testing.md) — the full `Differential.run/1`
  API, equivalence strategies, execution modes, and baselines
- [Writing Commands](writing_commands.md) — `when:`/`with:` wiring and `external()`
- [Integration Testing](integration_testing.md) — driving live services
- `benches/gitea_bench/` — the complete, runnable example this guide is drawn from
