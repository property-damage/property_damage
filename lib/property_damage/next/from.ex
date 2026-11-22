defmodule PropertyDamage.Next.From do
  @moduledoc """
  Marks a command field whose generator depends on other drawn fields.

  `PropertyDamage.Next.Command.from/2` builds it; it runs nothing. At the
  draw, PD calls `fun` with the named field's value (one field) or a map of
  exactly the named fields (a list), and draws the generator it returns.
  It is accepted only as a value in a command's generator map.
  """

  @enforce_keys [:fields, :fun]
  defstruct [:fields, :fun]

  @type t :: %__MODULE__{fields: atom() | [atom()], fun: (term() -> term())}
end
