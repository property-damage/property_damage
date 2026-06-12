defmodule CachexBench do
  @moduledoc """
  PropertyDamage bench against Cachex (real third-party software).

  Validates the core PD loop end to end: generation, simulation,
  execution via an adapter, projection updates, and invariant checks,
  with automatic shrinking on failure.
  """

  @keys [:alpha, :bravo, :charlie, :delta, :echo, :foxtrot]

  def keys, do: @keys
end

defmodule CachexBench.Adapter do
  @moduledoc "Executes cache commands against a real Cachex instance."
  use PropertyDamage.Adapter

  alias CachexBench.Commands.{ClearCache, DelKey, GetKey, PutKey}
  alias CachexBench.Events.{CacheCleared, EntryDeleted, EntryPut, EntryRead}

  @impl true
  def setup(_config) do
    # A fresh, uniquely named cache per run keeps runs isolated
    name = :"cachex_bench_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Cachex.start_link(name)
    {:ok, %{cache: name}}
  end

  @impl true
  def teardown(%{cache: cache}) do
    case Process.whereis(cache) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal)
    end

    :ok
  end

  @impl true
  def execute(%PutKey{key: key, value: value}, %{cache: cache}) do
    {:ok, true} = Cachex.put(cache, key, value)
    {:ok, [%EntryPut{key: key, value: value}]}
  end

  def execute(%GetKey{key: key}, %{cache: cache}) do
    {:ok, value} = Cachex.get(cache, key)
    {:ok, [%EntryRead{key: key, value: value}]}
  end

  def execute(%DelKey{key: key}, %{cache: cache}) do
    {:ok, _existed?} = Cachex.del(cache, key)
    {:ok, [%EntryDeleted{key: key}]}
  end

  def execute(%ClearCache{}, %{cache: cache}) do
    {:ok, _count} = Cachex.clear(cache)
    {:ok, [%CacheCleared{}]}
  end
end
