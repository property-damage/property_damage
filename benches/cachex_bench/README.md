# Cachex Bench

PropertyDamage exercised against [Cachex](https://hex.pm/packages/cachex), real
third-party software, as a self-contained mix project (`{:property_damage, path: "../.."}`).

What it validates:

- **The core loop end to end**: generation → simulation → adapter execution →
  projection updates → `@check` invariants, against a real cache rather than
  the framework's own test mocks.
- **Path equivalence**: `Incr k n` may run, per target, as itself or as two
  increments that add up to `n` (`expansions/0` in the model).
  `test/expansions_test.exs` runs two targets that choose independently, plants
  a bug only the two-step path exposes, and samples the choices with
  `mix pd.validate --seeds`.
- **Non-vacuity**: `test/seeded_bug_test.exs` runs the same model against an
  adapter with a deliberate bug (delete silently no-ops) and asserts that
  PropertyDamage finds it via the read-consistency invariant **and** shrinks it
  to a near-minimal reproduction (put → del → get, ≤ 5 commands).

Run it:

```bash
mix deps.get
mix test
```

Layout:

- `lib/cachex_bench/commands.ex` — events + five commands (put/get/del/clear/incr)
- `lib/cachex_bench/model.ex` — projection with the read-consistency invariant,
  simulator, model with the `Incr` expansion
- `lib/cachex_bench.ex` — the adapter against a real Cachex instance
