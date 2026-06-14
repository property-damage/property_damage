defmodule RedisBench do
  @moduledoc """
  PropertyDamage exercised against [Redis](https://redis.io) over the network:
  the external-SUT + fault-injection rung of the bench ladder.

  This is the first out-of-BEAM, network-attached SUT (6a/6c were in-process,
  6b was Postgres-via-Ecto). The SUT is a Redis-backed atomic register: `INCR`
  is atomic and linearizable on a single instance, so a faithful adapter is
  always linearizable. That is the same canonical register as the 6c ETS bench,
  but reached over a real socket, so the connection can be routed through
  [Toxiproxy](https://github.com/Shopify/toxiproxy) and degraded with latency,
  packet-loss and partition toxics to test consistency under faults.

  See `RedisBench.Conn` for endpoint resolution.
  """

  @doc "Direct Redis connection options (baseline, no faults)."
  def redis_url, do: Application.fetch_env!(:redis_bench, :redis_url)
end

defmodule RedisBench.Conn do
  @moduledoc """
  Resolves Redis connection options and opens short-lived Redix connections.

  Two endpoints:

    * `start_direct/0` connects straight to Redis (baseline suites).
    * `start_through_proxy/0` connects through Toxiproxy, so the fault suites
      can add toxics on the proxy and observe the SUT degrade.

  Each connection is owned by one PropertyDamage run's adapter context and
  closed in `teardown/1`.
  """

  @doc "Open a Redix connection straight to Redis."
  def start_direct do
    Redix.start_link(RedisBench.redis_url())
  end

  @doc "Open a Redix connection to Redis through the Toxiproxy proxy."
  def start_through_proxy do
    host = Application.fetch_env!(:redis_bench, :redis_proxy_host)
    port = Application.fetch_env!(:redis_bench, :redis_proxy_port)
    Redix.start_link(host: host, port: port)
  end

  @doc """
  A run key namespace unique across the whole Redis lifetime.

  Must be globally unique, not just per-VM: the container outlives a single
  `mix` invocation, so a bare `System.unique_integer` (which resets each OS
  process) would collide with keys left by an earlier run. Mirrors the Oban
  bench's `run_id`.
  """
  def run_key do
    "pd:#{System.system_time(:nanosecond)}:#{System.unique_integer([:positive])}"
  end
end
