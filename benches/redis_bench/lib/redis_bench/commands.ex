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
