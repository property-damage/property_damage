defmodule CachexBench.Events do
  @moduledoc "Events describing what happened against the cache."

  defmodule EntryPut do
    defstruct [:key, :value]
  end

  defmodule EntryDeleted do
    defstruct [:key]
  end

  defmodule EntryRead do
    # value is what the SUT actually returned (nil when absent)
    defstruct [:key, :value]
  end

  defmodule CacheCleared do
    defstruct []
  end
end

defmodule CachexBench.Commands.PutKey do
  @moduledoc "Write a value under a key."
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:key, :value]

  @impl true
  def generator(overrides \\ %{}) do
    %{
      key: StreamData.member_of(CachexBench.keys()),
      value: StreamData.integer(0..1_000)
    }
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule CachexBench.Commands.GetKey do
  @moduledoc "Read a key; the model asserts the returned value matches expectation."
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:key]

  @impl true
  def generator(overrides \\ %{}) do
    %{key: StreamData.member_of(CachexBench.keys())}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule CachexBench.Commands.DelKey do
  @moduledoc "Delete a key (idempotent: deleting an absent key is fine)."
  @behaviour PropertyDamage.Command

  import PropertyDamage.Generator, only: [merge_overrides: 2]

  defstruct [:key]

  @impl true
  def generator(overrides \\ %{}) do
    %{key: StreamData.member_of(CachexBench.keys())}
    |> merge_overrides(overrides)
    |> StreamData.fixed_map()
  end
end

defmodule CachexBench.Commands.ClearCache do
  @moduledoc "Wipe the whole cache."
  @behaviour PropertyDamage.Command

  defstruct []

  @impl true
  def generator(_overrides \\ %{}) do
    StreamData.constant(%{})
  end
end
