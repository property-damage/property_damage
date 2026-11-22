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

  When a `from/2` function returns something other than a PD description,
  generation passes it wrapped in `PropertyDamage.Next.Engine.Dependent`, so
  an engine knows the value depends on another field. An engine that can
  fit such a value unwraps it; PD's own engine refuses it.
  """

  alias PropertyDamage.Next.Journal

  @doc "Draws the value for `key` and returns it with the entry to record."
  @callback draw(journal :: Journal.t(), key :: term(), generator :: term(), seed :: integer()) ::
              {value :: term(), entry :: tuple()}
end
