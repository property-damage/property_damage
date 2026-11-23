defmodule PropertyDamage.Next.Step do
  @moduledoc """
  One drawn step of a plan: the command and the assigns for the ports.

  `key` is the step's `{lane, slot}`, and `spec_id` the id of the spec it
  was drawn from. A step of a plan with one lane, or of the prefix of a
  plan with two lanes, has key `{0, slot}`; a step in a lane has key
  `{1, slot}` or `{2, slot}`. The step is PD's own: the ports receive the command and
  the assigns, never the step.

  `path` is `nil` unless the model lists the step's command module in
  `expansions/0` (see `PropertyDamage.Next.Model`). For a listed module it
  is `{index, commands}`: the index of the path PD picked among those the
  paths function returned, and the commands of that path, which the variant
  execution runs in place of the step's command. The plain path is
  `{0, [command]}`.
  """

  @enforce_keys [:key, :spec_id, :command]
  defstruct [:key, :spec_id, :command, assigns: %{}, path: nil]

  @type t :: %__MODULE__{
          key: term(),
          spec_id: pos_integer(),
          command: struct(),
          assigns: map(),
          path: {non_neg_integer(), [struct(), ...]} | nil
        }
end
