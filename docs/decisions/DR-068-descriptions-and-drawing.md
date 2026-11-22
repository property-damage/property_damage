# DR-068: Generators Describe Their Draws, and an Engine Behaviour Draws Them

**Status:** Accepted. Amended (2026-11-22, see "Amendment" at the end): `Engine.Native` draws a dependent StreamData generator instead of refusing it, warns once per site per call and lists the site as kept; `dependent_stream_data: :raise` raises `DependentStreamDataError`; an engine answers whether it can fit such a value through an optional exported `fits_dependent?/1`. Amended by DR-069: a StreamData entry is `{:stream_data, value, path}`; integer and member entries record the domain generation offers now, and a stored value is fitted to it (keep, else clamp; keep the member, else the stored index, else the last); a fresh StreamData value is the root of its shrink tree.
**Date:** 2026-11-22

## Context

The new engine under `PropertyDamage.Next` keeps the test case as a journal:
one entry per draw, keyed by where generation made the draw. PD rebuilds a
plan by running generation again against the journal. A key with an entry
gives back the stored value; a key without one draws afresh.

A rebuild can move the domain of a later draw. Take a refund whose amount is
drawn from `1..(payment - 1)`. If an edit to the journal lowers the payment
from 500 to 40, the refund's stored amount of 300 no longer fits. To fit it,
PD must know two things: the domain the value was drawn from, and the domain
generation offers now. Without the first, every fitting rule is a guess,
because a bare value cannot say whether it sat on a bound.

A StreamData generator cannot tell PD its domain. `StreamData.integer(1..n)`
returns a `%StreamData{}` struct that wraps a closure. PD can draw from the
closure, but it cannot read the range out of it. A value drawn through
StreamData therefore reaches the journal without a domain.

Generation draws one value per command field and per assign, each under its
own key. A key names the step as `{lane, slot}` and then the draw: for
example `{{0, 3}, :command, :amount}` is the `amount` field of the command at
slot 3 of lane 0. A one-lane plan uses lane 0, and slots count from 1. The
lane is part of every key from the start, so a plan with several lanes needs
no new key shape.

## Decision

1. **Three functions return descriptions.** `PropertyDamage.Next.Gen.integer/1`,
   `member_of/1` and `boolean/0` return a `%PropertyDamage.Next.Gen{kind:,
   domain:}` struct that draws nothing:
   - `integer(first..last)` gives `kind: :integer` and the range as the
     domain. The range must have a step of 1 and hold at least one integer;
     anything else raises `ArgumentError`.
   - `member_of(list)` gives `kind: :member` and the list as the domain. The
     list must not be empty. Another enumerable is turned into a list first,
     so the engine can record an index.
   - `boolean()` is a member draw over `[false, true]`.
2. **Every other StreamData generator name delegates.** `Gen` defines every
   other public StreamData generator function under the same name and arity.
   The functions are generated at compile time from
   `StreamData.__info__(:functions)`, minus a written list of functions that
   build no generator, such as `check_all/3`. Each one calls StreamData and
   returns `%Gen{kind: :delegated, domain: %StreamData{}}`.
3. **A delegating function converts its arguments first.** Before it calls
   StreamData, it replaces every description and delegated value in its
   arguments with a StreamData generator. It looks inside lists, tuples,
   maps and keyword lists, and inside the result of a function argument,
   such as the function given to `bind/2`. So `list_of(integer(1..3))` works,
   and StreamData draws the inner integers: a description inside a
   combinator is not fitted. `Gen.to_stream_data/1` performs the same
   conversion for one value.
4. **One import.** `use PropertyDamage.Next.Command` imports
   `PropertyDamage.Next.Gen` whole. `StreamData` stays usable by its full
   name, and a `%StreamData{}` is a legal value in a generator map. A test
   compares `Gen`'s exports with StreamData's public generator functions and
   fails on a missing name and arity.
