defmodule PropertyDamage.Progress.RunUpdate do
  @moduledoc """
  Intermediate progress for `PropertyDamage.run/1` (DR-022): a coarse
  per-iteration heartbeat of cumulative campaign state. Not the authoritative
  result — see `PropertyDamage.Progress.RunResult`.

  ## Phases

  - `:start` — emitted once before the first run (`run_number` is `0`); signals
    the campaign has begun and carries `total_runs`.
  - `:run` — emitted per sequence with the 1-based `run_number`, the
    `command_count`, and `branch_count` (`0` for a linear sequence).
  - `:shrink` — reserved for per-iteration shrink progress (`shrink_iteration`).
  """

  @type phase :: :start | :run | :shrink

  @type t :: %__MODULE__{
          run_number: non_neg_integer(),
          total_runs: pos_integer(),
          command_count: non_neg_integer() | nil,
          phase: phase(),
          shrink_iteration: non_neg_integer() | nil,
          branch_count: non_neg_integer()
        }

  @enforce_keys [:run_number, :total_runs]
  defstruct [
    :run_number,
    :total_runs,
    :command_count,
    :shrink_iteration,
    phase: :run,
    branch_count: 0
  ]
end
