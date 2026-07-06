defmodule PropertyDamage.ProjectionError do
  @moduledoc """
  Raised internally when a projection's `apply/2` fails while folding a
  command or event into state — whether it raised, exited, or threw.

  A failing `apply/2` is a legitimate way for a projection to signal a
  transition invariant violation (see `PropertyDamage.Model.Projection`).
  The executor catches this and turns it into a reported failure
  (a `%PropertyDamage.Failure{}` of kind `:projection_violation`) rather than letting it
  crash the whole run. `original` is the raised exception, or a `{:exit, reason}`
  / `{:throw, value}` tuple when `apply/2` escaped by exiting or throwing.
  """
  defexception [:projection, :item, :original, :original_stacktrace]

  @impl true
  def message(%__MODULE__{projection: projection, original: original}) do
    "projection #{inspect(projection)} failed while applying an item: " <>
      describe_original(original)
  end

  defp describe_original(original) when is_exception(original),
    do: Exception.message(original)

  defp describe_original(original), do: inspect(original)
end
