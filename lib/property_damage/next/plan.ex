defmodule PropertyDamage.Next.Plan do
  @moduledoc """
  A plan built by generation, not yet executed.

  `steps` are the drawn steps in slot order, `journal` the draws they were
  built from, and `withdrawn` the slots whose stored pick is no longer
  offered, each as `%{key: key, command: module}`.

  `kept` lists the sites where a `from/2` function or a dependent assign
  returned a StreamData generator that PD's engine drew without being able
  to fit it, each as `%{site: :field | :assign, command: module, key: atom,
  spec: id | nil}`, in the order first drawn (see
  `PropertyDamage.Next.Engine`).
  """

  alias PropertyDamage.Next.{Engine.Dependent, Journal, Step}

  @enforce_keys [:journal]
  defstruct steps: [], journal: nil, withdrawn: [], kept: []

  @type t :: %__MODULE__{
          steps: [Step.t()],
          journal: Journal.t(),
          withdrawn: [%{key: term(), command: module()}],
          kept: [Dependent.site()]
        }
end
