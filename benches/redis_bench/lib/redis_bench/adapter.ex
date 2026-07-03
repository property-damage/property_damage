defmodule RedisBench.Adapter do
  @moduledoc """
  Faithfully drives the Redis register over a direct connection (no faults).

  Each run gets its own Redix connection and a globally-unique key, so
  concurrent PropertyDamage runs never share register state. `INCR` is atomic,
  so this adapter is always linearizable.
  """
  use PropertyDamage.Adapter

  alias RedisBench.Commands.{GetThenSet, Increment, ReadValue}
  alias RedisBench.Conn
  alias RedisBench.Events.{Incremented, ValueRead, Written}

  @impl true
  def setup(_config) do
    {:ok, conn} = Conn.start_direct()
    {:ok, %{conn: conn, key: Conn.run_key()}}
  end

  @impl true
  def teardown(%{conn: conn}) do
    Redix.stop(conn)
    :ok
  end

  @impl true
  def execute(%Increment{}, %{conn: conn, key: key}, _runtime) do
    {:ok, to} = Redix.command(conn, ["INCR", key])
    {:ok, [%Incremented{from: to - 1, to: to}]}
  end

  def execute(%GetThenSet{}, %{conn: conn, key: key}, _runtime) do
    # Non-atomic read-modify-write: GET the value, compute +1, SET it back. The
    # executor runs branches one after another over this single connection, so
    # each GetThenSet observes the previous one's write -- a faithful RMW is
    # therefore always linearizable. (A lost update requires an adapter that
    # reports a stale read; see the parallel_linearization test's
    # LostUpdateAdapter.)
    {:ok, raw} = Redix.command(conn, ["GET", key])
    from = to_int(raw)
    to = from + 1
    {:ok, _} = Redix.command(conn, ["SET", key, Integer.to_string(to)])
    {:ok, [%Written{from: from, to: to}]}
  end

  def execute(%ReadValue{}, %{conn: conn, key: key}, _runtime) do
    {:ok, raw} = Redix.command(conn, ["GET", key])
    {:ok, [%ValueRead{value: to_int(raw)}]}
  end

  @doc "Redis returns counter values as strings; nil means the key is unset."
  def to_int(nil), do: 0
  def to_int(value) when is_binary(value), do: String.to_integer(value)
end
