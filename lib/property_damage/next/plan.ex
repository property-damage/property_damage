defmodule PropertyDamage.Next.Plan do
  @moduledoc """
  A plan built by generation, not yet executed.

  `steps` are the drawn steps in slot order, `journal` the draws they were
  built from, and `withdrawn` the slots whose stored pick is no longer
  offered, each as `%{key: key, command: module}`.
  """

  alias PropertyDamage.Next.{Journal, Step}

  @enforce_keys [:journal]
  defstruct steps: [], journal: nil, withdrawn: []

  @type t :: %__MODULE__{
          steps: [Step.t()],
          journal: Journal.t(),
          withdrawn: [%{key: term(), command: module()}]
        }
end
