# DR-052: A Check's Verdict Is Its Return Value

**Status:** Accepted
**Date:** 2026-10-16

## Context

A `@check` function passed when it returned, whatever it returned; the only
failure was a raise, usually through `PropertyDamage.fail!/2`. A check
written as a predicate, `def net_covers_fees(state, _), do: state.net >=
state.fees`, therefore passed on `false`, silently.

An `@eventually` function returns a predicate that `PropertyDamage.StatePoller`
calls on every poll. The poller judged the predicate's answer by truthiness:
`nil` and `false` meant "not yet", anything else meant satisfied. So the two
kinds disagreed on what `false` means. Two more gaps sat on the eventually
path. The poller received the `@eventually` function's return without checking
that it is a function: a function that returned a boolean made every poll
raise `BadFunctionError` inside the poller's rescue, log a warning, and the
window timed out with a report that read "never became true". And a raise
inside the predicate was treated as "not yet": the poller rescued it, kept it
as `last_predicate_error`, and polled on until the window expired, so a
predicate with a wrong key or a non-exhaustive head cost the whole window per
trigger and surfaced as a timeout.

The precedent for "the return is the verdict" is the predicate callback:
`Enum.filter/2`, and in this library the command `when:` precondition and the
eventually predicate itself, both judged by truthiness. ExUnit's `assert`
judges one expression the same way (`nil` and `false` fail, everything else
passes) but ignores a test body's return; a `@check` function is closer to a
predicate than to a test body, and this record chooses the predicate rule.

## Decision

1. **A `@check` passes on a truthy return and fails on `nil` or `false`.** The
   failure is a check failure like a raise, with the same state snapshot. A
   raise is still a failure, and `fail!/2` is still how a check attaches a
   message and details from inside a body. The rule holds for `every:` and
   `at:` checks and in every runner: the executor, forensics and the
   load-test worker.
1a. **One verdict grammar for the three kinds**, read by one function
   (`PropertyDamage.Verdict.read/1`, which replaces
   `PropertyDamage.Equivalence.verdict/3`) in every runner, the poller and
   the convergence loop:

   | Return | `@check` | `@eventually` predicate | `using:` relation |
   |--------|----------|-------------------------|-------------------|
   | truthy | pass | satisfied | agree |
   | `nil`, `false` | fail, generic message | not yet | disagree, both values |
   | `{:fail, "text"}` | fail, that message | never: fail now, that reason | disagree, that message |
   | `{:fail, %Exception{}}` | fail, that exception | never: fail now, that exception | disagree, that exception |
   | raise | fail, the exception | fail, the exception | fail in that variant, the exception |
   | bare exception struct, `{:error, _}` | fail, with the grammar nudge | same | same |

   A string reason is wrapped in `CheckFailed` (checks, predicates) or
   `ComparisonMismatch` (relations) so the report has one shape whichever
   form the author chose. `{:fail, reason}` is the returned form of
   `fail!/2`: raising is the early exit, returning is the tail. The tag is
   `:fail`, not `:error`, because a verdict is a protocol return read by this
   library alone, like `{:cont, _}`/`{:halt, _}` in `Enum.reduce_while/3`,
   and an error tuple means something broke. `:match` and `{:mismatch, _}`
   are retired (DR-046 item 2 and item 10).
1b. **Two non-verdict shapes fail with a nudge.** A bare exception struct and
   an `{:error, _}` tuple cannot have meant "pass" and would otherwise be
   truthy; the reader fails on them carrying the value, plus one sentence:
   "a verdict is truthy, `nil`/`false`, or `{:fail, reason}`". One taught
   form, no silent pass.
1c. **Composition.** A verdict is a final value, never a boolean: `&&`,
   `||`, `!` and `Enum.all?/2` see a `{:fail, _}` as truthy. Sub-checks
   compose with `with true <- balance_ok(a), true <- limit_ok(a), do: true`,
   or with a raising helper under `Enum.each/2`. The guides show both and
   name the trap.
2. **The `if condition, do: fail!(...)` idiom is retired**, because it
   returns `nil` when the check passes. A check is written as a predicate
   (`state.net >= state.fees`), as `condition or fail!("...", ...)` when it
   needs a message, or as a body that ends with a truthy value (`:ok`, the
   result of `Enum.each/2`, `true`). Every check in the repository, the
   guides, the moduledocs and the `mix pd.gen.*` templates follows the rule.
