defmodule PropertyDamage.Next.Engine.Dependent do
  @moduledoc """
  A generator that a `from/2` function or a dependent assign
  (`PropertyDamage.Next.StepSpec.assign_from_command/3`) returned and that
  is not a PD description: a plain StreamData generator or a delegated one.

  Generation hands it to the engine instead of the bare generator, so the
  engine knows the value depends on another value of the step. `site`
  names where it was returned:

    * `%{site: :field, command: module, key: field, spec: nil}` for a
      `from/2` field;
    * `%{site: :assign, command: module, key: assign, spec: id}` for a
      dependent assign of the spec with that id.

  An engine draws `generator`. PD's own engine draws it as any other
  StreamData generator, with its path; see `PropertyDamage.Next.Engine` for
  how generation warns about such a site, or raises.
  """

  @enforce_keys [:generator, :site]
  defstruct [:generator, :site]

  @typedoc "Where a dependent generator was returned."
  @type site :: %{
          site: :field | :assign,
          command: module(),
          key: atom(),
          spec: pos_integer() | nil
        }

  @type t :: %__MODULE__{generator: term(), site: site()}
end
