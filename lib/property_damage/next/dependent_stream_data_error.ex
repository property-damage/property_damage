defmodule PropertyDamage.Next.DependentStreamDataError do
  @moduledoc """
  Raised in raise mode (`dependent_stream_data: :raise`) when a `from/2`
  function or a dependent assign returns a StreamData generator that the
  engine cannot fit.

  `site` names where it was returned, as
  `%{site: :field | :assign, command: module, key: atom, spec: id | nil}`
  (see `PropertyDamage.Next.Engine.Dependent`). The message names the
  command module and the field or assign, and lists PD's descriptions to
  return instead.
  """

  defexception [:site, :message]

  @descriptions "Return one of PD's descriptions instead: integer/1, member_of/1 or boolean/0."

  @impl true
  def exception(opts) do
    site = Keyword.fetch!(opts, :site)
    generator = Keyword.fetch!(opts, :generator)

    message =
      "#{returned(site)} #{inspect(generator)}, a StreamData generator. PD's engine cannot " <>
        "fit its value when the field it depends on changes. " <> @descriptions

    %__MODULE__{site: site, message: message}
  end

  @doc false
  # The warning logged for `site` in warn mode.
  @spec warning(PropertyDamage.Next.Engine.Dependent.site()) :: String.t()
  def warning(site) do
    "#{returned(site)} a StreamData generator. PD's engine draws it, but cannot fit its " <>
      "value when the field it depends on changes: the value then follows its stored path " <>
      "on the new generator, and the site is on the kept list. " <> @descriptions
  end

  defp returned(%{site: :field, command: module, key: field}),
    do: "#{inspect(module)}, field #{inspect(field)}: the from/2 function returned"

  defp returned(%{site: :assign, command: module, key: key, spec: id}),
    do:
      "#{inspect(module)}, assign #{inspect(key)} of spec #{id}: " <>
        "the assign_from_command/3 function returned"

  @type t :: %__MODULE__{
          site: PropertyDamage.Next.Engine.Dependent.site(),
          message: String.t()
        }
end
