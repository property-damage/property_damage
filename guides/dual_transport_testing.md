# Dual-Transport Testing

> #### Builds on Differential Testing {: .info}
>
> This guide is the applied half of [Differential Testing](differential_testing.md):
> it takes the multi-target `PropertyDamage.run/1` oracle from that guide and points
> it at *two transports of one system* instead of two independent implementations.
> Read [Differential Testing](differential_testing.md) first for the `run/1` API,
> `@compare` observations, and `external()` capture. Everything here still reads
> standalone, but the API details live there.

Many systems expose the same operations through more than one transport: a REST
API *and* a web UI, a gRPC service *and* a CLI, a v1 *and* a v2 endpoint. They are
supposed to behave identically, but they drift: a form validates a field the API
accepts, one path trims whitespace and the other doesn't, a default differs.

Dual-transport testing catches that drift with a single source of truth. You write
**one transport-agnostic model** (the intent) and **one adapter per transport** (the
realization), then use [differential testing](differential_testing.md) to assert
the transports agree on the observations the model names. This guide shows the pattern and the decisions that make it
honest, using [Gitea](https://about.gitea.com) (a git forge with a REST API and an
equivalent web UI) as the running example. A complete, runnable version lives in
`benches/gitea_bench/`.

## The shape

```
              GiteaBench.Model           (intent: commands + invariants)
                /            \
       ApiAdapter            UiAdapter    (two realizations)
         (REST)              (Playwright)
            \                  /
            PropertyDamage.run/1          (oracle: @compare observations must agree)
```

