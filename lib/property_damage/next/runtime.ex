defmodule PropertyDamage.Next.Runtime do
  @moduledoc """
  PD's handle for the ports, passed to the adapter's `setup/2`.

  The adapter keeps it and uses PD's services through it; its contents are
  PD's own and may change, so the adapter never reads its fields.
  """

  defstruct []

  @opaque t :: %__MODULE__{}
end
