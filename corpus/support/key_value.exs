defmodule Corpus.KeyValue do
  @moduledoc """
  A small key-value store.

  Started with `bug: nil` it stores every value. With `bug: :rejected_set` a
  `set/3` of an empty string is rejected, and the store records that in the
  fire log.
  """

  use Agent

  alias PropertyDamage.Corpus.FireLog

  @doc "Starts a store. Options: `:bug` (default `nil`) and `:fire_log`."
  def start(opts) do
    log = Keyword.get(opts, :fire_log)
    instance = FireLog.started(log)

    Agent.start_link(fn ->
      %{bug: Keyword.get(opts, :bug), log: log, instance: instance, entries: %{}}
    end)
  end

  @doc "Stops the store."
  def stop(store), do: Agent.stop(store)

  @doc "Stores `value` under `key`; returns `:ok` or `{:error, :rejected}`."
  def set(store, key, value) do
    Agent.get_and_update(store, fn
      %{bug: :rejected_set, log: log, instance: instance} = state when value == "" ->
        FireLog.fired(log, instance)
        {{:error, :rejected}, state}

      state ->
        {:ok, %{state | entries: Map.put(state.entries, key, value)}}
    end)
  end

  @doc "The value under `key`, or `nil`."
  def get(store, key), do: Agent.get(store, &Map.get(&1.entries, key))
end
