defmodule PropertyDamage.Next.ModelChangedError do
  @moduledoc """
  Raised when a journal is replayed on a model whose spec list changed.

  The journal's picks name specs by their position in the list, so after a
  change PD cannot tell which spec a pick meant, and refuses the journal
  instead of guessing.
  """

  defexception [:model, :expected, :actual]

  @impl true
  def message(%__MODULE__{model: model}) do
    "the model changed: #{inspect(model)} no longer has the spec list the journal was " <>
      "recorded on (a spec was added, removed, moved or reweighted, or its option, " <>
      "change or assign keys differ), so the journal cannot be replayed on it"
  end
end
