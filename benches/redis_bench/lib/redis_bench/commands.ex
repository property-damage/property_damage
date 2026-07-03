defmodule RedisBench.Events do
  @moduledoc "Events describing what happened against the Redis register."

  defmodule Incremented do
    @moduledoc """
    The register was atomically incremented from `from` to `to`.

    `INCR` returns only the new value; `from` is `to - 1` because the operation
    is atomic +1. The value-carrying pair lets the linearization checker refute
    lost updates on events alone (two concurrent increments both claiming the
    same `from` have no serialization).
    """
    defstruct [:from, :to]
  end

  defmodule ValueRead do
    @moduledoc "A `GET` observed the register holding `value`."
    defstruct [:value]
  end

  defmodule Written do
    @moduledoc """
    A non-atomic read-modify-write moved the register from `from` to `to`.

    Emitted by `GetThenSet`: the client `GET`s `from`, computes `from + 1`, and
    `SET`s `to`. Unlike `Incremented` (which `INCR` produces atomically), the two
    steps are separate round-trips, so a faithful `to` is always `from + 1` but
    two concurrent read-modify-writes can both observe the same `from` and both
    write the same `to` -- the classic lost update. The value-carrying pair lets
    the linearization checker refute that on the write events alone: two `Written`
    both claiming `from: 0` have no sequential explanation.
    """
    defstruct [:from, :to]
  end
end

defmodule RedisBench.Commands.Increment do
  @moduledoc "Atomically increment the register (`INCR`)."
  @behaviour PropertyDamage.Command

  defstruct []

  @impl true
  def generator(_overrides \\ %{}), do: StreamData.constant(%{})
end

defmodule RedisBench.Commands.ReadValue do
  @moduledoc "Read the register (`GET`); the model asserts the value is consistent."
  @behaviour PropertyDamage.Command

  defstruct []

  @impl true
  def read_only?, do: true

  @impl true
  def generator(_overrides \\ %{}), do: StreamData.constant(%{})
end

defmodule RedisBench.Commands.GetThenSet do
  @moduledoc """
  Non-atomically increment the register: `GET` the value, compute `+1`, `SET` it.

  This is the deliberately racy contrast to `Increment`. `INCR` is atomic and
  linearizable, so it can never lose an update; a `GET`-then-`SET` is two
  separate round-trips, so concurrent read-modify-writes over separate
  connections can both read the same value and both write the same result,
  losing one update. This is the command whose branches the linearization
  checker refutes when the race bites.
  """
  @behaviour PropertyDamage.Command

  defstruct []

  @impl true
  def generator(_overrides \\ %{}), do: StreamData.constant(%{})
end
