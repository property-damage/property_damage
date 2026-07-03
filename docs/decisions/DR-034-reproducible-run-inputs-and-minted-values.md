# DR-034: Reproducible Run Inputs and Client-Minted Run-Scoped Values

**Status:** Accepted
**Date:** 2026-07-02

> Part of the run-comparison campaign (with DR-033, DR-035, DR-036). This
> record reconciles two goods that pull in opposite directions: determinism
> ("same seed → same everything") and per-run uniqueness (a UUID you send to
> a SUT you cannot reset must differ from the one you sent last run).

## Decision

### 1. Three run inputs: `seed`, `run_number`, `run_nonce`

The plan axis is unchanged: one base seed (`opts[:seed]`), explored by
`run_number`, with `effective_seed = Generator.run_seed(seed, run_number)`
and the plan a pure function of the effective seed. The **`run_nonce`** is a
new, separate axis: a 64-bit integer, independent of plan generation, that
seeds *only* the resolution of run-scoped minted values (§2). Holding
`(seed, run_number)` fixed while varying `run_nonce` executes the identical
plan with fresh minted values (flakiness investigation on a shared SUT);
pinning all three reproduces a run byte-exactly against a pristine SUT.
Models that declare no minted fields are entirely unaffected by the nonce.

Resolution order for both `seed` and `run_nonce`: explicit option, else
environment variable (`PD_SEED`, `PD_RUN_NONCE` — added because `mix test`
cannot forward custom flags), else a random default. All three inputs are
recorded on the trace (DR-033) and report, so the normal reproduction path
is replay from the artifact, with the env vars as the ad-hoc CLI channel.

**The nonce's random default MUST NOT come from the process RNG.** ExUnit
seeds each test process's `:rand` from the suite seed
(`ExUnit.Runner` seeds `:rand` with a hash of module, test name, and seed),
so a `:rand.uniform/1` default — the idiom the seed default uses today at
`property_damage.ex:304` — is silently pinned the moment a user reruns with
`mix test --seed N` to reproduce a plan. A pinned nonce re-mints the same
UUIDs against the non-resettable SUT and manufactures the phantom
"duplicate id" collision the random default exists to prevent. The default
is therefore drawn from entropy independent of `:rand` —
`:crypto.strong_rand_bytes(8) |> :binary.decode_unsigned()` — and recorded.
(The determinism contract is untouched: the prohibition on unrecorded
entropy applies to *value resolution*; choosing the recorded nonce itself
may use any entropy source.) 64 bits rather than the seed's `1..10^9`
because investigations mint many nonces and birthday collisions at 10^9
start at tens of thousands of draws.

### 2. `mint_per_run/1`: client-minted, run-scoped values

A command generator may mark a field
(`%{request_id: PropertyDamage.mint_per_run(:uuid), ...}`) as run-scoped:
minted client-side at execution rather than fixed at generation.
`mint_per_run` contrasts with `external/0`: `external` captures a value the
SUT returns; `mint_per_run` mints a value the client sends.

- **Symbolic phase:** the field holds a reified marker struct, not a value,
  so the plan remains a pure function of the effective seed and positionally
  identical across runs sharing it. At generation the marker is stamped with
  its coordinates — the structured generation `%Sequence.Position{}` and
  field path — per DR-036's identity scheme. **The executor's flat
  `command_index` is explicitly not the key:** sibling parallel branches
  share flat indices (each branch numbers from `start_index`, exactly the
  collision DR-021 documents for capture), so a flat-index key would mint
  identical "unique" values in two branches of one run — the very
  duplicate-identity bug this feature exists to prevent. Baking coordinates
  in at generation also makes a command's minted value stable under
  shrinking, since the marker travels inside the command struct that the
  shrinker preserves.
- **Concrete phase:** the marker resolves in the same seam that resolves
  placeholders (the executor's resolution pass, and
  `PlaceholderRegistry.resolve_data/2` for the Differential/LoadTest paths).
  The value is a pure function of
  `(run_nonce, mint_epoch, position, path, kind)`:
  `bytes = :crypto.hash(:sha256, :erlang.term_to_binary(tuple, minor_version: 2))`,
  then a kind-specific formatter. Never `UUID.uuid4/0`, `:rand` at call
  time, or wall-clock reads. `:erlang.phash2/2` was considered and rejected
  as the derivation: it yields at most 32 bits, which both collides too
  easily and cannot fill a 128-bit UUID honestly.
- **Kinds are named, high-entropy, and closed over data:**
  `mint_per_run(:uuid)` (16 derived bytes with RFC 4122 version/variant bits
  set), `mint_per_run({:hex, n})`, and an escape hatch
  `mint_per_run({module, function})` where the function receives the derived
  bytes and returns the value. Anonymous-function forms are rejected:
  markers persist inside plans and traces (DR-033), and anonymous funs do
  not survive `binary_to_term` across recompiles. High entropy is not
  cosmetic — provenance classification of *event* fields recognizes minted
  echoes by value (§3), which is only sound when accidental equality is
  negligible.

### 3. `mint_epoch`: uniqueness across executions inside one logical run

