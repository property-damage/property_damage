defmodule RedisBench.ProxyAdapter do
  @moduledoc """
  Drives the Redis register through the Toxiproxy proxy instead of connecting to
  Redis directly. Functionally identical to `RedisBench.Adapter` when no toxics
  are active, but every command's bytes pass through the proxy, so faults added
  via `RedisBench.Toxiproxy` degrade it for real.

  Connection failures (e.g. during a partition) are reported honestly as
  `{:error, {:redis_unavailable, reason}}` so PropertyDamage surfaces the fault
  as an adapter/connection error, never as a false consistency violation.
  """
  use PropertyDamage.Adapter

  alias RedisBench.Commands.{Increment, ReadValue}
  alias RedisBench.Conn
  alias RedisBench.Events.{Incremented, ValueRead}

  @command_timeout 1500

  @impl true
  def setup(_config) do
    {:ok, conn} = Conn.start_through_proxy()
    {:ok, %{conn: conn, key: Conn.run_key()}}
  end

  @impl true
  def teardown(%{conn: conn}) do
    Redix.stop(conn)
    :ok
  end

  @impl true
  def execute(%Increment{}, %{conn: conn, key: key}, _runtime) do
    case Redix.command(conn, ["INCR", key], timeout: @command_timeout) do
      {:ok, to} -> {:ok, [%Incremented{from: to - 1, to: to}]}
      {:error, reason} -> {:error, {:redis_unavailable, reason}}
    end
  end

  def execute(%ReadValue{}, %{conn: conn, key: key}, _runtime) do
    case Redix.command(conn, ["GET", key], timeout: @command_timeout) do
      {:ok, raw} -> {:ok, [%ValueRead{value: RedisBench.Adapter.to_int(raw)}]}
      {:error, reason} -> {:error, {:redis_unavailable, reason}}
    end
  end
end
