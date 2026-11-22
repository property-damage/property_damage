defmodule PropertyDamage.Next.Failure do
  @moduledoc """
  A failed run: which plan failed, at which step, and why.

  `plan_number` counts the run's plans from 1, `seed` is the seed of the
  failing plan, `plan` and `journal` are the plan and the draws it was
  built from, `withdrawn` lists the slots withdrawn while building it,
  `step` is the key of the failing step, and `reason` is
  `{:check, name, message}`, `{:adapter_error, term}` or
  `{:raise, exception}`.
  """

  defstruct [:plan_number, :seed, :plan, :journal, :step, :reason, withdrawn: []]

  @type t :: %__MODULE__{
          plan_number: pos_integer(),
          seed: integer(),
          plan: PropertyDamage.Next.Plan.t(),
          journal: PropertyDamage.Next.Journal.t(),
          withdrawn: [map()],
          step: term(),
          reason:
            {:check, atom(), String.t()} | {:adapter_error, term()} | {:raise, Exception.t()}
        }
end