A "run" is not one SUT execution. Shrinking re-executes the sequence dozens
to hundreds of times; the report's minimal reproduction is re-executed once
more; replay re-executes it again later. With position-stable minted values
(§2) and one nonce, every one of those executions would re-send the same
UUIDs — on a non-resettable SUT, the attempts collide with the original run
and with each other, the failure signature mutates mid-shrink, and the
shrinker falls back to "could not reproduce". Therefore each SUT execution
within a logical run carries a **`mint_epoch`** (decided in design review,
2026-07-02, over the alternative of declaring non-resettable-SUT shrinking
out of scope): epoch 0 is the recorded exploration run; the shrinker
increments the epoch per attempt; the report's reproduction execution and
each replay get fresh epochs by default. The effective mint input is
`(run_nonce, mint_epoch)`, both recorded on the resulting trace/report, so
byte-exact reproduction pins both while default replay stays collision-free.
Minted values are run-scoped noise by definition, so differing values across
epochs cannot affect failure equivalence — any assertion that depended on a
specific minted value would be a model bug.

Engine notes: `Differential` executes one plan against N targets *within*
one run — all targets share the run's `(nonce, epoch)`, so every target
receives byte-identical client requests (correct like-for-like).
`LoadTest` workers are separate executions and derive distinct epochs.
`investigate` (DR-035) uses a fresh recorded nonce per run.

### 4. Value provenance classification

Every value in a run's executed commands and events is classifiable into
three classes, and the classification is derived **structurally at
consumption time** — no per-value tag is stored on `EventLog.Entry`:

- `plan-generated` — a pure function of the effective seed.
- `run-scoped` — minted via `mint_per_run`; a function of the nonce/epoch.
- `server-resolved` — produced by the SUT (captured via `external()` or
  simply observed in SUT output).

Concrete rules, which the earlier draft left command-centric and
underspecified for events:

- **Command fields** (from the plan + trace `executed`): a field whose plan
  value is a mint marker → `run-scoped`; a field whose plan value is a
  `%Placeholder{}` → `server-resolved` (it was filled from SUT output); all
  else → `plan-generated`.
- **Event fields** (from the event log): a path in
  `External.external_paths(event_module)` → `server-resolved` by
  definition; a field whose value is a member of this run's minted-value set
  → a `run-scoped` **echo** (the SUT reflecting back a correlation id;
  value-membership is sound because kinds are high-entropy, §2); all else →
  observed SUT output, treated as `server-resolved` for comparison purposes.
- The "differing `plan-generated` value ⇒ incomparable" tripwire (DR-035)
  applies to **command fields only** — event fields are never
  plan-generated.

Interpretation contract for consumers: a cross-run difference in a
`run-scoped` value is expected by design (a correlation id, never
suspicious); in a `server-resolved` value it is an observed behavioral
difference (the analysis subject); in a `plan-generated` value it is a
comparability violation (the runs are not executing the same plan).

## Context

There is one base seed and the framework explores by run number; the plan is
already a pure function of the effective seed. What the framework could not
express is a value that must be *unique per run yet reproducible*: a client-
minted idempotency key or request UUID sent to a SUT that survives between
runs. Users hardcode `UUID.uuid4/0` in generators today, which destroys
plan determinism (every generation differs) and is invisible to any
comparator. The nonce/mint design carves exactly that class of value out of
the plan while keeping it recorded and replayable, and the provenance
classes give run comparison (DR-035) the semantics it needs to separate
correlation noise from behavioral signal. A deterministic nonce default of
`0` was rejected in the original design sketch for colliding with the prior
run's residue; this record additionally closes the subtler ways the same
collision re-enters (process-RNG default under `--seed`; flat-index keying
under branching; epoch-less re-execution under shrinking).

## Consequences

- `property_damage.ex` `run/1`: nonce acquisition (opt/env/strong-random)
  beside the seed, `PD_SEED` added for symmetry, both threaded through
  `do_run`/`run_loop` and recorded.
- New marker struct + `PropertyDamage.mint_per_run/1`; generator reifies
  markers with position/path during instantiation (same pass that
  instantiates placeholders); both executor-private resolution and
  `PlaceholderRegistry.resolve_data/2` learn to resolve markers (the two
  parallel resolution engines are pre-existing friction — unifying them is
  desirable but optional here).
- `Executor.run` accepts `mint_epoch:` (default 0); the shrinker threads an
  attempt counter; `Replay` defaults to a fresh epoch with an option to pin.
- Provenance is computed by the comparator from plan + trace + event-module
  external paths; nothing new is stored per entry.
- Failing-first tests: same `(seed, run_number)` + different nonce ⇒ equal
  fingerprints, different minted values; same triple ⇒ byte-identical
  values; no minted fields ⇒ nonce inert; two same-index sibling-branch
  mints ⇒ distinct values; shrink attempts ⇒ distinct epochs.

## References

- `openspec/specs/execution-engine/spec.md` (Reproducible Run Inputs),
  `openspec/specs/command/spec.md` (Client-Minted Run-Scoped Values; Value
  Provenance Classification).
- Depends on DR-036 (identity scheme). Feeds DR-033 (trace identity fields)
  and DR-035 (comparability guard, provenance-aware highlighting).
- Related: DR-011/DR-021 (`external()` capture — the server-side mirror of
  minting), DR-029 (explicit RNG threading precedent).
