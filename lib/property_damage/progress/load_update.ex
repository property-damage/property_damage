defmodule PropertyDamage.Progress.LoadUpdate do
  @moduledoc """
  Intermediate progress for a load test (DR-022): a periodic, self-contained
  metrics snapshot.

  Consumers MUST NOT assume they receive every snapshot or contiguous ones — the
  load-test notifier may decimate buffered snapshots under backpressure — nor
  compute deltas across received snapshots. Each snapshot carries absolute,
  cumulative values so any single one stands alone.
  """

  @type t :: %__MODULE__{snapshot: map()}

  @enforce_keys [:snapshot]
  defstruct [:snapshot]
end
