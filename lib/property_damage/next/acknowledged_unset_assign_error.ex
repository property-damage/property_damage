defmodule PropertyDamage.Next.AcknowledgedUnsetAssignError do
  @moduledoc """
  Raised when an adapter acknowledges an assign the running step did not set.

  An assign is unset at a step when the step has no such key, or its drawn
  value is `nil` or `false`. `key` is the acknowledged key and `assigns` the
  keys the step did set. The error is a misuse of PD, not a failure of the
  system under test: `PropertyDamage.Next.run/1` and
  `PropertyDamage.Next.replay/2` raise it, and a run does not shrink it.
  """

  defexception [:key, assigns: []]

  @type t :: %__MODULE__{key: atom(), assigns: [atom()]}

  @impl true
  def message(%__MODULE__{key: key, assigns: assigns}) do
    "the adapter acknowledged the assign #{inspect(key)}, but the running step did not set it " <>
      "(assigns set at this step: #{inspect(assigns)}); " <>
      "acknowledge an assign only when the step carries it"
  end
end
