defmodule Corpus.Store do
  @moduledoc """
  A small key-value store with delete.

  Started with `bug: nil` it behaves as a map. With `bug: :noop_delete`
  `delete/2` answers success and changes nothing, and the store records that
  in the fire log.
  """

  use Agent

  alias PropertyDamage.Corpus.FireLog

  @doc "Starts an empty store. Options: `:bug` (default `nil`) and `:fire_log`."
  def start(opts) do
    log = Keyword.get(opts, :fire_log)
    instance = FireLog.started(log)

    Agent.start_link(fn ->
      %{bug: Keyword.get(opts, :bug), log: log, instance: instance, entries: %{}}
    end)
  end

  @doc "Stops the store."
  def stop(store), do: Agent.stop(store)

  @doc "Stores `value` under `key`."
  def put(store, key, value) do
    Agent.update(store, fn state -> %{state | entries: Map.put(state.entries, key, value)} end)
  end

  @doc "The value under `key`, or `nil`."
  def get(store, key), do: Agent.get(store, &Map.get(&1.entries, key))

  @doc "Removes `key`, or with the bug on, answers success and removes nothing."
  def delete(store, key) do
    Agent.update(store, fn
      %{bug: :noop_delete, log: log, instance: instance} = state ->
        FireLog.fired(log, instance)
        state

      state ->
        %{state | entries: Map.delete(state.entries, key)}
    end)
  end
end
