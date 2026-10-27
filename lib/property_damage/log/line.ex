defmodule PropertyDamage.Log.Line do
  @moduledoc """
  One log line, written by `PropertyDamage.log/2` or `PropertyDamage.Runtime.log/3`
  (DR-054).

  A line holds its message as it was given and the facts about the call; it
  never holds a copy of projections, the event log or any other run state.

  ## Fields

    * `:message` - what was logged, stored as given: a string, any other
      value, or a 0-arity function. The failure report formats a value with
      `inspect/2` and calls a function each time it is formatted.
    * `:tags` - the atoms given in `tags:`, in order (`[]` when none).
    * `:file`, `:line` - where `PropertyDamage.log/2` was called; `nil` for a
      line written through `Runtime.log/3`.
    * `:timestamp` - `System.monotonic_time(:millisecond)` at the call, the
      clock `PropertyDamage.EventLog.Entry` uses, so lines and events of one
      run order against each other.
    * `:attempt` - which execution of its step wrote the line: `1` for the
      first, then one more for each settle or stutter retry. A line written
      under `PropertyDamage.Log.capture/1` has attempt `1`. The failure report
      keeps the lines of a step's first and last attempts only
      (`PropertyDamage.Log.Gap`).
  """

  @type t :: %__MODULE__{
          message: term(),
          tags: [atom()],
          file: String.t() | nil,
          line: non_neg_integer() | nil,
          timestamp: integer(),
          attempt: pos_integer()
        }

  @enforce_keys [:message, :timestamp]
  defstruct [:message, :file, :line, :timestamp, tags: [], attempt: 1]
end