3. **The retired idiom is a compile error.** At `@on_definition` the
   projection reads each `@check` clause's body; a clause whose last
   expression is an `if` or `unless` without `else` is refused with a
   `CompileError` naming the clause and the rewrite ("`net_covers_fees/2`
   ends in `if` without `else`, which returns `nil` when the check passes;
   write `condition or fail!(...)`"). This is a guard for the one taught
   shape, not a proof: a `nil` from a lookup still surfaces at run time, which
   is where it belongs.
4. **The verdict failure message teaches the rule.** It names the check,
   shows the returned value and gives the three accepted forms of item 2 in
   one line: "check `net_covers_fees` returned `nil`; a check passes by
   returning a truthy value: a predicate, `condition or fail!(...)`, or a body
   that ends with `:ok`".
5. **An `@eventually` function must return a 1-arity function.** Any other
   return is a check failure at once, at the step that triggered the check,
   naming the check and the value.
6. **The predicate returns a verdict.** `nil` and `false` mean "not yet";
   `{:fail, reason}` means "never": the window ends at once as a check
   failure with that reason (a payment that reached `:failed` no longer waits
   out the timeout to report "never became `:confirmed`"); any other value
   means satisfied. A raise inside the predicate is a check failure at once,
   naming the check, the poll count and the exception, never "not yet". An exit or throw inside the
   predicate is caught and reported the same way, so the poller never kills
   the run. "Not yet" is written as a falsy return: the documentation teaches
   total predicates over the projection state (`get_in/2`, `match?/2`, a
   pattern with a fallback clause) and a timeout report reads "never became
   true" with nothing else to explain.
7. **One verdict vocabulary for the three kinds.** A `@check` judges its
   return now. An `@eventually` judges its predicate's return within the
   window. A `@compare` judges its return against the reference's through the
   relation (DR-051), whose return is read by the same grammar. In all three
   a raise is a failure and `{:fail, reason}` is the reasoned failure.

## Consequences

- Breaking: a check that returned `nil` or `false` and passed now fails, at
  its first run or, for the retired idiom, at compile time, so no consumer
  migrates silently. The CHANGELOG lists the change as BREAKING with the
  three accepted forms of item 2.
- Every check of the `if ..., do: fail!` form in the repository is rewritten;
  at the time of this record there were about forty one-line instances and
  further multi-line ones across the library, the guides and the tests.
- Breaking for eventually predicates that relied on a raise meaning "not
  yet" (`s.payments[id].status == :confirmed` before the payment exists):
  they fail at the first poll with the exception, and are rewritten as total
  predicates. A predicate bug now costs one poll, not one window per trigger.
- `StatePoller` drops `last_predicate_error`; its rescue and catch clauses
  convert to a failure message instead of continuing.
- A predicate is the shortest check, and it is now correct; `condition ||
  {:fail, "reason"}` is the shortest reasoned one.
- Relations change their rich form from `{:mismatch, detail}` to
  `{:fail, detail}`; the `using:` migration of DR-051 carries it, so `using:`
  changes once. `Equivalence.verdict/3` is replaced by `Verdict.read/1`.
- An `@eventually` window can end by verdict; the eventual-consistency spec,
  the poller and the report distinguish "never" from a timeout.
- No new failure kind and no persistence change: the verdict failure is a
  check failure with a message.

## Alternatives considered

- **Fail on `false` only; `nil` keeps passing.** Rejected: `nil` is what a
  missed map lookup or an `&&` chain returns, so it is the silent pass to
  close, and a loud first-run failure is cheaper than a silent one.
- **Keep the raise-only contract (a `@check` is a test body).** Rejected: a
  predicate check passes on `false`, which no reader of the check expects.
- **Require `:ok | {:error, reason}` returns.** Rejected: a predicate is the
  natural check, and `:ok` is truthy anyway, so the truthiness rule contains
  this one.
- **Keep a raise inside the eventually predicate as "not yet".** Rejected:
  it hides a predicate bug behind a timeout, spends the window on every
  trigger, and makes a raise mean two different things in two attributes.
  Retry-on-assertion helpers in test libraries exist because their predicate
  is written with `assert`; here the predicate returns a value, so a falsy
  return is the one spelling of "not yet".
- **A bare exception struct as the reasoned failure ("a falsy Failure").**
  Rejected: Elixir truthiness is closed to `nil` and `false`, so the struct
  is truthy in every `&&`, `if` and `Enum.all?/2`; a returned exception has
  no precedent outside a tuple; and `PropertyDamage.Failure.*` already names
  the report's failure records.
- **`{:error, reason}` as the tag.** Rejected: it borrows the general error
  convention for a verdict, reads as "the comparator broke" on a relation,
  and gains nothing, since no code outside this library matches a verdict
  and `with` composes on any tag.
- **A heuristic that detects every `nil`-returning body.** Rejected: not
  decidable at compile time; the guard covers the taught idiom and the run
  time message covers the rest.
