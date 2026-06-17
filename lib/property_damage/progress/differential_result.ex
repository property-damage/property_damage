defmodule PropertyDamage.Progress.DifferentialResult do
  @moduledoc """
  Terminal result notification for `PropertyDamage.Differential.run/1` (DR-022):
  the final comparison result.

  A copy for consumers; the `Differential.run/1` return value (`{:ok, result}`)
  remains the source of truth.
  """

  @type t :: %__MODULE__{result: term()}

  @enforce_keys [:result]
  defstruct [:result]
end
