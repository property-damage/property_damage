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
pd_version: "0.2.0"                   # PD version scaffolded against
transport: in_process                 # in_process | http | other (prose below)
reset: ecto_sandbox                   # how a run gets a clean SUT
openapi:                              # only when composed with an OpenAPI spec
  path: priv/openapi.json
  sha256: "ab12..."                   # content hash at scaffold time
interview: complete                   # complete | checkpoint
missing: []                           # checkpoint only: what was not covered
```

`interview: checkpoint` + `missing:` is the resume mechanism: a later session
(possibly a different agent) must be able to continue from the spec alone.
On re-run, compare the OpenAPI hash: a mismatch means drift (diff the
operations, delta-interview the changes); a missing file means *ask whether it
moved* - never conclude the composition is gone.

## Sections, in order

### 1. System overview

Prose only. What the SUT is, the entities in scope and their lifecycles, and
where this model's boundary sits (what neighboring subsystems it deliberately
excludes). Interview context, not scaffold input.

### 2. Commands

One `###`-heading per command:

```yaml
name: PlaceOrder
semantics: sync            # sync | probe | async
fields:
  amount: "positive cents, typically < 10^6; hostile edge: exactly 0"
  currency: "ISO 4217 code from the supported set"
when: "at least one open account exists"
weight: 5
events: [OrderPlaced, OrderRejected]
```

Field values are **generator notes** in plain language, not StreamData code -
the scaffolder translates. `when:` is prose describing the precondition; the
scaffolder turns it into a guard over projection state. `events:` is the
simulate contract: everything this command can observably produce, including
deliberate rejections. Prose after the block: edge cases, failure behavior,
anything the user said that a maintainer would need.

### 3. Events

One `###`-heading per event:

```yaml
name: OrderPlaced
fields:
  order_id: external       # server-generated -> external() in the struct
  amount: from_command
  placed_at: external
```

Every event here must be produced by at least one command's `events:` list.

### 4. Projections

The command-sequence projection (what state it tracks and which commands'
guards or generators need it), then assertion projections. State exists only
because something gates on it or an invariant inspects it.

### 5. Invariants

One `###`-heading per invariant:

```yaml
name: no_negative_balance
kind: trigger              # trigger (immediate) | poll_state (eventual)
projection: BalanceInvariants
after: every_step          # or an event name; poll_state: settling time too
```

Prose: the assertion in domain language, and the severity of a violation.
Suggested-but-unadopted invariants do not go here - they go in section 7 as
deferred.

### 6. Known failure modes

Prose. Where the user suspects or fears bugs. Steers weights and generator
hostility toward where blood is expected.

### 7. Explicitly not modeled

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
