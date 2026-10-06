# DR-046: Boundary Observations, the Convergence Loop and Adapter Errors

**Status:** Accepted
**Date:** 2026-10-06

## Context

DR-044 and DR-045 compared the targets of a run by their events: each
variant's answer to a root, under `equivalence: :exact | :structural | fun`.
That comparison had four problems.

- A check runs inside one variant, so it gives no equivalence coverage: two
  variants can each pass every check and still disagree on what the model
  cares about.
- Events are what the adapter happened to return. The model, not the
  transport, is the specification of what must agree, and events carry
  identifiers, timestamps and ordering that no author wants compared.
- Events that differ once both sides have answered rarely change, so a
  comparison that waits for agreement would have waited the whole bound on
  them. A comparison that applies only to variants running the same concrete
  commands also switches itself off silently for variants on different
  paths.
- A differential run (the same commands on two systems) and a
  path-equivalence run (equivalent commands on one system) need one oracle,
  not two.

DR-045 also left one question open: whether an agreed adapter error is a
comparable observation.

## Decision

1. **Events are never compared across variants.** There is no default
   observation. The only cross-variant oracle is a boundary observation: a
   public projection function `def name(state, root)` marked `@compare`. Its
   key `{projection, name}` names every failure it causes. `equivalence:`,
   `compare: :correctness | :performance | :both` and `compare: [settle:]`
   are removed.
2. **`@compare` options.** A function carries one `@compare`, written above its
    first clause; a second on another clause is a compile error. `every:` is the schedule, with the vocabulary of
   `@check`: `1` (default), `N`, `{N, Module}`, `Module`, `[Modules]` and
   `:end` (alone or in a list). A key is compared at most once per boundary,
   and `:end` names the final boundary, which is compared after every variant
   finalized its run. `using:` is a 2-arity predicate called
   `using.(reference_value, variant_value)`. It returns `:match`,
   `{:mismatch, exception}` or a boolean, and defaults to `&==/2`. It may be
   any expression: a capture, a closure or a pipeline of
   `PropertyDamage.Equivalence` helpers. A `using:` that is not a 2-arity
   function is an error, at compile time when it is a literal and at run
   start otherwise.
3. **`{:pending, reason}`.** An observation returns `{:pending, reason}` when
   its variant will reach a comparable value with no further command, through
   asynchronous catch-up only. State that depends on a later command is a
   value, not a pending: both variants return the same "not yet" value and
   agree. A pending side is never a disagreement. A timeout is therefore
   always a finding: either the system is slower than the convergence bound,
   or the function claims a readiness it cannot reach.
4. **Vocabulary.**

   | Term | Meaning |
   |------|---------|
   | settle | one system catching up with itself per adapter call (the per-command `settle:` map) |
   | convergence, the convergence loop | the variants reaching agreement at a boundary |
   | the convergence bound | `converge_within:` |
   | time to converge | the measured duration |
   | did not converge | a side still pending at the bound (`:did_not_converge`) |
   | diverged | ready sides that differ at the bound (`:diverged`) |

   The loop ends by convergence, by divergence, or by the bound expiring with
   a side still pending; only the third is did not converge.
5. **The convergence loop runs at every scheduled boundary.** No boundary is
   skipped. Each iteration drains and folds every variant's event queue, runs
   the async checks, re-reads the root in every variant (the reference and the
   final boundary included) when the root is a `:probe` command, and
   evaluates every scheduled observation again. If every side is ready and
   equal, the boundary is done. At the final boundary the loop starts after
   finalization, so only a probe root still changes anything there.
6. **`compare: [converge_within: ms]`.** An integer of milliseconds,
   default `5_000`. The bound starts when the last variant arrived at the
   boundary and is checked between iterations, so a probe re-read that
   started before the bound runs to its own settle: the loop overshoots the
   bound by at most one iteration. Every report states the time waited.
   `settle:` under `compare:`, an atom and an unknown key are option errors
   that name `converge_within:`.
7. **Two outcomes at the bound.** A side still pending is `:did_not_converge`
   (`Failure.Convergence`: key, root, command, reason, time waited, bound). If
   no side is pending and ready sides differ, the failure is `:diverged`
   (`Failure.Divergence`: key, root, command, reference value, variant value,
   mismatch). With several keys failing at a boundary, the first in
   declaration order is reported, and within it a pending side wins over a
   difference.  Ready sides that differ are judged again until the bound,
   because a later event can still bring them into agreement.
8. **Cadence.** The loop evaluates again at most 50 ms after the last
   evaluation, and sooner when a drain delivered an event. A probe root is
   re-read no more than once per 50 ms, starting at once. Under `check_mode: :record` a variant whose check failed on
    a final re-read keeps re-reading with the others.
9. **`@eventually` has precedence.** A window that expires inside the loop is
   a check failure at once, at the command that opened it. A polling
   `@eventually` that has not expired does not block agreement.
10. **`ComparisonMismatch` and the helpers.** `PropertyDamage.ComparisonMismatch`
    is the default detail of a mismatch (`left`, `right`, optional message).
    `PropertyDamage.Equivalence` offers `by_key/1` (compare a key of each
    value), `normalize/1` (strip identifier and timestamp keys, unwrap
    `{:ok, _}` and `{:error, _}`) and `drop_keys/2` (remove keys at every
    depth). A raise in a `@compare` function or in a `using:` predicate is a
    check failure in the variant it ran for, naming the key, never a
    divergence.
