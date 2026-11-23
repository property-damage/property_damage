defmodule PropertyDamage.Next.AcknowledgedIgnoredAssignError do
  @moduledoc """
  Raised when an adapter acknowledges an assign its target lists in
  `ignored_assigns:`.

  A target ignores an assign to say that its adapter never acts on it, so
  an acknowledgment of that assign contradicts the target's own entry. `key`
  is the acknowledged key and `target` the target's adapter module. The
  error is a misuse of PD, not a failure of the system under test:
  `PropertyDamage.Next.run/1` and `PropertyDamage.Next.replay/2` raise it,
  and a run does not shrink it.
  """

  defexception [:key, :target]

  @type t :: %__MODULE__{key: atom(), target: module()}

  @impl true
  def message(%__MODULE__{key: key, target: target}) do
    "the adapter #{inspect(target)} acknowledged the assign #{inspect(key)}, " <>
      "but its target lists #{inspect(key)} in ignored_assigns:; " <>
      "remove the key from ignored_assigns: or stop acknowledging it"
  end
end
