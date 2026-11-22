defmodule PropertyDamage.Next.Engine do
  @moduledoc """
  The behaviour of an engine: the code that draws one value for a journal key.

  Generation calls `c:draw/4` once per drawn field and assign, with the
  journal it rebuilds from, the key of the draw, the generator and the
  journal's seed. The engine answers the value and the journal entry to
  record under the key. The kind of entry follows the generator, and the
  set of kinds is open: PD's own engine, `PropertyDamage.Next.Engine.Native`,
  records these three.

  | Generator | Entry |
  |---|---|
  | `integer/1` description | `{:integer, value, range}` |
  | `member_of/1` or `boolean/0` description | `{:member, value, index}`, index from 0 |
  | any other generator | `{:stream_data, value, path}`, path a list of child indices |

  A StreamData entry's path locates the value in the shrink tree that the
  generator, drawn from the key's seed, gives: `[]` for a fresh draw. See
  `PropertyDamage.Next.Steering`.

  An engine treats the key as an opaque term: it may look the key up in the
  journal and derive a seed from it, nothing else.

  ## Dependent generators

  When a `from/2` function or a dependent assign
  (`PropertyDamage.Next.StepSpec.assign_from_command/3`) returns a generator
  that is not a PD description (a plain or delegated StreamData generator),
  generation passes it wrapped in `PropertyDamage.Next.Engine.Dependent`,
  so an engine knows the value depends on another value of the step and
  where it was returned. The engine draws the wrapped generator.

  An engine module may also export `fits_dependent?/1`. It is not a
  callback of this behaviour: generation loads the engine module and
  checks whether it exports the function, and an engine without it is
  treated as answering `false`. Generation calls it with the bare
  generator the function returned. An engine answering `true` says it
  can fit such a value when its source changes, and generation draws the
  value through it with no warning, no raise and no kept site.

  For an engine that does not fit the value, PD's own engine included,
  generation looks at the `dependent_stream_data:` option of
  `PropertyDamage.Next.plan/3`, `PropertyDamage.Next.run/1` and
  `PropertyDamage.Next.replay/2`:

    * `:warn` (the default) - the value is drawn; the first draw at each
      site in one call logs a warning that names the site and PD's
      descriptions `integer/1`, `member_of/1` and `boolean/0`, and the site
      is put on the kept list (`kept` of the plan, the failure and the
      result of `run/1` and `replay/2`);
    * `:raise` - the first draw at such a site raises
      `PropertyDamage.Next.DependentStreamDataError`.
  """

  alias PropertyDamage.Next.Journal

  @doc "Draws the value for `key` and returns it with the entry to record."
  @callback draw(journal :: Journal.t(), key :: term(), generator :: term(), seed :: integer()) ::
              {value :: term(), entry :: tuple()}
end
