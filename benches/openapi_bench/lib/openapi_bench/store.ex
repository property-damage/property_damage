defmodule OpenapiBench.Store do
  @moduledoc """
  The in-memory state behind the KV HTTP API: a single Agent holding the
  key/value map and a `bug` flag.

  The `bug` flag is what makes this SUT seedable for non-vacuity. When it is
  set, `PUT /kv/{key}` still answers `200` with the requested value (it *looks*
  like the write succeeded) but silently drops the write, so a later
  `GET /kv/{key}` returns `404`. That is a read-consistency violation the
  generated PropertyDamage suite must catch and shrink. With the flag clear the
  store is a faithful register.

  State is reset between PropertyDamage sequences via `POST /__reset__` (the
  model's `setup_each/1` calls it), so runs never share key/value state.
  """
  use Agent

  @name __MODULE__

  def start_link(_opts) do
    Agent.start_link(fn -> %{data: %{}, bug: false} end, name: @name)
  end

  @doc "Clear all keys and set the `bug` flag for the next sequence."
  def reset(bug \\ false) do
    Agent.update(@name, fn _ -> %{data: %{}, bug: bug} end)
  end

  @doc """
  Store `value` under `key`.

  Returns the value the API will echo back (always the requested value, so a
  buggy no-op write is indistinguishable from a real one on the write path).
  Under the `bug` flag the write is dropped.
  """
  def put(key, value) do
    Agent.update(@name, fn
      %{bug: true} = state -> state
      %{data: data} = state -> %{state | data: Map.put(data, key, value)}
    end)

    value
  end

  @doc "Fetch the value for `key`, or `:error` when absent."
  def get(key) do
    Agent.get(@name, fn %{data: data} -> Map.fetch(data, key) end)
  end
end
