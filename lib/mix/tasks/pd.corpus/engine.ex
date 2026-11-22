defmodule PropertyDamage.Corpus.Engine do
  @moduledoc """
  What the corpus harness needs from a testing engine.

  An engine runs one entry on one seed and answers with a normalized result,
  so the harness can measure any engine the same way. To measure another
  engine, write a module with these two callbacks and point entries at it.

  The result map has these keys:

    * `:found?` - the engine reported a failure within `plan_cap` plans.
    * `:plans_until_found` - how many plans the engine generated up to and
      including the failing one, or `nil` when nothing failed.
    * `:shrink_runs` - how many runs the engine spent shrinking, or `0`.
    * `:shrunk` - the shrunk failing plan as a list of plain maps (see
      `PropertyDamage.Corpus.Entry`), or `nil`.
    * `:bug_fired?` - the seeded bug's path ran in the system instance that
      reproduced the failure.
    * `:fires` - how many times the seeded bug's path ran across the whole
      seed, shrink runs included.
    * `:kept` - the sites where the engine drew a value it cannot fit when
      the value it depends on changes, each a map; `[]` for an engine that
      has none (see `PropertyDamage.Next.Engine`).

  An entry whose `bug` is `nil` runs with the bug off; the engine runs it the
  same way, with the same `plan_cap`.
  """

  alias PropertyDamage.Corpus.Entry

  @type result :: %{
          found?: boolean(),
          plans_until_found: pos_integer() | nil,
          shrink_runs: non_neg_integer(),
          shrunk: [map()] | nil,
          bug_fired?: boolean(),
          fires: non_neg_integer(),
          kept: [map()]
        }

  @doc "The engine's name, as written into saved tables."
  @callback name() :: String.t()

  @doc "Runs `entry` on `seed`, generating at most `plan_cap` plans."
  @callback run(Entry.t(), seed :: integer(), plan_cap :: pos_integer()) :: result()
end
