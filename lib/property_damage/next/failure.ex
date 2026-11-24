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
  `shrink_dropped` counts the shrink candidates dropped without a run
  because the model raised while rebuilding their plan; they are not in
  `shrink_runs`.
  `shrink_ended` is `:cap` when the shrink stopped because it reached
  `max_shrink_runs`, so the plan may shrink further, `:done` when the
  shrink found no smaller plan to try, and `nil` when nothing was shrunk.
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

  `format/1` renders a failure as text.
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
    :shrink_ended,
    withdrawn: [],
    shrink_runs: 0,
    shrink_dropped: 0,
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
          shrink_dropped: non_neg_integer(),
          shrink_ended: :cap | :done | nil,
          kept: [PropertyDamage.Next.Engine.Dependent.site()],
          original: %{
            plan: PropertyDamage.Next.Plan.t(),
            journal: PropertyDamage.Next.Journal.t(),
            step: term(),
            reason: reason(),
            withdrawn: [map()]
          }
        }

  @doc """
  Renders `failure` as text: the same lines for the same failure.

  The first line names the failing step and the reason, then one line per
  step of the final plan, its key and its command, then the shrink runs.
  When the run budget ended the shrink, a last line says so and names the
  option that sets the budget, `max_shrink_runs`. A failure with no plan
  to blame renders its reason alone.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{plan: nil} = failure), do: "Failed: #{inspect(failure.reason)}\n"

  def format(%__MODULE__{} = failure) do
    steps = Enum.map(failure.plan.steps, &"  #{inspect(&1.key)} #{inspect(&1.command)}")

    (["Failed at step #{inspect(failure.step)}: #{inspect(failure.reason)}", "Steps"] ++
       steps ++ ["Shrink runs: #{failure.shrink_runs}"] ++ notice(failure))
    |> Enum.map_join(&(&1 <> "\n"))
  end

  defp notice(%__MODULE__{shrink_ended: :cap, shrink_runs: runs}),
    do: ["Shrinking stopped at #{runs} runs (max_shrink_runs). The plan may shrink further."]

  defp notice(_failure), do: []
end
