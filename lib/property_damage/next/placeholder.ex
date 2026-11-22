defmodule PropertyDamage.Next.Placeholder do
  @moduledoc """
  A value the system under test mints, as the predicted state holds it.

  When a simulated event has a field marked `PropertyDamage.external()`,
  generation puts a placeholder there, so later commands can name the value
  before it exists (for example a payment id picked with `member_of/1`). A
  placeholder is identified by the step that produced the event, the
  event's index in the step's events (from 0) and the field's path inside
  the event. At execution PD replaces it with the value at the same place
  in the real events; the system under test never sees it.
  """

  @enforce_keys [:step, :event_index, :path]
  defstruct [:step, :event_index, :path]

  @type t :: %__MODULE__{
          step: term(),
          event_index: non_neg_integer(),
          path: [atom() | non_neg_integer()]
        }
end
