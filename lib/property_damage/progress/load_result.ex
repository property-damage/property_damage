defmodule PropertyDamage.Progress.LoadResult do
  @moduledoc """
  Terminal result notification for a load test (DR-022): the final report.

  A copy for consumers; the load-test runner's `await/1` returns the
  authoritative report.
  """

  @type t :: %__MODULE__{report: term()}

  @enforce_keys [:report]
  defstruct [:report]
end
