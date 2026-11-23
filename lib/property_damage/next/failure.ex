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

  A run can also fail with no plan failing. After the search,
  `reason` is `{:unacknowledged_assigns, rows}` when an assign some step set
  was acknowledged by no port, or `{:never_drawn, rows}` when the run asked
  for `never_drawn: :fail` and a spec was never drawn (the rows are those of
  `PropertyDamage.Next.Report`). Then `plan`, `journal`, `step`, `seed`,
  `plan_number` and `original` are `nil`, because no plan is to blame.

  `report` is the `PropertyDamage.Next.Report` of the run, with the counts
  of its search plans; it is `nil` for a failure `replay/2` returns.

  `kept` lists every site where PD's engine drew a dependent StreamData
  generator it cannot fit, across every plan the call built, shrink
  candidates included (see `PropertyDamage.Next.Plan`).
  """

  defstruct [
    :plan_number,
    :seed,
    :plan,
    :journal,
    :step,
    :reason,
    :original,
    :report,
    withdrawn: [],
    shrink_runs: 0,
    kept: []
  ]

  @type reason ::
          {:check, atom(), String.t()}
          | {:adapter_error, term()}
          | {:raise, Exception.t()}
          | {:unacknowledged_assigns, [PropertyDamage.Next.Report.assign_row()]}
          | {:never_drawn, [PropertyDamage.Next.Report.never_drawn()]}

  @type t :: %__MODULE__{
          plan_number: pos_integer() | nil,
          seed: integer() | nil,
          plan: PropertyDamage.Next.Plan.t() | nil,
          journal: PropertyDamage.Next.Journal.t() | nil,
          report: PropertyDamage.Next.Report.t() | nil,
          withdrawn: [map()],
          step: term(),
          reason: reason(),
          shrink_runs: non_neg_integer(),
          kept: [PropertyDamage.Next.Engine.Dependent.site()],
          original: %{
            plan: PropertyDamage.Next.Plan.t(),
            journal: PropertyDamage.Next.Journal.t(),
            step: term(),
            reason: reason(),
            withdrawn: [map()]
          }
        }
end