5. **The engine is a behaviour with one callback.**
   `PropertyDamage.Next.Engine` declares
   `draw(journal, key, generator, seed) :: {value, entry}`. Generation calls
   it once per drawn field and assign and records the entry under the key.
   The set of entry kinds is open. PD's own engine,
   `PropertyDamage.Next.Engine.Native`, records three:

   | Generator | Entry |
   |---|---|
   | `integer/1` description | `{:integer, value, range}` |
   | `member_of/1` or `boolean/0` description | `{:member, value, index}`, index from 0 |
   | delegated value or `%StreamData{}` | `{:stream_data, value, path}`, path a list of child indices |

   *Amended by DR-069: a StreamData entry was `{:stream_data, value}`. It
   now also records the value's path in the generator's shrink tree, `[]`
   for a fresh draw. An integer entry records the range generation offers
   now, and a member entry the index in the list generation offers now,
   not the domain of the first draw.*

   `run/1`, `plan/3` and `replay/2` of `PropertyDamage.Next` take the engine
   as the `:engine` option, with `Engine.Native` as the default.
6. **The key is opaque to the engine.** An engine may use the key for two
   things: to look up the journal's entry, and to derive the key's seed with
   `Journal.key_seed/2`, a hash of the journal's seed and the key. It must not
   read the key's shape. Generation alone owns that shape. The pick of a
   step's spec is generation's own weighted draw and does not pass through
   the engine. A mint field records no entry, and the engine never sees it.
7. **A dependent field that returns a StreamData generator is the engine's
   question.** A `from/2` function computes a field's generator from other
   drawn fields. If it returns a description, generation passes the
   description to the engine as it is. If it returns any other generator,
   generation wraps it in `%PropertyDamage.Next.Engine.Dependent{generator:,
   command:, field:}`. The wrapper tells the engine that the value depends
   on another field. An engine that can fit such a value unwraps it and
   draws. `Engine.Native` cannot fit it, so it raises `ArgumentError`, naming
   the command module and the field and pointing at the three description
   functions.
   *Amended (2026-11-22): `Engine.Native` no longer raises here. It draws
   the wrapped generator, generation warns once per site and lists the
   site as kept, and `dependent_stream_data: :raise` restores a raise. The
   wrapper also covers a dependent assign. See "Amendment" below.*
8. **What `Engine.Native` does with an entry.** On a key with no entry it
   draws from the key's seed: an integer uniformly over the range, a member
   uniformly by index, and a StreamData value from the generator seeded with
   the key's seed at a fixed size. On a key whose entry still fits the
   generator, it returns the stored value and entry unchanged. An entry that
   no longer fits, or that is of another kind than the generator, is
   replaced by a fresh draw from the key's seed. A rule that fits a stored
   value into a moved domain belongs to the shrinker and is not part of this
   record.
   *Amended by DR-069: an integer or member entry of the generator's kind
   is now fitted on every rebuild, not redrawn. An integer is kept if it
   lies in the current range, else clamped to the nearer bound. A member
   is kept if the current list holds it, else the member at the stored
   index is taken, else the last member. A StreamData entry is walked: its
   stored path is followed on the current generator from the key's seed
   and cut at its longest prefix that exists there. A fresh StreamData
   value is the root of the generator's shrink tree from the key's seed,
   reached through `StreamData.check_all/3` as DR-069 describes, so a
   walk of the empty path gives back the fresh value.*

## Alternatives

- **One module holding both the descriptions and the drawing.** Rejected:
  the descriptions are what a command module builds, and the drawing is
  PD's internal work. In one module, a second engine (one that draws
  through StreamData, say) would have to replace the module command code
  imports. Tests would also lose the seam they use to pass a fake engine
  that draws, for example, the lowest value of every domain.
- **A separate package for the descriptions.** Rejected: PD is their only
  user. A package would add a release and a version to keep in step with
  PD and with StreamData, and no other consumer would gain from it.
- **Importing StreamData beside PD's three functions, with an exclusion
  list.** Each command module would carry
  `import StreamData, except: [integer: 1, member_of: 1, boolean: 0]` and a
  second import of PD's three. Rejected: StreamData's combinators would
  then receive PD's descriptions, and StreamData refuses a value that is not
  one of its own generators. `list_of(integer(1..3))` would raise. Only a
  PD-owned combinator can convert the description first. Every command
  module would also repeat the exclusion list, and a name PD later turns
  into a description would need an edit in each of them.

## Consequences

- A command module reads as if it were written with StreamData, with one
  import.
