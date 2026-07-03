# Deterministic Generation

PropertyDamage generates a command sequence as a **pure function of the seed**.
Reproducing a failure with `mix test ... seed: N`, and comparing two runs of the
same plan, both depend on that purity. This guide states the contract, shows the
three blessed ways to model nondeterministic needs without breaking it, and
points at the audit that enforces it.

## The determinism contract

> Generation MUST be a pure function of `(seed, model, generation options)`.

Concretely, the following code runs during the **symbolic phase** and MUST be
free of side effects and ambient reads:

- command generators (`generator/1`),
- `when:` and `with:` predicates in the model's command list,
- the `command_sequence_projection`, and
- the `simulator`.

None of them may read the wall clock (`DateTime.utc_now/0`, `System.system_time/0`),
process or global randomness (`:rand`, `System.unique_integer/1`, `UUID.uuid4/0`),
ETS, the process dictionary, or any other state that varies within a VM. All
nondeterminism belongs behind an **execution-time seam** (the adapter, or
`mint_per_run/1`), never in generation.

Realize generated values only through the seeded path. The framework does this
for you via `PropertyDamage.Generator.generate_value/3`, which consumes a
generator through `StreamData.seeded/2` at a constant size. Never `Enum`-consume
a raw generator yourself: `Enum.at(generator, 0)` seeds `StreamData` from the
wall clock and silently breaks reproducibility.

### Why it matters

When generation is pure:

- **`seed: N` reproduces exactly.** Re-running a reported seed regenerates the
  identical failing sequence.
- **Run comparison works.** `PropertyDamage.RunComparison` (DR-035) recognizes
  two captured runs as the same plan via a plan fingerprint (DR-036). If two
  "same seed" generations differ, the comparability guard refuses every
  comparison for that model.

When it is impure, both break: the reported seed stops reproducing, and the
fingerprint guard rejects the model with a cryptic message. The audit below is
the actionable early warning for exactly that failure.

### Enforcement: `mix pd.audit`

Run the audit against your model in development and CI:

```bash
mix pd.audit MyApp.Model
mix pd.audit MyApp.Model --seeds 500 --max-commands 40
mix pd.audit MyApp.Model --branching --branch-probability 0.3
```

It realizes your model's generated sequence twice at each of N seeds and checks
the two are structurally identical. On divergence it prints the first diverging
seed and the first differing command position and fields, then exits non-zero so
CI gates on it. The programmatic form is `PropertyDamage.audit/2`.

The audit is generation-only: no adapter, no SUT, no execution. It never
resolves `mint_per_run` markers or `external()` placeholders (those are
deterministic symbolic structs and part of the plan).

## The three seams

Real systems need time, per-run uniqueness, and server-assigned ids. Each has a
deterministic pattern. Pick by **who produces the value**.

### 1. Time-dependent SUTs: a seeded relative offset, reified in the adapter

A SUT with timeliness requirements (a JWT `exp`, a token TTL) tempts you to bake
absolute time into a generator. Don't: the value differs on every generation.

```elixir
# ANTI-PATTERN: absolute time baked in at generation → non-deterministic,
# breaks `seed: N` reproduction and fails the plan-fingerprint guard.
def generator(_overrides) do
  StreamData.constant(%{exp: DateTime.utc_now()})
end
```

Instead, generate a **seeded relative offset** and reify absolute time in the
adapter at execution:

```elixir
# PATTERN: the plan carries only the offset — deterministic and seed-stable.
def generator(_overrides) do
  StreamData.bind(StreamData.member_of([-3600, -60, -1, 60, 3600, 86_400]), fn offset ->
    StreamData.constant(%{exp: {:relative_seconds, offset}})
  end)
end

# The adapter performs the ONE wall-clock read, at execution time:
def execute(%IssueToken{exp: {:relative_seconds, off}}, ctx) do
  exp = DateTime.add(DateTime.utc_now(), off, :second)
  # ... send `exp` to the SUT ...
end
```

The command (and the plan) carries only the offset, so it is byte-identical
across two same-seed runs. The wall-clock variance lives in the *resolved*
concrete value at execution, exactly where a JWT-validity divergence should
surface: in the event log and in run-comparison rows.

### 2. Client-minted unique values: `mint_per_run/1`, not `UUID.uuid4/0`

An idempotency key or request UUID that must be **unique per run** against a SUT
you cannot reset is the second classic contract-breaker. `UUID.uuid4/0` in a
generator destroys plan determinism: every generation differs.

```elixir
# ANTI-PATTERN: a fresh UUID each generation → the plan is never the same twice.
def generator(_overrides) do
  StreamData.constant(%{request_id: UUID.uuid4()})
end
```

Use `PropertyDamage.mint_per_run/1` (DR-034). The field carries a
position-stamped **marker** during generation (so the plan stays pure and
positionally identical across runs), and the concrete value is derived at
execution from the recorded `(run_nonce, mint_epoch, position, path, kind)`:

```elixir
# PATTERN: a deterministic marker in the plan; unique-per-run value at execution.
def generator(_overrides) do
  StreamData.constant(%{request_id: PropertyDamage.mint_per_run(:uuid)})
end
```

The result is unique per run yet byte-reproducible when the nonce and epoch are
pinned. Hold `(seed, run_number)` and vary the nonce to re-run the identical
plan with fresh minted values on a shared SUT.

### 3. Server-assigned output: `external/0`

Ids the **SUT returns** (an order id assigned on create, later read back) are
captured with `external/0`. Mark the field on the *event* the SUT produces; the
framework replaces it with a resolvable placeholder during generation and
resolves it from the recorded server output at execution:

```elixir
defmodule OrderCreated do
  import PropertyDamage, only: [external: 0]
  defstruct [:total, id: external()]
end
```

A later command can consume that placeholder (see the
[writing commands guide](writing_commands.md)); the placeholder's identity is a
deterministic function of its generation coordinates (DR-036), so an
`external()`-using model is still a pure function of the seed and passes the
audit.

> **`external/0` is NOT the seam for time or client-minted values.** It is for
> values the SUT *produces*, not values the client *computes or sends*. Use the
> relative-offset pattern for time and `mint_per_run/1` for client-minted
> uniqueness.

## Choosing a seam

| Need | Seam | Where the value is produced |
|------|------|-----------------------------|
| Time (JWT `exp`, TTL) | Seeded relative offset in the plan; adapter reifies at execution | Client, at execution |
| Client-minted uniqueness (request id, idempotency key) | `mint_per_run/1` | Client, minted from recorded run inputs |
| Server-assigned output (ids the SUT returns) | `external/0` | Server, captured from the SUT |

## Related: detecting cross-version drift

`mix pd.audit` catches *intra-version* nondeterminism: an impure generator, now.
Detecting *inter-version drift* — a model edit that changes what seed N
generates between releases — is adjacent but different machinery. The plan
fingerprint (`RunTrace.plan_fingerprint/1`, DR-036) is the natural stored-golden
representation, and `RunComparison`'s guard already refuses to compare traces
whose plans drifted across commits. See the
[static regression tests guide](static_regression_tests.md).
