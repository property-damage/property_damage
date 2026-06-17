defmodule PropertyDamage.Progress.MutationResult do
  @moduledoc """
  Terminal result notification for `PropertyDamage.Mutation.run/1` (DR-022): the
  final mutation report.

  A copy for consumers; the `Mutation.run/1` return value (`{:ok, report}`)
  remains the source of truth.
  """

  @type t :: %__MODULE__{report: term()}

  @enforce_keys [:report]
  defstruct [:report]
end
