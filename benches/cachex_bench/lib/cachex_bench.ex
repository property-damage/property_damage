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
  require PropertyDamage

  alias CachexBench.Commands.{ClearCache, DelKey, GetKey, Incr, PutKey}
  alias CachexBench.Events.{CacheCleared, EntryDeleted, EntryIncremented, EntryPut, EntryRead}

  # Every call logs what it sent to Cachex and what came back
  # (`PropertyDamage.log/2`), under the tag :cache and the operation's own
  # tag, so a failure report shows the cache calls under each step.
  #
  # Config keys (all optional):
  #
  #   :incr_bug  true plants a bug: an Incr below 3 adds one too much, so a
  #              target that runs `Incr k n` as two smaller increments diverges
  #              from one that runs it as itself (default false)
  @impl true
  def setup(config) do
    # A fresh, uniquely named cache per run keeps runs isolated
    name = :"cachex_bench_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Cachex.start_link(name)
    PropertyDamage.log("started cache #{inspect(name)}", tags: [:cache, :setup])
    {:ok, %{cache: name, incr_bug: Map.get(config || %{}, :incr_bug, false)}}
  end

  @impl true
  def teardown(%{cache: cache}) do
    PropertyDamage.log("stopping cache #{inspect(cache)}", tags: [:cache, :teardown])

    case Process.whereis(cache) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal)
    end

    :ok
  end

  @impl true
  def execute(%PutKey{key: key, value: value}, %{cache: cache}, _runtime) do
    PropertyDamage.log("put #{inspect(key)} #{inspect(value)}", tags: [:cache, :put])
    {:ok, true} = Cachex.put(cache, key, value)
    {:ok, [%EntryPut{key: key, value: value}]}
  end

  def execute(%GetKey{key: key}, %{cache: cache}, _runtime) do
    {:ok, value} = Cachex.get(cache, key)
    PropertyDamage.log("get #{inspect(key)} -> #{inspect(value)}", tags: [:cache, :get])
    {:ok, [%EntryRead{key: key, value: value}]}
  end

  def execute(%DelKey{key: key}, %{cache: cache}, _runtime) do
    PropertyDamage.log("del #{inspect(key)}", tags: [:cache, :del])
    {:ok, _existed?} = Cachex.del(cache, key)
    {:ok, [%EntryDeleted{key: key}]}
  end

  def execute(%ClearCache{}, %{cache: cache}, _runtime) do
    {:ok, count} = Cachex.clear(cache)
    PropertyDamage.log("clear -> #{count} removed", tags: [:cache, :clear])
    {:ok, [%CacheCleared{}]}
  end

  def execute(%Incr{key: key, amount: amount}, %{cache: cache} = ctx, _runtime) do
    applied = if ctx[:incr_bug] && amount < 3, do: amount + 1, else: amount
    PropertyDamage.log("incr #{inspect(key)} by #{applied}", tags: [:cache, :incr])
    {:ok, value} = Cachex.incr(cache, key, applied)
    PropertyDamage.log("incr #{inspect(key)} -> #{value}", tags: [:cache, :incr])
    {:ok, [%EntryIncremented{key: key, amount: applied, value: value}]}
  end
end
