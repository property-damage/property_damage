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
    * `:line` - optional. For a guardrail entry (see
      `PropertyDamage.Corpus.Entry`), the exception message or the report
      line that was found.

  An entry whose `bug` is `nil` runs with the bug off; the engine runs it the
  same way, with the same `plan_cap`.
  """

  alias PropertyDamage.Corpus.Entry

  @type result :: %{
          required(:found?) => boolean(),
          required(:plans_until_found) => pos_integer() | nil,
          required(:shrink_runs) => non_neg_integer(),
          required(:shrunk) => [map()] | nil,
          required(:bug_fired?) => boolean(),
          required(:fires) => non_neg_integer(),
          required(:kept) => [map()],
          optional(:line) => String.t() | nil
        }

  @doc "The engine's name, as written into saved tables."
  @callback name() :: String.t()

  @doc "Runs `entry` on `seed`, generating at most `plan_cap` plans."
  @callback run(Entry.t(), seed :: integer(), plan_cap :: pos_integer()) :: result()

  @doc """
  Runs `entry` on `seed` as `c:run/3` does, except that the shrink executes
  at most `budget` plans, or as many as the testing library allows by
  default when `budget` is `:default`.

  The harness measures the smallest-plan columns under each shrink budget
  through this callback. An engine without a shrink budget leaves it out,
  and its rows then have no such columns.
  """
  @callback run(
              Entry.t(),
              seed :: integer(),
              plan_cap :: pos_integer(),
              budget :: pos_integer() | :default
            ) :: result()

  @optional_callbacks run: 4
end
