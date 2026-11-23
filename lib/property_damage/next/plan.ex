defmodule PropertyDamage.Next.Plan do
  @moduledoc """
  A plan built by generation, not yet executed.

  `steps` are the drawn steps in slot order, `journal` the draws they were
  built from, and `withdrawn` the slots whose stored pick is no longer
  offered, each as `%{key: key, command: module}`. In a plan with two
  lanes, `steps` lists the prefix steps, then lane 1's, then lane 2's,
  each in slot order.

  `schedule` says how the two lanes interleave. For a plan with two lanes
  whose lanes both hold a step, it maps the key `{1, slot}` of each lane-1
  step to a list of `yields + 1` integers, one per point of that step in
  order: the step's first point is its call to `execute/3`, and each yield
  adds one. A value names a position in lane 2, counted by lane-2 slot:
  point `j` of the lane-2 step in slot `s` sits at position
  `(s - 1) * (yields + 1) + (j - 1)`. A lane-1 point runs once lane 2 has
  no point left before its value's position, so a schedule of zeros runs
  lane 1 to its end, then lane 2. Otherwise, and always for a plan with one
  lane, `schedule` is `%{}`.

  `kept` lists the sites where a `from/2` function or a dependent assign
  returned a StreamData generator that PD's engine drew without being able
  to fit it, each as `%{site: :field | :assign, command: module, key: atom,
  spec: id | nil}`, in the order first drawn (see
  `PropertyDamage.Next.Engine`).

  `eligible` lists the ids of the specs whose `when:` held at some slot the
  build evaluated, in id order. With the ids of `steps` it tells a spec
  that was never offered from one that was offered and never picked.
  """

  alias PropertyDamage.Next.{Engine.Dependent, Journal, Step}

  @enforce_keys [:journal]
  defstruct steps: [], journal: nil, withdrawn: [], kept: [], eligible: [], schedule: %{}

  @type t :: %__MODULE__{
          steps: [Step.t()],
          journal: Journal.t(),
          withdrawn: [%{key: term(), command: module()}],
          kept: [Dependent.site()],
          eligible: [pos_integer()],
          schedule: %{{1, pos_integer()} => [non_neg_integer()]}
        }
end