The model never mentions a transport. It defines commands as pure intents and
declares invariants over the observed state. Each adapter knows how to *perform*
an intent against its transport, and `PropertyDamage.run/1` runs the same generated
sequence against both and compares the `@compare` observations of the model's
projections (see [What the oracle compares](#what-the-oracle-compares)):

```elixir
PropertyDamage.run(
  model: GiteaBench.Model,
  targets: [
    {GiteaBench.ApiAdapter, name: "api", config: %{base_url: api_url}},
    {GiteaBench.UiAdapter, name: "ui", config: %{base_url: ui_url}}
  ]
)
```

The first target in the `targets:` list is the oracle: a divergence is reported
as "the UI did something the API didn't." The call returns `{:error, report}` with
`kind: :diverged`. `report.variant` names the target that differed
(`%{index: 1, name: "ui"}` here) and `report.failed_at_index` is the command index.
The framework shrinks the sequence first, so
`PropertyDamage.FailureReport.shrunk_sequence/1` is the minimal sequence that
still diverges, and `PropertyDamage.FailureReport.reproduction_command/1` reruns it.
Each target runs as its own variant (its own process), and the targets advance in
lockstep: both execute command `r`, the observations are compared, and only then does
either start command `r + 1`.

## The model is the intent

Write commands at the altitude of *what the user means*, not *how a transport does
it*. The Gitea chain is `CreateUser → CreateRepo → CreateIssue → CreateLabel →
AddLabelToIssue → CloseIssue`, wired together with `when:`/`overrides:` so each command
depends on state an earlier one produced (see
[Writing Commands](writing_commands.md)). None of it knows about HTTP verbs or CSS
selectors:

```elixir
def commands do
  [
    {CreateUser, weight: 3, overrides: &user_overrides/1},
    {CreateRepo, weight: 3, when: &has_users?/1, overrides: &repo_overrides/1},
    {CreateIssue, weight: 3, when: &has_repos?/1, overrides: &issue_overrides/1},
    # ...
  ]
end
```

The invariants live with the model too, and they hold *whichever transport ran the
sequence*. That is the whole point: you maintain one specification, not two test
suites that slowly disagree.

## What the oracle compares

The framework never compares the events two adapters return. The model says what
must agree, through `@compare` functions on its projections. The Gitea model
declares two:

```elixir
# GiteaBench.State: users, repos with their label names, issues with title,
# labels and open/closed, after every command. Keyed by client-chosen names only.
@compare every: 1
def forge(state, _root), do: state

# GiteaBench.LabelColors: the color the forge reports for each label.
@compare every: CreateLabel
def label_colors(colors, _root), do: colors
```

`GiteaBench.State` keeps only label names, because no invariant depends on a
color. The color is still observable state, so a second projection folds it:

```elixir
defmodule GiteaBench.LabelColors do
  use PropertyDamage.Model.Projection

  @impl true
  def init, do: %{}

  @impl true
  def apply(colors, %LabelCreated{full_name: full_name, name: name, color: color}) do
    Map.put(colors, {full_name, name}, color)
  end

  def apply(colors, _event), do: colors

  @compare every: CreateLabel
  def label_colors(colors, _root), do: colors
end
```

Both observations are keyed by repo and label names the client chose, so neither
holds a server id and plain `==` is the right predicate. A model that names no
observation cannot run with two targets: the run fails at start, before any
adapter is set up.

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
observations: the projections fold names, never ids, so the `@compare` functions
return values that do not hold them. If an observation must carry a record that
does, strip the noise under `using:` with
`PropertyDamage.Equivalence.by_key(&PropertyDamage.Equivalence.normalize/1)`.

Both transports then navigate to the same logical entity, and ids and timestamps
never cause spurious divergence reports. (If a later command genuinely consumes a
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

`PropertyDamage.run/1` calls each target's `setup/1` at the start of **every** run
and tears it down at the end, so a `max_runs: N` campaign resets both forges N
times. Because `setup/1` can find state a crashed run left behind, it must be
idempotent, which a purge-and-recreate reset is:

```elixir
result =
  PropertyDamage.run(
    model: GiteaBench.Model,
    targets: [
      {ApiAdapter, name: "api", config: Map.new(api_opts)},
      {UiAdapter, name: "ui", config: Map.new(ui_opts)}
    ],
    max_commands: 12,
    max_runs: 20,
    seed: 1
  )

assert {:ok, _stats} = result, inspect(result, pretty: true)
```

The two forges are separate instances, so the default `concurrency: :serial` is
the right choice. If both targets shared one forge, `concurrency: :parallel`
would need a distinct user namespace per target through `config:`.

If setup or a command fails, `run/1` returns `{:error, report}` and the report
names the variant and the kind, for example `report.kind == :setup_failed` and
`report.variant == %{index: 1, name: "ui"}` when the UI forge is down.

## Prove the oracle isn't vacuous

An oracle that can never fail tells you nothing. The strongest demonstration is a
bug in a property the model *deliberately doesn't specify*, so it can only be caught
by comparing transports — not by any single-transport check.

In the bench, a flag makes the UI adapter create labels with the **wrong color**.
The model never asserts anything about color, so a single-transport run stays green;
only the `label_colors` observation notices that the same `CreateLabel` intent
produced a different color via the UI:

```elixir
{:error, report} = oracle(seed, seed_bug: true)
assert report.kind == :diverged
assert report.variant == %{index: 1, name: "ui"}

# the command at the diverging root of the shrunk sequence
shrunk = PropertyDamage.FailureReport.shrunk_sequence(report)
assert %CreateLabel{} = Enum.at(PropertyDamage.Sequence.to_list(shrunk), report.failed_at_index)

%PropertyDamage.Failure.Divergence{key: key, reference_value: ref, variant_value: ui, mismatch: mismatch} =
  report.failure_reason.type

assert key == {GiteaBench.LabelColors, :label_colors}
assert Map.keys(ref) == Map.keys(ui)    # the same labels exist in both
refute ref == ui                        # caught only by the oracle: a color differs
assert %PropertyDamage.ComparisonMismatch{left: ^ref, right: ^ui} = mismatch
```

Without the flag, the same seeds all return `{:ok, _stats}` — so the divergence is the
bug, not flakiness. This is the canonical argument for what an oracle buys you over
single-transport checks.

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
  before cutting over (see [Differential Testing](differential_testing.md)).
- You have a trusted reference implementation and a new one to validate.

It is the wrong tool when the transports are *meant* to differ (e.g. a UI
deliberately exposes a subset of the API). There, model only the shared subset, or
test the transports separately.

## Next steps

- [Differential Testing](differential_testing.md) — the full multi-target
  `PropertyDamage.run/1` API, `@compare` observations, the convergence loop and `concurrency:`
- [Writing Commands](writing_commands.md) — `when:`/`overrides:` wiring and `external()`
- [Integration Testing](integration_testing.md) — driving live services
- `benches/gitea_bench/` — the complete, runnable example this guide is drawn from
