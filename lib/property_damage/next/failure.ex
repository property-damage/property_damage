defmodule PropertyDamage.Next.Failure do
  @moduledoc """
  A failed run: which plan failed, at which step, and why.

  `plan_number` counts the run's plans from 1 and `seed` is the seed of the
  plan that failed first. `plan` and `journal` are the final plan and the
  draws it was built from, `withdrawn` lists the slots withdrawn while
  building it, `step` is the key of its failing step, and `reason` is
  `{:check, name, message}`, `{:adapter_error, term}` or
  `{:raise, exception}`.

  After a shrink the final plan is the shrunk one: its journal holds
  exactly its plan's draws and replays to it. `shrink_runs` counts the
  executions after the plan that failed first, 0 when nothing was shrunk.
  `original` holds the `plan`, `journal`, `step`, `reason` and `withdrawn`
  of the plan that failed first; without a shrink they equal the final
  ones.
  """

  defstruct [
    :plan_number,
    :seed,
    :plan,
    :journal,
    :step,
    :reason,
    :original,
    withdrawn: [],
    shrink_runs: 0
  ]

  @type reason ::
          {:check, atom(), String.t()} | {:adapter_error, term()} | {:raise, Exception.t()}

  @type t :: %__MODULE__{
          plan_number: pos_integer(),
          seed: integer(),
          plan: PropertyDamage.Next.Plan.t(),
          journal: PropertyDamage.Next.Journal.t(),
          withdrawn: [map()],
          step: term(),
          reason: reason(),
          shrink_runs: non_neg_integer(),
          original: %{
            plan: PropertyDamage.Next.Plan.t(),
            journal: PropertyDamage.Next.Journal.t(),
            step: term(),
            reason: reason(),
            withdrawn: [map()]
          }
        }
end
