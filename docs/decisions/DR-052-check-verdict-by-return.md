# DR-052: A Check's Verdict Is Its Return Value

**Status:** Accepted
**Date:** 2026-10-16

## Context

A `@check` function passed when it returned, whatever it returned; the only
failure was a raise, usually through `PropertyDamage.fail!/2`. A check
written as a predicate, `def net_covers_fees(state, _), do: state.net >=
state.fees`, therefore passed on `false`, silently.

An `@eventually` function returns a predicate that `PropertyDamage.StatePoller`
calls on every poll. The poller judges the predicate's answer by truthiness:
`nil` and `false` mean "not yet", anything else means satisfied. So the two
kinds already disagreed on what `false` means. The poller also received the
`@eventually` function's return without checking that it is a function: a
function that returned a boolean made every poll raise `BadFunctionError`
inside the poller's rescue, log a warning, and the window timed out with a
report that read "never became true".

ExUnit's `assert` fails on `nil` and `false` only ("Expected truthy, got
..."), and every Elixir author knows that rule.

## Decision

1. **A `@check` passes on a truthy return and fails on `nil` or `false`.** The
   failure is a check failure like a raise, with a message that names the
   check and the value ("check `net_covers_fees` returned `false`") and the
   same state snapshot. A raise is still a failure, and `fail!/2` is still
   how a check attaches a message and details. The rule holds for `every:`
   and `at:` checks and in every runner: the executor, forensics and the
   load-test worker.
2. **The `if condition, do: fail!(...)` idiom is retired**, because it
   returns `nil` when the check passes. A check is written as a predicate
   (`state.net >= state.fees`), as `condition or fail!("...", ...)` when it
   needs a message, or as a body that ends with a truthy value (`:ok`, the
   result of `Enum.each/2`, `true`). Every check in the repository, the
   guides, the moduledocs and the `mix pd.gen.*` templates follows the rule.
3. **An `@eventually` function must return a 1-arity function.** Any other
   return is a check failure at once, at the step that triggered the check,
   naming the check and the value. The predicate's own verdict stays
   truthiness, and a raise inside the predicate stays "not yet" with the
   error kept for the timeout report, as before.
4. **One verdict vocabulary for the three kinds.** A `@check` judges the
   truthiness of its return now. An `@eventually` judges the truthiness of
   its predicate's return within the window. A `@compare` judges its return
   against the reference's through the relation (DR-051).

## Consequences

- Breaking: a check that returned `nil` or `false` and passed now fails, at
  its first run, so no consumer migrates silently. The CHANGELOG lists the
  change as BREAKING with the three accepted forms of item 2.
- Every check of the `if ..., do: fail!` form in the repository is rewritten;
  at the time of this record there were about forty one-line instances and
  further multi-line ones across the library, the guides and the tests.
- A predicate is the shortest check, and it is now correct.
- No new failure kind and no persistence change: the verdict failure is a
  check failure with a message.

## Alternatives considered

- **Fail on `false` only; `nil` keeps passing.** Rejected: `nil` is what a
  missed map lookup or an `&&` chain returns, so it is the silent pass to
  close, and the ExUnit rule is the one authors already know.
- **Keep the raise-only contract.** Rejected: a predicate check passes on
  `false`, which no reader of the check expects.
- **Require `:ok | {:error, reason}` returns.** Rejected: a predicate is the
  natural check, and `:ok` is truthy anyway, so the truthiness rule contains
  this one.