- `Gen` mirrors StreamData's public generator API at the version PD compiles
  against. A StreamData release that adds a generator adds it to `Gen` on
  the next compile; a name StreamData removes disappears from `Gen`.
- A kind that later moves from delegated to described changes how its
  values are drawn and fitted without a change at any call site. The
  changelog must name each kind that moves.
- `Engine.Native` refuses a `from/2` function that returns a delegated or
  plain StreamData generator, `constant/1` included. A constant that depends
  on another field is written `integer(x..x)` or `member_of([x])`. An
  engine that can fit such values accepts the same model unchanged.
  *Amended (2026-11-22): `Engine.Native` draws such a value and
  generation warns about the site, unless `dependent_stream_data: :raise`
  is given.*
- A value drawn through StreamData is stored as a bare value. PD can keep it
  or draw it afresh, but it cannot fit it into a moved domain.
- A generator returned by an `assign_from_command/3` function reaches the
  engine unwrapped. That function receives the whole drawn command, not a
  named field, so the wrapper of decision 7 does not apply to it.
  *Amended (2026-11-22): a dependent assign's generator is now wrapped
  too, with the spec and the assign key as its site.*
- *Amended by DR-069: a value drawn through StreamData is stored with its
  path. PD still cannot fit it into a moved domain, but after a change it
  follows its stored path on the new generator, and the shrinker lowers it
  by extending the path.*

## Amendment (2026-11-22)

A `from/2` function or a dependent assign that returns a StreamData
generator is now accepted with a warning by default, instead of refused.

1. **The wrapper covers both dependent sites.** Generation wraps such a
   generator in `Engine.Dependent{generator:, site:}`. The site is
   `%{site: :field, command: module, key: field, spec: nil}` for a
   `from/2` field and `%{site: :assign, command: module, key: assign,
   spec: id}` for a dependent assign
   (`StepSpec.assign_from_command/3`). A PD description and a mint marker
   still pass unwrapped.
2. **`Engine.Native` draws it.** It unwraps the generator and draws it as
   any other StreamData generator, with its path (DR-069). After the
   field it depends on changes, the value follows its stored path on the
   new generator. `Engine.Native` cannot fit that value to the new domain.
3. **Generation warns once per site and keeps the site.** Under the
   default `dependent_stream_data: :warn`, the value is drawn. The first
   draw at each site in one call of `run/1`, `plan/3` or `replay/2` logs
   one warning. The warning names the site and PD's three descriptions,
   `integer/1`, `member_of/1` and `boolean/0`. The site goes on the kept
   list: `kept` of the plan, of the failure, and of the result of `run/1`
   and `replay/2`. `mix pd.corpus` prints each entry's kept sites after
   its table. The warned set spans the whole call, so a site first met
   during a shrink is warned about once and kept.
4. **Raise mode.** With `dependent_stream_data: :raise`, generation raises
   `PropertyDamage.Next.DependentStreamDataError` at the first draw at
   such a site. The exception carries the site, and its message names the
   command module, the field or assign, and the three descriptions. The
   shrinker lets the exception through, so raise mode stops a shrink as
   it stops a run.
5. **The engine decides whether its value fits.** Before the warning or
   the raise, generation asks the engine. An engine module may export
   `fits_dependent?/1`; generation loads the module and checks whether it
   exports the function. An engine without it answers `false`. An engine
   answering `true` for the bare generator gets the wrapped generator with
   no warning, no raise and no kept site. `Engine.Native` does not export
   the function. The behaviour keeps its one callback, `draw/4`.

Why: refusing every dependent StreamData generator turned away models
that run correctly and only shrink less well. A dependent value drawn by
path still replays exactly, because its path and its key's seed fix it.
What PD loses is fitting: when the source shrinks, the value may move
away from the one that made the failure, and the shrink may stop early.
A warning and the kept list name that loss at each site without blocking
the run, and the raise mode keeps the strict behavior for a team that
wants it.

The answer belongs to the engine because only the engine knows whether it
can fit the value. An engine that records domains for StreamData values
would accept the same model with no warning. Making `fits_dependent?/1` a
second callback was rejected: every engine would have to define it,
although most engines answer `false`. An optional exported function lets an engine opt in and
costs the others nothing.
