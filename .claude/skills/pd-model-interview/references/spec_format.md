# model_spec.md Format

One spec per model, named exactly `model_spec.md`, living in the model's
directory (default `test/support/pd/<model_slug>/`). Discovery is by glob:
trust where specs actually are over where the convention says they should be.
The spec is markdown with a fixed section order; each item is a heading, a
fenced `yaml` block for mechanical facts, and free prose for the nuance the
block cannot carry. The prose is not decoration - edge cases, rationale, and
severity live there and inform generation.

The spec pins **behavior, not code identity**: two regenerations may word the
code differently while meaning the same thing. What the YAML blocks state and
the prose describes is the contract.

## Header

Opens the file as a fenced `yaml` block:

```yaml
model: OrderBook                      # model module basename
namespace: MyApp.PD.OrderBook         # module prefix for generated code
dir: test/support/pd/order_book/      # this directory
pd_version: "0.2.0"                   # PD version scaffolded against (see below)
transport: in_process                 # in_process | http | other (prose below)
reset: ecto_sandbox                   # adapter-only side effects that give a run a clean SUT
openapi:                              # only when composed with an OpenAPI spec
  path: priv/openapi.json
  sha256: "ab12..."                   # content hash at scaffold time
interview: complete                   # complete | checkpoint
missing: []                           # checkpoint only: what was not covered
```

Regeneration reads `pd_version`: it compares the key with the installed
PropertyDamage version and writes the installed version back after a
successful regeneration (see `regeneration.md`).

`interview: checkpoint` + `missing:` is the resume mechanism: a later session
(possibly a different agent) must be able to continue from the spec alone.
On re-run, compare the OpenAPI hash: a mismatch means drift (diff the
operations, delta-interview the changes); a missing file means *ask whether it
moved* - never conclude the composition is gone.

## Sections, in order

### 1. System overview

Prose. What the SUT is, the entities in scope and their lifecycles, and
where this model's boundary sits (what neighboring subsystems it deliberately
excludes). The scaffold copies it into the model's `@moduledoc`, and the
failure report prints that text as the model's description, so write it for a
reader who has never seen the system.

### 2. Commands

One `###`-heading per command:

```yaml
name: PlaceOrder
execution: sync            # sync | probe | async
role: root                 # root (default) | setup | teardown (see section 3)
fields:
  amount: "positive cents, typically < 10^6; hostile edge: exactly 0"
  currency: "ISO 4217 code from the supported set"
when: "at least one open account exists"
weight: 5
shrink: neutral            # neutral (default) | prefer_remove | prefer_keep
events: [OrderPlaced, OrderRejected]
```

`shrink:` tells the shrinker how to treat the command when it cuts a failing
sequence down. Write `prefer_remove` for a read-only command, so the shrinker
drops it first, and `prefer_keep` for a command a failure usually needs;
leave it out for `neutral`. The scaffold passes it as the command's
`shrink:` option.

Field values are **generator notes** in plain language, not StreamData code -
the scaffolder translates. `when:` is prose describing the precondition; the
scaffolder turns it into a guard over projection state. `events:` is the
simulate contract: everything this command can observably produce, including
deliberate rejections. The scaffolder generates the model's simulator from
it, one clause per command. Prose after the block: edge cases, failure
behavior, anything the user said that a maintainer would need; the scaffold
copies it into the command module's `@moduledoc`, which the failure report
prints.

For an `async` command, add `completion:` with how the user learns the work
finished: `poll` (a probe command reads the result; name it) or `injected`
(the system pushes a webhook or callback; the event it carries is marked
`source: injected` in the Events section).

### 3. Setup and teardown

Fixtures: what must exist before anything can happen (an admin user, an open
session), and what must be cleaned up after. Each one is a command, written
up in section 2 with `role: setup` or `role: teardown`, and listed here in
the order it runs:

```yaml
setup:
  - command: CreateUser
    overrides: "role is admin"   # plain-language note; becomes overrides:
teardown:
  - command: DeleteTestUsers
```

The scaffold turns the lists into the model's `setup_each/0` and
`teardown_each/0`. Every entry runs, in order, in every run and every target.
Omit the section when there are no fixtures. Do not put fixtures in the
adapter: its `setup/1` only does what the adapter can do alone (start or
reset the system) and must be idempotent, because it runs once per run in
every target. That is what the header's `reset:` records.

### 4. Events

One `###`-heading per event:

```yaml
name: OrderPlaced
source: command          # command (default) | injected
fields:
  order_id: external       # server-generated -> external() in the struct
  amount: from_command
  placed_at: external
```

Every event with `source: command` must be produced by at least one command's
`events:` list. An event with `source: injected` reaches the test through an
injector (a webhook, a callback), not from a command, so the closure rule
exempts it. The scaffold lists it in the model's `injectable_events/0` and
stubs the injector. Prose after the block becomes the event module's
`@moduledoc`.

### 5. Projections

The command-sequence projection (what state it tracks and which commands'
guards or generators need it), then check projections. State exists only
because something gates on it or an invariant inspects it. The prose becomes
each projection module's `@moduledoc`.

### 6. Invariants

One `###`-heading per invariant:

```yaml
name: no_negative_balance
kind: check                # check (now) | eventually (within a window)
projection: BalanceInvariants
every: [WalletOpened, Deposited]   # check: event or command names (or a step count),
                           # or `at: teardown` instead (once, on the settled final state)
```

An `eventually` invariant takes `after:` (the event that starts the window),
`timeout:` and `interval:` instead of `every:`:

```yaml
name: payment_confirmed
kind: eventually
projection: PaymentInvariants
after: PaymentInitiated
timeout: 5s
interval: 100ms
```

A safety invariant ("this never happens too much") is `kind: check` with
`at: teardown`. Its projection must accumulate evidence (a count, a maximum,
a sticky flag), because the check reads only the final state.

Prose: the check in domain language, and the severity of a violation. The
scaffold copies it into the `@doc` of the check function, and the failure
report prints it under "What this checks". Suggested-but-unadopted invariants
do not go here - they go in section 9 as deferred.

### 7. Targets and expansions (optional)

Two optional features. Record them when the user says yes, and leave the section
out otherwise (a `deferred` or `declined` entry in section 9 records the
no):

```yaml
targets: [reference, candidate]    # compare the same commands on several targets
compare:
  - name: balance
    every: end                     # the value to compare, and when
expansions:
  - root: Pay
    as: "authorize, then capture"  # a root that may run as an equivalent sequence
```

The scaffold turns `compare:` into `@compare` functions in a check
projection, and `expansions:` into the model's `expansions/0`. A model with
`expansions:` must also compare at the end of the run.

### 8. Known failure modes

Prose. Where the user suspects or fears bugs. Steers weights and generator
hostility toward where blood is expected.

### 9. Explicitly not modeled

The anti-scope, and the delta interview's memory. Flat list, each entry
marked:

- `deferred` - in scope eventually, not yet covered (partial sessions,
  postponed invariants, suggested invariants awaiting adoption). **Re-raise
  these next session.**
- `declined` - the user said no, with their reason. **Never raise again**
  unless the user does.

Every "no" during the interview lands here at the moment it is said. A spec
whose not-modeled section is empty after a real interview is a red flag: it
means rejections went unrecorded and the next delta interview will nag.

## Editing and regeneration

Users edit this file by hand; that is the intended workflow. Regeneration
reads the spec (and the OpenAPI document when composed) and applies the
file-class rules in [regeneration.md](regeneration.md). Hand-edits to
*generated code* that the spec does not capture get folded back into the spec
or reverted - the spec never silently loses to the code.
