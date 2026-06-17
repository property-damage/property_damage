defmodule PropertyDamage.Progress.DifferentialUpdate do
  @moduledoc """
  Intermediate progress for `PropertyDamage.Differential.run/1` (DR-022): a coarse
  heartbeat as the run proceeds. Not the authoritative result — see
  `PropertyDamage.Progress.DifferentialResult`.

  ## Phases

  - `:run` — emitted per generated sequence in interleaved execution, carrying the
    1-based `run_number`, `total_runs`, and `command_count`.
  - `:target` — emitted per target in sequential execution, carrying the
    `target_name` currently being run.
  """

  @type phase :: :run | :target

  @type t :: %__MODULE__{
          phase: phase(),
          run_number: pos_integer() | nil,
          total_runs: pos_integer() | nil,
          command_count: non_neg_integer() | nil,
          target_name: String.t() | nil
        }

  @enforce_keys [:phase]
  defstruct [:phase, :run_number, :total_runs, :command_count, :target_name]
end
