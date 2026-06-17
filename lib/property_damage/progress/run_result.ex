defmodule PropertyDamage.Progress.RunResult do
  @moduledoc """
  Terminal result notification for `PropertyDamage.run/1` (DR-022).

  Carries a copy of the authoritative outcome for consumers; the `run/1` return
  value (`{:ok, stats}` | `{:error, report}`) remains the source of truth.
  """

  @type t :: %__MODULE__{
          outcome: :ok | :error,
          runs_completed: non_neg_integer() | nil,
          total_commands: non_neg_integer() | nil,
          seed: integer() | nil,
          failure: term() | nil
        }

  @enforce_keys [:outcome]
  defstruct [:outcome, :runs_completed, :total_commands, :seed, :failure]
end
