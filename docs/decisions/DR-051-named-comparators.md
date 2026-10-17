# DR-051: Named Comparators, `using:` Is a Name

**Status:** Accepted
**Date:** 2026-10-16

## Context

DR-046 made `@compare using:` "any expression: a capture, a closure or a
pipeline of `PropertyDamage.Equivalence` helpers". A module attribute cannot
hold a local capture or a closure, so `use PropertyDamage.Model.Projection`
replaced `Kernel.@/1` inside projection modules with its own `@/1`
(`PropertyDamage.Model.Projection.CompareAttribute`), which kept the options
of `@compare` as code and forwarded every other attribute. That mechanism had
five costs.

- `@compare` was the only one of the three check attributes with a mechanism
  of its own; `@check` and `@eventually` are plain attributes read at
  `@on_definition`.
- A projection module could not import another `@/1` macro, and a `@compare`
  that another `@/1` handled registered no observation; a compile-time guard
  was needed to turn that silent drop into an error.
- Every `@doc`, `@spec` and `@impl` in every projection passed through the
  library's macro.
- A relation written as a closure cannot be printed in a failure report or
  recorded in a replay artifact; it prints as `#Function<...>`.
- The documentation taught normalization through `using:`
  (`by_key(fn v -> v |> normalize() |> drop_keys([:fees]) end)`) when the
  observation body can return the canonical value itself, so that each
  target normalizes its own value and the report shows what was compared.

Of the `@compare` declarations in the repository at the time of this record,
about one in eight carried a `using:`; the rest compared under `==`.

## Decision

1. **`@compare` is a plain module attribute.** It is read like `@check` and
   `@eventually`, at `@on_definition`. The `@/1` replacement, the
   `CompareAttribute` module and the compile-time guard for a `@compare`
   handled by another `@/1` are removed, with their tests and the two
   documentation sentences about the `@/1` conflict.
2. **`using:` names the relation.** Three forms:

   | Form | Meaning |
   |------|---------|
   | `:fun` | `fun/2` in the projection module, public or private |
   | `{Mod, :fun}` | `Mod.fun/2`, public |
   | `{Mod, :fun, args}` | `Mod.fun/(2 + length(args))`, public, called as `fun(reference_value, variant_value, arg1, ..., argN)` |

   `Mod` may be `__MODULE__`, and then the function may be private. `args` are
   literals a module attribute can hold (numbers, atoms, strings, lists,
   tuples, maps, module names); a function value in `args` is an error that
   names the form to use instead. Without `using:` the relation is `==`.
   The relation's answer is a verdict under DR-052's grammar: truthy to
   agree, `nil` or `false` to disagree with both values reported,
   `{:fail, reason}` to disagree with a message or an exception. `:match`
   and `{:mismatch, detail}` of DR-046 items 2 and 10 are retired, and
   `Equivalence.verdict/3` becomes `Verdict.read/1`.
3. **Checked at compile time.** An unknown form, a local function that is
   missing or has the wrong arity, and a module that does not export the
   function are each a `CompileError` naming the observation, the `using:`
   term and the expected arity. The check of another module calls
   `Code.ensure_compiled!/1` and adds a compile-time dependency on that
   module, as `Plug.Builder` does for module plugs.
4. **The dispatch is generated inside the projection.** `__compare_using__/1`
   returns a 2-arity function per observation, built from the named form, so
   the convergence loop and the shrinker call a relation as they did; the
   only change there is that the relation's answer is read through
   `Verdict.read/1` (DR-052) instead of `Equivalence.verdict/3`.
5. **The relation is recorded as written.** A `:diverged` failure carries the
   `using:` term (`{PropertyDamage.Equivalence, :within, [0.01]}`), and the
   reporter prints it beside the two values. The persistence version stays
   15 while 15 is unreleased.
6. **`stutter: [using:]` accepts the same named forms** beside a 2-arity
   function (DR-046 item 17); a function stays legal there because a run
   option is runtime data. Documentation teaches the named form first.
7. **Normalization belongs in the observation.** The guides and the
   `PropertyDamage.Equivalence` documentation teach returning a canonical
   value from the `@compare` function and reserve `using:` for relations that
   are not equalities: a tolerance, order-insensitive agreement, subsumption
   of the reference's fields. `by_key/1`, `normalize/1` and `drop_keys/2`
   stay, for use inside observation bodies and named comparators;
   `Equivalence.within/3` (a tolerance) is added as the first
   data-parametrized relation, and further 3-arity relations are added where
   a pattern recurs.
8. **One shape, three verbs.** The projection documentation describes the
   three attributes together: each sits above a 2-arity function of the
   projection state; a `@check` function's return is its verdict (DR-052), an
   `@eventually` function returns the predicate to poll, a `@compare` function
   returns the value compared across targets.

## Consequences

- Breaking for every relation that returned `:match` or `{:mismatch, _}`:
  `:match` is simply truthy now, `{:mismatch, d}` becomes `{:fail, d}`.
- Breaking for every `using:` value: `&local/2` becomes `:local`, `&Mod.fun/2`
  becomes `{Mod, :fun}`, a closure or a helper pipeline becomes a named
  private function. The CHANGELOG lists the change as BREAKING with the
  table above.
- A relation is a named, unit-testable function, checked for existence and
  arity before any run, and printable in a report.
- A projection module is an ordinary module again: `Kernel.@/1` is in scope
  and any attribute macro may be imported beside `use
  PropertyDamage.Model.Projection`.
- The `mix pd.gen.projection` template, the projection moduledoc, the
  `Equivalence` moduledoc example and the guides that show `using:` change
  to the named form and to normalization in the observation body.

## Alternatives considered

- **Keep the `@/1` replacement with the guard.** Rejected: one attribute with
  a mechanism of its own, a custom `@` in every projection, and relations
  that cannot be printed or persisted, for the convenience of a closure in an
  attribute.
- **A `compare/2` macro beside `@check` and `@eventually`.** Rejected: three
  kinds of check in two shapes.
- **Bare `check`, `eventually` and `compare` macros before `def`, or a
  `defcheck`/`defeventually`/`defcompare` family.** Rejected: a migration of
  every check in every consumer for enforcement the attribute already gives,
  formatter configuration in every consumer, name collisions with a model's
  own `check/1` or `compare/1`, and `@invariant` would stay an attribute while
  the checks changed shape.
- **Remote captures only.** Rejected: a relation private to the model would
  need a public function.
- **No `using:` at all; every observation returns a canonical value.**
  Rejected: a tolerance is not an equality and cannot be made one by
  rounding, and a subsumption relation has no canonical form.
- **An attribute on the comparator pointing at the observation.** Rejected:
  the observation's own line would no longer say its relation, and a fourth
  attribute would serve one declaration in eight.
