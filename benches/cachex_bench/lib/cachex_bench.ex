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

  # Every Cachex call logs one entry after it returns (`PropertyDamage.log/2`,
  # tag :cache): the operation, then what Cachex answered, so a failure report
  # shows the cache calls under each step.
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
    # The name changes every run, so it goes below the summary.
    PropertyDamage.log("start cache -> ok\nname:\n  #{inspect(name)}", tags: [:cache])
    {:ok, %{cache: name, incr_bug: Map.get(config || %{}, :incr_bug, false)}}
  end

  @impl true
  def teardown(%{cache: cache}) do
    outcome =
      case Process.whereis(cache) do
        nil ->
          "not running"

        pid ->
          Supervisor.stop(pid, :normal)
          "ok"
      end

    PropertyDamage.log("stop cache -> #{outcome}\nname:\n  #{inspect(cache)}", tags: [:cache])
    :ok
  end

  @impl true
  def execute(%PutKey{key: key, value: value}, %{cache: cache}, _runtime) do
    {:ok, true} = Cachex.put(cache, key, value)
    PropertyDamage.log("put #{inspect(key)} #{inspect(value)} -> ok", tags: [:cache])
    {:ok, [%EntryPut{key: key, value: value}]}
  end

  def execute(%GetKey{key: key}, %{cache: cache}, _runtime) do
    {:ok, value} = Cachex.get(cache, key)
    PropertyDamage.log("get #{inspect(key)} -> #{inspect(value)}", tags: [:cache])
    {:ok, [%EntryRead{key: key, value: value}]}
  end

  def execute(%DelKey{key: key}, %{cache: cache}, _runtime) do
    {:ok, _existed?} = Cachex.del(cache, key)
    PropertyDamage.log("del #{inspect(key)} -> ok", tags: [:cache])
    {:ok, [%EntryDeleted{key: key}]}
  end

  def execute(%ClearCache{}, %{cache: cache}, _runtime) do
    {:ok, count} = Cachex.clear(cache)
    PropertyDamage.log("clear -> #{count} removed", tags: [:cache])
    {:ok, [%CacheCleared{}]}
  end

  def execute(%Incr{key: key, amount: amount}, %{cache: cache} = ctx, _runtime) do
    applied = if ctx[:incr_bug] && amount < 3, do: amount + 1, else: amount
    {:ok, value} = Cachex.incr(cache, key, applied)
    PropertyDamage.log("incr #{inspect(key)} by #{applied} -> #{value}", tags: [:cache])
    {:ok, [%EntryIncremented{key: key, amount: applied, value: value}]}
  end
end
