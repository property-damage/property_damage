defmodule OpenapiBench.Store do
  @moduledoc """
  The in-memory state behind the KV HTTP API: a single Agent holding the
  key/value map, a `bug` flag, and (for the idempotency bench) a create-log
  keyed by an `Idempotency-Key`.

  The `bug` flag is what makes this SUT seedable for non-vacuity. When it is
  set, `PUT /kv/{key}` still answers `200` with the requested value (it *looks*
  like the write succeeded) but silently drops the write, so a later
  `GET /kv/{key}` returns `404`. That is a read-consistency violation the
  generated PropertyDamage suite must catch and shrink. With the flag clear the
  store is a faithful register.

  `POST /values` is a genuinely non-idempotent create: each call mints a fresh
  server-assigned id. To make retries safe it honors an `Idempotency-Key`
  header, returning the original id for a repeated key. The `idempotency_bug`
  flag makes it ignore the key, so a stutter retry double-creates: exactly the
  idempotency violation the framework's stutter testing must catch.

  State is reset between PropertyDamage sequences via `POST /__reset__` (the
  model's `setup_each/1` calls it), so runs never share state.
  """
  use Agent

  @name __MODULE__

  def start_link(_opts) do
    Agent.start_link(fn -> fresh_state(false, false) end, name: @name)
  end

  @doc """
  Clear all state and set the seeded-bug flags for the next sequence.

  `bug` seeds the dropped-write read-consistency bug; `idempotency_bug` seeds
  the ignored-Idempotency-Key double-create bug.
  """
  def reset(bug \\ false, idempotency_bug \\ false) do
    Agent.update(@name, fn _ -> fresh_state(bug, idempotency_bug) end)
  end

  defp fresh_state(bug, idempotency_bug) do
    %{
      data: %{},
      bug: bug,
      idempotency_bug: idempotency_bug,
      created: %{},
      idem_keys: %{},
      next_id: 1
    }
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

  @doc """
  Create a value, returning `%{id: id, value: value}` with a server-assigned id.

  With `idempotency_bug` clear, a non-nil `idempotency_key` already seen returns
  the original id (retry-safe). With it set, the key is ignored and every call
  mints a new id, so a stutter retry double-creates.
  """
  def create(value, idempotency_key) do
    Agent.get_and_update(@name, fn state ->
      if not state.idempotency_bug and not is_nil(idempotency_key) and
           Map.has_key?(state.idem_keys, idempotency_key) do
        id = state.idem_keys[idempotency_key]
        {%{id: id, value: Map.fetch!(state.created, id)}, state}
      else
        id = state.next_id

        idem_keys =
          if is_nil(idempotency_key),
            do: state.idem_keys,
            else: Map.put(state.idem_keys, idempotency_key, id)

        state = %{
          state
          | next_id: id + 1,
            created: Map.put(state.created, id, value),
            idem_keys: idem_keys
        }

        {%{id: id, value: value}, state}
      end
    end)
  end
end
