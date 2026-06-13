defmodule PropertyDamage.ProjectionError do
  @moduledoc """
  Raised internally when a projection's `apply/2` raises while folding a
  command or event into state.

  A raising `apply/2` is a legitimate way for a projection to signal a
  transition invariant violation (see `PropertyDamage.Model.Projection`).
  The executor catches this and turns it into a reported failure
  (`{:projection_violation, projection, exception}`) rather than letting it
  crash the whole run.
  """
  defexception [:projection, :item, :original, :original_stacktrace]

  @impl true
  def message(%__MODULE__{projection: projection, original: original}) do
    "projection #{inspect(projection)} raised while applying an item: " <>
      Exception.message(original)
  end
end
