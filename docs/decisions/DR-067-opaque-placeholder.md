# DR-067: The Placeholder Is a Public Opaque Type with an Explicit Unresolved Marker

**Status:** Accepted
**Date:** 2026-11-09

## Context

A `PropertyDamage.Placeholder` stands for a value the system under test mints,
such as the id of a created order. User code that touched one (a `when:`
predicate, an `overrides:` function, a simulator) read its struct fields
directly, and so did most of the framework.

The struct marked "not answered yet" with `resolved: nil`. A system that
answered `nil` for the field therefore looked unanswered: the placeholder
stayed unresolved and the run failed with "Unresolved placeholder" although
the system had replied. The same reading made `nil` an impossible resolved
value.

Because the fields were the public surface, every change to the struct
reached user code.

## Decision

1. **The placeholder is a public opaque type.** `PropertyDamage.Placeholder.t/0`
   is `@opaque`. Code reads it through `id/1`, `position/1`, `path/1`,
   `event_module/1`, `event_index/1`, `resolved?/1`, `value/1` and `value!/1`.
   `placeholder?/1` tests any term. `retarget/2` returns a placeholder for
   another event field, which the registry uses when it aliases one.
2. **`resolved` has two states.** Its domain is `:unresolved | {:resolved,
   term()}`. A fresh placeholder is `:unresolved`. `value/1` returns
   `{:ok, value}` or `:error`.
3. **An answer of `nil` resolves to `nil`.** The placeholder is resolved, and
   `value/1` returns `{:ok, nil}`.
4. **A missing field leaves the placeholder unresolved.** The registry reads
   the producing event with `External.fetch_at_path/2`, which returns
   `{:ok, value}` or `:error`. If the event lacks the field at that path, the
   placeholder stays unresolved and a command that needs it fails as an
   unresolved placeholder.
5. **One deep resolve.** The registry holds the only function that replaces
   the placeholders inside a command's fields with their values. The executor
   steps delegate to it.
6. **`PlaceholderRegistry` stays internal.** Only the placeholder type and its
   accessors are public.
7. **The serialized shape changes.** A saved placeholder holds the new marker,
   so persistence moves to version 21 and the replay artifact to format 4.
   Both loaders refuse older files with their existing error shapes.

## Alternatives

- **Keep `nil` as the marker.** Rejected: it cannot tell "not answered" from
  "answered nil", which is the defect.
- **A separate sentinel struct for "unresolved" while `resolved` holds the
  bare value.** Rejected: a bare value still needs a second field or a
  sentinel to say whether it is present, and a sentinel that can collide with
  a user value reintroduces the defect. A tagged tuple cannot collide.
- **Leave the fields public and add the accessors.** Rejected: code keeps
  reading fields, and the next change to the struct breaks it again.

## Consequences

- Code that read `placeholder.id`, `.path` or the other fields calls the
  accessor. Code that tested `resolved == nil` calls `resolved?/1`.
- A system that answers `nil` for a field no longer fails the run; later
  commands receive `nil`.
- A producing event that lacks the field still fails as an unresolved
  placeholder.
- Saved reports of version 20 and older, and replay artifacts of format 3 and
  older, cannot be loaded. Capture the failure again.
- The struct may change shape later without reaching user code.
