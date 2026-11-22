defmodule PropertyDamage.Next.Engine.Dependent do
  @moduledoc """
  A generator returned by a `from/2` function that is not a PD description.

  Generation hands it to the engine instead of the bare generator, with the
  command module and the field it is drawn for. An engine that can fit a
  dependent value when its source field changes draws `generator`; one that
  cannot raises and names the module and the field.
  """

  @enforce_keys [:generator, :command, :field]
  defstruct [:generator, :command, :field]

  @type t :: %__MODULE__{generator: term(), command: module(), field: atom()}
end
