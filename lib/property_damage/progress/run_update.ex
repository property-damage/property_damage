defmodule PropertyDamage.Progress.RunUpdate do
  @moduledoc """
  Intermediate progress for `PropertyDamage.run/1` (DR-022): a coarse
  per-iteration heartbeat of cumulative campaign state. Not the authoritative
  result — see `PropertyDamage.Progress.RunResult`.
  """

  @type phase :: :run | :shrink

  @type t :: %__MODULE__{
          run_number: pos_integer(),
          total_runs: pos_integer(),
          command_count: non_neg_integer() | nil,
          phase: phase(),
          shrink_iteration: non_neg_integer() | nil,
          branching?: boolean()
        }

  @enforce_keys [:run_number, :total_runs]
  defstruct [
    :run_number,
    :total_runs,
    :command_count,
    :shrink_iteration,
    phase: :run,
    branching?: false
  ]
end
