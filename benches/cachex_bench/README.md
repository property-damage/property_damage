# Cachex Bench

PropertyDamage exercised against [Cachex](https://hex.pm/packages/cachex), real
third-party software, as a self-contained mix project (`{:property_damage, path: "../.."}`).

What it validates:

- **The core loop end to end**: generation → simulation → adapter execution →
  projection updates → `@trigger` invariants, against a real cache rather than
  the framework's own test mocks.
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

- `lib/cachex_bench/commands.ex` — events + four commands (put/get/del/clear)
- `lib/cachex_bench/model.ex` — projection with the read-consistency invariant,
  simulator, model
- `lib/cachex_bench.ex` — the adapter against a real Cachex instance