11. **`==` is a trap in five ways.** The default predicate is what
    `assert a == b` uses, so authors expect it, and it produces a false
    divergence in five cases. (a) Lists are ordered, so an observation that
    returns a list whose order is not part of the contract diverges when
    injector-delivered events were folded in a different order per variant;
    return a map or a set, or compare through `by_key(&Enum.sort/1)`. The
    framework never sorts silently, because order is sometimes the property
    under test. (b) Keyword lists compare as lists. (c) `==` coerces numbers:
    `100 == 100.0`, which hides an integer-cents against float difference;
    use `&===/2` when the representation matters. (d) Value structs
    (`Decimal`, `Money`, `DateTime`) compare field by field, so `1.0` and
    `1.00` as decimals differ, and so do two `DateTime` values that differ in
    precision or zone; compare a key under `by_key/1`. (e) Floats differ in
    the last bit across implementations; use a tolerance predicate. Server
    minted identifiers and timestamps cause the same false divergence in any
    of these cases: leave them out of the observation or strip them with
    `normalize/1`.
12. **Counters.** For every declared key the run keeps `compared_at`
    (boundaries compared), `waited_at` (boundaries at which the key did not
    agree at some judgement) and `waited_ms` (the time spent waiting). They
    are `compare_counts` on the stats of a passing run and on the failure
    report, printed by the reporter, and persisted.
13. **The no-observation guard.** A run with two or more targets whose model
    declares no `@compare` is an error at run start, before any adapter setup:
    without an observation the variants would never be compared and the run
    would pass vacuously. With one target the `@compare` functions are not
    called.
14. **`latency: true` measures.** The old `compare: :performance | :both` is
    replaced by `latency: true | false` (default `false`), which measures each
    target's latency per command. It requires `concurrency: :serial`.
15. **The failure name.** For `:diverged` and `:did_not_converge` the failure
    name is the `@compare` key. It is the shrinker identity's name, so
    `{kind, key, variant_index}` identifies the failure and a candidate that
    fails on another observation is rejected. The mismatch is detail. A
    `:did_not_converge` failure is shrunk like any other.
16. **Adapter errors are final.** `:execution_failed` is a failure for an
    adapter raise and for an adapter `{:error, _}` answer at a root, in every
    mode, and is never an observation. A failure of the reference stops the
    run. A failure of a non-reference variant retires that variant at once:
    its pollers are finalized, its `:teardown` checks and `Adapter.teardown/1`
    run before the next root, and the other variants go on. The run stops when
    no non-reference variant remains. The report names a primary failure, the
    first in root order and then in target order, and lists the rest in
    `other_failures`. Every run, with or without a retired variant, orders its failures by one
    rule: root, then target, then when it happened within that root and target
    (a check recorded under `check_mode: :record` while the root was stepped,
    then the comparison failure at that root's boundary, then a failure found
    while the target finalized). A failure with no root found at the end of the
    run comes after every rooted failure, in target order. A finalize-time
    repeat of a failure already found is listed once, and nothing is dropped.
    The primary failure is the only shrink target; a
    candidate is judged by its primary failure alone. The choice among failures
    of one root depends on target order, since the first target is the
    reference and the others are compared in order.
17. **Stutter.** The retry comparison of `stutter:` is the same predicate:
    `using:` with the contract of item 2, called
    `using.(original_events, retry_events)`, default `&==/2`. The `comparison:`
    atoms and tuples (`:strict`, `{:structural, _}`, `{:custom, _}`),
    `:acceptable` and the command key `acceptable_retry_events:` are removed:
    a command that may answer a retry differently is handled by a `using:`
    that accepts that answer.
18. **Persistence version 10.** Failure reports and traces are version 10. A
    report carries `compare` (`[converge_within: ms]`, replacing
    `equivalence`), `compare_counts` and `other_failures`. Loaders refuse
    version 9 and older. `shrink_further/2` re-shrinks under the report's
    `compare`, accepts `compare:` and rejects `equivalence:`.

## Consequences

- A model that runs two or more targets must say what has to agree. A model
  author writes that once, as `@compare` functions beside the projection that
  holds the state, and the same functions serve a differential run and a
  path-equivalence run.
- A comparison waits only for what an observation can still change: a
  pending side, or a difference that a late event may remove, each up to the
  bound. An observation that agrees at once costs no wait.
- Code that read `report.equivalence`, `Failure.Divergence.reference_result`
  or `divergent_result`, or passed `equivalence:`, `compare: :correctness`
  or Stutter `comparison:`, must change. The CHANGELOG lists each removed
  name.
- A run whose adapter answers `{:error, _}` fails with `:execution_failed`
  where an agreed error used to pass. A latency run reports no error count
  from an adapter error, because such an error ends the run.
- Persisted version 9 reports and traces are refused.

## Alternatives considered

- **Keep a default event observation, structural by default.** Rejected: it
  puts transport detail in the oracle, waits on mismatches that cannot
  change, and does not apply to variants on different paths.
- **A library projection that re-creates event comparison on an opt-in
  basis.** Considered and not shipped: an author who wants it writes the
  observation, and then it names what matters.
- **Keep per-variant checks as the only oracle.** Rejected: they give no
  equivalence coverage.
- **Treat an agreed adapter error as an observation.** Rejected: a business
  rejection is an event, so an error answer means the adapter could not do
  its job, and two variants failing alike is still a failed run.
- **One word for the per-call and per-boundary waits.** Rejected: `settle:`
  bounds one adapter call and `converge_within:` bounds one boundary, and a
  report that says "did not converge" must leave no doubt which bound expired.

## Open questions

- A budget grammar for `latency:` (a threshold per target) is not decided;
  `latency: true` measures only.
- Branching sequences run with one target only.
