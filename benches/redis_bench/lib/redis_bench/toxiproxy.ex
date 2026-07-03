defmodule RedisBench.Toxiproxy do
  @moduledoc """
  Thin client for the [Toxiproxy](https://github.com/Shopify/toxiproxy) control
  API, used to inject real network faults in front of Redis.

  Toxiproxy sits between the bench and Redis: the app connects through the proxy
  (`RedisBench.Conn.start_through_proxy/0`), and toxics added here degrade that
  connection for real (latency, bandwidth throttling, partition). That makes
  this module the live oracle for the nemesis audit: a fault is REAL only if the
  SUT's observable behavior (round-trip time, connectivity) changes when it is
  injected.

  All calls hit the control API resolved from config (`:toxiproxy_url`). The
  proxy is named `"redis"` and forwards `:redis_proxy_port` to `:redis_upstream`.
  """

  @proxy "redis"

  @doc "The proxy name this module manages."
  def proxy_name, do: @proxy

  @doc "Control-API base URL (e.g. http://localhost:8474)."
  def api_url, do: Application.fetch_env!(:redis_bench, :toxiproxy_url)

  @doc """
  Idempotently (re)create the Redis proxy and clear any leftover toxics.

  Uses `/populate`, which creates the proxy if absent or updates it in place,
  then `/reset` to remove all toxics and re-enable it. Safe to call before every
  fault test.
  """
  def ensure_clean_proxy do
    port = Application.fetch_env!(:redis_bench, :redis_proxy_port)
    upstream = Application.fetch_env!(:redis_bench, :redis_upstream)

    body = [
      %{
        name: @proxy,
        listen: "0.0.0.0:#{port}",
        upstream: upstream,
        enabled: true
      }
    ]

    {:ok, _} = post("/populate", body)
    {:ok, _} = post("/reset", %{})
    :ok
  end

  @doc """
  Add a toxic to the proxy.

    * `:type` - e.g. `"latency"`, `"bandwidth"`, `"timeout"`
    * `:stream` - `"downstream"` (default) or `"upstream"`
    * `:attributes` - toxic-specific map (e.g. `%{latency: 300}`)
  """
  def add_toxic(name, type, attributes, stream \\ "downstream") do
    body = %{name: name, type: type, stream: stream, attributes: attributes}
    post("/proxies/#{@proxy}/toxics", body)
  end

  @doc "Remove a previously added toxic by name."
  def remove_toxic(name) do
    delete("/proxies/#{@proxy}/toxics/#{name}")
  end

  @doc "List the toxics currently installed on the proxy (decoded JSON list)."
  def list_toxics do
    case get("/proxies/#{@proxy}/toxics") do
      {:ok, body} -> {:ok, Jason.decode!(body)}
      other -> other
    end
  end

  @doc "Enable or disable the whole proxy (disabled = full partition)."
  def set_enabled(enabled?) when is_boolean(enabled?) do
    post("/proxies/#{@proxy}", %{enabled: enabled?})
  end

  @doc """
  Time a single round-trip (`PING`) through the proxy, in milliseconds.

  Returns `{:ok, ms}` on success or `{:error, reason}` if the proxied
  connection cannot complete the command (e.g. during a partition). This is the
  differential probe: it measures the SUT's observable behavior so a toxic can
  be proven real.
  """
  def probe_ping_ms(timeout_ms \\ 2000) do
    case RedisBench.Conn.start_through_proxy() do
      {:ok, conn} ->
        try do
          {elapsed, result} =
            :timer.tc(fn -> Redix.command(conn, ["PING"], timeout: timeout_ms) end)

          case result do
            {:ok, "PONG"} -> {:ok, div(elapsed, 1000)}
            {:error, reason} -> {:error, reason}
          end
        after
          Redix.stop(conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- HTTP helpers (Toxiproxy control API) --------------------------------

  defp post(path, body) do
    request(:post, path, body)
  end

  defp delete(path) do
    request(:delete, path, nil)
  end

  defp get(path) do
    request(:get, path, nil)
  end

  defp request(method, path, body) do
    url = String.to_charlist(api_url() <> path)

    req =
      case method do
        m when m in [:delete, :get] -> {url, []}
        _ -> {url, [], ~c"application/json", Jason.encode!(body)}
      end

    case :httpc.request(method, req, [{:timeout, 5000}], []) do
      {:ok, {{_, status, _}, _, resp}} when status in 200..299 ->
        {:ok, resp}

      {:ok, {{_, status, _}, _, resp}} ->
        {:error, {:http_error, status, to_string(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
