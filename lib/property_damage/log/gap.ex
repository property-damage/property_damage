defmodule PropertyDamage.Log.Gap do
  @moduledoc """
  The log lines of the attempts the retry cap dropped from one step
  (DR-054 decision 13).

  A settle or stutter retry can run a command hundreds of times. A step keeps
  the lines of its first attempt and of its last `keep_attempts` attempts
  (`log: [keep_attempts: n]`, default 3), and one `Gap` stands in the step's
  line list, between the first attempt's lines and the kept ones, for every
  attempt in between. The failure report prints it as
  `... 296 attempts omitted (1,184 lines)`.

  ## Fields

    * `:attempts` - how many attempts the cap dropped.
    * `:lines` - how many lines those attempts wrote, a line that arrived for
      an attempt already dropped included.
    * `:timestamp` - the earliest timestamp among the dropped lines, in the
      clock `PropertyDamage.Log.Line` uses. It places the gap among the lines
      and events of its step when the report sorts them by time.

  A gap exists only when the cap dropped at least one line. An attempt that
  logged nothing leaves no gap behind it.
  """

  @type t :: %__MODULE__{
          attempts: pos_integer(),
          lines: pos_integer(),
          timestamp: integer()
        }

  @enforce_keys [:attempts, :lines, :timestamp]
  defstruct [:attempts, :lines, :timestamp]
end
