defmodule PropertyDamage.Next.Step do
  @moduledoc """
  One drawn step of a plan: the command and the assigns for the ports.

  `key` is the step's `{lane, slot}`, and `spec_id` the id of the spec it
  was drawn from. The step is PD's own: the ports receive the command and
  the assigns, never the step.
  """

  @enforce_keys [:key, :spec_id, :command]
  defstruct [:key, :spec_id, :command, assigns: %{}]

  @type t :: %__MODULE__{key: term(), spec_id: pos_integer(), command: struct(), assigns: map()}
end
