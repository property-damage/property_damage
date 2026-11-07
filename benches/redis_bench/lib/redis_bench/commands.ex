defmodule RedisBench.Events do
  @moduledoc "Events describing what happened against the Redis register."

  defmodule Incremented do
    @moduledoc """
    The register was atomically incremented from `from` to `to`.

    `INCR` returns only the new value; `from` is `to - 1` because the operation
    is atomic +1.
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
  use PropertyDamage.Command

  defstruct []

  @impl true
  def generator(_overrides \\ %{}), do: StreamData.constant(%{})
end

defmodule RedisBench.Commands.ReadValue do
  @moduledoc "Read the register (`GET`); the model asserts the value is consistent."
  use PropertyDamage.Command

  defstruct []

  @impl true
  def generator(_overrides \\ %{}), do: StreamData.constant(%{})
end
